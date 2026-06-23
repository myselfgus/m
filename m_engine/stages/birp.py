"""
Stage — BIRP (Behavior / Intervention / Response / Plan).

NOTA CLÍNICA IMEDIATA: disparada logo após a transcrição diarizada, usando
APENAS a transcrição bruta (sem ASL/VDLP/GEM). É também o stage que CRIA/ATUALIZA
o dossiê do paciente (info.json: sessão + clinical_summary).

Fluxo:
  1. Carrega a transcrição bruta (campo `transcricao` ou `text`) — ÚNICO input.
  2. Chama o LLM (complete_json + schema BirpNote) para extrair, só da transcrição:
     identidade, as 4 seções BIRP e os metadados clínicos
     (icd_codes / medications_mentioned / topicos_principais / clinical_context).
  3. Resolve dossiê idempotente (find_existing_patient → senão generate_patient_id
     + ensure_dossier).
  4. Monta a nota BIRP em Markdown + grava o JSON estrutural.
  5. ATUALIZA o info.json via store.register_session (sessão + clinical_metadata).

Modelo default deste stage: "sonnet" (config.STAGE_DEFAULTS["birp"]). Override
explícito vence; "cc" também funciona pois tudo passa por providers.llm.

GATE DE IDEMPOTÊNCIA vs IDENTIFICAÇÃO (decisão de projeto)
----------------------------------------------------------
O patient_id só é conhecido APÓS identificar o paciente, e a identificação fiel
mora na própria chamada ao LLM. Para NÃO gastar uma chamada cara de LLM só para
decidir o gate, fazemos uma identificação LEVE e determinística ANTES do gate:
  - nome a partir do conteúdo (heurística barata) ou do nome do arquivo;
  - resolve patient_id (find_existing_patient → senão seria um paciente novo, que
    por definição não tem BIRP anterior, então o gate nem se aplica).
Se já existir `<PID>_BIRP_<date>_*.md` e force=False, retornamos o mais recente
SEM chamar o LLM. Caso o gate não acerte o paciente (heurística falha), seguimos
o caminho normal: o LLM faz a identificação canônica e reprocessa — pior caso é
uma regravação, nunca um dado errado. force=True sempre reprocessa.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path

import structlog

from m_engine.providers import llm
from m_engine.providers.llm import SystemBlock
from m_engine.schemas.birp import BirpNote
from m_engine.store import (
    birp_doc_path,
    birp_json_path,
    ensure_dossier,
    extract_initials,
    find_existing_patient,
    generate_patient_id,
    pat_dir,
    read_json,
    register_session,
    write_json,
)
from m_engine.util import estimate_tokens, load_prompt, now_iso, split_into_chunks, today

log = structlog.get_logger("m_engine.birp")


def prewarm_blocks() -> list[list[SystemBlock]]:
    """System prompt(s) deste stage para pré-aquecer o cache (mesma chave do run)."""
    return [[SystemBlock(text=load_prompt("birp"), cache=True)]]


# Acima deste tamanho (tokens estimados) a transcrição é dividida em blocos e
# consolidada numa única chamada (concatenamos os blocos rotulados no user prompt).
_CHUNK_THRESHOLD_TOKENS = 15_000
_CHUNK_SIZE_TOKENS = 14_000

# Teto defensivo de caracteres por bloco interpolado (evita prompts gigantes).
_MAX_CHARS_PER_CHUNK = 120_000


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _timestamp() -> str:
    """Timestamp do arquivo: ISO UTC sanitizado (sem ':'/'.'), até os segundos."""
    return datetime.now(timezone.utc).isoformat().replace(":", "-").replace(".", "-")[:19]


def _load_transcription(src_path: Path) -> str:
    """Carrega o texto bruto da transcrição (campo `transcricao` ou `text`)."""
    data = read_json(src_path)
    text = (data.get("transcricao") or data.get("text") or "").strip()
    if not text:
        raise ValueError(f"Transcrição vazia ou sem campo 'transcricao'/'text': {src_path}")
    return text


def _name_from_filename(src_path: Path) -> str:
    """
    Deriva um nome de paciente legível a partir do nome do arquivo, como fallback.
    Ex.: '2026-06-22_maria_silva_transcription.json' → 'Maria Silva'.
    """
    stem = src_path.stem
    # Remove sufixos/prefixos técnicos comuns e datas ISO no começo.
    stem = re.sub(r"\.transcription$|_transcription$|_transcricao$", "", stem, flags=re.IGNORECASE)
    stem = re.sub(r"^\d{4}-\d{2}-\d{2}[_-]?", "", stem)
    tokens = [t for t in re.split(r"[_\-\s]+", stem) if t and not t.isdigit()]
    if not tokens:
        return "Paciente"
    return " ".join(t.capitalize() for t in tokens)


def _light_patient_name(text: str, src_path: Path) -> str:
    """
    Identificação LEVE e determinística do nome do paciente (só para o gate de
    idempotência). Tenta padrões explícitos no início da transcrição; senão
    cai para o nome derivado do arquivo. NÃO substitui a identificação do LLM.
    """
    head = text[:2000]
    patterns = (
        r"paciente[:\s]+([A-ZÁÉÍÓÚÂÊÔÃÕÇ][\wÀ-ÿ]+(?:\s+[A-ZÁÉÍÓÚÂÊÔÃÕÇ][\wÀ-ÿ]+){0,3})",
        r"nome[:\s]+([A-ZÁÉÍÓÚÂÊÔÃÕÇ][\wÀ-ÿ]+(?:\s+[A-ZÁÉÍÓÚÂÊÔÃÕÇ][\wÀ-ÿ]+){0,3})",
    )
    for pat in patterns:
        m = re.search(pat, head, flags=re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return _name_from_filename(src_path)


def _build_user_prompt(text: str, src_path: Path) -> str:
    """
    Monta o user prompt que interpola a transcrição. Se a transcrição for grande
    (> ~15k tokens), divide em blocos rotulados e os concatena numa ÚNICA chamada
    (o system prompt instrui a consolidar). Cada bloco é truncado defensivamente.
    """
    fallback_name = _name_from_filename(src_path)
    header = (
        f"<nome_do_arquivo>{src_path.name}</nome_do_arquivo>\n"
        f"<nome_derivado_do_arquivo>{fallback_name}</nome_derivado_do_arquivo>\n\n"
        "Abaixo está a TRANSCRIÇÃO BRUTA DIARIZADA da sessão. Produza a nota BIRP "
        "consolidada e os metadados clínicos no JSON especificado, usando SOMENTE "
        "o que está na transcrição. Se o nome do paciente não aparecer no conteúdo, "
        "use o <nome_derivado_do_arquivo>.\n"
    )

    if estimate_tokens(text) <= _CHUNK_THRESHOLD_TOKENS:
        return f"{header}\n<transcricao>\n{text}\n</transcricao>"

    # Chunking simples: blocos sequenciais rotulados, consolidados pelo LLM.
    chunks = split_into_chunks(text, max_tokens_per_chunk=_CHUNK_SIZE_TOKENS)
    log.info("birp_chunking", n_chunks=len(chunks), tokens=estimate_tokens(text))
    parts = [
        header,
        f"\nA transcrição foi dividida em {len(chunks)} BLOCOS sequenciais de uma "
        "MESMA sessão. Considere-os em conjunto e produza UMA única nota consolidada.\n",
    ]
    for i, chunk in enumerate(chunks, start=1):
        parts.append(f"\n<bloco numero=\"{i}\" de=\"{len(chunks)}\">\n{chunk[:_MAX_CHARS_PER_CHUNK]}\n</bloco>")
    return "".join(parts)


def _assemble_markdown(note: BirpNote, *, date: str) -> str:
    """Monta a nota BIRP em Markdown: cabeçalho + as 4 seções B/I/R/P."""
    now = datetime.now(timezone.utc)
    gen_str = f"{now.strftime('%d/%m/%Y')} - {now.strftime('%H:%M')} UTC"

    def _sec(title: str, body: str) -> str:
        return f"## {title}\n\n{(body or '').strip() or '_Não abordado na sessão._'}"

    return f"""# NOTA CLÍNICA — BIRP

