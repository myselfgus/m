"""
Stage `asl` — Análise Sistêmica Linguística (ASL).

Análise psicolinguística profunda da fala do PACIENTE em uma transcrição clínica,
em 8 domínios linguísticos (11 blocos de topo no JSON). Porta fiel da lógica do
legado `medscribe-asl.ts`, adaptada ao contrato do M-Engine:

  - Entrada: transcrição normalizada (store.transcription_path).
  - Prompt MASSIVO (system + schema completo) carregado de prompts/asl.md, enviado
    como dois SystemBlock cacheados (prompt caching da Anthropic).
  - Chunking: transcrições > 10k tokens são divididas (~15k tokens/chunk, em batches
    de 3) e as 11 categorias são CONSOLIDADAS manualmente (somas de contagens, médias
    de scores, concatenação de exemplos), replicando a lógica do legado.
  - Saída: envelope ASL gravado em store.asl_path.

Regras: default model None (Claude Opus 4.8); LLM somente via providers.llm;
nenhum path/LLM hardcoded; idempotência por `force`.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import structlog

from m_engine.providers.llm import SystemBlock, complete_json
from m_engine.schemas.asl import ASL_ANALYSIS_VERSION, ASLArtifact, LinguisticAnalysis
from m_engine.store import asl_path, read_json, transcription_path, write_json
from m_engine.util import estimate_tokens, load_prompt, now_iso, split_into_chunks

log = structlog.get_logger("m_engine.asl")

# Threshold de chunking e tamanho do chunk — idênticos ao legado.
CHUNK_THRESHOLD_TOKENS = 10_000
CHUNK_SIZE_TOKENS = 15_000
BATCH_SIZE = 3

# Chaves do texto da transcrição, na ordem de preferência (espelha o legado).
_TEXT_KEYS = ("transcription_corrected", "transcricao", "transcricao_normalizada", "text")


def prewarm_blocks() -> list[list[SystemBlock]]:
    """System prompt(s) deste stage para pré-aquecer o cache (mesma chave do run)."""
    system_text, schema_text, _ = _load_prompt_sections()
    return [[SystemBlock(text=system_text, cache=True), SystemBlock(text=schema_text, cache=True)]]


# ---------------------------------------------------------------------------
# Carregamento e fatiamento do prompt (system / schema / user)
# ---------------------------------------------------------------------------


def _load_prompt_sections() -> tuple[str, str, str]:
    """
    Lê prompts/asl.md e separa as três seções por marcadores `### asl:<sec>`.
    Retorna (system, schema, user_template).
    """
    raw = load_prompt("asl")
    sections: dict[str, str] = {}
    current: str | None = None
    buf: list[str] = []
    for line in raw.splitlines():
        marker = re.match(r"^###\s+asl:(system|schema|user)\s*$", line.strip())
        if marker:
            if current is not None:
                sections[current] = "\n".join(buf).strip()
            current = marker.group(1)
            buf = []
            continue
        if current is not None:
            buf.append(line)
    if current is not None:
        sections[current] = "\n".join(buf).strip()

    missing = {"system", "schema", "user"} - sections.keys()
    if missing:
        raise ValueError(f"Seções ausentes em prompts/asl.md: {sorted(missing)}")
    return sections["system"], sections["schema"], sections["user"]


# ---------------------------------------------------------------------------
# Leitura da transcrição e metadados
# ---------------------------------------------------------------------------


def _resolve_transcription_text(data: dict[str, Any]) -> str:
    """Resolve o texto do diálogo na transcrição normalizada (ordem do legado)."""
    for key in _TEXT_KEYS:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return ""


def _build_metadata(data: dict[str, Any], date: str, fallback_source: str) -> dict[str, Any]:
    """Extrai metadados da transcrição (espelha o objeto transcription_metadata do legado)."""
    meta = data.get("metadata") if isinstance(data.get("metadata"), dict) else {}
    sessao = meta.get("session")
    if sessao is None and isinstance(meta.get("_sessao"), dict):
        sessao = meta["_sessao"].get("numero")

    processed = data.get("processed_at")
    date_resolved = (
        meta.get("date")
        or data.get("date")
        or (processed.split("T")[0] if isinstance(processed, str) and "T" in processed else None)
        or date
    )
    return {
        "date": date_resolved,
        "session": sessao,
        "patient_name": meta.get("patient_name"),
        "source_file": data.get("arquivo_original") or data.get("source_file") or fallback_source,
    }


# ---------------------------------------------------------------------------
# Consolidação manual das 11 categorias (port direto do legado)
# ---------------------------------------------------------------------------


def _g(d: Any, *keys: str) -> Any:
    """Acesso aninhado tolerante: retorna None se qualquer nível faltar/não for dict."""
    cur = d
    for k in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def _add(base: dict, key: str, value: Any) -> None:
    """Soma numérica tolerante (trata None como 0)."""
    base[key] = (base.get(key) or 0) + (value or 0)


def _consolidate(chunks: list[dict[str, Any]]) -> dict[str, Any]:
    """
    Consolida as análises de múltiplos chunks numa única análise.
    Réplica fiel da lógica do legado: o primeiro chunk é a base; os demais somam
    contagens, fazem médias incrementais de scores e concatenam exemplos/turnos.
    Blocos globais (contexto_identificado, sintese_interpretativa) vêm do 1º chunk.
    """
    consolidated = chunks[0]

    for i in range(1, len(chunks)):
        chunk = chunks[i]

        # 1. contexto_identificado — global, mantém do primeiro chunk.

        # 2. metadata — somar contagens.
        bmeta, cmeta = consolidated.get("metadata"), chunk.get("metadata")
        if isinstance(bmeta, dict) and isinstance(cmeta, dict):
            _add(bmeta, "num_turnos_falante", cmeta.get("num_turnos_falante"))
            _add(bmeta, "total_palavras_falante", cmeta.get("total_palavras_falante"))
            _add(bmeta, "total_sentencas_falante", cmeta.get("total_sentencas_falante"))

        # 3. transcricao_filtrada — concatenar turnos e fala completa.
        bturnos = _g(consolidated, "transcricao_filtrada", "turnos_individuais")
        cturnos = _g(chunk, "transcricao_filtrada", "turnos_individuais")
        if isinstance(bturnos, list) and isinstance(cturnos, list):
            bturnos.extend(cturnos)
            bfala = consolidated["transcricao_filtrada"].get("fala_falante_completa") or ""
            cfala = chunk["transcricao_filtrada"].get("fala_falante_completa") or ""
            consolidated["transcricao_filtrada"]["fala_falante_completa"] = bfala + "\n\n" + cfala

        # 4. morfossintaxe (4 subcategorias).
        if isinstance(consolidated.get("morfossintaxe"), dict) and isinstance(chunk.get("morfossintaxe"), dict):
            # 4a. estrutura_sintatica — somar num_sentencas_total.
            be = _g(consolidated, "morfossintaxe", "estrutura_sintatica", "metricas_quantitativas")
            ce = _g(chunk, "morfossintaxe", "estrutura_sintatica", "metricas_quantitativas")
            if isinstance(be, dict) and isinstance(ce, dict):
                _add(be, "num_sentencas_total", ce.get("num_sentencas_total"))

            # 4b. classes_gramaticais — somar todas as contagens absolutas.
            bc = _g(consolidated, "morfossintaxe", "classes_gramaticais", "metricas_quantitativas", "contagens_absolutas")
            cc = _g(chunk, "morfossintaxe", "classes_gramaticais", "metricas_quantitativas", "contagens_absolutas")
            if isinstance(bc, dict) and isinstance(cc, dict):
                for key, val in cc.items():
                    _add(bc, key, val)

            # 4c. conjugacao_verbal — somar total_verbos.
            bcv = _g(consolidated, "morfossintaxe", "conjugacao_verbal", "metricas_quantitativas")
            ccv = _g(chunk, "morfossintaxe", "conjugacao_verbal", "metricas_quantitativas")
            if isinstance(bcv, dict) and isinstance(ccv, dict):
                _add(bcv, "total_verbos", ccv.get("total_verbos"))

            # 4d. marcadores_morfologicos — somar totais de pronomes por pessoa.
            bp = _g(consolidated, "morfossintaxe", "marcadores_morfologicos", "metricas_quantitativas", "pronomes_pessoais")
            cp = _g(chunk, "morfossintaxe", "marcadores_morfologicos", "metricas_quantitativas", "pronomes_pessoais")
            if isinstance(bp, dict) and isinstance(cp, dict):
                for pessoa in ("primeira_pessoa", "segunda_pessoa", "terceira_pessoa"):
                    if isinstance(bp.get(pessoa), dict) and isinstance(cp.get(pessoa), dict):
                        _add(bp[pessoa], "total", cp[pessoa].get("total"))

        # 5. semantica (4 subcategorias).
        if isinstance(consolidated.get("semantica"), dict) and isinstance(chunk.get("semantica"), dict):
            # 5a. diversidade_lexical — somar tokens/types.
            bd = _g(consolidated, "semantica", "diversidade_lexical", "metricas_quantitativas")
            cd = _g(chunk, "semantica", "diversidade_lexical", "metricas_quantitativas")
            if isinstance(bd, dict) and isinstance(cd, dict):
                _add(bd, "total_tokens", cd.get("total_tokens"))
                _add(bd, "total_types", cd.get("total_types"))

            # 5b. campos_semanticos — média incremental das densidades por campo.
            bcs = _g(consolidated, "semantica", "campos_semanticos", "metricas_quantitativas", "densidade_por_campo")
            ccs = _g(chunk, "semantica", "campos_semanticos", "metricas_quantitativas", "densidade_por_campo")
            if isinstance(bcs, dict) and isinstance(ccs, dict):
                for campo, val in ccs.items():
                    bcs[campo] = ((bcs.get(campo) or 0) * i + (val or 0)) / (i + 1)

            # 5c. polaridade_emocional — concatenar palavras positivas/negativas.
            bpol = _g(consolidated, "semantica", "polaridade_emocional", "metricas_quantitativas")
            cpol = _g(chunk, "semantica", "polaridade_emocional", "metricas_quantitativas")
            if isinstance(bpol, dict) and isinstance(cpol, dict):
                bpol["palavras_positivas"] = (bpol.get("palavras_positivas") or []) + (cpol.get("palavras_positivas") or [])
                bpol["palavras_negativas"] = (bpol.get("palavras_negativas") or []) + (cpol.get("palavras_negativas") or [])

            # 5d. densidade_conteudo — somar palavras conteúdo/função.
            bdc = _g(consolidated, "semantica", "densidade_conteudo", "metricas_quantitativas")
            cdc = _g(chunk, "semantica", "densidade_conteudo", "metricas_quantitativas")
            if isinstance(bdc, dict) and isinstance(cdc, dict):
                _add(bdc, "palavras_conteudo", cdc.get("palavras_conteudo"))
                _add(bdc, "palavras_funcao", cdc.get("palavras_funcao"))

        # 6. coerencia_coesao (2 subcategorias).
        if isinstance(consolidated.get("coerencia_coesao"), dict) and isinstance(chunk.get("coerencia_coesao"), dict):
            # 6a. coesao_gramatical — somar total_conectivos.
            bcg = _g(consolidated, "coerencia_coesao", "coesao_gramatical", "metricas_quantitativas")
            ccg = _g(chunk, "coerencia_coesao", "coesao_gramatical", "metricas_quantitativas")
            if isinstance(bcg, dict) and isinstance(ccg, dict):
                _add(bcg, "total_conectivos", ccg.get("total_conectivos"))

            # 6b. coerencia_textual — média incremental do score global.
            bct = _g(consolidated, "coerencia_coesao", "coerencia_textual", "metricas_quantitativas")
            cct = _g(chunk, "coerencia_coesao", "coerencia_textual", "metricas_quantitativas")
            if isinstance(bct, dict) and isinstance(cct, dict):
                base_score = bct.get("score_coerencia_global") or 0
                chunk_score = cct.get("score_coerencia_global") or 0
                bct["score_coerencia_global"] = (base_score * i + chunk_score) / (i + 1)

        # 7. pragmatica (2 subcategorias).
        if isinstance(consolidated.get("pragmatica"), dict) and isinstance(chunk.get("pragmatica"), dict):
            # 7a. atos_de_fala — somar contagens.
            ba = _g(consolidated, "pragmatica", "atos_de_fala", "metricas_quantitativas")
            ca = _g(chunk, "pragmatica", "atos_de_fala", "metricas_quantitativas")
            if isinstance(ba, dict) and isinstance(ca, dict):
                _add(ba, "assertivos", ca.get("assertivos"))
                _add(ba, "diretivos", ca.get("diretivos"))
                _add(ba, "expressivos", ca.get("expressivos"))
                _add(ba, "total", ca.get("total"))

            # 7b. modalizacao — somar counts de certeza/incerteza.
            bm = _g(consolidated, "pragmatica", "modalizacao", "metricas_quantitativas")
            cm = _g(chunk, "pragmatica", "modalizacao", "metricas_quantitativas")
            if isinstance(bm, dict) and isinstance(cm, dict):
                if isinstance(bm.get("marcadores_certeza"), dict) and isinstance(cm.get("marcadores_certeza"), dict):
                    _add(bm["marcadores_certeza"], "count", cm["marcadores_certeza"].get("count"))
                if isinstance(bm.get("marcadores_incerteza"), dict) and isinstance(cm.get("marcadores_incerteza"), dict):
                    _add(bm["marcadores_incerteza"], "count", cm["marcadores_incerteza"].get("count"))

        # 8. consistencia_temporal — somar distribuição passado/presente/futuro.
        bdist = _g(consolidated, "consistencia_temporal", "metricas_quantitativas", "distribuicao_temporal_referencias")
        cdist = _g(chunk, "consistencia_temporal", "metricas_quantitativas", "distribuicao_temporal_referencias")
        if isinstance(bdist, dict) and isinstance(cdist, dict):
            _add(bdist, "passado", cdist.get("passado"))
            _add(bdist, "presente", cdist.get("presente"))
            _add(bdist, "futuro", cdist.get("futuro"))

        # 9. fragmentacao_fluencia — somar disfluências.
        bfrag = _g(consolidated, "fragmentacao_fluencia", "metricas_quantitativas", "disfluencias")
        cfrag = _g(chunk, "fragmentacao_fluencia", "metricas_quantitativas", "disfluencias")
        if isinstance(bfrag, dict) and isinstance(cfrag, dict):
            _add(bfrag, "false_starts", cfrag.get("false_starts"))
            _add(bfrag, "repeticoes_hesitantes", cfrag.get("repeticoes_hesitantes"))
            _add(bfrag, "autocorrecoes", cfrag.get("autocorrecoes"))

        # 10. complexidade_densidade (2 subcategorias).
        if isinstance(consolidated.get("complexidade_densidade"), dict) and isinstance(chunk.get("complexidade_densidade"), dict):
            # 10a. complexidade_lexical — somar palavras_unicas.
            bcl = _g(consolidated, "complexidade_densidade", "complexidade_lexical", "metricas_quantitativas")
            ccl = _g(chunk, "complexidade_densidade", "complexidade_lexical", "metricas_quantitativas")
            if isinstance(bcl, dict) and isinstance(ccl, dict):
                _add(bcl, "palavras_unicas", ccl.get("palavras_unicas"))

            # 10b. densidade_informacional — somar proposicoes_estimadas.
            bdi = _g(consolidated, "complexidade_densidade", "densidade_informacional", "metricas_quantitativas")
            cdi = _g(chunk, "complexidade_densidade", "densidade_informacional", "metricas_quantitativas")
            if isinstance(bdi, dict) and isinstance(cdi, dict):
                _add(bdi, "proposicoes_estimadas", cdi.get("proposicoes_estimadas"))

        # 11. caracteristicas_prosodicas_textuais — somar marcadores de ênfase.
        bpros = _g(consolidated, "caracteristicas_prosodicas_textuais", "metricas_quantitativas", "marcadores_enfase")
        cpros = _g(chunk, "caracteristicas_prosodicas_textuais", "metricas_quantitativas", "marcadores_enfase")
        if isinstance(bpros, dict) and isinstance(cpros, dict):
            _add(bpros, "maiusculas", cpros.get("maiusculas"))
            _add(bpros, "exclamacoes", cpros.get("exclamacoes"))
            _add(bpros, "interrogacoes", cpros.get("interrogacoes"))

        # 12. sintese_interpretativa — global, mantém do primeiro chunk.

    return consolidated


# ---------------------------------------------------------------------------
# Chamada ao LLM (uma análise — texto inteiro ou um chunk)
# ---------------------------------------------------------------------------


def _analyze(
    *,
    system_blocks: list[SystemBlock],
    user_template: str,
    patient_id: str,
    transcription_text: str,
    model: str | None,
    debug_name: str,
) -> dict[str, Any]:
    """Roda uma análise linguística completa e devolve o dict do payload (permissivo)."""
    user = user_template.format(patient_id=patient_id, transcription_text=transcription_text)
    result: LinguisticAnalysis = complete_json(
        schema=LinguisticAnalysis,
        system=system_blocks,
        user=user,
        model=model,
        cache=True,
        debug_name=debug_name,
    )
    return result.model_dump()


# ---------------------------------------------------------------------------
# Ponto de entrada do stage (contrato: stages/__init__.py)
# ---------------------------------------------------------------------------


def run(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> Path:
    """
    Executa a ASL da fala do paciente para (patient_id, date) e grava o envelope em asl_path.
    Idempotente: se o output já existe e force=False, retorna o caminho sem reprocessar.
    """
    out = asl_path(patient_id, date)
    if out.exists() and not force:
        log.info("skip_cached", patient_id=patient_id, date=date, out=str(out))
        return out

    # 1. Lê a transcrição normalizada e resolve o diálogo completo.
    src = transcription_path(patient_id, date)
    data = read_json(src)
    text = _resolve_transcription_text(data)
    if not text:
        raise ValueError(f"Nenhum texto de transcrição encontrado em {src}")

    metadata = _build_metadata(data, date, src.name)

    # 2. Monta o system massivo: dois blocos cacheados (princípios + schema).
    system_text, schema_text, user_template = _load_prompt_sections()
    system_blocks = [
        SystemBlock(text=system_text, cache=True),
        SystemBlock(text=schema_text, cache=True),
    ]

    # 3. Decide entre análise direta ou por chunks.
    est_tokens = estimate_tokens(text)
    log.info("asl_tokens", patient_id=patient_id, date=date, tokens=est_tokens)

    if est_tokens > CHUNK_THRESHOLD_TOKENS:
        chunks = split_into_chunks(text, CHUNK_SIZE_TOKENS)
        log.info("asl_chunking", patient_id=patient_id, n_chunks=len(chunks))

        analyses: list[dict[str, Any]] = []
        # Processa em batches (mantido sequencial; o legado usava batch de 3 em paralelo).
        for start in range(0, len(chunks), BATCH_SIZE):
            for i in range(start, min(start + BATCH_SIZE, len(chunks))):
                # Marca o chunk para o modelo (paridade com o legado).
                chunk_text = f"[chunk {i + 1}/{len(chunks)}]\n{chunks[i]}"
                try:
                    analyses.append(
                        _analyze(
                            system_blocks=system_blocks,
                            user_template=user_template,
                            patient_id=patient_id,
                            transcription_text=chunk_text,
                            model=model,
                            debug_name=f"asl_{patient_id}_{date}_chunk{i + 1}",
                        )
                    )
                except Exception as err:  # noqa: BLE001 — chunk com erro é ignorado (como no legado)
                    log.warning("asl_chunk_failed", chunk=i + 1, error=str(err)[:300])

        if not analyses:
            raise RuntimeError(f"Todos os chunks falharam na ASL de {patient_id}/{date}")

        analysis = _consolidate(analyses) if len(analyses) > 1 else analyses[0]
    else:
        analysis = _analyze(
            system_blocks=system_blocks,
            user_template=user_template,
            patient_id=patient_id,
            transcription_text=text,
            model=model,
            debug_name=f"asl_{patient_id}_{date}",
        )

    # 4. Monta e valida o envelope, então grava.
    artifact = ASLArtifact(
        patient_id=patient_id,
        source_file=metadata.get("source_file") or src.name,
        transcription_metadata=metadata,
        linguistic_analysis=analysis,
        processed_at=now_iso(),
        model=model or "opus",
        analysis_version=ASL_ANALYSIS_VERSION,
    )
    write_json(out, artifact.model_dump())
    log.info(
        "asl_done",
        patient_id=patient_id,
        date=date,
        out=str(out),
        palavras=_g(analysis, "metadata", "total_palavras_falante"),
        turnos=_g(analysis, "metadata", "num_turnos_falante"),
    )
    return out
