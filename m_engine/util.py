"""Utilitários compartilhados: chunking, estimativa de tokens, loader de prompts."""

from __future__ import annotations

import re
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path

CHARS_PER_TOKEN = 4
_PROMPTS_DIR = Path(__file__).parent / "prompts"


def estimate_tokens(text: str) -> int:
    return -(-len(text) // CHARS_PER_TOKEN)  # ceil


def split_into_chunks(text: str, max_tokens_per_chunk: int = 15000) -> list[str]:
    """Divide respeitando limites naturais: parágrafos -> sentenças."""
    if estimate_tokens(text) <= max_tokens_per_chunk:
        return [text]

    max_chars = max_tokens_per_chunk * CHARS_PER_TOKEN
    chunks: list[str] = []
    current = ""
    for para in re.split(r"\n\n+", text):
        if len(para) > max_chars:
            if current:
                chunks.append(current.strip())
                current = ""
            for sentence in re.split(r"(?<=[.!?])\s+", para):
                if len(current + sentence) > max_chars:
                    if current:
                        chunks.append(current.strip())
                    current = sentence
                else:
                    current += (" " if current else "") + sentence
        elif len(current + "\n\n" + para) > max_chars:
            chunks.append(current.strip())
            current = para
        else:
            current += ("\n\n" if current else "") + para
    if current:
        chunks.append(current.strip())
    return chunks


@lru_cache
def load_prompt(name: str) -> str:
    """Carrega um prompt de m_engine/prompts/<name>.md (sem hardcode no código)."""
    path = _PROMPTS_DIR / f"{name}.md"
    if not path.exists():
        raise FileNotFoundError(f"Prompt não encontrado: {path}")
    return path.read_text(encoding="utf-8")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")
