"""
Testes de m_engine.providers.llm.extract_json — extração determinística de JSON.

NÃO toca em rede nem instancia clientes de provider: os SDKs (anthropic/openai)
são importados de forma lazy dentro das funções de cliente, então importar o
módulo e chamar `extract_json` é puramente local (regex + json).

Casos cobertos: JSON limpo, cercado por ```json, com anotação entre parênteses,
e com trailing comma.
"""

from __future__ import annotations

import pytest

from m_engine.providers.llm import extract_json


def test_extract_json_limpo():
    resp = '{"nome": "João", "idade": 30}'
    assert extract_json(resp) == {"nome": "João", "idade": 30}


def test_extract_json_com_cerca_de_codigo():
    resp = '```json\n{"ok": true, "n": 2}\n```'
    assert extract_json(resp) == {"ok": True, "n": 2}


def test_extract_json_com_texto_ao_redor():
    # Texto antes/depois é ignorado; o objeto é localizado por depth-counting.
    resp = 'Aqui está o resultado:\n{"status": "ok"}\nFim.'
    assert extract_json(resp) == {"status": "ok"}


def test_extract_json_anotacao_entre_parenteses():
    # Auto-correção: remove a anotação "(...)" logo após uma string.
    resp = '{"diagnostico": "ansiedade" (provável), "score": 5}'
    assert extract_json(resp) == {"diagnostico": "ansiedade", "score": 5}


def test_extract_json_trailing_comma():
    # Auto-correção: remove vírgula sobrando antes de } ou ].
    resp = '{"itens": [1, 2, 3,], "fim": true,}'
    assert extract_json(resp) == {"itens": [1, 2, 3], "fim": True}


def test_extract_json_anotacao_e_trailing_comma_juntos():
    resp = '{"campo": "valor" (nota), "lista": [1, 2,],}'
    assert extract_json(resp) == {"campo": "valor", "lista": [1, 2]}


def test_extract_json_aninhado():
    resp = '{"a": {"b": {"c": 1}}, "d": [ {"e": 2} ]}'
    assert extract_json(resp) == {"a": {"b": {"c": 1}}, "d": [{"e": 2}]}


def test_extract_json_sem_objeto_levanta():
    with pytest.raises(ValueError):
        extract_json("nenhum json aqui")


def test_extract_json_irrecuperavel_grava_debug(tmp_m_base):
    # JSON irreparável -> grava o malformado em $M_BASE/_debug e levanta ValueError.
    resp = '{"chave": valor_sem_aspas_invalido}'
    with pytest.raises(ValueError):
        extract_json(resp, debug_name="teste")
    debug_file = tmp_m_base / "_debug" / "debug_teste.json"
    assert debug_file.exists()
