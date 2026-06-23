"""
Stage `dimensional` — VDLP (15 Dimensões do Espaço Mental ℳ, v1..v15).

Extrai dimensões psicológicas a partir da ASL pré-computada + transcrição filtrada
do paciente. Cada dimensão é fundamentada em componentes da ASL e validada contra
frameworks psicométricos (RDoC, HiTOP, Big5, PERMA).

Pipeline (porte fiel do legado TS, sem Cloudflare / paths hardcoded):
  1. Lê ASL (store.asl_path) e extrai a fala do paciente de dentro dela
     (linguistic_analysis.transcricao_filtrada.fala_falante_completa; fallback transcrição).
  2. Monta system prompt MASSIVO via util.load_prompt("dimensional") com prompt caching.
  3. Se (ASL + fala) > 10k tokens: divide a FALA em chunks (a ASL é fixa e repetida em
     cada chunk), processa cada chunk e consolida (concat de evidencias_textuais e
     componentes_asl_usados com dedup; MANTÉM o score do 1º chunk).
  4. Grava envelope dimensional em store.dimensional_path.

Contrato: dimensional.run(patient_id, date, *, model=None, force=False) -> Path
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import structlog

from m_engine import store
from m_engine.config import resolve_model
from m_engine.providers.llm import SystemBlock, complete_json
from m_engine.schemas.dimensional import DimensionalAnalysis
from m_engine.util import estimate_tokens, load_prompt, now_iso, split_into_chunks

log = structlog.get_logger("m_engine.dimensional")

# Threshold (em tokens) acima do qual a fala do paciente é dividida em chunks.
# Mantido idêntico ao legado.
CHUNK_THRESHOLD_TOKENS = 10_000
# Tamanho máximo de cada chunk de fala (idêntico ao legado).
MAX_TOKENS_PER_CHUNK = 15_000

ANALYSIS_VERSION = "1.0-dimensional"


def prewarm_blocks() -> list[list[SystemBlock]]:
    """System prompt(s) deste stage para pré-aquecer o cache (mesma chave do run)."""
    return [_system_blocks()]


# ---------------------------------------------------------------------------
# Extração da fala do paciente
# ---------------------------------------------------------------------------


def _extract_patient_speech(asl_data: dict, fallback: str) -> str:
    """
    Recupera a fala filtrada do paciente de dentro da ASL:
      linguistic_analysis.transcricao_filtrada.fala_falante_completa
    Fallback: a transcrição completa passada.
    """
    speech = (
        asl_data.get("linguistic_analysis", {})
        .get("transcricao_filtrada", {})
        .get("fala_falante_completa")
    )
    return speech or fallback


# ---------------------------------------------------------------------------
# Montagem dos prompts
# ---------------------------------------------------------------------------


def _build_user_message(
    patient_id: str,
    asl_json_string: str,
    speech: str,
    *,
    chunk_index: int | None = None,
    chunk_total: int | None = None,
) -> str:
    """Monta o user message. Se chunk_index for dado, anota a porção do discurso."""
    # Cabeçalho da seção de transcrição muda quando estamos em modo chunk.
    if chunk_index is not None and chunk_total is not None:
        trans_header = (
            f"## TRANSCRIÇÃO FILTRADA CHUNK {chunk_index}/{chunk_total} (apenas paciente)"
        )
        chunk_note = (
            f"\nIMPORTANTE: Este é o chunk {chunk_index} de {chunk_total}. "
            f"Extraia as dimensões baseadas nesta porção do discurso.\n"
        )
    else:
        trans_header = "## TRANSCRIÇÃO FILTRADA (apenas paciente)"
        chunk_note = ""

    return f"""# DADOS PARA EXTRAÇÃO DIMENSIONAL

Falante ID: {patient_id}

## ANÁLISE LINGUÍSTICA SISTÊMICA (ASL)
Use esta ASL como BASE para extração das 15 dimensões:

{asl_json_string}

{trans_header}
{speech}

## INSTRUÇÕES DE EXTRAÇÃO

