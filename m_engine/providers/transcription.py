"""
M-Engine — Transcrição (ElevenLabs Scribe APENAS).

Sem Whisper / WhisperX / MLX / Workers AI. Diarização nativa do Scribe,
formatando o resultado em blocos [Falante N] (ambos os falantes preservados).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from m_engine.config import get_settings

MIME_TYPES = {
    "m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav", "aac": "audio/aac",
    "flac": "audio/flac", "ogg": "audio/ogg", "webm": "audio/webm", "mp4": "audio/mp4",
    "mov": "video/quicktime",
}

SCRIBE_MODEL = "scribe_v2"
LANGUAGE_CODE = "por"
TIMESTAMPS_GRANULARITY = "none"  # transcrição SEM timestamps (default da doc é "word")


@dataclass
class TranscriptionResult:
    text: str
    language_code: str
    language_probability: float
    diarized: bool
    service: str = "elevenlabs_scribe_v2"


def _format_diarized(words: list) -> str:
    """Reagrupa palavras diarizadas em blocos [Falante N] (1-indexed)."""
    out: list[str] = []
    current: str | None = None
    for w in words or []:
        speaker = getattr(w, "speaker_id", None) or (w.get("speaker_id") if isinstance(w, dict) else None)
        text = getattr(w, "text", None) or (w.get("text") if isinstance(w, dict) else "") or ""
        if speaker and speaker != current:
            current = speaker
            # speaker_id em formato inesperado é ERRO (não colapsar tudo em [Falante 1]).
            try:
                n = int(str(speaker).split("_")[1]) + 1
            except (IndexError, ValueError) as exc:
                raise ValueError(f"speaker_id em formato inesperado na diarização: {speaker!r}") from exc
            out.append(f"\n\n[Falante {n}] ")
        out.append(text)
    return "".join(out).strip()


def transcribe(audio_path: str | Path, *, diarize: bool = True) -> TranscriptionResult:
    """Transcreve um arquivo de áudio via ElevenLabs Scribe."""
    from elevenlabs.client import ElevenLabs

    s = get_settings()
    if not s.elevenlabs_api_key:
        raise RuntimeError("ELEVENLABS_API_KEY ausente.")

    audio_path = Path(audio_path)
    ext = audio_path.suffix.lower().lstrip(".")
    client = ElevenLabs(api_key=s.elevenlabs_api_key)

    with audio_path.open("rb") as fh:
        result = client.speech_to_text.convert(
            file=(audio_path.name, fh, MIME_TYPES.get(ext, f"audio/{ext}")),
            model_id=SCRIBE_MODEL,
            tag_audio_events=True,
            language_code=LANGUAGE_CODE,
            diarize=diarize,
            timestamps_granularity=TIMESTAMPS_GRANULARITY,
        )

    words = getattr(result, "words", None)
    text = _format_diarized(words) if (diarize and words) else (getattr(result, "text", "") or "")
    # Transcrição vazia NÃO é sucesso — STT falho/silencioso deve falhar alto.
    if not text.strip():
        raise RuntimeError(f"ElevenLabs Scribe retornou transcrição vazia para {audio_path.name}.")
    return TranscriptionResult(
        text=text,
        language_code=getattr(result, "language_code", LANGUAGE_CODE) or LANGUAGE_CODE,
        language_probability=getattr(result, "language_probability", 0.0) or 0.0,
        diarized=diarize,
    )
