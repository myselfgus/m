"""
M-Engine — Store de dossiês de pacientes (arquivos em volume).

Modelo (jun/2026, redesign orientado a NOME + consultas):

  pat/<slug>/
    profile.json            identidade EDITÁVEL: nome completo/exibição, CPF, telefone, idade…
    index.json              mantido pela máquina: consultas (C1/C2/C3…) + clinical_summary
    C1/                     uma pasta por consulta (data nos metadados do index.json)
      transcription.json
      BIRP.md   BIRP.json
      ASL.json  DIMENSIONAL.json  GEM.json
      SOAP_trajetorial.md
    C2/  …  C3/  …
    longitudinal/           SOAP longitudinal (cobre várias consultas)

Princípios:
- `slug` é um identificador LEGÍVEL e ESTÁVEL derivado do nome na criação. Corrigir o
  nome de exibição (profile.json) NÃO muda o slug nem quebra caminhos.
- As funções de path mantêm a assinatura `(patient_id, date)` — `patient_id` agora é o
  slug e o store resolve internamente a consulta `C{n}` pela data (mapa em index.json).
  Isso mantém os stages do pipeline praticamente inalterados.
- Naming de artefatos é centralizado aqui.
"""

from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

from m_engine.config import get_settings
from m_engine.util import now_iso

_CONNECTORS = {"E", "DE", "DA", "DO", "DAS", "DOS"}


# ---------------------------------------------------------------------------
# Helpers de texto
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


def slugify(name: str) -> str:
    """Slug legível: minúsculas, sem acento, palavras unidas por hífen."""
    base = _strip_accents(name or "").lower()
    base = re.sub(r"[^a-z0-9]+", "-", base).strip("-")
    return base or "paciente"


def pat_dir() -> Path:
    d = get_settings().pat_dir
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# Perfil do profissional ativo (M_BASE/professional.json) — fonte de verdade
# para assinatura, identificação e grounding da normalização.
# ---------------------------------------------------------------------------


def professional_path() -> Path:
    return get_settings().m_base / "professional.json"


def load_professional() -> dict:
    """
    Lê M_BASE/professional.json (perfil ÚNICO do clínico ativo). Tolerante:
    arquivo ausente ou corrompido → {}. Nunca levanta exceção.
    Campos: name, credential (CRM/RQE), specialty, clinic, signature, notes.
    """
    try:
        p = professional_path()
        if p.is_file():
            return json.loads(p.read_text(encoding="utf-8")) or {}
    except (json.JSONDecodeError, OSError, ValueError):
        pass
    return {}


def save_professional(professional: dict) -> None:
    """Persiste o perfil do profissional ativo (M_BASE/professional.json)."""
    p = professional_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(professional or {}, ensure_ascii=False, indent=2), encoding="utf-8")


def professional_signature_block() -> str:
    """
    Bloco de assinatura em Markdown a partir do perfil ativo. Omite linhas vazias.
    Retorna "" quando não há perfil. `credential` aceita o alias legado `registration`.
    """
    prof = load_professional()
    if not prof:
        return ""
    name = (prof.get("name") or "").strip()
    credential = (prof.get("credential") or prof.get("registration") or "").strip()
    specialty = (prof.get("specialty") or "").strip()
    clinic = (prof.get("clinic") or "").strip()
    signature = (prof.get("signature") or "").strip()

    lines: list[str] = []
    if name:
        lines.append(f"**{name}**")
    cred_spec = " · ".join(x for x in (credential, specialty) if x)
    if cred_spec:
        lines.append(cred_spec)
    if clinic:
        lines.append(clinic)
    if signature:
        lines.append(signature)
    if not lines:
        return ""
    # Markdown hard line breaks (two trailing spaces) entre as linhas do bloco.
    body = "  \n".join(lines)
    return f"\n\n---\n\n{body}"


# ---------------------------------------------------------------------------
# Identidade do paciente (slug + profile.json)
# ---------------------------------------------------------------------------


def generate_slug(patient_name: str) -> str:
    """Slug único e estável a partir do nome; desambigua com sufixo -2, -3…"""
    base = slugify(patient_name)
    root = pat_dir()
    if not (root / base).exists():
        return base
    n = 2
    while (root / f"{base}-{n}").exists():
        n += 1
    return f"{base}-{n}"


# Mantido para compatibilidade com call sites (birp/normalize): agora devolve um SLUG.
def generate_patient_id(patient_name: str) -> str:
    return generate_slug(patient_name)


