"""
Stage 1 — Normalize.

Porta a lógica declarativa do legado (medscribe-process-transcriptions.ts) para o
contrato do M-Engine, sem interação humana (CLI/readline) e sem Cloudflare:

  1. Carrega o JSON de transcrição (campo `transcricao` ou `text`).
  2. extractMetadata        → ExtractedMetadata (via complete_json).
  3. Se needs_correction    → correctTranscription (chunking quando >15k tokens).
  4. Resolve/garante dossiê  → store.find_existing_patient / generate_patient_id.
  5. Grava NormalizedTranscription em store.transcription_path(patient_id, date).
  6. Atualiza info.json (sessions[] desduplicado por source_file).

REGRA CRÍTICA: `transcription_corrected` = DIÁLOGO COMPLETO (ambos falantes).
A fala isolada do paciente, quando extraída, vai APENAS em `patient_speech`
(suplementar/opcional) — NUNCA substitui a transcrição canônica.

Idempotência: se o output já existe e force=False, retorna o caminho sem reprocessar.
Modelo default None → Claude Opus 4.8 (config.resolve_model). Toda LLM via providers.llm.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import structlog

from m_engine.providers import llm
from m_engine.providers.llm import SystemBlock
from m_engine.schemas.base import NormalizedTranscription
from m_engine.schemas.transcription import (
    CorrectedTranscription,
    ExtractedMetadata,
    PatientSpeech,
)
from m_engine.store import (
    ensure_dossier,
    find_existing_patient,
    generate_patient_id,
    load_info,
    read_json,
    save_info,
    transcription_path,
    write_json,
)
from m_engine.util import load_prompt, now_iso, split_into_chunks, today

log = structlog.get_logger("m_engine.normalize")

# Mesmo limiar do legado: acima disso, a correção roda por chunks.
MAX_TOKENS_PER_CHUNK = 15000


# ---------------------------------------------------------------------------
# Carregamento dos system prompts (blocos delimitados em prompts/normalize.md)
# ---------------------------------------------------------------------------


def _prompt_block(name: str) -> str:
    """Extrai um bloco <!-- BEGIN: name --> ... <!-- END: name --> do prompt."""
    full = load_prompt("normalize")
    pattern = rf"<!--\s*BEGIN:\s*{re.escape(name)}\s*-->(.*?)<!--\s*END:\s*{re.escape(name)}\s*-->"
    match = re.search(pattern, full, re.DOTALL)
    if not match:
        raise ValueError(f"Bloco de prompt '{name}' não encontrado em normalize.md")
    return match.group(1).strip()


def prewarm_blocks() -> list[list[SystemBlock]]:
    """System prompts cacheados deste stage (metadata + correction) para pré-aquecer."""
    return [
        [SystemBlock(_prompt_block("metadata"), cache=True)],
        [SystemBlock(_prompt_block("correction"), cache=True)],
    ]


# ---------------------------------------------------------------------------
# Etapa: extração de metadados (extractMetadata)
# ---------------------------------------------------------------------------


def _extract_metadata(text: str, filename: str, *, model: str | None) -> ExtractedMetadata:
    system = _prompt_block("metadata")
    # User prompt montado em código (fiel ao legado), com os exemplos few-shot.
    user = f"""<source_filename>
{filename}
</source_filename>

<clinical_transcription>
{text}
</clinical_transcription>

TASK: Extract basic metadata from the transcription above.

STEP-BY-STEP EXTRACTION:
1. Identify patient name/initials (check BOTH filename and transcription content)
2. Identify professional name (look for therapist/doctor identification, use config if available)
3. Generate general searchable tags (3-8 tags)
4. Assess transcription quality and identify if corrections are needed

EXAMPLES:

Example 1 - Patient name in transcription:
Filename: "audio_001.json"
Text: "[Falante 1] Olá, João Silva, como você está hoje?"
Extract: {{"patient_name": "João Silva", "patient_initials": "JS"}}

Example 2 - Patient name in filename:
Filename: "2025-10-20_maria_santos_consulta.json"
Text: "[Falante 1] Como você está se sentindo?"
Extract: {{"patient_name": "Maria Santos", "patient_initials": "MS"}}