1. **USAR A ASL COMO BASE**: Todos os scores devem ser derivados dos componentes da ASL fornecida
2. **EXTRAIR AS 15 DIMENSÕES**: Seguindo rigorosamente o framework de validação
3. **RASTREABILIDADE COMPLETA**: Para cada dimensão liste componentes ASL usados com caminhos JSON completos
4. **MAPEAMENTO EXPLÍCITO**: Preencha valores_asl_extraidos com valores numéricos da ASL
5. **VALIDAÇÃO CRUZADA**: Verifique consistência entre dimensões relacionadas
6. **SÍNTESE INTEGRATIVA**: Forneça perfil dimensional coerente ao final
{chunk_note}
Responda APENAS com o JSON completo conforme o schema fornecido."""


def _system_blocks() -> list[SystemBlock]:
    """System prompt MASSIVO (1 bloco) com prompt caching ativado."""
    # O prompt completo (missão + frameworks + schema) vive em prompts/dimensional.md.
    # Um único bloco cacheável é suficiente para o caching nativo da Anthropic.
    return [SystemBlock(text=load_prompt("dimensional"), cache=True)]


# ---------------------------------------------------------------------------
# Consolidação de chunks
# ---------------------------------------------------------------------------


def _dedup_extend(target: list[Any], extra: list[Any]) -> None:
    """Estende `target` com itens de `extra` preservando ordem e evitando duplicatas."""
    seen = set(target)
    for item in extra:
        if item not in seen:
            target.append(item)
            seen.add(item)


def _consolidate(chunk_analyses: list[dict]) -> dict:
    """
    Consolida análises dimensionais de múltiplos chunks.

    Regra do legado: usa o 1º chunk como base e, para cada dimensão,
      - concatena evidencias_textuais (todas, sem dedup — são citações por chunk)
      - concatena componentes_asl_usados COM dedup
      - MANTÉM o score do 1º chunk (não faz média: o score deriva da ASL completa,
        que é única e repetida em cada chunk).
    """
    consolidated = chunk_analyses[0]

    for chunk in chunk_analyses[1:]:
        dims = consolidated.get("dimensoes_espaco_mental")
        chunk_dims = chunk.get("dimensoes_espaco_mental")
        if not isinstance(dims, dict) or not isinstance(chunk_dims, dict):
            continue

        for key, dim in dims.items():
            chunk_dim = chunk_dims.get(key)
            if not isinstance(dim, dict) or not isinstance(chunk_dim, dict):
                continue

            # Concatenar evidências textuais (sem dedup, como no legado)
            ev = dim.get("evidencias_textuais")
            chunk_ev = chunk_dim.get("evidencias_textuais")
            if isinstance(ev, list) and isinstance(chunk_ev, list):
                ev.extend(chunk_ev)

            # Concatenar componentes ASL usados com dedup
            comp = dim.get("componentes_asl_usados")
            chunk_comp = chunk_dim.get("componentes_asl_usados")
            if isinstance(comp, list) and isinstance(chunk_comp, list):
                _dedup_extend(comp, chunk_comp)

            # Score: mantém o do 1º chunk (já presente em `dim`) — nada a fazer.

    return consolidated


# ---------------------------------------------------------------------------
# Chamada LLM (single ou chunked)
# ---------------------------------------------------------------------------


def _analyze(
    patient_id: str,
    asl_data: dict,
    speech: str,
    model: str | None,
) -> dict:
    """Executa a extração dimensional, fazendo chunking quando necessário."""
    system = _system_blocks()
    asl_json_string = json.dumps(asl_data, ensure_ascii=False, indent=2)

    estimated = estimate_tokens(asl_json_string + speech)
    log.info("dimensional_tokens", patient_id=patient_id, estimated_tokens=estimated)

    if estimated <= CHUNK_THRESHOLD_TOKENS:
        # Caminho direto — texto pequeno.
        user = _build_user_message(patient_id, asl_json_string, speech)
        result = complete_json(
            schema=DimensionalAnalysis,
            system=system,
            user=user,
            model=model,
            debug_name="dimensional",
        )
        return result.model_dump()

    # Caminho com chunking — divide apenas a fala (a ASL é fixa e repetida).
    chunks = split_into_chunks(speech, max_tokens_per_chunk=MAX_TOKENS_PER_CHUNK)
    log.info("dimensional_chunking", patient_id=patient_id, chunks=len(chunks))

    chunk_analyses: list[dict] = []
    total = len(chunks)
    for i, chunk in enumerate(chunks, start=1):
        user = _build_user_message(
            patient_id, asl_json_string, chunk, chunk_index=i, chunk_total=total
        )
        try:
            result = complete_json(
                schema=DimensionalAnalysis,
                system=system,
                user=user,
                model=model,
                debug_name=f"dimensional_chunk{i}",
            )
            chunk_analyses.append(result.model_dump())
        except Exception as err:  # noqa: BLE001 — chunk individual não derruba o lote
            log.warning("dimensional_chunk_failed", patient_id=patient_id, chunk=i, error=str(err)[:300])

    if not chunk_analyses:
        raise RuntimeError("Extração dimensional falhou: nenhum chunk produziu resultado válido.")

    return _consolidate(chunk_analyses)


# ---------------------------------------------------------------------------
# Entry point do stage
# ---------------------------------------------------------------------------


def run(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> Path:
    """
    Extrai as 15 dimensões do Espaço Mental para (patient_id, date).

    Inputs: ASL (store.asl_path) + transcrição filtrada do paciente (de dentro da ASL).
    Output: envelope dimensional em store.dimensional_path.
    Idempotência: se o output existe e force=False, retorna sem reprocessar.
    """
    out_path = store.dimensional_path(patient_id, date)
    if out_path.exists() and not force:
        log.info("dimensional_skip_existing", patient_id=patient_id, date=date, path=str(out_path))
        return out_path

    asl_file = store.asl_path(patient_id, date)
    if not asl_file.exists():
        raise FileNotFoundError(
            f"ASL não encontrada para {patient_id} em {date}: {asl_file}. "
            "Execute o stage 'asl' primeiro."
        )
    asl_data = store.read_json(asl_file)

    # Fallback de transcrição: dialogo completo da transcrição normalizada, se existir.
    fallback_text = ""
    trans_file = store.transcription_path(patient_id, date)
    if trans_file.exists():
        trans_data = store.read_json(trans_file)
        fallback_text = (
            trans_data.get("transcription_corrected")
            or trans_data.get("transcricao")
            or trans_data.get("transcription_original")
            or ""
        )

    speech = _extract_patient_speech(asl_data, fallback_text)
    if not speech:
        raise ValueError(
            f"Nenhuma fala do paciente disponível para {patient_id} em {date} "
            "(ASL sem transcricao_filtrada e sem transcrição de fallback)."
        )

    dimensional_analysis = _analyze(patient_id, asl_data, speech, model)

    # Envelope de proveniência (nomes de campo fiéis ao legado).
    spec = resolve_model(model)
    envelope = {
        "patient_id": patient_id,
        "source_transcription": trans_file.name if trans_file.exists() else None,
        "source_asl": asl_file.name,
        "dimensional_analysis": dimensional_analysis,
        "processed_at": now_iso(),
        "model": spec.id,
        "analysis_version": ANALYSIS_VERSION,
    }

    store.ensure_dossier(patient_id)
    store.write_json(out_path, envelope)
    log.info("dimensional_done", patient_id=patient_id, date=date, path=str(out_path))
    return out_path