def find_existing_patient(patient_name: str | None = None, *, cpf: str | None = None) -> str | None:
    """
    Resolve o slug de um dossiê existente por CPF (preferencial) ou nome normalizado.
    Devolve o slug (nome do diretório) ou None.
    """
    target = normalize_name(patient_name) if patient_name else None
    norm_cpf = re.sub(r"\D", "", cpf) if cpf else None
    for child in pat_dir().iterdir():
        if not child.is_dir():
            continue
        prof = load_profile(child.name)
        if not prof:
            continue
        if norm_cpf and re.sub(r"\D", "", str(prof.get("cpf") or "")) == norm_cpf:
            return child.name
        name = prof.get("full_name") or prof.get("display_name") or prof.get("patient_name")
        if target and name and normalize_name(name) == target:
            return child.name
    return None


# ---------------------------------------------------------------------------
# profile.json (identidade editável)
# ---------------------------------------------------------------------------


def profile_path(slug: str) -> Path:
    return pat_dir() / slug / "profile.json"


def load_profile(slug: str) -> dict:
    p = profile_path(slug)
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def save_profile(slug: str, profile: dict) -> None:
    p = profile_path(slug)
    p.parent.mkdir(parents=True, exist_ok=True)
    profile = {**profile, "slug": slug, "updated_at": now_iso()}
    p.write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding="utf-8")


def ensure_profile(slug: str, *, patient_name: str | None = None, professional: dict | None = None) -> dict:
    """Garante profile.json com a identidade mínima; não sobrescreve campos editados."""
    prof = load_profile(slug)
    if not prof:
        prof = {
            "slug": slug,
            "display_name": patient_name or slug,
            "full_name": patient_name or "",
            "cpf": None,
            "phone": None,
            "birthdate": None,
            "age": None,
            "email": None,
            "notes": None,
            "professional": professional or {},
            "created_at": now_iso(),
        }
        save_profile(slug, prof)
    else:
        changed = False
        if patient_name and not prof.get("full_name"):
            prof["full_name"] = patient_name
            changed = True
        if patient_name and not prof.get("display_name"):
            prof["display_name"] = patient_name
            changed = True
        if professional and not prof.get("professional"):
            prof["professional"] = professional
            changed = True
        if changed:
            save_profile(slug, prof)
    return prof


# ---------------------------------------------------------------------------
# index.json (consultas + clinical_summary; mantido pela máquina)
# ---------------------------------------------------------------------------


def index_path(slug: str) -> Path:
    return pat_dir() / slug / "index.json"


def load_index(slug: str) -> dict:
    p = index_path(slug)
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {"slug": slug, "consultations": [], "clinical_summary": None, "last_updated": None}


def save_index(slug: str, index: dict) -> None:
    p = index_path(slug)
    p.parent.mkdir(parents=True, exist_ok=True)
    index = {**index, "slug": slug, "last_updated": now_iso()}
    p.write_text(json.dumps(index, ensure_ascii=False, indent=2), encoding="utf-8")


# load_info: visão mesclada (profile + index) — compat com API e stages SOAP.
def load_info(slug: str) -> dict:
    prof = load_profile(slug)
    idx = load_index(slug)
    if not prof and not idx.get("consultations"):
        return {}
    merged = {**prof}
    merged["patient_id"] = slug
    merged["patient_name"] = prof.get("display_name") or prof.get("full_name") or slug
    merged["consultations"] = idx.get("consultations", [])
    merged["sessions"] = idx.get("consultations", [])  # alias legado
    merged["clinical_summary"] = idx.get("clinical_summary")
    return merged


def save_info(slug: str, info: dict) -> None:
    """Compat: roteia campos de identidade ao profile e clínicos ao index."""
    prof = load_profile(slug) or {}
    for k in ("display_name", "full_name", "cpf", "phone", "birthdate", "age", "email", "notes", "professional"):
        if k in info:
            prof[k] = info[k]
    if info.get("patient_name") and not info.get("display_name"):
        prof["display_name"] = info["patient_name"]
    save_profile(slug, prof)
    if "clinical_summary" in info or "consultations" in info or "sessions" in info:
        idx = load_index(slug)
        if "clinical_summary" in info:
            idx["clinical_summary"] = info["clinical_summary"]
        if info.get("consultations") or info.get("sessions"):
            idx["consultations"] = info.get("consultations") or info.get("sessions")
        save_index(slug, idx)


# ---------------------------------------------------------------------------
# Consultas (C1/C2/C3…) — resolução data → pasta
# ---------------------------------------------------------------------------


def _consultations(idx: dict) -> list[dict]:
    return idx.setdefault("consultations", [])


