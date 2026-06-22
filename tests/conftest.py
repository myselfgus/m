"""
Fixtures compartilhadas dos testes do M-Engine.

Objetivo: testes 100% offline — sem rede, sem providers, sem SDKs.
A fixture `tmp_m_base` redireciona M_BASE para um diretório temporário e
limpa o cache de `get_settings` (que é lru_cache) antes e depois de cada teste.
"""

from __future__ import annotations

import pytest

from m_engine import config


@pytest.fixture
def tmp_m_base(tmp_path, monkeypatch):
    """Aponta M_BASE para um tmp_path isolado e reseta o cache das settings.

    Variáveis de ambiente têm precedência sobre o arquivo .env no
    pydantic-settings, então `setenv("M_BASE", ...)` prevalece mesmo que exista
    um .env no diretório de trabalho.
    """
    monkeypatch.setenv("M_BASE", str(tmp_path))
    config.get_settings.cache_clear()
    yield tmp_path
    config.get_settings.cache_clear()
