"""
Pré-aquecimento do prompt cache do M-Engine.

Dispara `max_tokens:0` para escrever no cache os system prompts GIGANTES (e estáveis)
dos stages, de modo que a 1ª chamada real de cada stage leia a 0.1x em vez de pagar
o input cheio. Útil no boot do worker e antes de um lote clínico.

Só os stages que expõem `prewarm_blocks() -> list[list[SystemBlock]]` são aquecidos,
e cada conjunto de blocos é aquecido com o modelo default daquele stage (a chave de
cache é por-modelo). Stages com múltiplos system prompts pequenos (normalize/soap)
ficam de fora por ora — o ganho está nos prompts grandes (asl/dimensional/gem/birp).
"""

from __future__ import annotations

import importlib

import structlog

from m_engine.config import stage_default_model
from m_engine.providers import llm

log = structlog.get_logger("m_engine.prewarm")

# Stages com system prompt grande/estável que vale aquecer.
# (asl/dimensional/gem → Opus; birp/normalize/soap_* → Sonnet, via stage_default_model.)
WARM_STAGES = (
    "asl",
    "dimensional",
    "gem",
    "birp",
    "normalize",
    "soap_trajetorial",
    "soap_longitudinal",
)


def warm_all() -> int:
    """Aquece o cache de todos os WARM_STAGES. Retorna o nº de escritas de cache."""
    writes = 0
    for name in WARM_STAGES:
        try:
            mod = importlib.import_module(f"m_engine.stages.{name}")
        except Exception as exc:  # noqa: BLE001 — stage ausente não derruba o warm
            log.warning("prewarm_import_failed", stage=name, error=str(exc)[:200])
            continue
        if not hasattr(mod, "prewarm_blocks"):
            continue
        model = stage_default_model(name)
        for blocks in mod.prewarm_blocks():
            try:
                if llm.prewarm(blocks, model=model):
                    writes += 1
            except Exception as exc:  # noqa: BLE001 — falha de warm é não-fatal
                log.warning("prewarm_failed", stage=name, model=model, error=str(exc)[:200])
    log.info("prewarm_done", stages=list(WARM_STAGES), cache_writes=writes)
    return writes