def resolve_consult(slug: str, date: str, *, create: bool = True) -> str | None:
    """
    Mapeia uma data para a pasta de consulta `C{n}` (via index.json).
    Ordinal por ordem de inserção; na migração as consultas entram em ordem de data,
    então C1 = mais antiga. Se a data é nova e create=True, reserva o próximo C{n}.
    """
    idx = load_index(slug)
    for c in _consultations(idx):
        if c.get("date") == date:
            return c.get("id")
    if not create:
        return None
    cid = f"C{len(_consultations(idx)) + 1}"
    _consultations(idx).append({"id": cid, "date": date})
    save_index(slug, idx)
    return cid


def consult_dir(slug: str, date: str, *, create: bool = True) -> Path:
    cid = resolve_consult(slug, date, create=create)
    d = pat_dir() / slug / (cid or "C0")
    if create:
        d.mkdir(parents=True, exist_ok=True)
    return d


def ensure_dossier(slug: str) -> Path:
    """Garante pat/<slug>/ com profile.json + index.json (sem subdirs de tipo)."""
    root = pat_dir() / slug
    root.mkdir(parents=True, exist_ok=True)
    ensure_profile(slug)
    if not index_path(slug).exists():
        save_index(slug, load_index(slug))
    return root


# ---------------------------------------------------------------------------
# Caminhos de artefatos por consulta (assinaturas preservadas: slug, date)
# ---------------------------------------------------------------------------


def transcription_path(patient_id: str, date: str) -> Path:
    return consult_dir(patient_id, date) / "transcription.json"


def asl_path(patient_id: str, date: str) -> Path:
    return consult_dir(patient_id, date) / "ASL.json"


def dimensional_path(patient_id: str, date: str) -> Path:
    return consult_dir(patient_id, date) / "DIMENSIONAL.json"


def gem_path(patient_id: str, date: str) -> Path:
    return consult_dir(patient_id, date) / "GEM.json"


def birp_doc_path(patient_id: str, date: str, timestamp: str | None = None) -> Path:
    """Nota BIRP em Markdown — uma por consulta, EDITÁVEL: C{n}/BIRP.md."""
    return consult_dir(patient_id, date) / "BIRP.md"


def birp_json_path(patient_id: str, date: str) -> Path:
    """JSON estrutural do BIRP: C{n}/BIRP.json."""
    return consult_dir(patient_id, date) / "BIRP.json"


def soap_trajetorial_path(patient_id: str, date: str) -> Path:
    return consult_dir(patient_id, date) / "SOAP_trajetorial.md"


def longitudinal_dir(patient_id: str) -> Path:
    d = pat_dir() / patient_id / "longitudinal"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def read_json(path: Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# clinical_summary — agregação por sessão (portado de patient-utils.ts)
# ---------------------------------------------------------------------------


def update_clinical_summary(summary: dict | None, clinical: dict, timestamp: str) -> dict:
    """
    Agrega metadados clínicos de uma sessão ao clinical_summary acumulado.
    `clinical` aceita: icd_codes[], medications_mentioned[], topicos_principais[],
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
    Garante identidade (profile.json) e registra a consulta no index.json
    (dedupe pela data; agrega clinical_summary se metadados fornecidos).
    `patient_id` é o slug.
    """
    ensure_profile(patient_id, patient_name=patient_name, professional=professional)

    idx = load_index(patient_id)
    date = session_entry.get("date")
    cid = resolve_consult(patient_id, date, create=True) if date else None
    idx = load_index(patient_id)  # recarrega: resolve_consult pode ter persistido o C{n}

    cons = _consultations(idx)
    merged_entry = {"id": cid, **session_entry}
    found = False
    for i, c in enumerate(cons):
        if (cid and c.get("id") == cid) or (date and c.get("date") == date):
            cons[i] = {**c, **merged_entry}
            found = True
            break
    if not found:
        cons.append(merged_entry)

    if clinical_metadata:
        ts = session_entry.get("processed_at") or now_iso()
        idx["clinical_summary"] = update_clinical_summary(idx.get("clinical_summary"), clinical_metadata, ts)

    save_index(patient_id, idx)
    return load_info(patient_id)


# ---------------------------------------------------------------------------
# Listagem (para a API)
# ---------------------------------------------------------------------------


def list_patients() -> list[dict]:
    """Lista dossiês com identidade resumida (slug + nome de exibição + nº de consultas)."""
    out: list[dict] = []
    for child in sorted(pat_dir().iterdir(), key=lambda c: c.name):
        if not child.is_dir():
            continue
        prof = load_profile(child.name)
        idx = load_index(child.name)
        out.append({
            "slug": child.name,
            "display_name": prof.get("display_name") or prof.get("full_name") or child.name,
            "consultation_count": len(idx.get("consultations", [])),
        })
    return out
