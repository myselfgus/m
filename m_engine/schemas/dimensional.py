"""
Schema da saída do stage `dimensional` (VDLP — 15 dimensões do Espaço Mental ℳ).

Política: o schema é PERMISSIVO (`extra="allow"`) em todos os níveis. O LLM
produz uma estrutura rica e variável por dimensão (v1..v15), e a validação estrita
quebraria com campos extras esperados. Capturamos apenas a "casca" obrigatória
(metadata + dimensoes_espaco_mental + mapeamentos + validação + perfil), deixando
o conteúdo interno de cada dimensão fluir livremente.

A consolidação de chunks (em stages/dimensional.py) opera diretamente sobre o dict
extraído, então o schema serve sobretudo para garantir presença das seções-chave
e dar 1 rodada de repair via complete_json.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class DimensionalAnalysis(BaseModel):
    """
    Payload analítico dimensional retornado pelo LLM.

    Mantém apenas as seções de topo do schema do prompt; cada uma é permissiva
    para acomodar a estrutura completa de cada dimensão (score, escala,
    componentes_asl_usados, calculo_explicito, evidencias_textuais,
    valores_asl_extraidos, mapeamento_framework, confianca, limitacoes,
    observacoes_qualitativas) sem enumerá-la campo a campo.
    """

    model_config = ConfigDict(extra="allow")

    # Metadados da extração (falante_id, data_extracao, versao_modelo, asl_utilizada, ...)
    metadata: dict[str, Any] = Field(default_factory=dict)

    # As 15 dimensões v1..v15 (chaves vN_nome). Permissivo: cada valor é um dict livre.
    dimensoes_espaco_mental: dict[str, Any] = Field(default_factory=dict)

    # Visão agregada de confiança/cobertura/mapeamento
    mapeamento_global: dict[str, Any] = Field(default_factory=dict)

    # Verificações de consistência interna entre dimensões
    validacao_cruzada: dict[str, Any] = Field(default_factory=dict)

    # Síntese integrativa final
    perfil_dimensional_integrativo: dict[str, Any] = Field(default_factory=dict)
