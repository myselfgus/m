"""
Stage — SOAP Trajetorial (documentação clínica de PRIMEIRA CONSULTA, C1).

Integra transcrição + ASL + VDLP (+ GEM opcional) do paciente/data e produz um
documento SOAP+DAP em Markdown gravado em pat/<id>/clinical-documents/.

Estrutura (porte fiel do legado medscribe-soap-trajetorial.ts):
  - Bloco CLÍNICO  → seções S (Subjetivo), O (Objetivo), A (Avaliação)
  - Bloco PLANO    → seções P (Plano) e A (Análise preditiva/estratégica)

★ MUDANÇA OBRIGATÓRIA vs legado: o legado gerava o bloco PLANO com Grok
  (clientGrok / MODEL_GROK). Isso foi REMOVIDO. AMBOS os blocos agora usam o
  modelo DEFAULT do pipeline (Claude Opus 4.8) via providers.llm.complete,
  resolvido por `model` (None → default). Não há hardcode de provider aqui.

Os DOIS system prompts vivem em m_engine/prompts/soap_trajetorial.md, separados
pelos delimitadores "## === SYSTEM: CLINICO ===" e "## === SYSTEM: PLANO ===".
Os user prompts são montados em código, truncando JSONs grandes como no legado.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import structlog

from m_engine.providers import llm
from m_engine.store import (
    asl_path,
    dimensional_path,
    ensure_dossier,
    gem_path,
    load_info,
    read_json,
    transcription_path,
)
from m_engine.util import load_prompt

log = structlog.get_logger("m_engine.soap_trajetorial")

# Delimitadores dos dois system prompts dentro de prompts/soap_trajetorial.md
_DELIM_CLINICO = "## === SYSTEM: CLINICO ==="
_DELIM_PLANO = "## === SYSTEM: PLANO ==="

# Limites de truncamento dos JSONs interpolados nos user prompts (iguais ao legado)
_TRUNC_ASL = 50_000
_TRUNC_VDLP = 50_000
_TRUNC_GEM_CLINICO = 30_000  # GEM no bloco clínico
_TRUNC_GEM_PLANO = 5_000  # GEM no bloco plano
_TRUNC_VDLP_PLANO = 2_000  # recorte de dimensões no bloco plano


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _dump(obj: object) -> str:
    """Serializa para JSON indentado (None vira string 'null' explícita)."""
    return json.dumps(obj, ensure_ascii=False, indent=2)


def _truncate(text: str, limit: int) -> str:
    """Trunca preservando a marca do legado quando o JSON é grande demais."""
    if len(text) > limit:
        return text[:limit] + "\n\n[TRUNCADO - Use os dados disponíveis]"
    return text


def _split_system_prompts() -> tuple[str, str]:
    """Carrega o .md único e separa os dois system prompts pelos delimitadores."""
    raw = load_prompt("soap_trajetorial")
    if _DELIM_CLINICO not in raw or _DELIM_PLANO not in raw:
        raise ValueError(
            "prompts/soap_trajetorial.md não contém os delimitadores esperados "
            f"({_DELIM_CLINICO!r} / {_DELIM_PLANO!r})."
        )
    # Tudo após CLINICO e antes de PLANO = system clínico; após PLANO = system plano.
    _, after_clinico = raw.split(_DELIM_CLINICO, 1)
    clinico, plano = after_clinico.split(_DELIM_PLANO, 1)
    return clinico.strip(), plano.strip()


def prewarm_blocks() -> list[list["llm.SystemBlock"]]:
    """System prompts (clínico e plano) deste stage para pré-aquecer o cache."""
    clinico, plano = _split_system_prompts()
    return [[llm.SystemBlock(text=clinico, cache=True)], [llm.SystemBlock(text=plano, cache=True)]]


def _timestamp() -> str:
    """Timestamp do arquivo no padrão do legado: ISO sem ':'/'.' até os segundos."""
    return datetime.now(timezone.utc).isoformat().replace(":", "-").replace(".", "-")[:19]


# ---------------------------------------------------------------------------
# Geração das seções (ambos os blocos no MODELO DEFAULT — sem Grok)
# ---------------------------------------------------------------------------


def _generate_clinical_analysis(
    asl: dict, vdlp: dict, gem: dict | None, patient_info: dict, transcript: str, *, model: str | None
) -> str:
    """Gera as seções S, O, A (narrativa-fenomenológica + EEM a partir da transcrição)."""
    system, _ = _split_system_prompts()

    asl_block = _truncate(_dump(asl), _TRUNC_ASL)
    vdlp_block = _truncate(_dump(vdlp), _TRUNC_VDLP)
    if gem is not None:
        gem_block = "# GRAFO DO ESPAÇO-CAMPO MENTAL (GEM)\n\n" + _truncate(_dump(gem), _TRUNC_GEM_CLINICO)
    else:
        gem_block = "# GEM não disponível"

    user = f"""# DADOS DO PACIENTE

