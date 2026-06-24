"""
M-Engine — Assistente clínico agêntico (Claude Sonnet 4.6 via Anthropic API).

Diferente da versão antiga (subprocesso do CLI Claude Code, efêmero e por paciente),
esta é UMA conversa GERAL e PERSISTENTE:

  - Modelo: claude-sonnet-4-6 (janela de 1M de contexto) via Anthropic API.
  - Estado: o transcript vive no servidor em `M_BASE/assistant/general.json`
    (lista de mensagens no formato da Messages API). Sobrevive a reconexões,
    background do app e reinício do processo.
  - Agêntico: loop manual de tool-use com ferramentas confinadas a M_BASE
    (`bash`, `read_file`, `write_file`) — o assistente lê dossiês de pacientes,
    roda o CLI `m` (pipeline) e inspeciona arquivos, tudo dentro do workspace.
  - A execução do turno NÃO está atrelada ao WebSocket: quando o app vai a
    segundo plano e o socket cai, o turno continua e é persistido; ao reconectar,
    o histórico é reproduzido.

Frames emitidos ao cliente (compatíveis com o front atual):
  {"type":"history","role":"user"|"assistant","text":...}  (replay ao conectar)
  {"type":"ready"}
  {"type":"assistant","text":"..."}      (delta de texto em streaming)
  {"type":"tool","name":"bash","summary":"..."}
  {"type":"result"}                       (turno concluído)
  {"type":"error","message":"..."}
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any, Awaitable, Callable

import structlog

from m_engine.config import get_settings

log = structlog.get_logger("m_engine.assistant")

MODEL = "claude-sonnet-4-6"
MAX_TOKENS = 8000
BASH_TIMEOUT = 120  # s
MAX_TOOL_OUTPUT = 20000  # chars devolvidos ao modelo por chamada de ferramenta

EmitFn = Callable[[dict], Awaitable[None]]


# ---------------------------------------------------------------------------
# Persistência do transcript
# ---------------------------------------------------------------------------
def _assistant_dir() -> Path:
    d = get_settings().m_base / "assistant"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _transcript_path() -> Path:
    return _assistant_dir() / "general.json"


def _professional_path() -> Path:
    return get_settings().m_base / "professional.json"


def _has_tool_use(content: Any) -> bool:
    """True se o conteúdo (lista de blocos) contém algum bloco tool_use."""
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "tool_use" for b in content)
    return False


def _has_tool_result(content: Any) -> bool:
    """True se o conteúdo (lista de blocos) contém algum bloco tool_result."""
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return False


def _sanitize(messages: list[dict]) -> list[dict]:
    """
    Repara um transcript para um estado VÁLIDO para a Messages API, evitando 400
    que travariam a conversa para sempre. Varre do fim removendo:
      - turno final `assistant` com `tool_use` sem o `tool_result` correspondente
        logo depois (turno interrompido antes de executar a ferramenta);
      - turno final `user` que é só `tool_result` sem o `tool_use` anterior.
    Por fim, garante que a 1ª mensagem (se houver) seja `role:"user"`.
    """
    if not isinstance(messages, list):
        return []
    msgs = [m for m in messages if isinstance(m, dict) and m.get("role") in ("user", "assistant")]

    # Remove caudas inválidas (pode haver mais de uma camada).
    changed = True
    while changed and msgs:
        changed = False
        last = msgs[-1]
        if last.get("role") == "assistant" and _has_tool_use(last.get("content")):
            # tool_use sem tool_result seguinte → turno interrompido.
            msgs.pop()
            changed = True
            continue
        if last.get("role") == "user" and _has_tool_result(last.get("content")):
            prev = msgs[-2] if len(msgs) >= 2 else None
            if not (prev and prev.get("role") == "assistant" and _has_tool_use(prev.get("content"))):
                msgs.pop()
                changed = True
                continue

    # A conversa precisa começar com `user`.
    while msgs and msgs[0].get("role") != "user":
        msgs.pop(0)
    return msgs


def load_transcript() -> list[dict]:
    p = _transcript_path()
    if p.is_file():
        try:
            return _sanitize(json.loads(p.read_text("utf-8")))
        except Exception:  # noqa: BLE001
            return []
    return []


def save_transcript(messages: list[dict]) -> None:
    """Grava o transcript de forma ATÔMICA (tmp + os.replace) p/ não corromper em crash."""
    p = _transcript_path()
    data = json.dumps(messages, ensure_ascii=False, indent=0)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(data, "utf-8")
    os.replace(tmp, p)


def _professional_context() -> str:
    """Bloco de contexto com o perfil do profissional (professional.json), se houver."""
    p = _professional_path()
    if not p.is_file():
        return ""
    try:
        prof = json.loads(p.read_text("utf-8"))
    except Exception:  # noqa: BLE001
        return ""
    if not isinstance(prof, dict) or not prof:
        return ""
    parts = []
    for key, label in (
        ("name", "Nome"),
        ("specialty", "Especialidade"),
        ("registration", "Registro (CRM/RQE)"),
        ("clinic", "Clínica/Instituição"),
        ("notes", "Observações"),
    ):
        val = prof.get(key)
        if val:
            parts.append(f"  - {label}: {val}")
    if not parts:
        return ""
    return "\n\nPerfil do profissional (use como contexto de quem você assiste):\n" + "\n".join(parts)


# ---------------------------------------------------------------------------
# Prompt de sistema + ferramentas
# ---------------------------------------------------------------------------
def _system_prompt() -> str:
    base = get_settings().m_base
    pat = base / "pat"
    return (
        "Você é o assistente clínico GERAL do M-Engine, operando dentro do servidor "
        "(VM) do Dr. Gustavo. Tem acesso a shell e arquivos CONFINADO ao workspace de "
        f"dados em `{base}`.\n\n"
        f"- Os dossiês dos pacientes ficam em `{pat}/<slug>/` (profile.json, index.json, "
        "e uma pasta por consulta C1/C2/... com transcription.json, ASL.json, "
        "DIMENSIONAL.json, GEM.json, BIRP.md, SOAP_trajetorial.md).\n"
        "- Use a ferramenta `bash` para listar/inspecionar arquivos e para rodar o CLI "
        "`m` (já no PATH) nos stages do pipeline (transcribe, normalize, asl, dimensional, "
        "gem, birp, soap). Rode `m --help` em caso de dúvida.\n"
        "- Use `read_file` para ler um arquivo e `write_file` para escrever (caminhos "
        f"relativos a `{base}`).\n"
        "- Esta é uma conversa geral e contínua (não está presa a um paciente). Quando o "
        "usuário citar um paciente, descubra o slug listando `pat/`.\n"
        "- Responda SEMPRE em português do Brasil, de forma concisa e clínica.\n"
        "- TODO o conteúdo é PHI (dado de saúde sensível). NÃO exponha dados além do "
        f"necessário e não acesse nada fora de `{base}`.\n"
        "- Antes de ações destrutivas (apagar/sobrescrever), confirme no texto da resposta."
        + _professional_context()
    )


TOOLS: list[dict] = [
    {
        "name": "bash",
        "description": (
            "Executa um comando de shell no diretório de dados (M_BASE). Use para listar "
            "arquivos (ls, find), inspecionar conteúdo (cat, grep) e rodar o CLI `m`."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Comando bash a executar."}
            },
            "required": ["command"],
        },
    },
    {
        "name": "read_file",
        "description": "Lê um arquivo de texto (caminho relativo a M_BASE) e devolve o conteúdo.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Caminho relativo a M_BASE."}
            },
            "required": ["path"],
        },
    },
    {
        "name": "write_file",
        "description": "Escreve (cria/sobrescreve) um arquivo de texto (caminho relativo a M_BASE).",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Caminho relativo a M_BASE."},
                "content": {"type": "string", "description": "Conteúdo a gravar."},
            },
            "required": ["path", "content"],
        },
    },
]


def _summarize_tool(name: str, ti: dict) -> str:
    ti = ti or {}
    if name == "bash":
        return str(ti.get("command", ""))[:200]
    if name in ("read_file", "write_file"):
        return str(ti.get("path", ""))
    for v in ti.values():
        if isinstance(v, str) and v:
            return v[:200]
    return ""


# ---------------------------------------------------------------------------
# Execução das ferramentas (confinada a M_BASE)
# ---------------------------------------------------------------------------
def _resolve_in_base(rel: str) -> Path:
    base = get_settings().m_base.resolve()
    target = (base / rel).resolve()
    if base != target and base not in target.parents:
        raise ValueError(f"Caminho fora do workspace permitido: {rel}")
    return target


def _venv_path_env() -> dict[str, str]:
    """env com o bin do venv no PATH (para o CLI `m` ser chamável)."""
    import sys

    env = os.environ.copy()
    venv_bin = str(Path(sys.executable).parent)
    cur = env.get("PATH", "")
    if venv_bin and venv_bin not in cur.split(os.pathsep):
        env["PATH"] = venv_bin + os.pathsep + cur
    return env


async def _exec_tool(name: str, ti: dict) -> tuple[str, bool]:
    """Executa uma ferramenta e devolve (conteúdo, is_error)."""
    base = get_settings().m_base
    try:
        if name == "bash":
            cmd = (ti or {}).get("command", "")
            if not cmd:
                return ("comando vazio", True)
            proc = await asyncio.create_subprocess_shell(
                cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=str(base),
                env=_venv_path_env(),
            )
            try:
                out, _ = await asyncio.wait_for(proc.communicate(), timeout=BASH_TIMEOUT)
            except asyncio.TimeoutError:
                proc.kill()
                return (f"[timeout após {BASH_TIMEOUT}s]", True)
            text = out.decode("utf-8", "replace")
            if len(text) > MAX_TOOL_OUTPUT:
                text = text[:MAX_TOOL_OUTPUT] + "\n[...saída truncada...]"
            return (text or "(sem saída)", proc.returncode != 0)

        if name == "read_file":
            path = _resolve_in_base((ti or {}).get("path", ""))
            if not path.is_file():
                return (f"arquivo inexistente: {ti.get('path')}", True)
            text = path.read_text("utf-8", "replace")
            if len(text) > MAX_TOOL_OUTPUT:
                text = text[:MAX_TOOL_OUTPUT] + "\n[...truncado...]"
            return (text, False)

        if name == "write_file":
            path = _resolve_in_base((ti or {}).get("path", ""))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text((ti or {}).get("content", ""), "utf-8")
            return (f"gravado: {ti.get('path')}", False)

        return (f"ferramenta desconhecida: {name}", True)
    except Exception as exc:  # noqa: BLE001
        return (f"erro ao executar {name}: {exc}", True)


# ---------------------------------------------------------------------------
# Sessão geral (singleton)
# ---------------------------------------------------------------------------
class GeneralAssistant:
    """
    Conversa geral única e persistente. Compartilhada entre conexões/dispositivos.
    Um turno por vez (lock). O turno roda como task de fundo e transmite frames
    para todos os assinantes (WebSockets); se nenhum estiver conectado, o turno
    continua e é persistido mesmo assim.
    """

    def __init__(self) -> None:
        self.messages: list[dict] = load_transcript()
        self.subscribers: set[asyncio.Queue] = set()
        self._lock = asyncio.Lock()
        self._client = None  # AsyncAnthropic, lazy
        # Referência FORTE às tasks de turno: o event loop só guarda referência fraca,
        # então sem isto o GC poderia cancelar um turno no meio (modelo "não responde").
        self._turn_tasks: set[asyncio.Task] = set()
        # Último erro de turno (em background); reemitido ao reconectar p/ não sumir.
        self._last_error: str | None = None

    def _anthropic(self):
        if self._client is None:
            import anthropic

            key = get_settings().anthropic_api_key
            if not key:
                raise RuntimeError("ANTHROPIC_API_KEY ausente — configure no servidor.")
            self._client = anthropic.AsyncAnthropic(api_key=key)
        return self._client

    # -- assinaturas (WebSockets) -------------------------------------------
    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue()
        self.subscribers.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self.subscribers.discard(q)

    async def _broadcast(self, frame: dict) -> None:
        for q in list(self.subscribers):
            try:
                q.put_nowait(frame)
            except Exception:  # noqa: BLE001
                pass

    # -- replay de histórico ao conectar ------------------------------------
    def history_frames(self) -> list[dict]:
        frames: list[dict] = []
        for msg in self.messages:
            role = msg.get("role")
            content = msg.get("content")
            text = _extract_text(content)
            if not text:
                continue
            if role == "user":
                frames.append({"type": "history", "role": "user", "text": text})
            elif role == "assistant":
                frames.append({"type": "history", "role": "assistant", "text": text})
        # Reemite um turno que falhou em background (socket caído) para não sumir.
        if self._last_error:
            frames.append({"type": "error", "message": self._last_error})
        return frames

    # -- turno --------------------------------------------------------------
    async def handle_user(self, text: str) -> None:
        """Agenda um turno do usuário (não bloqueia o loop de recepção do WS)."""
        text = (text or "").strip()
        if not text:
            return
        # Guarda referência forte até concluir; senão o GC pode cancelar o turno.
        task = asyncio.create_task(self._run_turn(text))
        self._turn_tasks.add(task)
        task.add_done_callback(self._turn_tasks.discard)

    async def _run_turn(self, user_text: str) -> None:
        async with self._lock:
            self._last_error = None
            self.messages.append({"role": "user", "content": user_text})
            save_transcript(self.messages)
            try:
                client = self._anthropic()
            except Exception as exc:  # noqa: BLE001
                self._last_error = str(exc)
                await self._broadcast({"type": "error", "message": str(exc)})
                return

            system = _system_prompt()
            try:
                while True:
                    # Auto-corrige um estado inválido em memória antes de chamar a API
                    # (ex.: tool_use sem tool_result), evitando 400 que travaria a conversa.
                    self.messages = _sanitize(self.messages)
                    assistant_blocks: list[dict] = []
                    async with client.messages.stream(
                        model=MODEL,
                        max_tokens=MAX_TOKENS,
                        system=system,
                        tools=TOOLS,
                        messages=self.messages,
                    ) as stream:
                        async for event in stream:
                            if (
                                event.type == "content_block_delta"
                                and getattr(event.delta, "type", "") == "text_delta"
                            ):
                                await self._broadcast(
                                    {"type": "assistant", "text": event.delta.text}
                                )
                        final = await stream.get_final_message()

                    assistant_blocks = [b.model_dump() for b in final.content]
                    self.messages.append({"role": "assistant", "content": assistant_blocks})
                    save_transcript(self.messages)

                    if final.stop_reason != "tool_use":
                        await self._broadcast({"type": "result"})
                        break

                    # Executa as ferramentas pedidas e devolve os resultados.
                    tool_results: list[dict] = []
                    for block in final.content:
                        if block.type != "tool_use":
                            continue
                        await self._broadcast(
                            {
                                "type": "tool",
                                "name": block.name,
                                "summary": _summarize_tool(block.name, block.input),
                            }
                        )
                        content, is_error = await _exec_tool(block.name, block.input)
                        tool_results.append(
                            {
                                "type": "tool_result",
                                "tool_use_id": block.id,
                                "content": content,
                                "is_error": is_error,
                            }
                        )
                    self.messages.append({"role": "user", "content": tool_results})
                    save_transcript(self.messages)
            except Exception as exc:  # noqa: BLE001
                log.error("assistant_turn_failed", error=str(exc))
                self._last_error = str(exc)[:500]
                await self._broadcast({"type": "error", "message": str(exc)[:500]})


def _extract_text(content: Any) -> str:
    """Texto concatenado de um campo content (string ou lista de blocos)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text"):
                parts.append(b["text"])
        return "\n".join(parts)
    return ""


# Singleton do processo.
_ASSISTANT: GeneralAssistant | None = None


def get_assistant() -> GeneralAssistant:
    global _ASSISTANT
    if _ASSISTANT is None:
        _ASSISTANT = GeneralAssistant()
    return _ASSISTANT
