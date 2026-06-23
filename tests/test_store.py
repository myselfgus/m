"""
Testes de m_engine.store — identidade do paciente, slugs e layout de dossiê.

Tudo offline: usa a fixture `tmp_m_base` para isolar M_BASE em tmp_path.

Layout (redesign jun/2026):
    pat/<slug>/profile.json   (identidade editável)
    pat/<slug>/index.json     (consultas C1/C2/C3 + clinical_summary)
    pat/<slug>/C{n}/...        (artefatos por consulta)
"""

from __future__ import annotations

from m_engine import store


# ---------------------------------------------------------------------------
# extract_initials (preservado)
# ---------------------------------------------------------------------------


def test_extract_initials_basico():
    assert store.extract_initials("João Silva") == "JS"


def test_extract_initials_ignora_conectores():
    # "de", "da", "dos" etc. não entram nas iniciais.
    assert store.extract_initials("Maria da Silva dos Santos") == "MSS"


def test_extract_initials_remove_acentos_e_capitaliza():
    assert store.extract_initials("ângela écio") == "AE"


def test_extract_initials_limita_a_quatro():
    # No máximo 4 partes significativas.
    assert store.extract_initials("Ana Beatriz Carla Daniela Eduarda") == "ABCD"


def test_extract_initials_vazio_retorna_xxx():
    assert store.extract_initials("") == "XXX"
    assert store.extract_initials("   ") == "XXX"


# ---------------------------------------------------------------------------
# normalize_name (preservado)
# ---------------------------------------------------------------------------


def test_normalize_name_minusculas_e_espacos():
    assert store.normalize_name("  João   Silva  ") == "joao silva"


def test_normalize_name_remove_acentos():
    assert store.normalize_name("José Antônio") == "jose antonio"


def test_normalize_name_idempotente():
    once = store.normalize_name("Maria DA Silva")
    assert store.normalize_name(once) == once


# ---------------------------------------------------------------------------
# slugify / generate_slug
# ---------------------------------------------------------------------------


def test_slugify_basico():
    assert store.slugify("João Silva") == "joao-silva"


def test_slugify_remove_acentos_e_pontuacao():
    assert store.slugify("José Antônio, Jr.") == "jose-antonio-jr"


def test_slugify_colapsa_espacos_e_hifens():
    assert store.slugify("  Maria   --  Souza  ") == "maria-souza"


def test_slugify_vazio_fallback():
    assert store.slugify("") == "paciente"
    assert store.slugify("!!!") == "paciente"


def test_generate_slug_primeiro(tmp_m_base):
    assert store.generate_slug("João Silva") == "joao-silva"


def test_generate_slug_colisao_sufixo_2(tmp_m_base):
    # Já existe o dossiê base -> próximo slug recebe sufixo -2.
    (store.pat_dir() / "joao-silva").mkdir()
    assert store.generate_slug("João Silva") == "joao-silva-2"


def test_generate_slug_colisao_sequencial(tmp_m_base):
    base = store.pat_dir()
    (base / "joao-silva").mkdir()
    (base / "joao-silva-2").mkdir()
    assert store.generate_slug("João Silva") == "joao-silva-3"


def test_generate_slug_nomes_distintos_independentes(tmp_m_base):
    (store.pat_dir() / "joao-silva").mkdir()
    # Nome diferente -> slug próprio, sem sufixo.
    assert store.generate_slug("Maria Souza") == "maria-souza"


def test_generate_patient_id_alias_de_slug(tmp_m_base):
    # generate_patient_id é mantido por compat e agora devolve um slug.
    assert store.generate_patient_id("João Silva") == "joao-silva"


# ---------------------------------------------------------------------------
# pat_dir
# ---------------------------------------------------------------------------


def test_pat_dir_criado_sob_tmp_m_base(tmp_m_base):
    d = store.pat_dir()
    assert d.exists() and d.is_dir()
    assert d == tmp_m_base / "pat"