Nome: {patient_info.get("nome") or patient_info.get("patient_name") or "Não informado"}
Idade: {patient_info.get("idade") or "Não informada"}
Prontuário: {patient_info.get("prontuario") or "_____________________"}

# TRANSCRIÇÃO DA CONSULTA (diálogo completo — médico e paciente)

{transcript}

# ANÁLISE SISTÊMICA LINGUÍSTICA (ASL) — fala do paciente

{asl_block}

# 15 DIMENSÕES DO ESPAÇO MENTAL (VDLP)

{vdlp_block}

{gem_block}

---

Redija as seções **S, O, A** do SOAP em Markdown, seguindo rigorosamente as diretrizes do system.
Use a TRANSCRIÇÃO para a narrativa fenomenológica e o Exame do Estado Mental; ASL/VDLP/GEM
sustentam os achados (citações literais e métricas). Não invente dados."""

    log.info("clinical_analysis", model=model or "default")
    res = llm.complete(system=[llm.SystemBlock(text=system, cache=True)], user=user, model=model, temperature=0.3)
    return res.content.strip()


def _generate_therapeutic_plan(
    clinical_analysis: str,
    asl: dict,
    vdlp: dict,
    gem: dict | None,
    patient_info: dict,
    transcript: str,
    *,
    model: str | None,
) -> str:
    """Gera a seção P (conduta), incluindo a conduta que o MÉDICO indicou na sessão."""
    _, system = _split_system_prompts()

    # Recortes-chave do legado (navegação defensiva — ASL/VDLP são dicts livres).
    asl_metrics = (asl.get("linguistic_analysis") or {}).get("metricas_quantitativas") or {}
    vdlp_dims = (vdlp.get("dimensional_analysis") or {}).get("dimensoes_espaco_mental") or {}
    if not vdlp_dims:
        raise ValueError(
            "VDLP sem 'dimensoes_espaco_mental' — plano não pode ser gerado sobre dimensões vazias. "
            "Rode/reprocesse o stage 'dimensional'."
        )
    vdlp_dims_block = _dump(vdlp_dims)[:_TRUNC_VDLP_PLANO]

    if gem is not None:
        gem_block = "**GEM - Grafo do Espaço-Campo Mental**:\n" + _truncate(_dump(gem), _TRUNC_GEM_PLANO)
    else:
        gem_block = "**GEM**: Não disponível"

    user = f"""# ANÁLISE CLÍNICA PRÉVIA (S+O+A)

{clinical_analysis}

# TRANSCRIÇÃO DA CONSULTA (diálogo completo — médico e paciente)

**IMPORTANTE**: extraia da fala do MÉDICO a conduta que ele indicou durante a sessão
(medicamentos prescritos/suspensos, doses, exames, encaminhamentos, orientações, retorno)
e torne-a EXPLÍCITA na seção P. A conduta documentada deve refletir o que o médico disse.

{transcript}

# DADOS DIMENSIONAIS (Referência)

**ASL - Métricas Linguísticas Chave**:
{_dump(asl_metrics)}

**VDLP - Dimensões ℳ Principais**:
{vdlp_dims_block}

{gem_block}

# INFORMAÇÕES DO PACIENTE

Nome: {patient_info.get("nome") or patient_info.get("patient_name") or "Não informado"}
Idade: {patient_info.get("idade") or "Não informada"}

---

Redija a seção **P (Conduta)** do SOAP em Markdown, seguindo as diretrizes do system.
Priorize a conduta efetivamente indicada pelo médico na sessão; complemente com o plano
fundamentado em ASL/VDLP/GEM sem contradizê-la."""

    log.info("therapeutic_plan", model=model or "default")
    res = llm.complete(system=[llm.SystemBlock(text=system, cache=True)], user=user, model=model, temperature=0.4)
    return res.content.strip()


# ---------------------------------------------------------------------------
# Montagem do documento (cabeçalho/rodapé VOITHER preservados do legado)
# ---------------------------------------------------------------------------


def _assemble_document(
    clinical_analysis: str,
    therapeutic_plan: str,
    patient_info: dict,
    professional_info: dict,
    session_date: str,
) -> str:
    """Monta o Markdown final com cabeçalho/rodapé VOITHER do legado."""
    now = datetime.now(timezone.utc)
    date_str = now.strftime("%d/%m/%Y")
    time_str = now.strftime("%H:%M")

    nome = patient_info.get("nome") or patient_info.get("patient_name") or "Não informado"
    idade = patient_info.get("idade") or "Não informada"
    prontuario = patient_info.get("prontuario") or "_____________________"
    prof_nome = professional_info.get("nome") or "Profissional não configurado"
    prof_registro = professional_info.get("registro") or "Registro não configurado"

    return f"""# SOAP — Sumário

