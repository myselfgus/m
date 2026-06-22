"""
Schemas pydantic do stage ASL (Análise Sistêmica Linguística).

Política de validação (alinhada a schemas/base.py):
  - O ENVELOPE (ASLArtifact) é validado/reparado — é o contrato estável do artefato.
  - O PAYLOAD analítico (LinguisticAnalysis) é PERMISSIVO (extra="allow"): captura as
    11 categorias principais + metadata + transcricao_filtrada + sintese_interpretativa,
    mas as estruturas profundas (metricas_quantitativas, analise_contextual, etc.) ficam
    como dict livre. O LLM produz JSON muito aninhado; o objetivo aqui é garantir o
    envelope e os blocos de topo, não tipar cada métrica.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from m_engine.schemas.base import Artifact

# Versão da análise (gravada no envelope). Mantida idêntica ao legado.
ASL_ANALYSIS_VERSION = "2.0-patient-focused"


class LinguisticAnalysis(BaseModel):
    """
    Payload analítico do ASL: as 8 categorias (11 blocos de topo) + metadados internos.

    Permissivo por design: cada bloco é um dict livre porque o schema profundo
    (ver prompts/asl.md) é enorme e variável. Validamos a PRESENÇA dos blocos
    principais como opcionais e deixamos o conteúdo passar como está.
    """

    model_config = ConfigDict(extra="allow")

    # Blocos globais
    contexto_identificado: dict[str, Any] | None = None
    metadata: dict[str, Any] | None = None
    transcricao_filtrada: dict[str, Any] | None = None

    # As 8 categorias de análise linguística
    morfossintaxe: dict[str, Any] | None = None
    semantica: dict[str, Any] | None = None
    coerencia_coesao: dict[str, Any] | None = None
    pragmatica: dict[str, Any] | None = None
    consistencia_temporal: dict[str, Any] | None = None
    fragmentacao_fluencia: dict[str, Any] | None = None
    complexidade_densidade: dict[str, Any] | None = None
    caracteristicas_prosodicas_textuais: dict[str, Any] | None = None

    # Síntese final
    sintese_interpretativa: dict[str, Any] | None = None


class ASLArtifact(Artifact):
    """
    Envelope do artefato ASL gravado em store.asl_path.

    Herda de Artifact: patient_id, source_file, processed_at, model, analysis_version.
    Acrescenta os metadados da transcrição e o payload linguístico.
    """

    model_config = ConfigDict(extra="allow")

    transcription_metadata: dict[str, Any] | None = None
    linguistic_analysis: dict[str, Any] = Field(default_factory=dict)
    analysis_version: str = ASL_ANALYSIS_VERSION