# ---------------------------------------------------------------------------
# resolve_consult — data -> C{n}
# ---------------------------------------------------------------------------


def test_resolve_consult_primeira_data_e_C1(tmp_m_base):
    slug = "joao-silva"
    assert store.resolve_consult(slug, "2026-01-10") == "C1"


def test_resolve_consult_mesma_data_estavel(tmp_m_base):
    slug = "joao-silva"
    cid1 = store.resolve_consult(slug, "2026-01-10")
    cid2 = store.resolve_consult(slug, "2026-01-10")
    assert cid1 == cid2 == "C1"


def test_resolve_consult_datas_novas_sequenciais(tmp_m_base):
    slug = "joao-silva"
    assert store.resolve_consult(slug, "2026-01-10") == "C1"
    assert store.resolve_consult(slug, "2026-02-20") == "C2"
    assert store.resolve_consult(slug, "2026-03-30") == "C3"
    # Revisitar uma data antiga continua estável.
    assert store.resolve_consult(slug, "2026-01-10") == "C1"


def test_resolve_consult_ordem_de_insercao_crescente(tmp_m_base):
    # Migração: inserir datas em ordem crescente => C1 é a mais antiga.
    slug = "ana-paula"
    for d in ("2025-06-01", "2025-09-15", "2026-01-02"):
        store.resolve_consult(slug, d)
    idx = store.load_index(slug)
    by_id = {c["id"]: c["date"] for c in idx["consultations"]}
    assert by_id["C1"] == "2025-06-01"
    assert by_id["C2"] == "2025-09-15"
    assert by_id["C3"] == "2026-01-02"


def test_resolve_consult_sem_create_retorna_none(tmp_m_base):
    slug = "joao-silva"
    assert store.resolve_consult(slug, "2026-01-10", create=False) is None
    # Não deve ter persistido nada.
    assert store.load_index(slug)["consultations"] == []


# ---------------------------------------------------------------------------
# Caminhos de artefatos — resolvem sob pat/<slug>/C{n}/ com nomes canônicos
# ---------------------------------------------------------------------------


def test_path_helpers_sob_consulta_com_nomes_canonicos(tmp_m_base):
    slug = "joao-silva"
    date = "2026-01-10"
    base = store.pat_dir() / slug / "C1"

    assert store.transcription_path(slug, date) == base / "transcription.json"
    assert store.asl_path(slug, date) == base / "ASL.json"
    assert store.dimensional_path(slug, date) == base / "DIMENSIONAL.json"
    assert store.gem_path(slug, date) == base / "GEM.json"
    assert store.birp_doc_path(slug, date) == base / "BIRP.md"
    assert store.birp_json_path(slug, date) == base / "BIRP.json"
    assert store.soap_trajetorial_path(slug, date) == base / "SOAP_trajetorial.md"


def test_birp_doc_path_ignora_timestamp(tmp_m_base):
    # birp_doc_path ainda aceita um timestamp (compat) mas não o usa no nome.
    slug = "joao-silva"
    date = "2026-01-10"
    with_ts = store.birp_doc_path(slug, date, timestamp="20260110T120000")
    without_ts = store.birp_doc_path(slug, date)
    assert with_ts == without_ts
    assert with_ts.name == "BIRP.md"


def test_path_helpers_datas_distintas_pastas_distintas(tmp_m_base):
    slug = "joao-silva"
    p1 = store.asl_path(slug, "2026-01-10")
    p2 = store.asl_path(slug, "2026-02-20")
    assert p1.parent.name == "C1"
    assert p2.parent.name == "C2"
    assert p1 != p2


def test_longitudinal_dir(tmp_m_base):
    slug = "joao-silva"
    d = store.longitudinal_dir(slug)
    assert d == store.pat_dir() / slug / "longitudinal"
    assert d.exists() and d.is_dir()


def test_consult_dir_cria_pasta(tmp_m_base):
    slug = "joao-silva"
    d = store.consult_dir(slug, "2026-01-10")
    assert d == store.pat_dir() / slug / "C1"
    assert d.exists()


