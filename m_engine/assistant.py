"""
M-Engine — Assistente clínico agêntico (Claude Code CLI em streaming).

Spawna o CLI Claude Code em modo STREAMING bidirecional (stream-json em ambas as
direções), reaproveitando a AUTH DO SISTEMA (sessão logada / OAuth / keychain) —
igual a `providers.llm._complete_claude_cli`, sem API key direta.

Diferente do provider de completion (one-shot `-p --output-format json`), aqui a
sessão é LONGA e INTERATIVA: o cliente WebSocket envia mensagens de usuário e
recebe, em tempo real, texto do assistente, eventos de uso de ferramenta e o
resultado de cada turno. É FULL AGENTIC (bypassPermissions, aprovado): o agente
tem shell + acesso a arquivos confinado ao workspace de dados (M_BASE) e pode
rodar os stages do pipeline via o CLI `m`.

Protocolo do CLI (verificado contra `claude --help` / execução real, v2.1.x):
  - Entrada  : --input-format stream-json  → JSONL de mensagens de usuário no stdin
               {"type":"user","message":{"role":"user","content":"..."}}
  - Saída    : --output-format stream-json --verbose → JSONL de eventos no stdout
               system/init, assistant (text|tool_use), result, ...
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any, Callable, Optional

import structlog

from m_engine.config import get_settings

log = structlog.get_logger("m_engine.assistant")


# Prompt de sistema (PT-BR) — anexado ao default do Claude Code via --append-system-prompt.
def _system_prompt(slug: Optional[str]) -> str:
    base = get_settings().m_base
    pat = base / "pat"
    focus = ""
    if slug:
        safe = Path(slug).name
        focus = (
            f"\n\nContexto da sessão: o usuário está focado no paciente cujo slug é "
            f"`{safe}`. O dossiê dele fica em `{pat / safe}`. Comece por aí quando "
            f"a pergunta for sobre 'este paciente'."
        )
    return (
        "Você é o assistente clínico do M-Engine, operando dentro do servidor (VM) do "
        "Dr. Gustavo. Você tem acesso a shell e arquivos, CONFINADO ao workspace de dados.\n\n"
        f"- Os dossiês dos pacientes ficam em `{pat}/<slug>/` (profile.json, index.json, "
        "e uma pasta por consulta C1/C2/... com transcription.json, ASL.json, "
        "DIMENSIONAL.json, GEM.json, BIRP.md, SOAP_trajetorial.md).\n"
        "- Use o CLI `m` (já no PATH) para rodar stages do pipeline "
        "(transcribe, normalize, asl, dimensional, gem, birp, soap). Rode `m --help` se "
        "tiver dúvida sobre subcomandos.\n"
        "- Responda SEMPRE em português do Brasil, de forma concisa e clínica.\n"
        "- TODO o conteúdo é PHI (dado de saúde sensível). NÃO copie dados de paciente "
        "para fora da VM, não os exponha em texto desnecessário e não acesse nada fora "
        f"de `{base}`.\n"
        "- Antes de ações destrutivas (apagar/sobrescrever), confirme o que vai fazer no "
        "texto da resposta." + focus
    )


def _build_cmd(slug: Optional[str]) -> list[str]:
    """Monta o comando do CLI Claude Code em modo streaming bidirecional."""
    settings = get_settings()
    # M_FORCE_MODEL pode trazer um alias de stage ("cc"); para o chat queremos um alias
    # real de modelo. Se for "cc" ou vazio, cai para "opus".
    forced = (settings.m_force_model or "").strip().lower()
    model = forced if forced and forced != "cc" else "opus"
    return [
        settings.m_claude_cli_bin,
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",  # obrigatório com --output-format stream-json em -p
        "--model", model,
        "--permission-mode", "bypassPermissions",
        "--add-dir", str(settings.m_base),
        "--append-system-prompt", _system_prompt(slug),
    ]


def _venv_path_env() -> dict[str, str]:
    """env com o PATH incluindo o bin do venv (para o CLI `m` ser chamável)."""
    env = os.environ.copy()
    # Diretório do venv que roda este processo (sys.executable). Garante que `m`,
    # instalado como console_script do projeto, esteja no PATH do agente.
    import sys

    venv_bin = str(Path(sys.executable).parent)
    current = env.get("PATH", "")
    if venv_bin and venv_bin not in current.split(os.pathsep):
        env["PATH"] = venv_bin + os.pathsep + current
    return env


class AssistantSession:
    """
    Sessão de chat agêntico ligada a um subprocesso do CLI Claude Code.

    Uso:
        sess = AssistantSession(slug="fulano-de-tal")
        await sess.start()
        await sess.send_user("Resuma a última consulta deste paciente")
        async for frame in sess.events():   # frames normalizados (dict)
            ...
        await sess.close()
    """

    def __init__(self, slug: Optional[str] = None, *, workspace: Optional[Path] = None) -> None:
        self.slug = slug
        # cwd da sessão: por padrão, a raiz de dados (assim caminhos relativos do
        # agente caem dentro de M_BASE). Permite override em testes.
        self.workspace = workspace or get_settings().m_base
        self.proc: Optional[asyncio.subprocess.Process] = None

    async def start(self) -> None:
        cmd = _build_cmd(self.slug)
        self.workspace.mkdir(parents=True, exist_ok=True)
        log.info("assistant_start", slug=self.slug, bin=cmd[0], workspace=str(self.workspace))
        self.proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(self.workspace),
            env=_venv_path_env(),
        )

    async def send_user(self, text: str) -> None:
        """Escreve uma mensagem de usuário no stdin como JSONL stream-json."""
        if not self.proc or not self.proc.stdin:
            raise RuntimeError("Sessão do assistente não iniciada.")
        msg = {"type": "user", "message": {"role": "user", "content": text}}
        line = (json.dumps(msg, ensure_ascii=False) + "\n").encode("utf-8")
        self.proc.stdin.write(line)
        await self.proc.stdin.drain()

    async def read_events(self, on_frame: Callable[[dict], Any]) -> None:
        """
        Lê o stdout (JSONL) do CLI, NORMALIZA cada evento e chama on_frame(frame).
        on_frame pode ser sync ou async. Termina quando o stdout fecha (EOF).
        """
        if not self.proc or not self.proc.stdout:
            raise RuntimeError("Sessão do assistente não iniciada.")
        async for raw in self.proc.stdout:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue  # ignora ruído não-JSON
            for frame in normalize_event(event):
                res = on_frame(frame)
                if asyncio.iscoroutine(res):
                    await res

    async def stderr_text(self) -> str:
        if not self.proc or not self.proc.stderr:
            return ""
        data = await self.proc.stderr.read()
        return data.decode("utf-8", errors="replace")

    async def close(self) -> None:
        """Encerra o subprocesso (fecha stdin, termina, aguarda, mata se preciso)."""
        proc = self.proc
        if not proc:
            return
        try:
            if proc.stdin and not proc.stdin.is_closing():
                proc.stdin.close()
        except Exception:
            pass
        if proc.returncode is None:
            try:
                proc.terminate()
            except ProcessLookupError:
                return
            try:
                await asyncio.wait_for(proc.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
                await proc.wait()
        log.info("assistant_closed", slug=self.slug, returncode=proc.returncode)


def _summarize_tool(name: str, tool_input: dict | None) -> str:
    """Resumo curto e legível de um tool_use (esconde o schema cru do cliente)."""
    ti = tool_input or {}
    if name in ("Bash",) and ti.get("command"):
        return str(ti["command"])[:200]
    if name in ("Read", "Write", "Edit") and ti.get("file_path"):
        return str(ti["file_path"])
    if name == "Glob" and ti.get("pattern"):
        return str(ti["pattern"])
    if name == "Grep" and ti.get("pattern"):
        return str(ti["pattern"])
    if name == "Skill" and ti.get("skill"):
        return str(ti["skill"])
    # Fallback: primeiro valor string curto do input, se houver.
    for v in ti.values():
        if isinstance(v, str) and v:
            return v[:200]
    return ""


def normalize_event(event: dict) -> list[dict]:
    """
    Converte UM evento nativo do CLI (stream-json) em zero+ frames COMPACTOS para
    o cliente. Esconde os internos; o frontend não precisa parsear o schema do CLI.

    Frames de saída:
      {"type":"ready"}                              (system/init)
      {"type":"assistant","text": "..."}            (texto do assistente)
      {"type":"tool","name":"Bash","summary":"..."} (uso de ferramenta)
      {"type":"result","text":"...","usage":{...}}  (turno concluído)
      {"type":"error","message":"..."}              (falha)
    """
    etype = event.get("type")
    frames: list[dict] = []

    if etype == "system" and event.get("subtype") == "init":
        frames.append({"type": "ready", "model": event.get("model")})
        return frames

    if etype == "assistant":
        content = (event.get("message") or {}).get("content") or []
        for block in content:
            btype = block.get("type")
            if btype == "text":
                text = block.get("text") or ""
                if text:
                    frames.append({"type": "assistant", "text": text})
            elif btype == "tool_use":
                name = block.get("name") or "tool"
                frames.append({
                    "type": "tool",
                    "name": name,
                    "summary": _summarize_tool(name, block.get("input")),
                })
        return frames

    if etype == "result":
        if event.get("is_error") or event.get("subtype") not in (None, "success"):
            frames.append({
                "type": "error",
                "message": str(event.get("result") or event.get("subtype") or "erro desconhecido"),
            })
            return frames
        usage = event.get("usage") or {}
        compact_usage = {
            "input": usage.get("input_tokens", 0) or 0,
            "output": usage.get("output_tokens", 0) or 0,
            "cache_read": usage.get("cache_read_input_tokens", 0) or 0,
            "cache_write": usage.get("cache_creation_input_tokens", 0) or 0,
            "cost_usd": event.get("total_cost_usd"),
        }
        frames.append({
            "type": "result",
            "text": event.get("result") or "",
            "usage": compact_usage,
        })
        return frames

    # Demais eventos (rate_limit_event, post_turn_summary, user echo, etc.): ocultos.
    return frames
