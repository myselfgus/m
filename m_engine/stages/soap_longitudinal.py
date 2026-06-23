"""
Stage `soap_longitudinal` — SOAP de acompanhamento (análise evolutiva).

Compara 2 a 5 consultas sequenciais (C1 → C2 → ...) de um mesmo paciente,
gerando um documento SOAP+BIRP longitudinal em Markdown.

Para cada data informada, carrega a tupla:
  (transcrição, ASL, VDLP/dimensional, GEM opcional)
usando o naming UNIFICADO do store (store.transcription_path / asl_path /
dimensional_path / gem_path). Isso resolve a inconsistência de nomes do legado
(ex.: `.gem.json` vs `_GEM.json`).

Pipeline (porte fiel do legado, com UMA mudança obrigatória):
  1. Seções S+O+A (análise evolutiva comparativa, BIRP, setas ↗↘→)
  2. Seção P (plano evolutivo)

★ MUDANÇA EM RELAÇÃO AO LEGADO: o legado gerava a seção P com Grok-4. Aqui NÃO
  se usa Grok nem qualquer outro LLM externo — TODAS as seções (S/O/A e P) usam
  o modelo default do pipeline (Claude Opus 4.8) via providers.llm.complete.
  O parâmetro `model=None` resolve para o default em config.resolve_model.

Saída: pat/<id>/clinical-documents/<PID>_SOAP_LONG_<range>_<ts>.md
Idempotência: se já existir um documento para o mesmo range e force=False,
retorna o caminho existente mais recente sem reprocessar.
"""

from __future__ import annotations

import json
import re
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
from m_engine.util import load_prompt, now_iso

log = structlog.get_logger("m_engine.soap_longitudinal")

# Delimitador que separa os DOIS system prompts em prompts/soap_longitudinal.md
_PROMPT_DELIM = "===PLANO==="


def prewarm_blocks() -> list[list["llm.SystemBlock"]]:
    """System prompts (S/O/A e Plano) deste stage para pré-aquecer o cache."""
    raw = re.sub(r"<!--.*?-->", "", load_prompt("soap_longitudinal"), flags=re.DOTALL)
    soa, plan = (p.strip() for p in raw.split(_PROMPT_DELIM, 1))
    return [[llm.SystemBlock(text=soa, cache=True)], [llm.SystemBlock(text=plan, cache=True)]]

# Limites de truncamento dos JSONs no user prompt (espelham o legado TS)
_MAX_ASL_CHARS = 30000
_MAX_VDLP_CHARS = 30000
_MAX_GEM_CHARS = 15000
_MAX_TRANSCRIPTION_CHARS = 20000
_MAX_DIMS_CHARS = 3000

_VERSION = "soap_longitudinal_v1_opus"


# ---------------------------------------------------------------------------
# Estrutura de sessão (uma consulta carregada)
# ---------------------------------------------------------------------------


class _Session:
    """Dados de UMA consulta (transcrição + ASL + VDLP + GEM opcional)."""

    def __init__(self, number: int, date: str, transcription: str, asl: dict, vdlp: dict, gem: dict | None):
        self.number = number  # C1, C2, ... (1-indexed)
        self.date = date
        self.transcription = transcription
        self.asl = asl
        self.vdlp = vdlp
        self.gem = gem


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _truncate_json(obj: dict, max_chars: int) -> str:
    """Serializa um JSON (indentado) e trunca como no legado, sinalizando o corte."""
    text = json.dumps(obj, ensure_ascii=False, indent=2)
    if len(text) > max_chars:
        return text[:max_chars] + "\n\n[TRUNCADO - Use os dados disponíveis]"
    return text


def _truncate_text(text: str, max_chars: int) -> str:
    """Trunca texto cru (transcrição) sinalizando o corte."""
    if len(text) > max_chars:
        return text[:max_chars] + "\n\n[TRUNCADO]"
    return text


def _load_session(patient_id: str, date: str, number: int) -> _Session:
    """
    Carrega a tupla (transcrição, ASL, VDLP, GEM opcional) de uma consulta,
    usando exclusivamente o naming unificado do store.
    """
    # Transcrição (diálogo completo); aceita tanto o campo legado `transcricao`
    # quanto o `transcription_corrected` do stage normalize.
    tpath = transcription_path(patient_id, date)
    if not tpath.exists():
        raise FileNotFoundError(f"Transcrição não encontrada: {tpath}")
    tdata = read_json(tpath)
    transcription = tdata.get("transcricao") or tdata.get("transcription_corrected") or ""

    # ASL (obrigatório)
    apath = asl_path(patient_id, date)
    if not apath.exists():
        raise FileNotFoundError(f"ASL não encontrada: {apath}")
    asl = read_json(apath)

    # VDLP / dimensional (obrigatório)
    dpath = dimensional_path(patient_id, date)
    if not dpath.exists():
        raise FileNotFoundError(f"VDLP (dimensional) não encontrada: {dpath}")
    vdlp = read_json(dpath)

    # GEM (opcional)
    gpath = gem_path(patient_id, date)
    gem = read_json(gpath) if gpath.exists() else None

    return _Session(number, date, transcription, asl, vdlp, gem)


