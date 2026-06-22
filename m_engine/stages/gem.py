"""
Stage `gem` — Grafo do Espaço-Campo Mental (GEM).

DECLARATIVO: o LLM constrói o grafo multidimensional do espaço mental a partir da
TRÍADE de inputs (transcrição + ASL + VDLP) e produz um JSON com 4 camadas:

  • .aje (Actions and Journey Events)      — eventos/ações da jornada
  • .ire (Intelligible Relational Entities) — clusters relacionais inteligíveis
  • .e   (Eulerian Flows)                    — fluxos eulerianos (DIAGNÓSTICO)
  • .epe (Emergenable Pathways)              — caminhos emergenáveis (PROGNÓSTICO/POTÊNCIA)

AUTO-CORREÇÃO DE JSON (pedido explícito do usuário): toda a robustez vem de
`providers.llm.complete_json`, que faz extract_json + validação pydantic + 1 rodada
de repair. O schema permissivo `schemas.gem.GEM` (extra="allow") garante que o GEM
herde esse comportamento, igual a ASL/dimensional.

CHUNKING: se a tríade combinada excede ~50k tokens, dividimos APENAS a transcrição
em chunks de ~30k (ASL/VDLP são resumos e vão íntegros em cada chunk). Os GEMs de
cada chunk são consolidados concatenando os arrays aje/ire/e/epe.

Modelo default = None → Claude Opus 4.8 (config.resolve_model). LLM só via providers.llm.
Idempotência: se o output existe e force=False, retorna o caminho sem reprocessar.
"""

from __future__ import annotations

import json
from pathlib import Path

import structlog

from m_engine.config import resolve_model
from m_engine.providers.llm import SystemBlock, complete_json
from m_engine.schemas.gem import GEM
from m_engine.store import (
    asl_path,
    dimensional_path,
    gem_path,
    read_json,
    transcription_path,
    write_json,
)
from m_engine.util import estimate_tokens, load_prompt, now_iso, split_into_chunks

log = structlog.get_logger("m_engine.gem")

# Limiares portados FIEL do legado (medscribe-gem.ts)
CHUNK_THRESHOLD_TOKENS = 50_000   # acima disso → chunking
CHUNK_SIZE_TOKENS = 30_000        # tamanho-alvo de cada chunk da transcrição

ANALYSIS_VERSION = "gem-v3-emergenabilidade"


# ---------------------------------------------------------------------------
# Montagem do user prompt (workflow de 5 stages + Required Output Structure)
# Portado FIEL da constante userPrompt do legado.
# ---------------------------------------------------------------------------