# ---------------------------------------------------------------------------
# profile.json — editar display_name NÃO muda o slug/paths
# ---------------------------------------------------------------------------


def test_editar_display_name_nao_muda_slug_nem_paths(tmp_m_base):
    slug = store.generate_slug("João Silva")  # joao-silva
    store.ensure_profile(slug, patient_name="João Silva")
    path_antes = store.asl_path(slug, "2026-01-10")

    prof = store.load_profile(slug)
    prof["display_name"] = "João Pereira da Silva (corrigido)"
    store.save_profile(slug, prof)

    # Slug permanece; profile preserva o slug original.
    assert store.load_profile(slug)["slug"] == slug
    assert store.load_profile(slug)["display_name"] == "João Pereira da Silva (corrigido)"
    # O caminho do artefato não muda.
    assert store.asl_path(slug, "2026-01-10") == path_antes


def test_ensure_profile_nao_sobrescreve_campos_editados(tmp_m_base):
    slug = "joao-silva"
    store.ensure_profile(slug, patient_name="João Silva")
    prof = store.load_profile(slug)
    prof["full_name"] = "João da Silva Pereira"
    store.save_profile(slug, prof)
    # Re-chamar ensure_profile com outro nome não deve sobrescrever full_name já definido.
    store.ensure_profile(slug, patient_name="Outro Nome")
    assert store.load_profile(slug)["full_name"] == "João da Silva Pereira"


# ---------------------------------------------------------------------------
# find_existing_patient
# ---------------------------------------------------------------------------


def test_find_existing_patient_por_nome(tmp_m_base):
    slug = store.generate_slug("João Silva")
    store.ensure_profile(slug, patient_name="João Silva")
    # Match por nome normalizado (acentos/caixa irrelevantes).
    assert store.find_existing_patient("joao silva") == slug
    assert store.find_existing_patient("JOÃO SILVA") == slug


def test_find_existing_patient_por_cpf(tmp_m_base):
    slug = store.generate_slug("Maria Souza")
    store.ensure_profile(slug, patient_name="Maria Souza")
    prof = store.load_profile(slug)
    prof["cpf"] = "123.456.789-00"
    store.save_profile(slug, prof)
    # CPF com formatação diferente ainda casa (normaliza dígitos).
    assert store.find_existing_patient(cpf="12345678900") == slug
    assert store.find_existing_patient(cpf="123.456.789-00") == slug


def test_find_existing_patient_inexistente(tmp_m_base):
    store.ensure_profile("joao-silva", patient_name="João Silva")
    assert store.find_existing_patient("Fulano Inexistente") is None
    assert store.find_existing_patient(cpf="00000000000") is None


# ---------------------------------------------------------------------------
# register_session — profile + index, dedupe por data, agrega clinical_summary
# ---------------------------------------------------------------------------


def test_register_session_cria_profile_e_index(tmp_m_base):
    slug = "joao-silva"
    store.register_session(
        slug,
        patient_name="João Silva",
        professional={"name": "Dr. Teste"},
        session_entry={"date": "2026-01-10", "transcript_chars": 100},
    )
    assert store.profile_path(slug).exists()
    assert store.index_path(slug).exists()

    prof = store.load_profile(slug)
    assert prof["display_name"] == "João Silva"
    assert prof["professional"] == {"name": "Dr. Teste"}

    idx = store.load_index(slug)
    assert len(idx["consultations"]) == 1
    c = idx["consultations"][0]
    assert c["id"] == "C1"
    assert c["date"] == "2026-01-10"
    assert c["transcript_chars"] == 100


