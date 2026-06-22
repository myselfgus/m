"""
Testes de m_engine.store — identidade do paciente e geração de ID.

Tudo offline: usa a fixture `tmp_m_base` para isolar M_BASE em tmp_path.
"""

from __future__ import annotations

from m_engine import store


# ---------------------------------------------------------------------------
# extract_initials
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
# normalize_name
# ---------------------------------------------------------------------------


def test_normalize_name_minusculas_e_espacos():
    assert store.normalize_name("  João   Silva  ") == "joao silva"


def test_normalize_name_remove_acentos():
    assert store.normalize_name("José Antônio") == "jose antonio"


def test_normalize_name_idempotente():
    once = store.normalize_name("Maria DA Silva")
    assert store.normalize_name(once) == once


# ---------------------------------------------------------------------------
# generate_patient_id (usa M_BASE -> tmp via fixture)
# ---------------------------------------------------------------------------


def test_generate_patient_id_primeiro(tmp_m_base):
    pid = store.generate_patient_id("João Silva")
    assert pid == "PAT_JS_01"


def test_generate_patient_id_sequencial(tmp_m_base):
    # Cria um dossiê já existente para o mesmo prefixo -> próximo deve ser _02.
    base = store.pat_dir()
    (base / "PAT_JS_01").mkdir()
    pid = store.generate_patient_id("João Silva")
    assert pid == "PAT_JS_02"


def test_generate_patient_id_prefixos_independentes(tmp_m_base):
    base = store.pat_dir()
    (base / "PAT_JS_01").mkdir()
    (base / "PAT_JS_02").mkdir()
    # Prefixo diferente reinicia a numeração.
    assert store.generate_patient_id("Maria Souza") == "PAT_MS_01"


def test_generate_patient_id_ignora_dirs_nao_numericos(tmp_m_base):
    base = store.pat_dir()
    (base / "PAT_JS_01").mkdir()
    (base / "PAT_JS_foo").mkdir()  # cauda não-numérica é ignorada
    assert store.generate_patient_id("João Silva") == "PAT_JS_02"


def test_pat_dir_criado_sob_tmp_m_base(tmp_m_base):
    d = store.pat_dir()
    assert d.exists() and d.is_dir()
    # Deve estar dentro do M_BASE temporário (M_BASE/pat).
    assert d == tmp_m_base / "pat"
