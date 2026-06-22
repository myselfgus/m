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

from pathlib import Path
from typing import Optional

from celery.result import AsyncResult
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

from m_engine.config import get_settings
from m_engine.store import load_info, pat_dir
from m_engine.tasks import STAGE_TASKS, celery_app

# Extensões de áudio/vídeo aceitas no upload (mesma lista do stage transcribe).
AUDIO_EXTS = {".m4a", ".mp3", ".wav", ".aac", ".flac", ".ogg", ".webm", ".mp4", ".mov"}

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
    diarize: bool = True  # usado por transcribe/pipeline
    deep: bool = True  # pipeline: roda o ramo B completo (asl→dim→gem→soap)


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

    if stage == "pipeline":
        if not req.audio_path:
            raise HTTPException(422, "audio_path é obrigatório para 'pipeline'.")
        return (req.audio_path,), {
            "diarize": req.diarize,
            "deep": req.deep,
            "model": req.model,
            "force": req.force,
        }

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


class UploadResponse(BaseModel):
    filename: str
    path: str  # caminho absoluto salvo em $M_BASE/audio


@app.post("/audio", response_model=UploadResponse)
async def upload_audio(file: UploadFile = File(...)) -> UploadResponse:
    """
    Recebe um arquivo de áudio e o grava em $M_BASE/audio (entrada do STT).
    Não dispara processamento — a UI chama depois POST /jobs/pipeline com o path.
    """
    name = Path(file.filename or "").name  # evita path traversal
    if not name:
        raise HTTPException(422, "Nome de arquivo ausente.")
    if Path(name).suffix.lower() not in AUDIO_EXTS:
        raise HTTPException(422, f"Extensão não suportada. Aceitas: {sorted(AUDIO_EXTS)}")

    audio_dir = get_settings().audio_dir
    audio_dir.mkdir(parents=True, exist_ok=True)
    dest = audio_dir / name

    data = await file.read()
    if not data:
        raise HTTPException(422, "Arquivo de áudio vazio.")
    dest.write_bytes(data)
    return UploadResponse(filename=name, path=str(dest))


class DocumentsResponse(BaseModel):
    patient_id: str
    documents: list[str]


@app.get("/patients/{patient_id}/documents", response_model=DocumentsResponse)
def list_documents(patient_id: str) -> DocumentsResponse:
    """Lista os documentos clínicos (.md) gerados no dossiê do paciente."""
    docs_dir = pat_dir() / patient_id / "clinical-documents"
    if not docs_dir.is_dir():
        raise HTTPException(404, f"Paciente sem documentos: {patient_id}")
    docs = sorted(p.name for p in docs_dir.glob("*.md"))
    return DocumentsResponse(patient_id=patient_id, documents=docs)


@app.get("/patients/{patient_id}/documents/{name}", response_class=PlainTextResponse)
def get_document(patient_id: str, name: str) -> str:
    """Retorna o conteúdo (Markdown) de um documento clínico."""
    safe = Path(name).name  # evita path traversal
    path = pat_dir() / patient_id / "clinical-documents" / safe
    if not path.is_file():
        raise HTTPException(404, f"Documento não encontrado: {safe}")
    return path.read_text(encoding="utf-8")


@app.get("/patients/{patient_id}/info")
def get_patient_info(patient_id: str) -> dict:
    """Retorna o info.json do paciente (metadados + clinical_summary)."""
    info = load_info(patient_id)
    if not info:
        raise HTTPException(404, f"info.json ausente para {patient_id}")
    return info


@app.get("/healthz")
def healthz() -> dict:
    """Liveness simples + eco da raiz de dados configurada."""
    return {"status": "ok", "m_base": str(get_settings().m_base)}