**Paciente:** {nome}  ·  **Idade:** {idade}  ·  **Prontuário:** {prontuario}
**Data da consulta:** {session_date or date_str}  ·  **Tipo:** Primeira consulta psiquiátrica
**Profissional:** {prof_nome}{f" — {prof_registro}" if prof_registro and prof_registro != "Registro não configurado" else ""}

---

{clinical_analysis}

---

{therapeutic_plan}

---

© 2026 IREAJE"""


# ---------------------------------------------------------------------------
# Entry point (CONTRATO)
# ---------------------------------------------------------------------------


def run(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> Path:
    """
    Gera o SOAP Trajetorial (C1) e grava .md em clinical-documents/.

    Inputs (do paciente/data via store): transcrição + ASL + VDLP + GEM (opcional).
    `model` é alias de config.MODELS; None → Sonnet (default deste stage, ver
    config.STAGE_DEFAULTS) para TODAS as seções (S, O, A, P). Override explícito vence.
    `force` regrava mesmo havendo output anterior.

    Idempotência: como o nome do arquivo carrega timestamp, reusa o documento mais
    recente existente quando force=False (não há reprocessamento desnecessário).
    """
    model = model or "sonnet"
    root = ensure_dossier(patient_id)
    out_dir = root / "clinical-documents"

    # Idempotência: já existe um SOAP_TRAJETORIAL gerado? Reusa o mais recente.
    if not force:
        existing = sorted(out_dir.glob(f"{patient_id}_SOAP_TRAJETORIAL_*.md"))
        if existing:
            log.info("skip_cached", patient=patient_id, out=str(existing[-1]))
            return existing[-1]

    # Inputs obrigatórios.
    tpath = transcription_path(patient_id, date)
    apath = asl_path(patient_id, date)
    vpath = dimensional_path(patient_id, date)
    if not tpath.exists():
        raise FileNotFoundError(f"Transcrição não encontrada: {tpath}")
    if not apath.exists():
        raise FileNotFoundError(f"ASL não encontrada: {apath}. Rode o stage 'asl' primeiro.")
    if not vpath.exists():
        raise FileNotFoundError(f"VDLP não encontrada: {vpath}. Rode o stage 'dimensional' primeiro.")

    asl = read_json(apath)
    vdlp = read_json(vpath)

    # Transcrição COMPLETA (diálogo médico+paciente) — necessária para EEM e para
    # extrair a conduta que o médico indicou na sessão.
    tdata = read_json(tpath)
    transcript = (
        tdata.get("transcription_corrected") or tdata.get("transcricao") or tdata.get("text") or ""
    )

    # GEM é opcional.
    gpath = gem_path(patient_id, date)
    gem = read_json(gpath) if gpath.exists() else None

    # Metadados de paciente; profissional vem de info.json (chave 'professional' se houver).
    patient_info = load_info(patient_id)
    professional_info = patient_info.get("professional") or patient_info.get("profissional") or {}

    # Bloco clínico (S, O, A) — narrativa-fenomenológica + EEM da transcrição.
    clinical_analysis = _generate_clinical_analysis(asl, vdlp, gem, patient_info, transcript, model=model)
    # Bloco plano (P) — conduta indicada pelo médico na sessão + plano fundamentado.
    therapeutic_plan = _generate_therapeutic_plan(
        clinical_analysis, asl, vdlp, gem, patient_info, transcript, model=model
    )

    # Data da sessão: a do argumento (já é a data do encontro).
    session_date = date
    document = _assemble_document(
        clinical_analysis, therapeutic_plan, patient_info, professional_info, session_date
    )

    out_path = out_dir / f"{patient_id}_SOAP_TRAJETORIAL_{_timestamp()}.md"
    out_path.write_text(document, encoding="utf-8")
    log.info("soap_trajetorial_done", patient=patient_id, out=str(out_path))
    return out_path
