"""
M-Engine — CLI (Typer).

Substitui os menus readline interativos do legado por argumentos explícitos.
Entrypoint `m` (declarado em pyproject [project.scripts]).

Convenções:
  - `--model` é alias de config.MODELS; None (omitido) => default (Claude Opus 4.8).
  - `--force` reprocessa mesmo com artefato em cache.
  - `--diarize / --no-diarize` controla diarização da transcrição.
  - Imports dos stages são LAZY (dentro das funções) para não pagar custo/erro
    de import na inicialização do CLI.
  - Zero hardcode de path: tudo via m_engine.store / m_engine.config.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

import typer

from m_engine.config import get_settings

app = typer.Typer(
    name="m",
    help="M-Engine — pipeline clínico-linguístico (transcrição → ASL → dimensional → GEM → SOAP).",
    no_args_is_help=True,
    add_completion=False,
)

# Opções reutilizadas (declaradas no nível do módulo para consistência).
ModelOpt = typer.Option(
    None,
    "--model",
    "-m",
    help="Alias do modelo (config.MODELS). Omitido => default Claude Opus 4.8.",
)
ForceOpt = typer.Option(
    False,
    "--force",
    "-f",
    help="Reprocessa mesmo se o artefato já existir.",
)


def _echo_path(path: Path) -> None:
    """Imprime o caminho do artefato gerado (saída padrão da CLI)."""
    typer.echo(str(path))


@app.command()
def warm() -> None:
    """Pré-aquece o prompt cache dos system prompts grandes (asl/dimensional/gem/birp)."""
    from m_engine.prewarm import warm_all  # import lazy

    writes = warm_all()
    typer.echo(f"cache pré-aquecido: {writes} escrita(s)")


# ---------------------------------------------------------------------------
# Stage 0 — Transcrição
# ---------------------------------------------------------------------------
@app.command()
def transcribe(
    audio: Optional[Path] = typer.Argument(
        None,
        help="Arquivo de áudio. Omitido => transcreve todos em $M_BASE/audio (run_all).",
    ),
    diarize: bool = typer.Option(True, "--diarize/--no-diarize", help="Diarização por falante."),
    force: bool = ForceOpt,
) -> None:
    """Transcreve um arquivo (ou todos os áudios da pasta) via ElevenLabs Scribe."""
    from m_engine.stages import transcribe as stage  # import lazy

    if audio is None:
        for out in stage.run_all(diarize=diarize, force=force):
            _echo_path(out)
    else:
        _echo_path(stage.run_file(audio, diarize=diarize, force=force))


# ---------------------------------------------------------------------------
# Stage 0.5 — BIRP (dispara logo após transcribe; consome só a transcrição;
# atualiza o info.json). Default Sonnet (resolvido no stage via STAGE_DEFAULTS).
# ---------------------------------------------------------------------------
@app.command()
def birp(
    transcription_json: Optional[Path] = typer.Argument(
        None,
        help="Path do *_transcription.json. Omitido => processa todos em $M_BASE/audio/transcriptions.",
    ),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
    patient_id: Optional[str] = typer.Option(
        None, "--patient-id", help="Força o dossiê de destino (ex.: PAT_CADO_01) — útil em imports."
    ),
    date: Optional[str] = typer.Option(
        None, "--date", help="Força a data da nota (YYYY-MM-DD) — útil em imports (data real da consulta)."
    ),
) -> None:
    """Roda o BIRP sobre uma transcrição (ou todas as transcrições) e atualiza o info.json."""
    from m_engine.stages import birp as stage  # import lazy

    if transcription_json is None:
        # Sem argumento: processa todos os *_transcription.json do diretório de transcrições.
        transcriptions_dir = get_settings().transcriptions_dir
        for tj in sorted(transcriptions_dir.glob("*_transcription.json")):
            _echo_path(stage.run(tj, model=model, force=force))
    else:
        _echo_path(stage.run(
            transcription_json, model=model, force=force,
            patient_id_override=patient_id, date_override=date,
        ))


# ---------------------------------------------------------------------------
# Ingestão a partir do áudio — DOIS RAMOS PARALELOS saindo do transcribe:
#   Ramo A (nota clínica imediata):  transcribe → birp            (folha)
#   Ramo B (análise profunda ℳ):     transcribe → normalize → asl → dim → gem → soap-t
# BIRP NÃO é passo do ramo B — é uma folha independente. Ambos consomem a MESMA
# transcrição. O birp roda primeiro só porque estabelece o dossiê/info.json que o
# ramo B reusa; a saída do birp não alimenta o normalize.
# ---------------------------------------------------------------------------
@app.command()
def ingest(
    audio: Path = typer.Argument(..., help="Arquivo de áudio a ingerir."),
    diarize: bool = typer.Option(True, "--diarize/--no-diarize", help="Diarização por falante."),
    deep: bool = typer.Option(True, "--deep/--no-deep", help="Ramo B completo (asl→dim→gem→soap) ou só normalize."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Ingere um áudio em dois ramos: A) transcribe→birp; B) transcribe→normalize→asl→dim→gem→soap-t."""
    from m_engine.stages import (  # import lazy
        asl, birp, dimensional, gem, normalize, soap_trajetorial, transcribe,
    )

    # transcribe (raiz comum dos dois ramos)
    transcription_json = transcribe.run_file(audio, diarize=diarize, force=force)
    _echo_path(transcription_json)

    # Ramo A — nota clínica imediata (folha); também estabelece dossiê + info.json.
    _echo_path(birp.run(transcription_json, model=model, force=force))

    # Ramo B — análise profunda (independente do ramo A).
    norm_path = normalize.run(transcription_json, model=model, force=force)
    _echo_path(norm_path)
    if deep:
        # Deriva patient_id/date do artefato do dossiê: pat/<PID>/transcriptions/<date>_transcription.json
        patient_id = norm_path.parent.parent.name
        date = norm_path.stem.replace("_transcription", "")
        _echo_path(asl.run(patient_id, date, model=model, force=force))
        _echo_path(dimensional.run(patient_id, date, model=model, force=force))
        _echo_path(gem.run(patient_id, date, model=model, force=force))
        _echo_path(soap_trajetorial.run(patient_id, date, model=model, force=force))


