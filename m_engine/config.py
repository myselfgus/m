"""
Configuração central do M-Engine.

ÚNICO ponto de verdade para:
  - chaves de API (via env / .env)
  - paths de dados (relativos a M_BASE)
  - registro de modelos (IDs diretos por provider)
  - modelo default (Claude Opus 4.8 em TODOS os stages)

Nada de paths hardcoded; nada de Cloudflare Gateway.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

Provider = Literal["anthropic", "claude_cli", "xai", "deepseek"]


@dataclass(frozen=True)
class ModelSpec:
    """Especificação de um modelo no provider direto."""

    provider: Provider
    id: str  # ID DIRETO do provider (sem prefixo de gateway)
    label: str
    max_output_tokens: int
    context_window: int  # janela de contexto do modelo (informativo; default do modelo)


# ---------------------------------------------------------------------------
# Registro de modelos. Editar IDs aqui quando os providers publicarem versões.
# Default de TODOS os stages = "opus" (Claude Opus 4.8).
# ---------------------------------------------------------------------------
MODELS: dict[str, ModelSpec] = {
    # Opus 4.8 — modelo pesado do pipeline (asl/dimensional/gem). Saída 128K (streaming),
    # janela de contexto 1M (default do modelo, sem parâmetro de request).
    "opus": ModelSpec("anthropic", "claude-opus-4-8", "Claude Opus 4.8", 128000, 1_000_000),
    # Sonnet 4.6 — default de normalize e dos SOAPs. Saída 64K, janela 1M.
    "sonnet": ModelSpec("anthropic", "claude-sonnet-4-6", "Claude Sonnet 4.6", 64000, 1_000_000),
    # Claude via CLI Claude Code (subprocess) — reaproveita a AUTH DO SISTEMA (sessão
    # logada / OAuth / keychain), sem API key direta. `id` é o alias passado ao --model do CLI.
    "cc": ModelSpec("claude_cli", "opus", "Claude Code CLI (opus, auth do sistema)", 128000, 1_000_000),
    # NOTA: Haiku removido (não usaremos). Aliases grok/deepseek removidos por ora —
    # o plumbing dos providers xai/deepseek segue em providers/llm.py (dormente).
}

DEFAULT_MODEL_ALIAS = "opus"

# Default por stage. Stages ausentes usam DEFAULT_MODEL_ALIAS (opus).
STAGE_DEFAULTS: dict[str, str] = {
    "birp": "sonnet",
    "normalize": "sonnet",
    "soap_trajetorial": "sonnet",
    "soap_longitudinal": "sonnet",
}


def stage_default_model(stage: str) -> str:
    """Alias de modelo default para um stage.

    Se `M_FORCE_MODEL` estiver setado (ex.: `cc`), TODOS os stages usam esse modelo
    — útil em deploy que roda 100% na assinatura (Claude Code) sem crédito de API.
    Caso contrário: normalize/SOAPs → sonnet; resto → opus.
    """
    forced = get_settings().m_force_model
    if forced:
        return forced
    return STAGE_DEFAULTS.get(stage, DEFAULT_MODEL_ALIAS)


class Settings(BaseSettings):
    """Variáveis de ambiente do M-Engine (lidas de .env / ambiente)."""

    model_config = SettingsConfigDict(env_file=".env", env_prefix="", extra="ignore")

    # Raiz de dados
    m_base: Path = Path("/var/lib/m-engine")

    # Providers
    anthropic_api_key: str | None = None
    xai_api_key: str | None = None
    deepseek_api_key: str | None = None
    elevenlabs_api_key: str | None = None

    # Modelo default (sobrescreve DEFAULT_MODEL_ALIAS se setado)
    m_default_model: str = DEFAULT_MODEL_ALIAS

    # Força UM modelo em TODOS os stages (ignora STAGE_DEFAULTS). Ex.: "cc" para
    # rodar 100% na assinatura Claude Code (sem crédito de API). None = comportamento normal.
    m_force_model: str | None = None

    # Fila / API
    redis_url: str = "redis://localhost:6379/0"
    m_api_host: str = "0.0.0.0"
    m_api_port: int = 8000

    # Binário do CLI Claude Code (provider "claude_cli"/alias "cc"). Em VM/systemd o
    # PATH pode não ter ~/.local/bin — aponte o caminho absoluto via M_CLAUDE_CLI_BIN.
    m_claude_cli_bin: str = "claude"

    # TTL do prompt caching (cache_control ephemeral). "5m" ou "1h". Default 1h:
    # janelas de lote clínico reusam os system prompts gigantes por mais tempo.
    m_cache_ttl: str = "1h"

    # ----- Paths derivados -----
    @property
    def pat_dir(self) -> Path:
        return self.m_base / "pat"

    @property
    def audio_dir(self) -> Path:
        return self.m_base / "audio"

    @property
    def transcriptions_dir(self) -> Path:
        return self.audio_dir / "transcriptions"

    @property
    def debug_dir(self) -> Path:
        return self.m_base / "_debug"


@lru_cache
def get_settings() -> Settings:
    return Settings()


def resolve_model(alias: str | None = None) -> ModelSpec:
    """Resolve um alias de modelo para ModelSpec. None → modelo default das settings."""
    key = (alias or get_settings().m_default_model or DEFAULT_MODEL_ALIAS).lower()
    if key not in MODELS:
        raise ValueError(f"Modelo desconhecido: {key!r}. Opções: {', '.join(MODELS)}")
    return MODELS[key]
