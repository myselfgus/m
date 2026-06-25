"""
M-Engine — API (FastAPI).

Camada de ORQUESTRAÇÃO apenas: enfileira jobs no Celery e consulta status.
Nenhuma lógica de negócio — toda a computação vive nos stages (rodando no worker).

Endpoints:
  POST /jobs/{stage}                                   enfileira um stage e devolve o job_id
  GET  /jobs/{job_id}                                  status/resultado via Celery AsyncResult
  POST /audio                                          upload de áudio para $M_BASE/audio
  GET  /patients                                       lista dossiês (slug + nome + nº consultas)
  GET  /patients/{slug}/profile                        identidade editável (profile.json)
  PUT  /patients/{slug}/profile                        merge de campos editáveis no profile.json
  GET  /patients/{slug}/consultations                  consultas + documentos (.md) por consulta
  GET  /patients/{slug}/consultations/{cid}/documents/{name}   conteúdo Markdown de um documento
  PUT  /patients/{slug}/consultations/{cid}/documents/{name}   sobrescreve um documento Markdown
  DELETE /patients/{slug}                              soft-delete do dossiê (move p/ _trash)
  DELETE /patients/{slug}/consultations/{cid}          soft-delete da consulta (+ remove do index)
  DELETE /patients/{slug}/consultations/{cid}/documents/{name}  soft-delete de um documento .md
  GET  /patients/{slug}/info                           visão mesclada (profile + index) [compat]
  GET  /healthz                                        liveness simples
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Optional

from celery.result import AsyncResult
from fastapi import Body, FastAPI, File, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field

from m_engine.config import get_settings
from m_engine import store
# Assistente conversacional movido para o cliente (mapp): Messages API direta.
# Não há mais backend de chat (WebSocket) — removido em jun/2026.
from m_engine.store import load_info, pat_dir
from m_engine.tasks import STAGE_TASKS, celery_app
from m_engine.util import today

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


class PatientSummary(BaseModel):
    slug: str
    display_name: str
    consultation_count: int


class PatientsResponse(BaseModel):
    patients: list[PatientSummary]


class ProfileUpdate(BaseModel):
    """Campos editáveis de identidade. `slug` nunca é aceito (ignorado/strip)."""

    display_name: Optional[str] = None
    full_name: Optional[str] = None
    cpf: Optional[str] = None
    phone: Optional[str] = None
    birthdate: Optional[str] = None
    age: Optional[int] = None
    email: Optional[str] = None
    notes: Optional[str] = None
    professional: Optional[dict] = None


class ProfessionalUpdate(BaseModel):
    """Perfil do próprio profissional (Dr. Gustavo), global ao app."""

    name: Optional[str] = None
    specialty: Optional[str] = None
    credential: Optional[str] = None  # CRM/RQE
    registration: Optional[str] = None  # alias legado de credential
    clinic: Optional[str] = None
    signature: Optional[str] = None  # linha livre de assinatura (opcional)
    notes: Optional[str] = None


class ConsultationSummary(BaseModel):
    id: Optional[str] = None
    date: Optional[str] = None
    source: Optional[str] = None
    tags: Optional[list[str]] = None
    processed_at: Optional[str] = None
    documents: list[str] = Field(default_factory=list)


class ConsultationsResponse(BaseModel):
    slug: str
    consultations: list[ConsultationSummary]


class DocumentWriteResult(BaseModel):
    ok: bool
    bytes: int


class PatientCreate(BaseModel):
    """Corpo de criação de paciente. Apenas `full_name` é obrigatório."""

    full_name: str = Field(..., min_length=1)
    cpf: Optional[str] = None
    phone: Optional[str] = None
    age: Optional[int] = None
    email: Optional[str] = None
    notes: Optional[str] = None


class ConsultationCreate(BaseModel):
    """Corpo de criação de consulta. `date` opcional (default = hoje)."""

    date: Optional[str] = None


class ConsultationCreateResult(BaseModel):
    id: str
    date: str


class DocumentCreate(BaseModel):
    """Corpo de criação de um novo documento Markdown numa consulta."""

    name: str = Field(..., min_length=1)
    content: str = ""


class DocumentCreateResult(BaseModel):
    ok: bool
    name: str


# Helper de segurança: confina um path sob pat_dir()/slug/... rejeitando traversal.
def _patient_root(slug: str) -> Path:
    safe_slug = Path(slug).name
    if not safe_slug or safe_slug != slug:
        raise HTTPException(400, "Slug inválido.")
    return pat_dir() / safe_slug


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
    """Lista dossiês em pat/ com identidade resumida (slug + nome + nº de consultas)."""
    return PatientsResponse(patients=[PatientSummary(**p) for p in store.list_patients()])


@app.get("/patients/{slug}/profile")
def get_profile(slug: str) -> dict:
    """Retorna o profile.json (identidade editável) do paciente."""
    root = _patient_root(slug)
    if not (root / "profile.json").is_file():
        raise HTTPException(404, f"profile.json ausente para {slug}")
    return store.load_profile(slug)


@app.put("/patients/{slug}/profile")
def put_profile(slug: str, update: ProfileUpdate) -> dict:
    """Merge dos campos editáveis no profile.json (slug nunca é alterado)."""
    _patient_root(slug)  # valida o slug
    existing = store.load_profile(slug)
    if not existing:
        raise HTTPException(404, f"profile.json ausente para {slug}")
    patch = update.model_dump(exclude_unset=True)
    patch.pop("slug", None)  # defensivo: nunca deixar o body trocar o slug
    merged = {**existing, **patch}
    store.save_profile(slug, merged)  # save_profile força slug=slug
    return store.load_profile(slug)


@app.get("/patients/{slug}/consultations", response_model=ConsultationsResponse)
def list_consultations(slug: str) -> ConsultationsResponse:
    """Lista as consultas do index.json, com os documentos (.md) de cada pasta C{n}/."""
    root = _patient_root(slug)
    if not root.is_dir():
        raise HTTPException(404, f"Paciente não encontrado: {slug}")
    idx = store.load_index(slug)
    out: list[ConsultationSummary] = []
    for c in idx.get("consultations", []):
        cid = c.get("id")
        docs: list[str] = []
        if cid:
            cdir = root / Path(str(cid)).name
            if cdir.is_dir():
                docs = sorted(p.name for p in cdir.glob("*.md"))
        out.append(ConsultationSummary(
            id=cid,
            date=c.get("date"),
            source=c.get("source"),
            tags=c.get("tags"),
            processed_at=c.get("processed_at"),
            documents=docs,
        ))
    return ConsultationsResponse(slug=slug, consultations=out)


def _consult_doc_path(slug: str, cid: str, name: str) -> Path:
    """Resolve e valida pat/<slug>/<cid>/<name>.md, confinando sob pat_dir()/slug."""
    root = _patient_root(slug)
    safe_cid = Path(cid).name
    safe_name = Path(name).name
    if not safe_cid or safe_cid != cid:
        raise HTTPException(400, "Id de consulta inválido.")
    if not safe_name or Path(safe_name).suffix.lower() != ".md":
        raise HTTPException(400, "Apenas documentos .md são permitidos.")
    return root / safe_cid / safe_name


@app.get("/patients/{slug}/consultations/{cid}/documents/{name}", response_class=PlainTextResponse)
def get_consult_document(slug: str, cid: str, name: str) -> str:
    """Retorna o conteúdo (Markdown) de um documento de uma consulta."""
    path = _consult_doc_path(slug, cid, name)
    if not path.is_file():
        raise HTTPException(404, f"Documento não encontrado: {Path(name).name}")
    return path.read_text(encoding="utf-8")


@app.put("/patients/{slug}/consultations/{cid}/documents/{name}", response_model=DocumentWriteResult)
def put_consult_document(slug: str, cid: str, name: str, content: str = Body(..., embed=True)) -> DocumentWriteResult:
    """Sobrescreve um documento Markdown de uma consulta; só grava em C{n}/*.md."""
    path = _consult_doc_path(slug, cid, name)
    if not path.parent.is_dir():
        raise HTTPException(404, f"Consulta não encontrada: {Path(cid).name}")
    data = content.encode("utf-8")
    path.write_bytes(data)
    return DocumentWriteResult(ok=True, bytes=len(data))


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


@app.get("/patients/{slug}/info")
def get_patient_info(slug: str) -> dict:
    """Visão mesclada (profile + index) do paciente [compat]."""
    info = load_info(slug)
    if not info:
        raise HTTPException(404, f"Dossiê ausente para {slug}")
    return info


# ---------------------------------------------------------------------------
# CRUD — criação de dossiês, consultas, documentos e arquivos
# ---------------------------------------------------------------------------
@app.post("/patients")
def create_patient(body: PatientCreate) -> dict:
    """Cria um dossiê novo a partir do nome completo e devolve o profile.json."""
    slug = store.generate_slug(body.full_name)
    store.ensure_profile(slug, patient_name=body.full_name)
    prof = store.load_profile(slug)
    prof["display_name"] = body.full_name
    prof["full_name"] = body.full_name
    for field in ("cpf", "phone", "age", "email", "notes"):
        value = getattr(body, field)
        if value is not None:
            prof[field] = value
    store.save_profile(slug, prof)  # força slug + updated_at
    return store.load_profile(slug)


@app.post("/patients/{slug}/consultations", response_model=ConsultationCreateResult)
def create_consultation(slug: str, body: ConsultationCreate) -> ConsultationCreateResult:
    """Cria (reserva) uma consulta para a data informada (default = hoje)."""
    root = _patient_root(slug)
    if not root.is_dir():
        raise HTTPException(404, f"Paciente não encontrado: {slug}")
    date = body.date or today()
    store.consult_dir(slug, date, create=True)  # cria a pasta + reserva C{n} no index
    cid = store.resolve_consult(slug, date, create=False)
    if not cid:
        raise HTTPException(500, "Falha ao resolver a consulta criada.")
    return ConsultationCreateResult(id=cid, date=date)


@app.post(
    "/patients/{slug}/consultations/{cid}/documents",
    response_model=DocumentCreateResult,
)
def create_consult_document(slug: str, cid: str, body: DocumentCreate) -> DocumentCreateResult:
    """Cria um NOVO documento Markdown em pat/<slug>/<cid>/ com o conteúdo dado."""
    root = _patient_root(slug)
    safe_cid = Path(cid).name
    if not safe_cid or safe_cid != cid:
        raise HTTPException(400, "Id de consulta inválido.")
    cdir = root / safe_cid
    if not cdir.is_dir():
        raise HTTPException(404, f"Consulta não encontrada: {safe_cid}")

    name = Path(body.name).name  # sanitiza traversal
    if not name or name in (".", ".."):
        raise HTTPException(400, "Nome de documento inválido.")
    if Path(name).suffix.lower() != ".md":
        name = f"{name}.md"

    dest = (cdir / name).resolve()
    # Confina rigorosamente sob a pasta da consulta.
    if cdir.resolve() not in dest.parents:
        raise HTTPException(400, "Caminho fora da consulta.")
    dest.write_text(body.content, encoding="utf-8")
    return DocumentCreateResult(ok=True, name=name)


@app.post("/patients/{slug}/consultations/{cid}/files", response_model=UploadResponse)
async def upload_consult_file(slug: str, cid: str, file: UploadFile = File(...)) -> UploadResponse:
    """Salva um arquivo (qualquer tipo) em pat/<slug>/<cid>/<filename>."""
    root = _patient_root(slug)
    safe_cid = Path(cid).name
    if not safe_cid or safe_cid != cid:
        raise HTTPException(400, "Id de consulta inválido.")
    cdir = root / safe_cid
    if not cdir.is_dir():
        raise HTTPException(404, f"Consulta não encontrada: {safe_cid}")

    name = Path(file.filename or "").name  # evita traversal
    if not name or name in (".", ".."):
        raise HTTPException(422, "Nome de arquivo ausente ou inválido.")
    dest = (cdir / name).resolve()
    if cdir.resolve() not in dest.parents:
        raise HTTPException(400, "Caminho fora da consulta.")

    data = await file.read()
    if not data:
        raise HTTPException(422, "Arquivo vazio.")
    dest.write_bytes(data)
    return UploadResponse(filename=name, path=str(dest))


# Stages expostos para a UI (rótulos PT-BR). O disparo continua via POST /jobs/{stage}.
_STAGES: list[dict[str, str]] = [
    {"key": "transcribe", "label": "Transcrição"},
    {"key": "normalize", "label": "Normalização"},
    {"key": "asl", "label": "Análise Sistêmica Linguística (ASL)"},
    {"key": "dimensional", "label": "Perfil Dimensional (VDLP)"},
    {"key": "gem", "label": "Grafo do Espaço Mental (GEM)"},
    {"key": "birp", "label": "Nota BIRP"},
    {"key": "soap_trajetorial", "label": "SOAP Trajetorial"},
    {"key": "soap_longitudinal", "label": "SOAP Longitudinal"},
    {"key": "pipeline", "label": "Pipeline completo"},
]


@app.get("/stages")
def list_stages() -> dict:
    """Lista os stages disponíveis (chave técnica + rótulo PT-BR) para a UI."""
    return {"stages": _STAGES}


# ---------------------------------------------------------------------------
# Perfil do profissional (professional.json) — global ao app
# Fonte de verdade para assinatura, identificação e grounding da normalização.
# ---------------------------------------------------------------------------
@app.get("/professional")
def get_professional() -> dict:
    """Retorna o perfil do profissional (Dr. Gustavo). Vazio se ainda não definido."""
    return store.load_professional()


@app.put("/professional")
def put_professional(update: ProfessionalUpdate) -> dict:
    """Salva/atualiza o perfil do profissional (merge dos campos não-nulos)."""
    current = store.load_professional()
    for k, v in update.model_dump(exclude_none=True).items():
        current[k] = v
    store.save_professional(current)
    return current


# ---------------------------------------------------------------------------
# Soft-delete (DESTRUCTIVE-SAFE): nada é apagado de verdade — tudo vai para o
# lixo em M_BASE/_trash/. Todos os caminhos confinados sob M_BASE.
# ---------------------------------------------------------------------------
def _trash_dir() -> Path:
    d = get_settings().m_base / "_trash"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _trash_dest(name: str, *, stamp: Optional[str] = None) -> Path:
    """
    Caminho destino em _trash/ a partir de um `name` base. Se `stamp` vier no body,
    usa-o; senão (e em caso de colisão) usa um sufixo incremental -2, -3… Como não
    há relógio confiável, o sufixo garante unicidade sem sobrescrever lixo anterior.
    """
    trash = _trash_dir()
    safe = Path(name).name  # defensivo contra traversal
    base = f"{safe}__{stamp}" if stamp else safe
    dest = trash / base
    if not dest.exists():
        return dest
    n = 2
    while (trash / f"{base}-{n}").exists():
        n += 1
    return trash / f"{base}-{n}"


@app.delete("/patients/{slug}")
def delete_patient(slug: str, body: Optional[dict] = Body(default=None)) -> dict:
    """Move pat/<slug> → _trash/<slug>__<stamp> (soft-delete, nunca rm)."""
    root = _patient_root(slug)  # valida slug + confina sob pat_dir()
    if not root.is_dir():
        raise HTTPException(404, f"Paciente não encontrado: {slug}")
    stamp = (body or {}).get("stamp")
    dest = _trash_dest(slug, stamp=stamp)
    root.rename(dest)
    return {"ok": True, "trashed": str(dest)}


@app.delete("/patients/{slug}/consultations/{cid}")
def delete_consultation(slug: str, cid: str, body: Optional[dict] = Body(default=None)) -> dict:
    """
    Move pat/<slug>/<cid> → _trash/<slug>__<cid>__<suffix> e remove a entrada da
    consulta do index.json. Soft-delete confinado sob M_BASE.
    """
    root = _patient_root(slug)
    safe_cid = Path(cid).name
    if not safe_cid or safe_cid != cid:
        raise HTTPException(400, "Id de consulta inválido.")
    cdir = root / safe_cid
    stamp = (body or {}).get("stamp")
    moved = None
    if cdir.is_dir():
        dest = _trash_dest(f"{slug}__{safe_cid}", stamp=stamp)
        cdir.rename(dest)
        moved = str(dest)
    # Remove a entrada do index.json (mesmo que a pasta não exista mais).
    idx = store.load_index(slug)
    cons = idx.get("consultations", [])
    idx["consultations"] = [c for c in cons if c.get("id") != safe_cid]
    store.save_index(slug, idx)
    if moved is None and len(idx["consultations"]) == len(cons):
        raise HTTPException(404, f"Consulta não encontrada: {safe_cid}")
    return {"ok": True}


@app.delete("/patients/{slug}/consultations/{cid}/documents/{name}")
def delete_consult_document(slug: str, cid: str, name: str, body: Optional[dict] = Body(default=None)) -> dict:
    """Move pat/<slug>/<cid>/<name>.md → _trash (soft-delete; só .md, confinado)."""
    path = _consult_doc_path(slug, cid, name)  # valida slug/cid/.md + confina
    if not path.is_file():
        raise HTTPException(404, f"Documento não encontrado: {Path(name).name}")
    stamp = (body or {}).get("stamp")
    dest = _trash_dest(f"{slug}__{Path(cid).name}__{path.name}", stamp=stamp)
    path.rename(dest)
    return {"ok": True}


@app.get("/healthz")
def healthz() -> dict:
    """Liveness simples + eco da raiz de dados configurada."""
    return {"status": "ok", "m_base": str(get_settings().m_base)}