# ---------------------------------------------------------------------------
# Stage 1 — Normalização (cria/atualiza dossiê a partir da transcrição)
# ---------------------------------------------------------------------------
@app.command()
def normalize(
    transcription_json: Path = typer.Argument(..., help="Path do *_transcription.json."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Normaliza uma transcrição e cria/atualiza o dossiê do paciente."""
    from m_engine.stages import normalize as stage  # import lazy

    _echo_path(stage.run(transcription_json, model=model, force=force))


# ---------------------------------------------------------------------------
# Stage 2 — ASL (Análise Sistêmica Linguística)
# ---------------------------------------------------------------------------
@app.command()
def asl(
    patient_id: str = typer.Argument(..., help="PATIENT_ID (PAT_<INICIAIS>_<NN>)."),
    date: str = typer.Argument(..., help="Data da sessão (YYYY-MM-DD)."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Gera a Análise Sistêmica Linguística (ASL) da sessão."""
    from m_engine.stages import asl as stage  # import lazy

    _echo_path(stage.run(patient_id, date, model=model, force=force))


# ---------------------------------------------------------------------------
# Stage 3 — Dimensional (VDLP)
# ---------------------------------------------------------------------------
@app.command()
def dimensional(
    patient_id: str = typer.Argument(..., help="PATIENT_ID (PAT_<INICIAIS>_<NN>)."),
    date: str = typer.Argument(..., help="Data da sessão (YYYY-MM-DD)."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Extrai o perfil dimensional (VDLP) da sessão."""
    from m_engine.stages import dimensional as stage  # import lazy

    _echo_path(stage.run(patient_id, date, model=model, force=force))


# ---------------------------------------------------------------------------
# Stage 4 — GEM (Grafo do Espaço-Campo Mental)
# ---------------------------------------------------------------------------
@app.command()
def gem(
    patient_id: str = typer.Argument(..., help="PATIENT_ID (PAT_<INICIAIS>_<NN>)."),
    date: str = typer.Argument(..., help="Data da sessão (YYYY-MM-DD)."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Constrói o Grafo do Espaço-Campo Mental (GEM) da sessão."""
    from m_engine.stages import gem as stage  # import lazy

    _echo_path(stage.run(patient_id, date, model=model, force=force))


# ---------------------------------------------------------------------------
# Stage 5 — SOAP trajetorial (uma sessão)
# ---------------------------------------------------------------------------
@app.command()
def soap(
    patient_id: str = typer.Argument(..., help="PATIENT_ID (PAT_<INICIAIS>_<NN>)."),
    date: str = typer.Argument(..., help="Data da sessão (YYYY-MM-DD)."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Gera a nota SOAP trajetorial (uma sessão)."""
    from m_engine.stages import soap_trajetorial as stage  # import lazy

    _echo_path(stage.run(patient_id, date, model=model, force=force))


# ---------------------------------------------------------------------------
# Stage 6 — SOAP longitudinal (várias sessões)
# ---------------------------------------------------------------------------
@app.command(name="soap-long")
def soap_long(
    patient_id: str = typer.Argument(..., help="PATIENT_ID (PAT_<INICIAIS>_<NN>)."),
    dates: list[str] = typer.Argument(..., help="Datas das sessões (YYYY-MM-DD ...)."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Gera a nota SOAP longitudinal a partir de múltiplas sessões."""
    from m_engine.stages import soap_longitudinal as stage  # import lazy

    _echo_path(stage.run(patient_id, dates, model=model, force=force))


# ---------------------------------------------------------------------------
# Pipeline completo p/ uma sessão: asl → dimensional → gem → soap_trajetorial
# ---------------------------------------------------------------------------
@app.command()
def run(
    patient_id: str = typer.Argument(..., help="PATIENT_ID (PAT_<INICIAIS>_<NN>)."),
    date: str = typer.Argument(..., help="Data da sessão (YYYY-MM-DD)."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Roda o pipeline analítico completo de uma sessão (asl → dimensional → gem → soap)."""
    # Imports lazy: só carregamos os stages quando o comando é de fato chamado.
    from m_engine.stages import asl, dimensional, gem, soap_trajetorial

    typer.echo(asl.run(patient_id, date, model=model, force=force))
    typer.echo(dimensional.run(patient_id, date, model=model, force=force))
    typer.echo(gem.run(patient_id, date, model=model, force=force))
    typer.echo(soap_trajetorial.run(patient_id, date, model=model, force=force))


# ---------------------------------------------------------------------------
# run-all — todas as sessões de um paciente (uma data por execução do pipeline)
# ---------------------------------------------------------------------------
@app.command(name="run-all")
def run_all(
    patient_id: str = typer.Argument(..., help="PATIENT_ID (PAT_<INICIAIS>_<NN>)."),
    model: Optional[str] = ModelOpt,
    force: bool = ForceOpt,
) -> None:
    """Roda o pipeline analítico para TODAS as sessões transcritas do paciente."""
    from m_engine.stages import asl, dimensional, gem, soap_trajetorial
    from m_engine.store import pat_dir

    # Descobre as datas via diretório de transcrições do paciente (sem hardcode).
    transcriptions = pat_dir() / patient_id / "transcriptions"
    if not transcriptions.exists():
        typer.echo(f"Sem transcrições para {patient_id} em {transcriptions}", err=True)
        raise typer.Exit(code=1)

    # Nome de arquivo: <DATE>_transcription.json -> extrai DATE.
    dates = sorted(
        p.name.removesuffix("_transcription.json")
        for p in transcriptions.glob("*_transcription.json")
    )
    if not dates:
        typer.echo(f"Nenhuma transcrição encontrada em {transcriptions}", err=True)
        raise typer.Exit(code=1)

    for date in dates:
        typer.echo(f"== {patient_id} {date} ==")
        typer.echo(asl.run(patient_id, date, model=model, force=force))
        typer.echo(dimensional.run(patient_id, date, model=model, force=force))
        typer.echo(gem.run(patient_id, date, model=model, force=force))
        typer.echo(soap_trajetorial.run(patient_id, date, model=model, force=force))


if __name__ == "__main__":
    app()
