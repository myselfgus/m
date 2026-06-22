"""
Schemas pydantic do stage `normalize` (Stage 1).

Modelam as saídas estruturadas que o LLM produz durante a normalização:
  - ExtractedMetadata     → extração de metadados clínicos da transcrição
  - CorrectedTranscription → resultado da correção/normalização do texto
  - PatientSpeech          → extração SUPLEMENTAR da fala isolada do paciente

REGRA CRÍTICA (ver schemas/base.NormalizedTranscription): a transcrição canônica
gravada no dossiê é SEMPRE o diálogo completo (ambos falantes). PatientSpeech é
material suplementar e NUNCA substitui a transcrição.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class ExtractedMetadata(BaseModel):
    """Metadados extraídos da transcrição pelo LLM (extractMetadata no legado)."""

    # extra="allow": tolera campos adicionais do LLM sem quebrar a validação
    model_config = ConfigDict(extra="allow")

    patient_name: str
    patient_initials: str | None = None
    professional_name: str
    tags: list[str] = Field(default_factory=list)
    confidence: Literal["high", "medium", "low"] = "medium"
    needs_correction: bool = False
    correction_notes: str | None = None


class CorrectedTranscription(BaseModel):
    """Resultado da correção/normalização (correctTranscription no legado)."""

    model_config = ConfigDict(extra="allow")

    original_had_errors: bool = False
    corrections_made: list[str] = Field(default_factory=list)
    corrected_text: str  # transcrição corrigida COMPLETA (diálogo inteiro)


class PatientSpeech(BaseModel):
    """
    Extração SUPLEMENTAR da fala do paciente (extractPatientSpeech no legado).
    NÃO é a transcrição canônica — vai apenas no campo opcional `patient_speech`.
    """

    model_config = ConfigDict(extra="allow")

    speaker_format_detected: str | None = None
    patient_speaker_label: str | None = None
    patient_speech: str = ""
    confidence: Literal["high", "medium", "low"] = "low"
