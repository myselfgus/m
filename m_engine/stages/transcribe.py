"""
Stage 0 — Transcrição (ElevenLabs Scribe apenas).

Lê um arquivo de áudio e grava audio/transcriptions/<base>_transcription.json.
Diálogo completo com diarização em blocos [Falante N].
"""

from __future__ import annotations

from pathlib import Path

import structlog

from m_engine.config import get_settings
from m_engine.providers.transcription import transcribe
from m_engine.schemas.base import TranscriptionArtifact
from m_engine.store import write_json
from m_engine.util import now_iso

log = structlog.get_logger("m_engine.transcribe")

AUDIO_EXTS = {".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg", ".webm", ".mp4", ".mov"}


def output_path(audio_path: Path) -> Path:
    return get_settings().transcriptions_dir / f"{audio_path.stem}_transcription.json"


def txt_output_path(audio_path: Path) -> Path:
    return get_settings().transcriptions_dir / f"{audio_path.stem}_transcription.txt"


def run_file(audio_path: str | Path, *, diarize: bool = True, force: bool = False) -> Path:
    audio_path = Path(audio_path)
    out = output_path(audio_path)
    txt_out = txt_output_path(audio_path)
    if out.exists() and not force:
        log.info("skip_cached", file=audio_path.name)
        return out

    result = transcribe(audio_path, diarize=diarize)
    artifact = TranscriptionArtifact(
        arquivo=audio_path.name,
        data=now_iso(),
        servico=result.service,
        idioma=result.language_code,
        confianca=result.language_probability,
        diarizacao=result.diarized,
        transcricao=result.text,
    )
    write_json(out, artifact.model_dump())
    # Output adicional em .txt (transcrição pura, sem timestamps)
    txt_out.parent.mkdir(parents=True, exist_ok=True)
    txt_out.write_text(result.text, encoding="utf-8")
    log.info("transcribed", file=audio_path.name, out=str(out), txt=str(txt_out))
    return out


def run_all(*, diarize: bool = True, force: bool = False) -> list[Path]:
    audio_dir = get_settings().audio_dir
    audio_dir.mkdir(parents=True, exist_ok=True)
    outputs: list[Path] = []
    for f in sorted(audio_dir.iterdir()):
        if f.suffix.lower() in AUDIO_EXTS:
            outputs.append(run_file(f, diarize=diarize, force=force))
    return outputs