# Bloco "## Your Task" em diante — reaproveitado tanto no caso direto quanto por chunk.
_TASK_BLOCK = """## Your Task

Before generating the final JSON output, work through your analysis systematically in your thinking block. It's OK for this section to be quite long.

<stage1_analysis_aje>
Identifique eventos (.aje - Actions and Journey Events) da transcrição. Para cada um:
- Cite o texto literal.
- Forneça um resumo semântico (semantic_summary).
- **Mapeie as Propriedades Dimensionais**: Calcule as 12+ propriedades (emotional_intensity, cognitive_complexity, affective_valence, agency, etc.) com base nos dados da ASL e VDLP. Use os escores v₁-v₁₅ do VDLP como guia direto.
- Mapeie Vetores Relacionais (relational_vectors).
</stage1_analysis_aje>

<stage2_clustering_ire>
Agrupe os eventos (by event_id) em clusters (.ire - Intelligible Relational Entities / entidades-clusters relacionais inteligíveis). Para cada um:
- Calcule a 'semantic_centrality' e 'relational_density'.
- Identifique as 'emergent_properties', incluindo o 'hiTOP_spectrum'.
- **IRE deve revelar a emergenabilidade** - estes clusters são a matéria-prima para .epe
</stage2_clustering_ire>

<stage3_flows_e>
Identifique 'Fluxos Eulerianos' (.e - Eulerian Flows) que representam as principais "Trajetórias Terapêuticas" *passadas* - os caminhos naturais que emergem.
- Mapeie 'source_events' e 'target_clusters'.
- Calcule a 'causal_strength'.
- **Mapeie para as 15 Dimensões ℳ**: Preencha 'mapped_dimensions' com os valores v₁, v₅, v₉, etc., relevantes para este fluxo.
- Esta é a camada de **Diagnóstico** (o que emergiu).
</stage3_flows_e>

<stage4_emergenable_pathways>
**A PARTE MAIS CRUCIAL**: Identifique 'Caminhos Emergenáveis' (.epe - Emergenable Pathways).
- Estes *não* são o que aconteceu, mas o que *pode* acontecer (a 'Emergenabilidade').
- Identifique os 'clusters de atrito' (ex: C2_ESCALATION_LOSS) - a "matéria-prima" do sofrimento.
- Identifique os 'clusters de alavancagem' (ex: C9_INTERVENTION_HOPE) - os pontos de potência.
- Proponha trajetórias clínicas que descrevem como a energia do atrito pode ser canalizada para a alavancagem.
- Esta é a camada de **Prognóstico e Potência** (o que pode emergir).
</stage4_emergenable_pathways>

<stage5_integration>
Calcule os 'key_insights' (insights) e o 'validation_score' final.
</stage5_integration>

## Required Output Structure

Your final response must be valid JSON with exactly this structure:

{
  "gem": {
    "aje": [
      {
        "event_id": "string",
        "timestamp_audio": "int (seconds)",
        "speaker": "string",
        "literal_text": "string",
        "semantic_summary": "string",
        "dimensional_properties": {
          "emotional_intensity": "float [0-1]",
          "cognitive_complexity": "float [0-1]",
          "temporal_significance": "float [0-1]",
          "semantic_centrality": "float [0-1]",
          "relational_density": "float [0-1]",
          "novelty_score": "float [0-1]",
          "coherence": "float [0-1]",
          "affective_valence": "float [-1,1]",
          "arousal_level": "float [0-1]",
          "certainty": "float [0-1]",
          "agency": "float [0-1]",
          "abstraction_level": "float [0-1]"
        },
        "paralinguistic_context": {
          "dominant_emotion": "string",
          "emotion_distribution": "object"
        },
        "relational_vectors": [
          {
            "target_event_id": "string",
            "influence_magnitude": "float [0-1]",
            "temporal_lag": "int (seconds)",
            "directionality": "string",
            "causal_strength": "float [0-1]",
            "semantic_similarity": "float [0-1]"
          }
        ]
      }
    ],
    "ire": [
      {
        "cluster_id": "string",
        "events": ["array of event_ids"],
        "semantic_centrality": "float [0-1]",
        "relational_density": "float [0-1]",
        "novelty_score": "float [0-1]",
        "emergent_properties": {
          "coherence": "float [0-1]",
          "hiTOP_spectrum": "string"
        },
        "inter_cluster_edges": [
          {
            "source_cluster": "string",
            "target_cluster": "string",
            "causal_strength": "float [0-1]",
            "semantic_similarity": "float [0-1]"
          }
        ]
      }
    ],
    "e": [
      {
        "flow_id": "string",
        "description": "DIAGNÓSTICO: Descrição da trajetória passada.",
        "source_events": ["array"],
        "target_clusters": ["array"],
        "causal_strength": "float [0-1]",
        "directionality": "string",
        "emergent_properties": {
          "trajectory_coherence": "float [0-1]",
          "attractor_stability": "float [0-1]"
        },
        "mapped_dimensions": {
          "v1_valencia": "float",
          "v5_temporal_distribution": "string (ex: 0.6 passado, 0.3 presente, 0.1 futuro)",
          "v9_agencia": "float",
          "v7_social": "float",
          "narrative": "string (resumo narrativo do fluxo)"
        }
      }
    ],
    "epe": [
      {
        "pathway_id": "string (ex: EPE_1_AGENCY_RECLAMATION)",
        "description": "PROGNÓSTICO: Descrição da trajetória de transformação potencial (Emergenabilidade).",
        "source_friction_clusters": ["array de cluster_ids (o sofrimento, a matéria-prima)"],
        "leverage_clusters": ["array de cluster_ids (a potência, a alavanca)"],
        "key_leverage_events": ["array de event_ids (os momentos-chave de 'abertura')"],
        "required_conditions": "string (O que é necessário para este fluxo se atualizar, ex: 'Foco terapêutico na aliança', 'Uso da tecnologia como ponte vocacional')",
        "emergenable_potential_score": "float [0-1]"
      }
    ]
  },
  "statistics": {
    "total_distinct_events": "int",
    "event_categories": "object",
    "semantic_clusters": "int",
    "key_articulation_points": "int"
  },
  "cross_references": {
    "aje_to_ire_mappings": "object",
    "cluster_flow_relationships": "object"
  },
  "key_insights": [
    "string (clinical insight 1)",
    "string (clinical insight 2)",
    "string (clinical insight 3)",
    "string (clinical insight 4)",
    "string (clinical insight 5)"
  ],
  "validation_score": "float [0-1]"
}

## Important Notes

- Prioritize clinically or semantically significant nodes (major revelations, turning points, breakthrough moments, technical solutions, decision points)
- Integrate ASL emotional analysis and VDLP scores into your dimensional property calculations
- Adapt your semantic analysis to the actual domain and context of the conversation - don't force therapeutic interpretations on technical or other types of discussions
- Ensure your event extraction captures the real substance and flow of the conversation
- All coherence scores must meet the specified thresholds

**CRITICAL - OUTPUT FORMAT**:
- Return ONLY the JSON object
- Do NOT add explanations, comments or text after the JSON
- Do NOT use markdown code blocks
- Stop IMMEDIATELY after closing the JSON with }

Your final output should consist only of the JSON structure and should not duplicate or rehash any of the analysis work you performed in the thinking block."""