def test_register_session_dedup_por_data(tmp_m_base):
    slug = "joao-silva"
    store.register_session(
        slug,
        patient_name="João Silva",
        session_entry={"date": "2026-01-10", "transcript_chars": 100},
    )
    # Re-registrar a MESMA data não cria nova consulta; faz merge no C1.
    info = store.register_session(
        slug,
        patient_name="João Silva",
        session_entry={"date": "2026-01-10", "transcript_chars": 250, "note": "revisado"},
    )
    cons = info["consultations"]
    assert len(cons) == 1
    assert cons[0]["id"] == "C1"
    assert cons[0]["transcript_chars"] == 250
    assert cons[0]["note"] == "revisado"


def test_register_session_datas_distintas_sequenciais(tmp_m_base):
    slug = "joao-silva"
    store.register_session(slug, patient_name="João Silva", session_entry={"date": "2026-01-10"})
    info = store.register_session(slug, patient_name="João Silva", session_entry={"date": "2026-02-20"})
    ids = [c["id"] for c in info["consultations"]]
    assert ids == ["C1", "C2"]


def test_register_session_agrega_clinical_summary(tmp_m_base):
    slug = "joao-silva"
    store.register_session(
        slug,
        patient_name="João Silva",
        session_entry={"date": "2026-01-10", "processed_at": "2026-01-10T10:00:00+00:00"},
        clinical_metadata={
            "icd_codes": [{"code": "F41.1", "description": "TAG", "certainty": "provavel"}],
            "medications_mentioned": [{"name": "Sertralina", "dosage": "50mg"}],
            "topicos_principais": ["ansiedade"],
            "clinical_context": {"encounter_type": "retorno"},
        },
    )
    store.register_session(
        slug,
        patient_name="João Silva",
        session_entry={"date": "2026-02-20", "processed_at": "2026-02-20T10:00:00+00:00"},
        clinical_metadata={
            "icd_codes": [{"code": "F41.1", "description": "TAG"}],
            "topicos_principais": ["ansiedade", "sono"],
        },
    )
    cs = store.load_index(slug)["clinical_summary"]
    # F41.1 mencionado em duas sessões -> 2 ocorrências, um único registro.
    f411 = next(i for i in cs["all_icd_codes"] if i["code"] == "F41.1")
    assert f411["occurrences"] == 2
    # Tópicos agregados; "ansiedade" mais frequente.
    topics = {t["topic"]: t["frequency"] for t in cs["common_topics"]}
    assert topics["ansiedade"] == 2
    assert topics["sono"] == 1
    # Medicação registrada.
    assert any(m["name"] == "Sertralina" for m in cs["all_medications"])
    # Tipo de encontro registrado.
    assert any(e["type"] == "retorno" for e in cs["encounter_types"])


# ---------------------------------------------------------------------------
# load_info — visão mesclada (profile + index)
# ---------------------------------------------------------------------------


def test_load_info_visao_mesclada(tmp_m_base):
    slug = "joao-silva"
    store.register_session(
        slug,
        patient_name="João Silva",
        session_entry={"date": "2026-01-10"},
    )
    info = store.load_info(slug)
    assert info["patient_id"] == slug
    assert info["patient_name"] == "João Silva"
    assert isinstance(info["consultations"], list) and len(info["consultations"]) == 1
    assert info["consultations"][0]["id"] == "C1"
    # alias legado preservado.
    assert info["sessions"] == info["consultations"]


def test_load_info_vazio_para_slug_inexistente(tmp_m_base):
    assert store.load_info("nao-existe") == {}


def test_list_patients(tmp_m_base):
    store.register_session("joao-silva", patient_name="João Silva", session_entry={"date": "2026-01-10"})
    store.register_session("maria-souza", patient_name="Maria Souza", session_entry={"date": "2026-01-11"})
    store.register_session("maria-souza", patient_name="Maria Souza", session_entry={"date": "2026-02-11"})

    listing = store.list_patients()
    by_slug = {p["slug"]: p for p in listing}
    assert by_slug["joao-silva"]["display_name"] == "João Silva"
    assert by_slug["joao-silva"]["consultation_count"] == 1
    assert by_slug["maria-souza"]["consultation_count"] == 2
