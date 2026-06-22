"""
M-Engine — Store de dossiês de pacientes (arquivos em volume).

Estrutura por paciente em $M_BASE/pat/<PATIENT_ID>/:
  transcriptions/        YYYY-MM-DD_transcription.json   (diálogo COMPLETO)
  linguistic-analysis/   <PID>_<DATE>_ASL.json
  dimensional-analysis/  <PID>_<DATE>_DIMENSIONAL.json
  gem/                   <PID>_<DATE>_GEM.json           (naming unificado)
  clinical-documents/    <PID>_SOAP_*_<ts>.md
  info.json

Naming de artefatos é centralizado aqui (resolve a inconsistência _GEM.json vs .gem.json do legado).
PATIENT_ID = PAT_<INICIAIS>_<NN>.
"""

from __future__ import annotations

import json
import unicodedata
from pathlib import Path

from m_engine.config import get_settings
from m_engine.util import now_iso

_CONNECTORS = {"E", "DE", "DA", "DO", "DAS", "DOS"}


# ---------------------------------------------------------------------------
# Identidade do paciente
# ---------------------------------------------------------------------------


def _strip_accents(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")


def extract_initials(full_name: str) -> str:
    if not full_name or not full_name.strip():
        return "XXX"
    parts = [p for p in _strip_accents(full_name).upper().split() if p]
    significant = [p for p in parts if p not in _CONNECTORS]
    initials = "".join(p[0] for p in significant[:4])
    return initials or "XXX"


def normalize_name(name: str) -> str:
    return " ".join(_strip_accents(name).lower().split())


def pat_dir() -> Path:
    d = get_settings().pat_dir
    d.mkdir(parents=True, exist_ok=True)
    return d


def generate_patient_id(patient_name: str) -> str:
    """PAT_<INICIAIS>_<NN> com NN sequencial sobre os dossiês existentes."""
    prefix = f"PAT_{extract_initials(patient_name)}_"
    max_n = 0
    base = pat_dir()
    for child in base.iterdir():
        if child.is_dir() and child.name.startswith(prefix):
            tail = child.name[len(prefix):]
            if tail.isdigit():
                max_n = max(max_n, int(tail))
    return f"{prefix}{max_n + 1:02d}"


def find_existing_patient(patient_name: str) -> str | None:
    """Retorna PATIENT_ID de dossiê existente com mesmo nome (normalizado), ou None."""
    target = normalize_name(patient_name)
    for child in pat_dir().iterdir():
        info = child / "info.json"
        if not (child.is_dir() and info.exists()):
            continue
        try:
            data = json.loads(info.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if data.get("patient_name") and normalize_name(data["patient_name"]) == target:
            return child.name
    return None


# ---------------------------------------------------------------------------
# Diretórios e caminhos de artefatos (naming unificado)
# ---------------------------------------------------------------------------

_SUBDIRS = ("transcriptions", "linguistic-analysis", "dimensional-analysis", "gem", "clinical-documents", "narrative")


def ensure_dossier(patient_id: str) -> Path:
    root = pat_dir() / patient_id
    for sub in _SUBDIRS:
        (root / sub).mkdir(parents=True, exist_ok=True)
    return root


def transcription_path(patient_id: str, date: str) -> Path:
    return pat_dir() / patient_id / "transcriptions" / f"{date}_transcription.json"


def asl_path(patient_id: str, date: str) -> Path:
    return pat_dir() / patient_id / "linguistic-analysis" / f"{patient_id}_{date}_ASL.json"


def dimensional_path(patient_id: str, date: str) -> Path:
    return pat_dir() / patient_id / "dimensional-analysis" / f"{patient_id}_{date}_DIMENSIONAL.json"


def gem_path(patient_id: str, date: str) -> Path:
    # Convenção ÚNICA: <PID>_<DATE>_GEM.json (todos os stages usam esta)
    return pat_dir() / patient_id / "gem" / f"{patient_id}_{date}_GEM.json"


# ---------------------------------------------------------------------------
# Metadados (info.json)
# ---------------------------------------------------------------------------


def load_info(patient_id: str) -> dict:
    path = pat_dir() / patient_id / "info.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {}


def save_info(patient_id: str, info: dict) -> None:
    path = pat_dir() / patient_id / "info.json"
    path.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def read_json(path: Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# BIRP — paths de artefatos
# ---------------------------------------------------------------------------


def birp_doc_path(patient_id: str, date: str, timestamp: str) -> Path:
    """Nota BIRP em Markdown: clinical-documents/<PID>_BIRP_<date>_<ts>.md."""
    return pat_dir() / patient_id / "clinical-documents" / f"{patient_id}_BIRP_{date}_{timestamp}.md"


def birp_json_path(patient_id: str, date: str) -> Path:
    """JSON estrutural do BIRP (seções + metadados clínicos): clinical-documents/<PID>_<date>_BIRP.json."""
    return pat_dir() / patient_id / "clinical-documents" / f"{patient_id}_{date}_BIRP.json"


# ---------------------------------------------------------------------------
# info.json — agregação de clinical_summary e registro de sessão
# (portado de patient-utils.ts do legado)
# ---------------------------------------------------------------------------


def update_clinical_summary(summary: dict | None, clinical: dict, timestamp: str) -> dict:
    """
    Agrega metadados clínicos de uma sessão ao clinical_summary acumulado.
    `clinical` aceita as chaves: icd_codes[], medications_mentioned[], topicos_principais[],
    clinical_context.encounter_type. Idempotente por código/nome/tópico/tipo.
    """
    s = summary or {
        "all_icd_codes": [],
        "all_medications": [],
        "common_topics": [],
        "encounter_types": [],
        "last_updated": timestamp,
    }

    for icd in clinical.get("icd_codes") or []:
        existing = next((i for i in s["all_icd_codes"] if i.get("code") == icd.get("code")), None)
        if existing:
            existing["last_mentioned"] = timestamp
            existing["occurrences"] = existing.get("occurrences", 0) + 1
            if icd.get("certainty") and icd["certainty"] not in existing.setdefault("certainty_history", []):
                existing["certainty_history"].append(icd["certainty"])
        else:
            s["all_icd_codes"].append({
                "code": icd.get("code"),
                "description": icd.get("description"),
                "first_mentioned": timestamp,
                "last_mentioned": timestamp,
                "occurrences": 1,
                "certainty_history": [icd["certainty"]] if icd.get("certainty") else [],
            })

    for med in clinical.get("medications_mentioned") or []:
        name = (med.get("name") or "").lower()
        existing = next((m for m in s["all_medications"] if (m.get("name") or "").lower() == name), None)
        if existing:
            existing["last_mentioned"] = timestamp
            if med.get("context") and med["context"] not in existing.setdefault("contexts", []):
                existing["contexts"].append(med["context"])
            if med.get("dosage"):
                existing.setdefault("dosages_mentioned", [])
                if med["dosage"] not in existing["dosages_mentioned"]:
                    existing["dosages_mentioned"].append(med["dosage"])
        else:
            s["all_medications"].append({
                "name": med.get("name"),
                "first_mentioned": timestamp,
                "last_mentioned": timestamp,
                "contexts": [med["context"]] if med.get("context") else [],
                "dosages_mentioned": [med["dosage"]] if med.get("dosage") else [],
            })

    for topic in clinical.get("topicos_principais") or []:
        existing = next((t for t in s["common_topics"] if t.get("topic") == topic), None)
        if existing:
            existing["frequency"] = existing.get("frequency", 0) + 1
        else:
            s["common_topics"].append({"topic": topic, "frequency": 1})
    s["common_topics"].sort(key=lambda t: t.get("frequency", 0), reverse=True)

    enc = (clinical.get("clinical_context") or {}).get("encounter_type")
    if enc:
        existing = next((e for e in s["encounter_types"] if e.get("type") == enc), None)
        if existing:
            existing["count"] = existing.get("count", 0) + 1
        else:
            s["encounter_types"].append({"type": enc, "count": 1})

    s["last_updated"] = timestamp
    return s


def register_session(
    patient_id: str,
    *,
    patient_name: str,
    patient_initials: str | None = None,
    professional: dict | None = None,
    session_entry: dict,
    clinical_metadata: dict | None = None,
) -> dict:
    """
    Cria/atualiza o info.json do dossiê: garante identidade, registra a sessão
    (dedupe por source_file) e agrega clinical_summary se metadados fornecidos.
    """
    info = load_info(patient_id) or {}
    if not info:
        info = {
            "patient_id": patient_id,
            "patient_name": patient_name,
            "patient_initials": patient_initials,
            "professional": professional or {},
            "created_at": now_iso(),
            "sessions": [],
        }
    else:
        info.setdefault("sessions", [])
        if patient_name:
            info["patient_name"] = patient_name
        if patient_initials:
            info["patient_initials"] = patient_initials
        if professional:
            info["professional"] = professional

    src = session_entry.get("source_file")
    info["sessions"] = [x for x in info["sessions"] if x.get("source_file") != src]
    info["sessions"].append(session_entry)

    if clinical_metadata:
        ts = session_entry.get("processed_at") or now_iso()
        info["clinical_summary"] = update_clinical_summary(info.get("clinical_summary"), clinical_metadata, ts)

    info["last_updated"] = now_iso()
    save_info(patient_id, info)
    return info