_FRAMEWORK_OVERVIEW = """## Framework Overview

**Espaço Mental ℳ:** Espaço vetorial de 15 dimensões (v₁-v₁₅) conforme definido no *system prompt*.

**GEM Structure:**
- **.aje (Actions and Journey Events):** eventos e ações da jornada
- **.ire (Intelligible Relational Entities):** entidades-clusters relacionais inteligíveis (clusters)
- **.e (Eulerian Flows):** fluxos eulerianos (O que emergiu - Diagnóstico)
- **.epe (Emergenable Pathways):** caminhos emergenáveis

**Validation Requirements:**
- Global coherence score >0.85
- .aje events coherence >0.8
- .ire clusters density >0.75
- .e flows causal strength >0.8
- Align with RDoC/HiTOP/WHODAS/Big Five/PERMA/Network Theory frameworks where applicable
"""


def _build_user_prompt(transcription: str, asl_json: str, vdlp_json: str) -> str:
    """User prompt para a tríade completa (caso sem chunking)."""
    return (
        "Aqui estão os dados para análise:\n\n"
        f"<transcription>\n{transcription}\n</transcription>\n\n"
        f"<asl_analysis>\n{asl_json}\n</asl_analysis>\n\n"
        f"<vdlp_scores>\n{vdlp_json}\n</vdlp_scores>\n\n"
        f"{_FRAMEWORK_OVERVIEW}\n"
        f"{_TASK_BLOCK}"
    )


def _build_chunk_user_prompt(
    chunk: str, asl_json: str, vdlp_json: str, idx: int, total: int
) -> str:
    """User prompt para um chunk específico da transcrição (mantém ASL/VDLP íntegros)."""
    return (
        f"Aqui estão os dados para análise (CHUNK {idx}/{total}):\n\n"
        f"<transcription>\n{chunk}\n</transcription>\n\n"
        f"<asl_analysis>\n{asl_json}\n</asl_analysis>\n\n"
        f"<vdlp_scores>\n{vdlp_json}\n</vdlp_scores>\n\n"
        "## Framework Overview\n\n"
        "**Espaço Mental ℳ:** Espaço vetorial de 15 dimensões (v₁-v₁₅) conforme definido no *system prompt*.\n\n"
        "**GEM Structure:**\n"
        "- **.aje (Actions and Journey Events):** Eventos e ações deste chunk da jornada\n"
        "- **.ire (Intelligible Relational Events):** Eventos relacionais deste chunk\n"
        "- **.e (Eulerian Flows):** Fluxos eulerianos deste chunk\n"
        "- **.epe (Emergenable Pathways):** Caminhos emergenáveis identificados neste chunk\n\n"
        f"IMPORTANTE: Este é o chunk {idx} de {total}. Analise este segmento específico da transcrição.\n\n"
        f"{_TASK_BLOCK}"
    )


# ---------------------------------------------------------------------------
# Consolidação de GEMs por chunk (concatena arrays das 4 camadas)
# ---------------------------------------------------------------------------