Example 3 - No patient name anywhere:
Filename: "recording_001.json"
Text: "[Falante 1] Como você está se sentindo?"
Extract: {{"patient_name": "Paciente", "patient_initials": null}}

Example 4 - Tags:
Text: "Primeira consulta, paciente relata ansiedade e dificuldade para dormir"
Extract: {{"tags": ["primeira_consulta", "ansiedade", "insonia", "psicoterapia"]}}

Example 5 - Needs correction:
Text: "o paciente tem hiper tensão e toma aspirin"
Extract: {{"needs_correction": true, "correction_notes": "Medical terms need standardization: 'hiper tensão' -> 'hipertensão', 'aspirin' -> 'aspirina'"}}

JSON SCHEMA:
{{
  "patient_name": "string",
  "patient_initials": "string | null",
  "professional_name": "string",
  "tags": ["string"],
  "confidence": "high | medium | low",
  "needs_correction": "boolean",
  "correction_notes": "string (optional)"
}}

Return ONLY the JSON object (no markdown, no explanations):"""

    # system com cache=True: a instrução é reutilizada entre chamadas.
    return llm.complete_json(
        schema=ExtractedMetadata,
        system=[SystemBlock(system, cache=True)],
        user=user,
        model=model,
        debug_name="normalize_metadata",
    )


# ---------------------------------------------------------------------------
# Etapa: correção / normalização (correctTranscription)
# ---------------------------------------------------------------------------


def _build_correction_user(text: str, correction_notes: str | None, chunk_info: str | None) -> str:
    """Monta o user prompt de correção (texto inteiro ou um chunk)."""
    correction_context = (
        f"\n\nCORRECTION GUIDANCE:\n{correction_notes}\n\nFocus on these identified issues."
        if correction_notes
        else ""
    )
    # Indicação de chunk, quando aplicável (espelha "This is chunk i of n" do legado).
    chunk_line = f"\nThis is {chunk_info} from a larger transcription." if chunk_info else ""

    return f"""<transcription>
{text}
</transcription>{correction_context}

TASK: Analyze if corrections are needed and apply them if necessary.{chunk_line}

STEP-BY-STEP PROCESS:
1. Scan for STT errors (homophones, misrecognitions)
2. Check medical terminology accuracy
3. Verify punctuation and clarity
4. Identify needed corrections
5. Apply corrections preserving clinical meaning
6. Document all changes made

EXAMPLES OF CORRECTIONS:

Example 1 - Medical terminology:
Original: "o paciente tem hiper tensão"
Corrected: "o paciente tem hipertensão"
Reason: "Medical term standardization"

Example 2 - Medication names:
Original: "toma aspirin 100mg"
Corrected: "toma aspirina 100 mg"
Reason: "Portuguese medication name + spacing"

Example 3 - PRESERVE paralinguistics:
Original: "Acho que melhorou (risadas). Mas ainda tenho dor (pigarro)."
Corrected: "Acho que melhorou (risadas). Mas ainda tenho dor (pigarro)."
Reason: "No errors detected - paralinguistics PRESERVED"

Example 4 - Fix error BUT keep paralinguistics:
Original: "Ele toma Haldol todo dia (risos). Faz dois mêses."
Corrected: "Ele toma Haldol todo dia (risos). Faz dois meses."
Reason: "Fixed 'mêses' -> 'meses', PRESERVED (risos)"

Example 5 - No corrections needed:
Original: "O paciente relatou melhora dos sintomas."
Corrected: "O paciente relatou melhora dos sintomas."
Reason: "No errors detected"

JSON SCHEMA:
{{
  "original_had_errors": "boolean",
  "corrections_made": ["array of strings describing each correction"],
  "corrected_text": "string (full corrected transcription)"
}}

