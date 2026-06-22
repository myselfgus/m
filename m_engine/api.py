"""
M-Engine — API (FastAPI).

Camada de ORQUESTRAÇÃO apenas: enfileira jobs no Celery e consulta status.
Nenhuma lógica de negócio — toda a computação vive nos stages (rodando no worker).

Endpoints:
  POST /jobs/{stage}   enfileira um stage e devolve o job_id
  GET  /jobs/{job_id}  status/resultado via Celery AsyncResult
  GET  /patients       lista os PATIENT_IDs (dossiês em pat/)
  GET  /healthz        liveness simples
"""

from __future__ import annotations

from typing import Optional

from celery.result import AsyncResult
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from m_engine.config import get_settings
from m_engine.store import pat_dir
from m_engine.tasks import STAGE_TASKS, celery_app

app = FastAPI(
    title="M-Engine API",
    description="Orquestração de jobs do pipeline clínico-linguístico (transcrição → ASL → dimensional → GEM → SOAP).",
    version="0.1.0",
)


# ---------------------------------------------------------------------------
# Modelos Pydantic (request / response)
# ---------------------------------------------------------------------------
class JobRequest(BaseModel):
    """
    Argumentos para enfileirar um stage. Os campos relevantes variam por stage;
    a validação por stage acontece em _build_args.

      transcribe          -> audio_path
      normalize           -> transcription_json_path
      asl/dimensional/gem -> patient_id + date
      soap_trajetorial    -> patient_id + date
      soap_longitudinal   -> patient_id + dates[]
    """

    audio_path: Optional[str] = None
    transcription_json_path: Optional[str] = None
    patient_id: Optional[str] = None
    date: Optional[str] = None
    dates: Optional[list[str]] = None

    # Comuns: model (alias; None => Opus 4.8) e force.
    model: Optional[str] = Field(default=None, description="Alias do modelo; None => Claude Opus 4.8.")
    force: bool = False
    diarize: bool = True  # usado apenas pelo stage transcribe


class JobResponse(BaseModel):
    """Resposta ao enfileirar: id do job e stage correspondente."""

    job_id: str
    stage: str
    status: str = "PENDING"


class JobStatus(BaseModel):
    """Estado de um job consultado via AsyncResult."""

    job_id: str
    status: str
    ready: bool
    successful: Optional[bool] = None
    result: Optional[str] = None  # path do artefato em caso de sucesso
    error: Optional[str] = None


class PatientsResponse(BaseModel):
    patients: list[str]


# ---------------------------------------------------------------------------
# Helpers de orquestração
# ---------------------------------------------------------------------------
def _build_args(stage: str, req: JobRequest) -> tuple[tuple, dict]:
    """
    Monta (args, kwargs) para a task do stage a partir do request, validando
    a presença dos campos obrigatórios. Sem lógica de negócio: só roteia args.
    """
    if stage == "transcribe":
        if not req.audio_path:
            raise HTTPException(422, "audio_path é obrigatório para 'transcribe'.")
        return (req.audio_path,), {"diarize": req.diarize, "force": req.force}

    if stage == "normalize":
        if not req.transcription_json_path:
            raise HTTPException(422, "transcription_json_path é obrigatório para 'normalize'.")
        return (req.transcription_json_path,), {"model": req.model, "force": req.force}

    if stage in ("asl", "dimensional", "gem", "soap_trajetorial"):
        if not req.patient_id or not req.date:
            raise HTTPException(422, f"patient_id e date são obrigatórios para '{stage}'.")
        return (req.patient_id, req.date), {"model": req.model, "force": req.force}

    if stage == "soap_longitudinal":
        if not req.patient_id or not req.dates:
            raise HTTPException(422, "patient_id e dates[] são obrigatórios para 'soap_longitudinal'.")
        return (req.patient_id, req.dates), {"model": req.model, "force": req.force}

    raise HTTPException(404, f"Stage desconhecido: {stage!r}. Opções: {', '.join(STAGE_TASKS)}")


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.post("/jobs/{stage}", response_model=JobResponse)
def enqueue_job(stage: str, req: JobRequest) -> JobResponse:
    """Enfileira um stage no Celery e devolve o job_id para acompanhamento."""
    task = STAGE_TASKS.get(stage)
    if task is None:
        raise HTTPException(404, f"Stage desconhecido: {stage!r}. Opções: {', '.join(STAGE_TASKS)}")

    args, kwargs = _build_args(stage, req)
    async_result = task.apply_async(args=args, kwargs=kwargs)
    return JobResponse(job_id=async_result.id, stage=stage, status=async_result.status)


@app.get("/jobs/{job_id}", response_model=JobStatus)
def get_job(job_id: str) -> JobStatus:
    """Consulta status/resultado de um job via Celery AsyncResult."""
    result = AsyncResult(job_id, app=celery_app)

    payload = JobStatus(job_id=job_id, status=result.status, ready=result.ready())
    if result.ready():
        payload.successful = result.successful()
        if result.successful():
            payload.result = str(result.result)
        else:
            # result.result é a exceção quando o job falha.
            payload.error = str(result.result)
    return payload


@app.get("/patients", response_model=PatientsResponse)
def list_patients() -> PatientsResponse:
    """Lista os PATIENT_IDs com dossiê em pat/ (paths via store/config)."""
    base = pat_dir()
    patients = sorted(child.name for child in base.iterdir() if child.is_dir())
    return PatientsResponse(patients=patients)


@app.get("/healthz")
def healthz() -> dict:
    """Liveness simples + eco da raiz de dados configurada."""
    return {"status": "ok", "m_base": str(get_settings().m_base)}