**Paciente:** {note.patient_name}
**Iniciais:** {note.patient_initials or "—"}
**Profissional:** {note.professional_name}
**Data da sessão:** {date}
**Tipo de encontro:** {note.clinical_context.encounter_type}

---

{_sec("B — Comportamento (Behavior)", note.behavior)}

{_sec("I — Intervenção (Intervention)", note.intervention)}

{_sec("R — Resposta (Response)", note.response)}

{_sec("P — Plano (Plan)", note.plan)}

---

*Nota gerada automaticamente a partir da transcrição da sessão — {gen_str}.*
"""


# ---------------------------------------------------------------------------
# Entry point (CONTRATO)
# ---------------------------------------------------------------------------


def run(transcription_json_path: str | Path, *, model: str | None = None, force: bool = False) -> Path:
    """
    Gera a nota BIRP a partir da transcrição bruta e cria/atualiza o dossiê.

    Args:
        transcription_json_path: JSON com a transcrição (campo `transcricao` ou `text`).
        model: alias de config.MODELS; None → "sonnet" (default deste stage). "cc" ok.
        force: regrava mesmo havendo BIRP anterior para o paciente/data.

    Returns:
        Path do arquivo .md da nota BIRP gravada.
    """
    model = model or "sonnet"  # default deste stage; override explícito vence
    src_path = Path(transcription_json_path)
    if not src_path.exists():
        raise FileNotFoundError(f"Transcrição não encontrada: {src_path}")

    text = _load_transcription(src_path)
    date = today()

    # --- GATE DE IDEMPOTÊNCIA (identificação LEVE antes do LLM) ---
    # Resolve um patient_id candidato de forma barata para checar BIRP anterior.
    if not force:
        light_name = _light_patient_name(text, src_path)
        candidate_pid = find_existing_patient(light_name)
        if candidate_pid:
            out_dir = pat_dir() / candidate_pid / "clinical-documents"
            existing = sorted(out_dir.glob(f"{candidate_pid}_BIRP_{date}_*.md")) if out_dir.exists() else []
            if existing:
                log.info("birp_skip_cached", patient=candidate_pid, out=str(existing[-1]))
                return existing[-1]

    # --- EXTRAÇÃO via LLM (identificação canônica + seções + metadados) ---
    system = [SystemBlock(text=load_prompt("birp"), cache=True)]
    user = _build_user_prompt(text, src_path)

    log.info("birp_extract", model=model, src=src_path.name, tokens=estimate_tokens(text))
    note = llm.complete_json(
        schema=BirpNote,
        system=system,
        user=user,
        model=model,
        debug_name="birp",
    )

    # --- RESOLUÇÃO DO DOSSIÊ (idempotente pelo nome canônico do LLM) ---
    patient_name = (note.patient_name or "Paciente").strip() or "Paciente"
    patient_id = find_existing_patient(patient_name) or generate_patient_id(patient_name)
    ensure_dossier(patient_id)

    # Iniciais: usa a do LLM se houver; senão deriva do nome.
    patient_initials = note.patient_initials or extract_initials(patient_name)

    # Re-checa o gate agora com o patient_id canônico (caso a heurística leve tenha
    # errado o paciente acima). Evita duplicar BIRP do mesmo dia sem force.
    if not force:
        out_dir = pat_dir() / patient_id / "clinical-documents"
        existing = sorted(out_dir.glob(f"{patient_id}_BIRP_{date}_*.md")) if out_dir.exists() else []
        if existing:
            log.info("birp_skip_cached_post", patient=patient_id, out=str(existing[-1]))
            return existing[-1]

    # --- GRAVAÇÃO: Markdown (com timestamp) + JSON estrutural ---
    ts = _timestamp()
    md_path = birp_doc_path(patient_id, date, ts)
    md_path.write_text(_assemble_markdown(note, date=date), encoding="utf-8")

    structural = {
        "patient_id": patient_id,
        "patient_name": patient_name,
        "patient_initials": patient_initials,
        "professional_name": note.professional_name,
        "source_file": src_path.name,
        "date": date,
        "processed_at": now_iso(),
        "model": model,
        "behavior": note.behavior,
        "intervention": note.intervention,
        "response": note.response,
        "plan": note.plan,
        "icd_codes": [c.model_dump() for c in note.icd_codes],
        "medications_mentioned": [m.model_dump(exclude_none=True) for m in note.medications_mentioned],
        "topicos_principais": note.topicos_principais,
        "clinical_context": note.clinical_context.model_dump(),
        "tags": note.tags,
    }
    write_json(birp_json_path(patient_id, date), structural)

    # --- ATUALIZA info.json (sessão + clinical_summary) ---
    clinical_metadata = {
        "icd_codes": [c.model_dump() for c in note.icd_codes],
        "medications_mentioned": [m.model_dump(exclude_none=True) for m in note.medications_mentioned],
        "topicos_principais": note.topicos_principais,
        "clinical_context": note.clinical_context.model_dump(),
    }
    register_session(
        patient_id,
        patient_name=patient_name,
        patient_initials=patient_initials,
        professional={"name": note.professional_name},
        session_entry={
            "date": date,
            "source_file": src_path.name,
            "tags": note.tags,
            "processed_at": now_iso(),
        },
        clinical_metadata=clinical_metadata,
    )

    log.info("birp_done", patient=patient_id, out=str(md_path))
    return md_path
