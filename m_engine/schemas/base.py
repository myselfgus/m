"""
Envelopes-base dos artefatos do pipeline.

Cada stage grava um envelope com proveniência (source, modelo, timestamp, versão)
envolvendo o payload analítico daquele stage. Os schemas detalhados de cada payload
(ASL, dimensional, GEM, SOAP) vivem nos módulos schemas/<stage>.py.

Política de validação: o payload analítico usa `extra="allow"` para não quebrar com
campos extras do LLM; a validação estrita fica nos sub-schemas quando definidos.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from m_engine.util import now_iso


class Artifact(BaseModel):
    """Envelope comum a todos os artefatos do pipeline."""

    model_config = ConfigDict(extra="allow")

    patient_id: str
    source_file: str | None = None
    processed_at: str = Field(default_factory=now_iso)
    model: str = ""
    analysis_version: str = ""


class TranscriptionArtifact(BaseModel):
    """Saída do stage de transcrição (audio/transcriptions/*.json)."""

    model_config = ConfigDict(extra="allow")

    arquivo: str
    data: str = Field(default_factory=now_iso)
    servico: str = "elevenlabs_scribe_v1"
    idioma: str = "por"
    confianca: float = 0.0
    diarizacao: bool = True
    transcricao: str


class NormalizedTranscription(BaseModel):
    """
    Saída do stage normalize (pat/<id>/transcriptions/<date>_transcription.json).
    REGRA: `transcription_corrected` é o DIÁLOGO COMPLETO (ambos falantes).
    A fala isolada do paciente, se extraída, é SUPLEMENTAR (patient_speech), nunca a canônica.
    """

    model_config = ConfigDict(extra="allow")

    source_file: str
    processed_at: str = Field(default_factory=now_iso)
    transcription_original: str
    transcription_corrected: str  # diálogo completo
    correction_applied: bool = False
    corrections: list[str] = Field(default_factory=list)
    metadata: dict[str, Any] = Field(default_factory=dict)
    patient_speech: str | None = None  # suplementar, opcional