Return ONLY the JSON object (no markdown, no explanations):"""


def _correct_transcription(
    text: str, correction_notes: str | None, *, model: str | None
) -> CorrectedTranscription:
    """
    Corrige a transcrição COMPLETA. Quando > MAX_TOKENS_PER_CHUNK, divide em chunks
    via util.split_into_chunks e processa SEQUENCIALMENTE, concatenando na ordem.
    Em caso de falha de um chunk, preserva o texto original daquele chunk (fallback).
    """
    system = _prompt_block("correction")

    chunks = split_into_chunks(text, MAX_TOKENS_PER_CHUNK)

    # Caminho simples: cabe em uma única requisição.
    if len(chunks) <= 1:
        try:
            return llm.complete_json(
                schema=CorrectedTranscription,
                system=[SystemBlock(system, cache=True)],
                user=_build_correction_user(text, correction_notes, None),
                model=model,
                debug_name="normalize_correction",
            )
        except Exception as err:  # noqa: BLE001 — fallback determinístico ao original
            log.warning("correction_failed_fallback_original", error=str(err)[:300])
            return CorrectedTranscription(original_had_errors=False, corrections_made=[], corrected_text=text)

    # Caminho com chunking: processamento sequencial preservando a ordem.
    log.info("correction_chunked", chunks=len(chunks))
    corrected_chunks: list[str] = []
    all_corrections: list[str] = []
    had_errors = False

    for i, chunk in enumerate(chunks):
        chunk_info = f"chunk {i + 1} of {len(chunks)}"
        try:
            result = llm.complete_json(
                schema=CorrectedTranscription,
                system=[SystemBlock(system, cache=True)],
                user=_build_correction_user(chunk, correction_notes, chunk_info),
                model=model,
                debug_name=f"normalize_correction_chunk_{i + 1}",
            )
            corrected_chunks.append(result.corrected_text)
            if result.original_had_errors:
                had_errors = True
                all_corrections.append(f"Chunk {i + 1}: {', '.join(result.corrections_made)}")
        except Exception as err:  # noqa: BLE001 — preserva o chunk original em caso de erro
            log.warning("correction_chunk_failed", chunk=i + 1, error=str(err)[:300])
            corrected_chunks.append(chunk)

    # Concatena preservando a ordem (mesma junção do legado).
    return CorrectedTranscription(
        original_had_errors=had_errors,
        corrections_made=all_corrections,
        corrected_text="\n\n".join(corrected_chunks),
    )


# ---------------------------------------------------------------------------
# Etapa SUPLEMENTAR: extração da fala do paciente (extractPatientSpeech)
# ---------------------------------------------------------------------------


def _extract_patient_speech(
    text: str, patient_name: str, professional_name: str, *, model: str | None
) -> str | None:
    """
    Extrai SOMENTE a fala do paciente (campo suplementar). Nunca substitui a
    transcrição canônica. Retorna None se a extração for vazia/curta ou falhar.
    """
    system = _prompt_block("patient_speech")
    # Mantém o recorte de 15k chars do legado para limitar a janela de análise.
    snippet = text[:15000]
    user = f"""<transcription>
{snippet}
</transcription>

<context>
Patient name: {patient_name}
Professional name: {professional_name}
</context>

TASK:
1. Detect the speaker label format used in this transcription
2. Identify which speaker is the patient
3. Extract ALL patient speech, concatenated with paragraph breaks

JSON SCHEMA:
{{
  "speaker_format_detected": "description of format found",
  "patient_speaker_label": "the label identifying the patient",
  "patient_speech": "all patient speech concatenated with \\n\\n between turns",
  "confidence": "high | medium | low"
}}

