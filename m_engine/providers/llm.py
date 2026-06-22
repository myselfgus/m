"""
M-Engine — Bloco ÚNICO de chamadas a LLM.

Toda chamada a modelo no pipeline passa por aqui. Sem Cloudflare Gateway.
Roteia por provider direto:
  - anthropic → SDK Anthropic (Messages API, prompt caching nativo, continuação)
  - xai/deepseek → SDK OpenAI apontando para a baseURL do provider (chat.completions)

Expõe:
  - complete(...)        -> CompletionResult (texto)
  - complete_json(...)   -> instância de um modelo pydantic (valida + 1 repair)
  - extract_json(...)    -> dict, parse ESTRITO (sem alterar conteúdo; raise em falha)

Default de modelo: config.resolve_model(None) == Claude Opus 4.8.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import TypeVar

import structlog
from pydantic import BaseModel, ValidationError
from tenacity import retry, retry_if_exception, stop_after_attempt, wait_exponential

from m_engine.config import ModelSpec, get_settings, resolve_model

log = structlog.get_logger("m_engine.llm")

T = TypeVar("T", bound=BaseModel)

# ---------------------------------------------------------------------------
# Clientes (lazy)
# ---------------------------------------------------------------------------


@lru_cache
def _anthropic():
    import anthropic

    s = get_settings()
    if not s.anthropic_api_key:
        raise RuntimeError("ANTHROPIC_API_KEY ausente.")
    return anthropic.Anthropic(api_key=s.anthropic_api_key)


@lru_cache
def _openai_compat(provider: str):
    from openai import OpenAI

    s = get_settings()
    if provider == "xai":
        if not s.xai_api_key:
            raise RuntimeError("XAI_API_KEY ausente.")
        return OpenAI(api_key=s.xai_api_key, base_url="https://api.x.ai/v1")
    if provider == "deepseek":
        if not s.deepseek_api_key:
            raise RuntimeError("DEEPSEEK_API_KEY ausente.")
        return OpenAI(api_key=s.deepseek_api_key, base_url="https://api.deepseek.com")
    raise ValueError(f"Provider OpenAI-compat desconhecido: {provider}")


# ---------------------------------------------------------------------------
# Tipos
# ---------------------------------------------------------------------------


@dataclass
class SystemBlock:
    """Bloco de system prompt. cache=True ativa cache_control ephemeral (Anthropic)."""

    text: str
    cache: bool = False


@dataclass
class Usage:
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0

    @property
    def total(self) -> int:
        return self.input + self.output


@dataclass
class CompletionResult:
    content: str
    usage: Usage = field(default_factory=Usage)
    model: str = ""
    provider: str = ""
    continuations: int = 0


# ---------------------------------------------------------------------------
# Retry
# ---------------------------------------------------------------------------


def _is_retryable(exc: BaseException) -> bool:
    status = getattr(exc, "status_code", None) or getattr(exc, "status", None)
    if status == 429 or (isinstance(status, int) and status >= 500):
        return True
    name = type(exc).__name__
    return name in {"APIConnectionError", "APITimeoutError", "RateLimitError", "InternalServerError"}


_retry = retry(
    retry=retry_if_exception(_is_retryable),
    wait=wait_exponential(multiplier=2, min=2, max=60),
    stop=stop_after_attempt(3),
    reraise=True,
)


# ---------------------------------------------------------------------------
# Normalização de system prompt
# ---------------------------------------------------------------------------


def _as_blocks(system: str | list[SystemBlock]) -> list[SystemBlock]:
    if isinstance(system, str):
        return [SystemBlock(system)]
    return system


# ---------------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------------


def complete(
    *,
    system: str | list[SystemBlock],
    user: str,
    model: str | None = None,
    max_tokens: int | None = None,
    temperature: float = 0.0,
    cache: bool = True,
    timeout: float = 1200.0,
    max_continuations: int = 5,
) -> CompletionResult:
    """
    Chamada de completion unificada. `model` é um alias (config.MODELS);
    None usa o default (Claude Opus 4.8). Continua automaticamente em truncamento.
    """
    spec = resolve_model(model)
    blocks = _as_blocks(system)
    out_tokens = max_tokens or spec.max_output_tokens

    if spec.provider == "anthropic":
        return _complete_anthropic(spec, blocks, user, out_tokens, temperature, cache, timeout, max_continuations)
    if spec.provider == "claude_cli":
        return _complete_claude_cli(spec, blocks, user, timeout)
    return _complete_openai_compat(spec, blocks, user, out_tokens, temperature, timeout, max_continuations)


@_retry
def _complete_anthropic(spec, blocks, user, max_tokens, temperature, cache, timeout, max_cont) -> CompletionResult:
    client = _anthropic()
    system_param = [
        (
            {"type": "text", "text": b.text, "cache_control": {"type": "ephemeral"}}
            if (cache and b.cache)
            else {"type": "text", "text": b.text}
        )
        for b in blocks
    ]
    messages = [{"role": "user", "content": user}]
    content, usage, cont = "", Usage(), 0

    # Opus 4.8 / Sonnet 4.6: adaptive thinking; sampling params (temperature/top_p/top_k)
    # foram REMOVIDOS nesta família (400 se enviados) — por isso `temperature` é ignorado aqui.
    # Saída em STREAMING (obrigatório para max_tokens grande, ex. 128K, sem timeout do SDK).
    sized = client.with_options(timeout=timeout)

    while True:
        with sized.messages.stream(
            model=spec.id,
            max_tokens=max_tokens,
            system=system_param,
            messages=messages,
            thinking={"type": "adaptive"},
        ) as stream:
            resp = stream.get_final_message()

        text = "".join(b.text for b in resp.content if getattr(b, "type", None) == "text")
        content += text
        u = resp.usage
        usage.input += getattr(u, "input_tokens", 0) or 0
        usage.output += getattr(u, "output_tokens", 0) or 0
        usage.cache_read += getattr(u, "cache_read_input_tokens", 0) or 0
        usage.cache_write += getattr(u, "cache_creation_input_tokens", 0) or 0

        if resp.stop_reason == "max_tokens":
            if cont >= max_cont:
                # Ainda truncado após o limite de continuações → ERRO (não devolver parcial).
                raise RuntimeError(f"Saída truncada após {max_cont} continuações (anthropic {spec.id}).")
            cont += 1
            # Echo do conteúdo COMPLETO (inclui thinking blocks) — exigido para continuar
            # na mesma sessão com adaptive thinking; passar só o texto quebraria a sequência.
            messages.append({"role": "assistant", "content": resp.content})
            messages.append({"role": "user", "content": "Continue exatamente de onde parou, sem repetir o que já escreveu."})
            continue
        break

    return CompletionResult(content, usage, spec.id, spec.provider, cont)


@_retry
def _complete_openai_compat(spec, blocks, user, max_tokens, temperature, timeout, max_cont) -> CompletionResult:
    client = _openai_compat(spec.provider)
    system_text = "\n\n".join(b.text for b in blocks)  # OpenAI-compat: system único, sem cache_control
    messages = [{"role": "system", "content": system_text}, {"role": "user", "content": user}]
    content, usage, cont = "", Usage(), 0

    while True:
        resp = client.chat.completions.create(
            model=spec.id, max_tokens=max_tokens, temperature=temperature, messages=messages, timeout=timeout
        )
        choice = resp.choices[0]
        text = choice.message.content or ""
        content += text
        if resp.usage:
            usage.input += resp.usage.prompt_tokens or 0
            usage.output += resp.usage.completion_tokens or 0

        if choice.finish_reason == "length":
            if cont >= max_cont:
                raise RuntimeError(f"Saída truncada após {max_cont} continuações ({spec.provider} {spec.id}).")
            cont += 1
            messages.append({"role": "assistant", "content": text})
            messages.append({"role": "user", "content": "Continue exatamente de onde parou, sem repetir o que já escreveu."})
            continue
        break

    return CompletionResult(content, usage, spec.id, spec.provider, cont)


def _complete_claude_cli(spec, blocks, user, timeout) -> CompletionResult:
    """
    Provider via subprocess do CLI Claude Code (`claude -p`), reaproveitando a AUTH
    DO SISTEMA (sessão logada / OAuth / keychain) — alternativa à API key direta.

    Notas:
      - System prompt vai por --system-prompt-file (substitui o default do CC; robusto
        contra ARG_MAX para prompts grandes). User prompt vai por stdin.
      - --output-format json devolve {result, usage, total_cost_usd, ...}.
      - NÃO usar --bare (forçaria API key e ignoraria OAuth/keychain).
      - temperature/max_tokens não são expostos pelo CLI → ignorados neste transporte.
      - cwd isolado (tempdir) evita herdar CLAUDE.md/projeto.
    """
    settings = get_settings()
    system_text = "\n\n".join(b.text for b in blocks)

    with tempfile.TemporaryDirectory() as tmp:
        sys_path = os.path.join(tmp, "system.txt")
        Path(sys_path).write_text(system_text, encoding="utf-8")
        cmd = [
            settings.m_claude_cli_bin, "-p",
            "--model", spec.id,
            "--system-prompt-file", sys_path,
            "--output-format", "json",
            "--no-session-persistence",
        ]
        try:
            proc = subprocess.run(
                cmd, input=user, capture_output=True, text=True,
                timeout=timeout, cwd=tmp, env=os.environ.copy(),
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"claude CLI timeout após {timeout}s") from exc

    if proc.returncode != 0:
        raise RuntimeError(f"claude CLI falhou (exit {proc.returncode}): {proc.stderr[:500]}")

    out = (proc.stdout or "").strip()
    # --output-format json DEVE devolver JSON com a chave "result". Saída fora disso
    # é erro (NÃO usar stdout cru como se fosse a resposta — degradação silenciosa).
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"claude CLI: saída não-JSON com --output-format json: {out[:500]}") from exc
    if "result" not in data:
        raise RuntimeError(f"claude CLI: JSON sem campo 'result': {out[:500]}")

    content = data["result"]
    usage = Usage()
    u = data.get("usage") or {}
    usage.input = u.get("input_tokens", 0) or 0
    usage.output = u.get("output_tokens", 0) or 0
    usage.cache_read = u.get("cache_read_input_tokens", 0) or 0
    usage.cache_write = u.get("cache_creation_input_tokens", 0) or 0

    return CompletionResult(content, usage, spec.id, spec.provider, 0)


# ---------------------------------------------------------------------------
# JSON: extração determinística + validação pydantic com repair
# ---------------------------------------------------------------------------


def extract_json(response: str, debug_name: str = "json") -> dict:
    """
    Extrai JSON de forma DETERMINÍSTICA, sem ALTERAR conteúdo:
      1) remove cercas de markdown (```json / ```)
      2) localiza o objeto por contagem de profundidade de chaves
      3) json.loads sobre o trecho extraído EXATAMENTE como veio

    POLÍTICA: nenhuma regex que altere conteúdo (ex.: apagar "(...)" após
    strings) é aplicada — isso poderia corromper dado clínico em silêncio.
    Em falha de parse, grava o malformado em $M_BASE/_debug/debug_<name>.json
    apenas para diagnóstico e LEVANTA erro (sem devolver nada "consertado").
    """
    text = response.strip()
    text = re.sub(r"```json\n?", "", text)
    text = re.sub(r"```\n?", "", text)

    start = text.find("{")
    if start == -1:
        raise ValueError(f"Nenhum JSON encontrado na resposta ({debug_name})")

    depth, end = 0, start
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    raw = text[start:end]

    # Único parse permitido: json.loads sobre o trecho cru, sem mutação.
    try:
        return json.loads(raw)
    except json.JSONDecodeError as err:
        # Dump de debug antes de levantar — diagnóstico, não auto-correção.
        debug_dir = get_settings().debug_dir
        debug_dir.mkdir(parents=True, exist_ok=True)
        path = debug_dir / f"debug_{debug_name}.json"
        Path(path).write_text(raw, encoding="utf-8")
        raise ValueError(f"Falha ao parsear JSON ({debug_name}). Salvo em {path}") from err


def complete_json(
    *,
    schema: type[T],
    system: str | list[SystemBlock],
    user: str,
    model: str | None = None,
    max_tokens: int | None = None,
    temperature: float = 0.0,
    cache: bool = True,
    timeout: float = 1200.0,
    debug_name: str = "json",
    repair: bool = True,
) -> T:
    """
    Completa e valida contra um schema pydantic.
    Pipeline de robustez (ÚNICO fallback permitido na política):
      1) extract_json (parse estrito, sem alterar conteúdo)
      2) schema.model_validate (schema ESTRITO → payload vazio/incompleto FALHA)
      3) se falhar e repair=True: 1 rodada de repair pedindo conformidade ao LLM;
         se a revalidação ainda falhar → raise (sem degradação).
    """
    res = complete(
        system=system, user=user, model=model, max_tokens=max_tokens,
        temperature=temperature, cache=cache, timeout=timeout,
    )
    try:
        return schema.model_validate(extract_json(res.content, debug_name))
    except (ValueError, ValidationError) as err:
        if not repair:
            raise
        log.warning("json_repair", stage=debug_name, error=str(err)[:300])
        repair_user = (
            f"O JSON abaixo é inválido para o schema esperado.\n"
            f"ERRO:\n{str(err)[:2000]}\n\n"
            f"SCHEMA (JSON Schema):\n{json.dumps(schema.model_json_schema())[:6000]}\n\n"
            f"JSON A CORRIGIR:\n{res.content[:60000]}\n\n"
            f"Retorne APENAS o JSON corrigido, válido e completo, sem comentários."
        )
        fixed = complete(
            system="Você corrige JSON para conformar exatamente a um schema. Responda só com JSON válido.",
            user=repair_user, model=model, max_tokens=max_tokens, temperature=0.0, cache=False, timeout=timeout,
        )
        return schema.model_validate(extract_json(fixed.content, f"{debug_name}_repaired"))