def _build_session_block(session: _Session) -> str:
    """Monta o bloco de dados de uma consulta para o user prompt S/O/A."""
    n = session.number
    block = f"""
# CONSULTA {n} (C{n}) — {session.date}

**NOTA**: A transcrição completa está em ASL.linguistic_analysis.transcricao_filtrada.fala_falante_completa

## ASL C{n}

{_truncate_json(session.asl, _MAX_ASL_CHARS)}

## VDLP C{n}

{_truncate_json(session.vdlp, _MAX_VDLP_CHARS)}
"""
    if session.gem is not None:
        block += f"\n## GEM C{n}\n\n{_truncate_json(session.gem, _MAX_GEM_CHARS)}\n"
    block += "\n---\n"
    return block


def _build_soa_user_prompt(sessions: list[_Session], info: dict) -> str:
    """User prompt das seções S/O/A — itera sobre todas as sessões (porte do legado)."""
    nome = info.get("patient_name") or info.get("nome") or "Não informado"
    idade = info.get("idade") or info.get("age") or "Não informada"

    session_data = "".join(_build_session_block(s) for s in sessions)
    first, last = sessions[0].number, sessions[-1].number

    return f"""# DADOS DO PACIENTE

Nome: {nome}
Idade: {idade}

{session_data}

# TAREFA

Gere as seções S, O, A do SOAP Longitudinal comparando C{first} → C{last}.

Foque em:
- **Evolução dimensional** (mudanças quantitativas nas 15 dimensões ℳ)
- **Resposta a intervenções** (medicamentosas e não-medicamentosas)
- **Padrões emergentes** (insights, mudanças narrativas)
- **Análise linguística evolutiva** (dados ASL comparativos)

**LEMBRE-SE**:
- Para citações comparativas: USE ASL.transcricao_filtrada de cada consulta
- Para métricas evolutivas: COMPARE scores VDLP entre C1, C2, C3...
- Para mudanças linguísticas: COMPARE ASL.metricas_quantitativas entre consultas
- NÃO precisa da transcrição separada - está tudo dentro do ASL e VDLP de cada consulta

Retorne em formato Markdown, seguindo rigorosamente as diretrizes fornecidas."""


def _build_plan_user_prompt(soa: str, sessions: list[_Session]) -> str:
    """User prompt da seção P — usa a análise S/O/A + a consulta mais recente (porte do legado)."""
    latest = sessions[-1]
    # Dimensões atuais: tenta o caminho do legado, com fallback tolerante ao schema.
    dims = (latest.vdlp.get("dimensional_analysis") or {}).get("dimensoes_espaco_mental") or {}
    if not dims:
        raise ValueError("VDLP da consulta mais recente sem 'dimensoes_espaco_mental'.")
    dims_text = json.dumps(dims, ensure_ascii=False, indent=2)[:_MAX_DIMS_CHARS]

    return f"""# ANÁLISE EVOLUTIVA PRÉVIA (S+O+A)

{soa}

# TRANSCRIÇÃO MAIS RECENTE (C{latest.number})

{_truncate_text(latest.transcription, _MAX_TRANSCRIPTION_CHARS)}

# DIMENSÕES ATUAIS (C{latest.number})

{dims_text}

---

Gere a seção P do SOAP Longitudinal em formato Markdown, seguindo rigorosamente as diretrizes fornecidas."""


def _assemble_document(soa: str, plan: str, sessions: list[_Session], info: dict) -> str:
    """Monta o Markdown final preservando cabeçalho/rodapé do legado."""
    now = datetime.now(timezone.utc)
    date_str = now.strftime("%d/%m/%Y")
    time_str = now.strftime("%H:%M")

    nome = info.get("patient_name") or info.get("nome") or "Paciente não informado"
    idade = info.get("idade") or info.get("age") or "Não informada"
    genero = info.get("genero") or info.get("gender") or "Não informado"
    profissional = info.get("professional_name") or info.get("profissional") or "Profissional não configurado"
    registro = info.get("registro") or info.get("professional_registry") or "Registro não configurado"

    first, last = sessions[0].number, sessions[-1].number
    session_range = f"C{first} → C{last}"
    consultas = " → ".join(f"C{s.number}" for s in sessions)
    datas = ", ".join(s.date for s in sessions)

    return f"""# SOAP — Seguimento

**Paciente:** {nome}  ·  **Idade:** {idade}  ·  {genero}
**Consultas comparadas:** {consultas}  ·  **Datas:** {datas}
**Profissional:** {profissional}{f" — {registro}" if registro and registro != "Registro não configurado" else ""}

---

{soa}

---

{plan}

---

© 2026 IREAJE"""