def _consolidate(chunk_gems: list[GEM]) -> GEM:
    """
    Consolida múltiplos GEMs (um por chunk) concatenando aje/ire/e/epe.
    Portado FIEL do legado: o primeiro chunk é a base; os demais só somam às
    listas das 4 camadas. statistics/cross_references/insights/score do 1º chunk.
    """
    base = chunk_gems[0]
    for chunk in chunk_gems[1:]:
        base.gem.aje.extend(chunk.gem.aje)
        base.gem.ire.extend(chunk.gem.ire)
        base.gem.e.extend(chunk.gem.e)
        base.gem.epe.extend(chunk.gem.epe)
    return base


# ---------------------------------------------------------------------------
# Entry point do stage (CONTRATO)
# ---------------------------------------------------------------------------


def run(patient_id: str, date: str, *, model: str | None = None, force: bool = False) -> Path:
    """
    Gera o GEM da sessão (patient_id, date) a partir da tríade e grava em store.gem_path.
    Retorna o Path do artefato.
    """
    out = gem_path(patient_id, date)

    # Idempotência: respeita force.
    if out.exists() and not force:
        log.info("skip_cached", patient_id=patient_id, date=date, out=str(out))
        return out

    # --- Carrega a tríade (transcrição + ASL + VDLP) ---
    tpath = transcription_path(patient_id, date)
    apath = asl_path(patient_id, date)
    vpath = dimensional_path(patient_id, date)
    for label, p in (("transcription", tpath), ("asl", apath), ("vdlp/dimensional", vpath)):
        if not p.exists():
            raise FileNotFoundError(f"Input '{label}' ausente para GEM: {p}")

    transcription_data = read_json(tpath)
    asl_data = read_json(apath)
    vdlp_data = read_json(vpath)

    # Transcrição canônica: campo `transcription_corrected` (normalize) com fallbacks do legado.
    transcription = (
        transcription_data.get("transcription_corrected")
        or transcription_data.get("transcricao")
        or transcription_data.get("content")
        or ""
    )

    asl_json = json.dumps(asl_data, ensure_ascii=False, indent=2)
    vdlp_json = json.dumps(vdlp_data, ensure_ascii=False, indent=2)

    # System prompt ÍNTEGRO (teoria do Espaço Mental ℳ + 4 camadas), com cache ativado.
    system = [SystemBlock(text=load_prompt("gem"), cache=True)]

    # Decide chunking pelo tamanho COMBINADO da tríade (igual ao legado).
    total_tokens = estimate_tokens(transcription + asl_json + vdlp_json)
    log.info(
        "gem_inputs",
        patient_id=patient_id,
        date=date,
        transcription_chars=len(transcription),
        estimated_tokens=total_tokens,
    )

    if total_tokens > CHUNK_THRESHOLD_TOKENS:
        # Divide APENAS a transcrição; ASL/VDLP vão íntegros em cada chunk.
        chunks = split_into_chunks(transcription, CHUNK_SIZE_TOKENS)
        log.info("gem_chunking", patient_id=patient_id, date=date, n_chunks=len(chunks))

        chunk_gems: list[GEM] = []
        for i, chunk in enumerate(chunks, start=1):
            user = _build_chunk_user_prompt(chunk, asl_json, vdlp_json, i, len(chunks))
            gem_obj = complete_json(
                schema=GEM,
                system=system,
                user=user,
                model=model,
                debug_name=f"gem_chunk_{i}",
            )
            chunk_gems.append(gem_obj)

        gem = _consolidate(chunk_gems)
    else:
        # Tríade pequena: uma chamada direta.
        user = _build_user_prompt(transcription, asl_json, vdlp_json)
        gem = complete_json(
            schema=GEM,
            system=system,
            user=user,
            model=model,
            debug_name="gem",
        )

    # --- Envelope: objeto GEM (formato legado) + proveniência mínima ---
    spec = resolve_model(model)
    payload = gem.model_dump()
    payload.update(
        {
            "patient_id": patient_id,
            "sources": {
                "transcription": str(tpath),
                "asl": str(apath),
                "vdlp": str(vpath),
            },
            "processed_at": now_iso(),
            "model": spec.label,
            "analysis_version": ANALYSIS_VERSION,
        }
    )
    write_json(out, payload)

    # Loga contagens das 4 camadas e validation_score.
    log.info(
        "gem_done",
        patient_id=patient_id,
        date=date,
        aje=len(gem.gem.aje),
        ire=len(gem.gem.ire),
        e=len(gem.gem.e),
        epe=len(gem.gem.epe),
        validation_score=gem.validation_score,
        out=str(out),
    )
    return out
