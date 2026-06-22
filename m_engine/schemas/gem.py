"""
Schema pydantic do stage `gem` (Grafo do Espaço-Campo Mental).

Política DELIBERADAMENTE PERMISSIVA (extra="allow"): o GEM é uma estrutura rica
e variável (12+ propriedades dimensionais por evento, vetores relacionais, etc.).
A validação aqui não engessa a forma interna de cada camada — ela apenas garante
o ESQUELETO esperado pelo legado:

    { "gem": { "aje": [...], "ire": [...], "e": [...], "epe": [...] },
      "statistics": {...}, "cross_references": {...},
      "key_insights": [...], "validation_score": float }

Ao passar este schema a `providers.llm.complete_json`, o GEM HERDA a auto-correção
de JSON (extract_json + validação pydantic + 1 rodada de repair), exatamente como
os stages ASL e dimensional. Por isso as camadas são `list[dict]` (não sub-schemas
estritos): toleramos qualquer conteúdo bem-formado do LLM sem provocar repairs
desnecessários, mas ainda assim capturamos JSON estruturalmente quebrado.
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class GEMGraph(BaseModel):
    """As 4 camadas do grafo: .aje, .ire, .e, .epe (cada item é um dict livre)."""

    model_config = ConfigDict(extra="allow")

    aje: list[dict] = Field(default_factory=list)  # Actions and Journey Events
    ire: list[dict] = Field(default_factory=list)  # Intelligible Relational Entities
    e: list[dict] = Field(default_factory=list)    # Eulerian Flows (diagnóstico)
    epe: list[dict] = Field(default_factory=list)  # Emergenable Pathways (prognóstico)


class GEM(BaseModel):
    """
    Objeto GEM no MESMO formato do legado.
    Permissivo de propósito (ver docstring do módulo) para herdar a auto-correção.
    """

    model_config = ConfigDict(extra="allow")

    gem: GEMGraph = Field(default_factory=GEMGraph)
    statistics: dict = Field(default_factory=dict)
    cross_references: dict = Field(default_factory=dict)
    key_insights: list[str] = Field(default_factory=list)
    validation_score: float = 0.0