def _output_path(patient_id: str, sessions: list[_Session], ts: str) -> Path:
    """Caminho de saída: <PID>_SOAP_LONG_<range>_<ts>.md em clinical-documents/."""
    rng = f"C{sessions[0].number}-C{sessions[-1].number}"
    root = ensure_dossier(patient_id)
    return root / "clinical-documents" / f"{patient_id}_SOAP_LONG_{rng}_{ts}.md"


def _find_existing(patient_id: str, sessions: list[_Session]) -> Path | None:
    """Para idempotência: procura documento já gerado para o mesmo range."""
    rng = f"C{sessions[0].number}-C{sessions[-1].number}"
    docs_dir = ensure_dossier(patient_id) / "clinical-documents"
    prefix = f"{patient_id}_SOAP_LONG_{rng}_"
    matches = sorted(p for p in docs_dir.glob(f"{prefix}*.md"))
    return matches[-1] if matches else None


# ---------------------------------------------------------------------------
# Entry point do stage (CONTRATO de stages/__init__.py)
# ---------------------------------------------------------------------------


def run(patient_id: str, dates: list[str], *, model: str | None = None, force: bool = False) -> Path:
    """
    Gera o SOAP Longitudinal comparando 2-5 consultas.

    Args:
        patient_id: ID do paciente (PAT_<INICIAIS>_<NN>).
        dates: lista ORDENADA de datas (YYYY-MM-DD), de C1 (mais antiga) a Cn.
        model: alias de config.MODELS; None → Sonnet (default deste stage, ver
               config.STAGE_DEFAULTS). ★ Sem Grok: P usa o MESMO default de S/O/A.
        force: se False e já existir documento para o range, retorna-o sem reprocessar.

    Returns:
        Path do Markdown gerado em pat/<id>/clinical-documents/.
    """
    model = model or "sonnet"
    if not (2 <= len(dates) <= 5):
        raise ValueError(f"SOAP Longitudinal requer 2 a 5 consultas; recebidas {len(dates)}.")

    # Carrega as sessões na ordem fornecida (C1 → Cn)
    sessions = [_load_session(patient_id, date, i + 1) for i, date in enumerate(dates)]

    # Idempotência por range
    if not force:
        existing = _find_existing(patient_id, sessions)
        if existing is not None:
            log.info("skip_cached", patient=patient_id, doc=existing.name)
            return existing

    info = load_info(patient_id)

    # Split dos DOIS system prompts (S/O/A e P) por delimitador
    raw_prompt = load_prompt("soap_longitudinal")
    if _PROMPT_DELIM not in raw_prompt:
        raise ValueError(f"Delimitador {_PROMPT_DELIM!r} ausente em prompts/soap_longitudinal.md")
    # Remove o bloco de comentário <!-- ... --> (documentação do arquivo de prompt)
    raw_prompt = re.sub(r"<!--.*?-->", "", raw_prompt, flags=re.DOTALL)
    system_soa, system_plan = (part.strip() for part in raw_prompt.split(_PROMPT_DELIM, 1))

    # 1) Seções S+O+A — Claude Opus 4.8 (default)
    log.info("gerando_soa", patient=patient_id, consultas=len(sessions))
    soa = llm.complete(
        system=[llm.SystemBlock(text=system_soa, cache=True)],
        user=_build_soa_user_prompt(sessions, info),
        model=model,  # None → default (sonnet); NUNCA Grok
        temperature=0.3,
    ).content

    # 2) Seção P — MESMO modelo default (★ remoção do Grok do legado)
    log.info("gerando_plano", patient=patient_id)
    plan = llm.complete(
        system=[llm.SystemBlock(text=system_plan, cache=True)],
        user=_build_plan_user_prompt(soa, sessions),
        model=model,  # None → default (sonnet); NUNCA Grok
        temperature=0.4,
    ).content

    # Monta e grava o documento final
    document = _assemble_document(soa, plan, sessions, info)
    ts = now_iso().replace(":", "-").replace(".", "-")[:19]
    out = _output_path(patient_id, sessions, ts)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(document, encoding="utf-8")

    log.info("soap_longitudinal_ok", patient=patient_id, out=str(out))
    return out
