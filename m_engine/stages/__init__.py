"""
Stages do pipeline M-Engine.

TOPOLOGIA — DOIS RAMOS PARALELOS a partir do transcribe (birp é FOLHA, não passo do ramo B):

  transcribe.run_file(audio_path, *, diarize=True, force=False) -> Path
    │
    ├─ Ramo A (nota clínica imediata):
    │     birp.run(transcription_json_path, *, model=None, force=False) -> Path   # só a transcrição; dono do info.json
    │
    └─ Ramo B (análise profunda ℳ):
          normalize.run(transcription_json_path, *, model=None, force=False) -> Path   # cria/atualiza dossiê
          asl.run(patient_id, date, *, model=None, force=False) -> Path
          dimensional.run(patient_id, date, *, model=None, force=False) -> Path
          gem.run(patient_id, date, *, model=None, force=False) -> Path
          soap_trajetorial.run(patient_id, date, *, model=None, force=False) -> Path
          soap_longitudinal.run(patient_id, dates: list[str], *, model=None, force=False) -> Path

  narrative.run(patient_id, date, *, model=None, force=False) -> Path   # placeholder (não especificado)

Regras gerais:
  - `model` é alias de config.MODELS; None usa o default (Claude Opus 4.8).
  - Idempotência: se o output existe e force=False, retorna o caminho sem reprocessar.
  - Toda chamada a LLM passa por m_engine.providers.llm (complete / complete_json).
  - Paths de artefatos vêm SEMPRE de m_engine.store (naming unificado).
"""
