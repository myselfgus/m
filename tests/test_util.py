"""
Testes de m_engine.util — estimativa de tokens e chunking.

Offline e sem dependências externas.
"""

from __future__ import annotations

from m_engine import util


# ---------------------------------------------------------------------------
# estimate_tokens (ceil de len/CHARS_PER_TOKEN)
# ---------------------------------------------------------------------------


def test_estimate_tokens_vazio():
    assert util.estimate_tokens("") == 0


def test_estimate_tokens_arredonda_para_cima():
    # CHARS_PER_TOKEN == 4 -> 4 chars = 1 token; 5 chars = 2 (ceil).
    assert util.estimate_tokens("abcd") == 1
    assert util.estimate_tokens("abcde") == 2


def test_estimate_tokens_proporcional():
    texto = "x" * 400
    assert util.estimate_tokens(texto) == 100


# ---------------------------------------------------------------------------
# split_into_chunks
# ---------------------------------------------------------------------------


def test_split_texto_curto_retorna_unico_chunk():
    texto = "Um texto pequeno."
    assert util.split_into_chunks(texto, max_tokens_per_chunk=15000) == [texto]


def test_split_por_paragrafos():
    # max baixo força a separação; cada parágrafo cabe sozinho.
    p1 = "a" * 40
    p2 = "b" * 40
    texto = f"{p1}\n\n{p2}"
    # 40 chars ~ 10 tokens cada; max 12 tokens não comporta os dois juntos.
    chunks = util.split_into_chunks(texto, max_tokens_per_chunk=12)
    assert len(chunks) == 2
    assert chunks[0] == p1
    assert chunks[1] == p2


def test_split_paragrafo_grande_quebra_em_sentencas():
    # Um parágrafo único maior que o limite é dividido por sentenças.
    para = "Primeira frase. Segunda frase. Terceira frase."
    chunks = util.split_into_chunks(para, max_tokens_per_chunk=5)  # ~20 chars/chunk
    assert len(chunks) >= 2
    # Nenhum conteúdo é perdido e a ordem é preservada.
    juntado = " ".join(chunks)
    for frase in ("Primeira frase.", "Segunda frase.", "Terceira frase."):
        assert frase in juntado


def test_split_preserva_conteudo_total():
    texto = "\n\n".join(f"Paragrafo numero {i} com algum conteudo." for i in range(10))
    chunks = util.split_into_chunks(texto, max_tokens_per_chunk=20)
    # Cada parágrafo deve aparecer em algum chunk.
    todos = "\n".join(chunks)
    for i in range(10):
        assert f"Paragrafo numero {i}" in todos
