"""
M-Engine — Fila de jobs (Celery).

Jobs longos (~20 min: chamadas LLM por stage) rodam AQUI, fora do request HTTP.

Princípios:
  - Broker e backend = get_settings().redis_url (zero hardcode).
  - Uma task fina por stage: apenas chama stage.run(...) e devolve o path (str).
  - Imports dos stages são LAZY (dentro da task) — o worker importa o stage só
    quando executa o job, evitando custo/erro de import no boot do worker e nos
    processos que apenas enfileiram (ex.: a API).
"""

from __future__ import annotations

from celery import Celery

from m_engine.config import get_settings

settings = get_settings()

# App Celery: broker e backend de resultados no Redis configurado.
celery_app = Celery(
    "m_engine",
    broker=settings.redis_url,
    backend=settings.redis_url,
)
celery_app.conf.update(
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    task_track_started=True,  # expõe estado STARTED para o endpoint de status
)


# ---------------------------------------------------------------------------
# Tasks finas — uma por stage. Retornam sempre o path do artefato como string.
# ---------------------------------------------------------------------------
@celery_app.task(name="m_engine.transcribe")
def transcribe_task(audio_path: str, *, diarize: bool = True, force: bool = False) -> str:
    """Transcreve um arquivo de áudio."""
    from m_engine.stages import transcribe as stage  # import lazy

    return str(stage.run_file(audio_path, diarize=diarize, force=force))


@celery_app.task(name="m_engine.birp")
def birp_task(transcription_json_path: str, *, model: str | None = None, force: bool = False) -> str:
    """BIRP — roda logo após transcribe sobre a transcrição; atualiza o info.json."""
    from m_engine.stages import birp as stage  # import lazy

    return str(stage.run(transcription_json_path, model=model, force=force))


@celery_app.task(name="m_engine.normalize")
def normalize_task(transcription_json_path: str, *, model: str | None = None, force: bool = False) -> str:
    """Normaliza transcrição e cria/atualiza o dossiê."""
    from m_engine.stages import normalize as stage  # import lazy

    return str(stage.run(transcription_json_path, model=model, force=force))


@celery_app.task(name="m_engine.asl")
def asl_task(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> str:
    """Análise Sistêmica Linguística (ASL)."""
    from m_engine.stages import asl as stage  # import lazy

    return str(stage.run(patient_id, date, model=model, force=force))


@celery_app.task(name="m_engine.dimensional")
def dimensional_task(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> str:
    """Perfil dimensional (VDLP)."""
    from m_engine.stages import dimensional as stage  # import lazy

    return str(stage.run(patient_id, date, model=model, force=force))


@celery_app.task(name="m_engine.gem")
def gem_task(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> str:
    """Grafo do Espaço-Campo Mental (GEM)."""
    from m_engine.stages import gem as stage  # import lazy

    return str(stage.run(patient_id, date, model=model, force=force))


@celery_app.task(name="m_engine.soap_trajetorial")
def soap_trajetorial_task(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> str:
    """Nota SOAP trajetorial (uma sessão)."""
    from m_engine.stages import soap_trajetorial as stage  # import lazy

    return str(stage.run(patient_id, date, model=model, force=force))


@celery_app.task(name="m_engine.soap_longitudinal")
def soap_longitudinal_task(patient_id: str, dates: list[str], *, model: str | None = None, force: bool = False) -> str:
    """Nota SOAP longitudinal (múltiplas sessões)."""
    from m_engine.stages import soap_longitudinal as stage  # import lazy

    return str(stage.run(patient_id, dates, model=model, force=force))


# Mapa stage -> task, consumido pela API para enfileirar por nome de stage.
STAGE_TASKS = {
    "transcribe": transcribe_task,
    "birp": birp_task,
    "normalize": normalize_task,
    "asl": asl_task,
    "dimensional": dimensional_task,
    "gem": gem_task,
    "soap_trajetorial": soap_trajetorial_task,
    "soap_longitudinal": soap_longitudinal_task,
}