Return ONLY the JSON:"""

    try:
        # cache=False no legado para esta etapa (entrada muito variável por sessão).
        result = llm.complete_json(
            schema=PatientSpeech,
            system=[SystemBlock(system, cache=False)],
            user=user,
            model=model,
            cache=False,
            debug_name="normalize_patient_speech",
        )
    except Exception as err:  # noqa: BLE001 — suplementar; falha não interrompe o stage
        log.warning("patient_speech_failed", error=str(err)[:300])
        return None

    speech = (result.patient_speech or "").strip()
    if len(speech) < 10:
        log.info("patient_speech_empty")
        return None
    return speech


# ---------------------------------------------------------------------------
# info.json — atualização desduplicada por source_file
# ---------------------------------------------------------------------------


def _update_info(
    patient_id: str, metadata: ExtractedMetadata, source_file: str, date: str, *, is_new: bool
) -> None:
    info = load_info(patient_id)

    if not info:
        # Dossiê novo — estrutura inicial.
        info = {
            "patient_id": patient_id,
            "patient_name": metadata.patient_name,
            "patient_initials": metadata.patient_initials,
            "professional": {"name": metadata.professional_name},
            "created_at": now_iso(),
            "sessions": [],
        }

    info.setdefault("sessions", [])

    session_entry = {
        "date": date,
        "source_file": source_file,
        "tags": metadata.tags,
        "processed_at": now_iso(),
    }

    # Desduplicação por source_file: atualiza no lugar ou adiciona.
    idx = next(
        (i for i, s in enumerate(info["sessions"]) if s.get("source_file") == source_file),
        None,
    )
    if idx is not None:
        info["sessions"][idx] = session_entry
    else:
        info["sessions"].append(session_entry)

    info["last_updated"] = now_iso()
    save_info(patient_id, info)


# ---------------------------------------------------------------------------
# Entrada do contrato
# ---------------------------------------------------------------------------


def run(transcription_json_path: str | Path, *, model: str | None = None, force: bool = False) -> Path:
    """
    Normaliza uma transcrição bruta e cria/atualiza o dossiê do paciente.

    Retorna o caminho do transcription.json gravado na consulta do dossiê
    (pat/<slug>/C{n}/transcription.json, via store.transcription_path).
    """
    # Default deste stage = Sonnet (ver config.STAGE_DEFAULTS). Override explícito vence.
    model = model or "sonnet"
    src_path = Path(transcription_json_path)
    filename = src_path.name

    # 1) Carrega o JSON de transcrição (campo `transcricao` ou `text`).
    data = read_json(src_path)
    text = (data.get("transcricao") or data.get("text") or "").strip()
    if not text:
        raise ValueError(f"Transcrição vazia em {src_path}")

    # 2) Extrai metadados (identifica paciente/profissional).
    metadata = _extract_metadata(text, filename, model=model)

    # 4) Resolve dossiê: existente por nome, ou novo ID + estrutura.
    #    (Resolvido antes de gravar para conhecer o patient_id e o caminho de saída.)
    existing = find_existing_patient(metadata.patient_name)
    is_new = existing is None
    patient_id = existing or generate_patient_id(metadata.patient_name)
    ensure_dossier(patient_id)

    date = today()
    out_path = transcription_path(patient_id, date)

    # Idempotência: output já existe e não forçado → retorna sem reprocessar.
    if out_path.exists() and not force:
        log.info("skip_cached", file=filename, patient_id=patient_id, out=str(out_path))
        return out_path

    # 3) Corrige a transcrição se necessário; senão usa o texto original.
    #    O resultado é SEMPRE o diálogo COMPLETO (ambos falantes).
    if metadata.needs_correction:
        correction = _correct_transcription(text, metadata.correction_notes, model=model)
        corrected_text = correction.corrected_text
        corrections = correction.corrections_made
    else:
        corrected_text = text
        corrections = []

    # Suplementar: fala isolada do paciente (NUNCA substitui a transcrição canônica).
    patient_speech = _extract_patient_speech(
        corrected_text, metadata.patient_name, metadata.professional_name, model=model
    )

    # 5) Grava NormalizedTranscription (transcription_corrected = diálogo completo).
    artifact = NormalizedTranscription(
        source_file=filename,
        processed_at=now_iso(),
        transcription_original=text,
        transcription_corrected=corrected_text,  # diálogo COMPLETO
        correction_applied=metadata.needs_correction,
        corrections=corrections,
        metadata=metadata.model_dump(),
        patient_speech=patient_speech,  # suplementar / opcional
    )
    write_json(out_path, artifact.model_dump())
    log.info(
        "normalized",
        file=filename,
        patient_id=patient_id,
        out=str(out_path),
        corrected=metadata.needs_correction,
        new_patient=is_new,
    )

    # 6) Atualiza info.json (sessions[] desduplicado por source_file).
    _update_info(patient_id, metadata, filename, date, is_new=is_new)

    return out_path
