"""
Schemas pydantic do stage `birp` (nota clínica imediata Behavior/Intervention/Response/Plan).

O BIRP é gerado SÓ da transcrição bruta diarizada (sem ASL/VDLP/GEM). O LLM
devolve, num único JSON:
  - Identidade (paciente/iniciais/profissional)
  - As 4 seções BIRP (texto clínico Markdown/pt-BR)
  - Metadados clínicos estruturados para alimentar o info.json
    (icd_codes / medications_mentioned / topicos_principais / clinical_context)

Política: schema PERMISSIVO (`extra="allow"`) em todos os níveis — o LLM pode
acrescentar campos sem quebrar a validação, e `complete_json` ainda garante a
presença das chaves obrigatórias (com 1 rodada de repair).

Os Literais de `certainty`/`context` espelham exatamente o que
store.update_clinical_summary consome (portado de patient-utils.ts).
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class IcdCode(BaseModel):
    """Código diagnóstico mencionado/cogitado na sessão (CID/ICD)."""

    model_config = ConfigDict(extra="allow")

    code: str  # ex.: "F41.1"
    description: str
    # confirmed = diagnóstico firmado; suspected = hipótese; rule_out = a descartar
    certainty: Literal["confirmed", "suspected", "rule_out"] = "suspected"


class MedicationMention(BaseModel):
    """Medicação citada na sessão (com contexto temporal/de uso)."""

    model_config = ConfigDict(extra="allow")

    name: str
    dosage: str | None = None
    # current = em uso; past = uso pregresso; discussed = apenas discutida/cogitada
    context: Literal["current", "past", "discussed"] = "discussed"


class ClinicalContext(BaseModel):
    """Contexto do encontro (tipo de consulta/atendimento)."""

    model_config = ConfigDict(extra="allow")

    # ex.: "primeira_consulta", "retorno", "avaliacao", "urgencia", "psicoterapia"
    encounter_type: str = "consulta"


class BirpNote(BaseModel):
    """
    Saída completa do stage BIRP retornada pelo LLM.

    Reúne identidade + as 4 seções clínicas + metadados estruturados. As seções
    B/I/R/P são texto livre em Markdown (pt-BR); os metadados são consumidos por
    store.register_session(clinical_metadata=...).
    """

    model_config = ConfigDict(extra="allow")

    # ----- Identidade (extraída SÓ da transcrição/nome do arquivo) -----
    patient_name: str = "Paciente"
    patient_initials: str | None = None
    professional_name: str = "Profissional não identificado"

    # ----- Seções BIRP (texto clínico em Markdown/pt-BR) -----
    behavior: str = ""  # B — Comportamento observado/relatado na sessão
    intervention: str = ""  # I — Intervenção realizada pelo profissional
    response: str = ""  # R — Resposta do paciente à intervenção
    plan: str = ""  # P — Plano/encaminhamentos

    # ----- Metadados clínicos para o info.json -----
    icd_codes: list[IcdCode] = Field(default_factory=list)
    medications_mentioned: list[MedicationMention] = Field(default_factory=list)
    topicos_principais: list[str] = Field(default_factory=list)
    clinical_context: ClinicalContext = Field(default_factory=ClinicalContext)

    # ----- Tags livres (3-8), opcional -----
    tags: list[str] = Field(default_factory=list)
