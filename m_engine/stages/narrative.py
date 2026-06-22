"""
Stage (placeholder) — Narrativa.

O módulo de narrativa não existia no snapshot legado; fica como placeholder
explícito conforme decidido. Implementar quando a especificação estiver pronta.
"""

from __future__ import annotations

from pathlib import Path


def run(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> Path:
    raise NotImplementedError(
        "Stage 'narrative' ainda não especificado. "
        "Placeholder intencional — ver m-engine-project (memória do projeto)."
    )
