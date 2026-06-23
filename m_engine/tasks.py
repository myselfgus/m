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
from celery.signals import worker_ready

from m_engine.config import get_settings

settings = get_settings()


@worker_ready.connect
def _prewarm_on_boot(**_kwargs) -> None:
    """Pré-aquece o prompt cache quando o worker sobe (não-fatal se faltar chave)."""
    try:
        from m_engine.prewarm import warm_all

        warm_all()
    except Exception:  # noqa: BLE001 — warm é otimização; nunca derruba o worker
        pass

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


@celery_app.task(name="m_engine.pipeline")
def pipeline_task(
    audio_path: str,
    *,
    diarize: bool = True,
    deep: bool = True,
    model: str | None = None,
    force: bool = False,
) -> str:
    """
    Pipeline completo de UMA sessão a partir do áudio (mesma topologia do `m ingest`):
    transcribe → [Ramo A: birp] e [Ramo B: normalize → asl → dim → gem → soap_t].
    Roda síncrono no worker (1 job_id para a UI acompanhar). Retorna o path do SOAP
    trajetorial (ramo B) ou da transcrição (se deep=False).
    """
    from m_engine.stages import (  # import lazy
        asl, birp, dimensional, gem, normalize, soap_trajetorial, transcribe,
    )

    transcription_json = transcribe.run_file(audio_path, diarize=diarize, force=force)
    # Ramo A — nota clínica imediata; também estabelece dossiê + info.json.
    birp.run(transcription_json, model=model, force=force)
    # Ramo B — análise profunda.
    norm_path = normalize.run(transcription_json, model=model, force=force)
    if not deep:
        return str(norm_path)
    patient_id = norm_path.parent.parent.name
    date = norm_path.stem.replace("_transcription", "")
    asl.run(patient_id, date, model=model, force=force)
    dimensional.run(patient_id, date, model=model, force=force)
    gem.run(patient_id, date, model=model, force=force)
    return str(soap_trajetorial.run(patient_id, date, model=model, force=force))


# Mapa stage -> task, consumido pela API para enfileirar por nome de stage.
STAGE_TASKS = {
    "pipeline": pipeline_task,
    "transcribe": transcribe_task,
    "birp": birp_task,
    "normalize": normalize_task,
    "asl": asl_task,
    "dimensional": dimensional_task,
    "gem": gem_task,
    "soap_trajetorial": soap_trajetorial_task,
    "soap_longitudinal": soap_longitudinal_task,
}
