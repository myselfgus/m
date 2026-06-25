# API — contrato do m-engine

Contrato HTTP/WebSocket exposto por `m_engine/api.py` (FastAPI). É o **único seam** entre o **mapp** (frontend) e o **m-engine** (backend): o app consome só estes endpoints, nunca o sistema de arquivos.

- Base URL: `http://<ip-tailnet>:<porta>` (uvicorn ligado em `M_API_HOST`/`M_API_PORT`).
- `<slug>` é o identificador estável do paciente; `<cid>` é a pasta de consulta (`C1`, `C2`…); `<name>` é um documento Markdown (`*.md`).
- **Contrato estável do mapp** = endpoints consumidos hoje pelo `APIClient.swift` / `AssistantSession`. Marcados com ✅. Os demais existem na API mas o app ainda não chama.

Os campos abaixo refletem `api.py` exatamente como implementado.

---

## Jobs (orquestração do pipeline)

### `POST /jobs/{stage}` ✅
Enfileira um stage no Celery e devolve o `job_id`.
- **stage** (path): `pipeline` · `transcribe` · `birp` · `normalize` · `asl` · `dimensional` · `gem` · `soap_trajetorial` · `soap_longitudinal`.
- **Request** (`JobRequest`, JSON) — campos relevantes variam por stage:
  - `transcribe` → `audio_path` (obrig.); opcionais `diarize` (bool, default `true`), `force` (bool).
  - `pipeline` → `audio_path` (obrig.); opcionais `diarize`, `deep` (bool, default `true`), `model` (str|null), `force`.
  - `normalize` → `transcription_json_path` (obrig.); opcionais `model`, `force`.
  - `asl` / `dimensional` / `gem` / `soap_trajetorial` → `patient_id` (slug) + `date` (obrig.); opcionais `model`, `force`.
  - `soap_longitudinal` → `patient_id` + `dates[]` (obrig.); opcionais `model`, `force`.
- **Response** (`JobResponse`): `{ job_id, stage, status }`.
- **Erros:** `404` stage desconhecido; `422` campo obrigatório ausente.

> O mapp usa este endpoint de duas formas: `startPipeline` → `POST /jobs/pipeline` (`{audio_path, deep, model?}`) e `enqueueStage` → `POST /jobs/{stage}` (`{patient_id, date, model?, force}`).

### `GET /jobs/{job_id}` ✅
Status/resultado de um job via Celery `AsyncResult`.
- **Response** (`JobStatus`): `{ job_id, status, ready, successful?, result?, error? }` — em sucesso `result` é o path do artefato; em falha `error` é a mensagem.

---

## Áudio

### `POST /audio` ✅
Upload de áudio para `$M_BASE/audio` (entrada do STT). Não dispara processamento — a UI chama depois `POST /jobs/pipeline` com o path.
- **Request:** `multipart/form-data`, campo `file`. Extensões aceitas: `.m4a .mp3 .wav .aac .flac .ogg .webm .mp4 .mov`.
- **Response** (`UploadResponse`): `{ filename, path }` (path absoluto salvo).
- **Erros:** `422` nome ausente, extensão não suportada, ou arquivo vazio.

---

## Pacientes — leitura/edição

### `GET /patients` ✅
Lista dossiês em `pat/` com identidade resumida.
- **Response** (`PatientsResponse`): `{ patients: [{ slug, display_name, consultation_count }] }`.

### `GET /patients/{slug}/profile` ✅
Retorna o `profile.json` (identidade editável).
- **Response:** objeto livre do `profile.json` (`display_name`, `full_name`, `cpf`, `phone`, `birthdate`, `age`, `email`, `notes`, `professional`, `slug`, `updated_at`…).
- **Erros:** `404` profile ausente; `400` slug inválido.

### `PUT /patients/{slug}/profile` ✅
Merge dos campos editáveis no `profile.json`. O `slug` nunca é alterado (removido do body por segurança).
- **Request** (`ProfileUpdate`, JSON, campos opcionais): `display_name`, `full_name`, `cpf`, `phone`, `birthdate`, `age`, `email`, `notes`, `professional`.
- **Response:** o `profile.json` atualizado.
- **Erros:** `404` profile ausente.

### `GET /patients/{slug}/consultations` ✅
Lista as consultas do `index.json`, com os documentos `.md` de cada pasta `C{n}/`.
- **Response** (`ConsultationsResponse`): `{ slug, consultations: [{ id, date, source, tags, processed_at, documents[] }] }` — `documents` são os nomes dos `*.md` da pasta.
- **Erros:** `404` paciente não encontrado.

### `GET /patients/{slug}/info`
Visão mesclada (profile + index) do paciente. Endpoint de compatibilidade.
- **Response:** objeto com `patient_id`, `patient_name`, `consultations[]`, `sessions[]` (alias), `clinical_summary`. *(O mapp tem `patientInfo(...)` para isso, mas o fluxo principal usa `/profile` + `/consultations`.)*
- **Erros:** `404` dossiê ausente.

---

## Documentos de consulta (Markdown)

### `GET /patients/{slug}/consultations/{cid}/documents/{name}` ✅
Conteúdo Markdown de um documento (`text/plain`).
- **Response:** corpo do `.md` como texto puro.
- **Erros:** `400` slug/cid inválido ou não-`.md`; `404` documento não encontrado.

### `PUT /patients/{slug}/consultations/{cid}/documents/{name}` ✅
Sobrescreve um documento Markdown existente. Só grava em `C{n}/*.md`.
- **Request:** corpo `text/plain` (o conteúdo do `.md`). *(O `APIClient.saveDocument` envia `{content}` JSON; o parâmetro do servidor é `Body(media_type="text/plain")`.)*
- **Response** (`DocumentWriteResult`): `{ ok, bytes }`.
- **Erros:** `400` caminho inválido; `404` consulta não encontrada.

### `POST /patients/{slug}/consultations/{cid}/documents` ✅
Cria um **novo** documento Markdown na consulta.
- **Request** (`DocumentCreate`, JSON): `{ name (obrig.), content (default "") }` — sufixo `.md` é forçado se ausente.
- **Response** (`DocumentCreateResult`): `{ ok, name }` (nome final gravado).
- **Erros:** `400` slug/cid/nome inválido; `404` consulta não encontrada.

### `DELETE /patients/{slug}/consultations/{cid}/documents/{name}` ✅
Soft-delete do documento → move `.md` para `_trash/` (nunca `rm`).
- **Request:** body JSON opcional `{ stamp? }`.
- **Response:** `{ ok: true }`.
- **Erros:** `400` caminho inválido; `404` documento não encontrado.

---

## Pacientes / consultas — criação e exclusão

### `POST /patients` ✅
Cria um dossiê novo a partir do nome completo; gera o slug.
- **Request** (`PatientCreate`, JSON): `{ full_name (obrig.), cpf?, phone?, age?, email?, notes? }`.
- **Response:** o `profile.json` resultante.

### `POST /patients/{slug}/consultations` ✅
Reserva uma consulta para a data informada (default = hoje), criando a pasta `C{n}`.
- **Request** (`ConsultationCreate`, JSON): `{ date? }` (default = hoje).
- **Response** (`ConsultationCreateResult`): `{ id, date }`.
- **Erros:** `404` paciente não encontrado.

### `POST /patients/{slug}/consultations/{cid}/files` ✅
Sobe um arquivo de qualquer tipo para `pat/<slug>/<cid>/`.
- **Request:** `multipart/form-data`, campo `file`.
- **Response** (`UploadResponse`): `{ filename, path }`.
- **Erros:** `400` cid/caminho inválido; `404` consulta não encontrada; `422` nome/arquivo inválido ou vazio.

### `DELETE /patients/{slug}` ✅
Soft-delete do paciente → move `pat/<slug>` para `_trash/` (nunca `rm`).
- **Request:** body JSON opcional `{ stamp? }`.
- **Response:** `{ ok: true, trashed: <path> }`.
- **Erros:** `404` paciente não encontrado.

### `DELETE /patients/{slug}/consultations/{cid}` ✅
Soft-delete da consulta → move `C{n}` para `_trash/` e remove a entrada do `index.json`.
- **Request:** body JSON opcional `{ stamp? }`.
- **Response:** `{ ok: true }`.
- **Erros:** `400` cid inválido; `404` consulta não encontrada.

---

## Stages (catálogo para a UI)

### `GET /stages` ✅
Lista os stages disponíveis (chave técnica + rótulo PT-BR). O disparo continua via `POST /jobs/{stage}`.
- **Response:** `{ stages: [{ key, label }] }` — ex.: `{transcribe, "Transcrição"}`, `{asl, "Análise Sistêmica Linguística (ASL)"}`, `{pipeline, "Pipeline completo"}`.

---

## Profissional (global ao app)

### `GET /professional` ✅
Perfil do profissional ativo (assinatura, identificação, grounding da normalização). Vazio (`{}`) se não definido.
- **Response:** `{ name?, specialty?, credential?, registration?, clinic?, signature?, notes? }`.

### `PUT /professional` ✅
Salva/atualiza o perfil do profissional (merge dos campos não-nulos).
- **Request** (`ProfessionalUpdate`, JSON, opcionais): `name`, `specialty`, `credential` (CRM/RQE), `registration` (alias legado), `clinic`, `signature`, `notes`.
- **Response:** o perfil atualizado.

---

## Assistente (chat agêntico, persistente)

Conversa GERAL e persistente (Claude Sonnet 4.6 via Anthropic API); transcript em `M_BASE/assistant/general.json`.

### `GET /assistant/history` ✅
Histórico persistido da conversa (replay alternativo ao WS).
- **Response:** `{ messages: [...] }`.

### `WS /assistant/ws` ✅
Ponte WebSocket ↔ conversa geral. URL derivada da base (`http→ws`, `https→wss`).
- **Cliente → servidor:** `{ "type": "user", "text": "..." }`.
- **Servidor → cliente (frames):** `{type:"history", role, text}` (replay) · `{type:"ready"}` · `{type:"assistant", text}` (delta) · `{type:"tool", name, summary}` · `{type:"result"}` · `{type:"error", message}`.

---

## Saúde

### `GET /healthz` ✅
Liveness simples + eco da raiz de dados.
- **Response:** `{ status: "ok", m_base: <path> }`.

---

## Resumo do contrato estável (mapp)

| Recurso | Método · path |
| --- | --- |
| Saúde | `GET /healthz` |
| Upload de áudio | `POST /audio` |
| Pipeline | `POST /jobs/pipeline` |
| Stage individual | `POST /jobs/{stage}` |
| Status de job | `GET /jobs/{job_id}` |
| Catálogo de stages | `GET /stages` |
| Lista de pacientes | `GET /patients` |
| Criar paciente | `POST /patients` |
| Perfil (ler/editar) | `GET` · `PUT /patients/{slug}/profile` |
| Apagar paciente | `DELETE /patients/{slug}` |
| Consultas | `GET /patients/{slug}/consultations` |
| Criar consulta | `POST /patients/{slug}/consultations` |
| Apagar consulta | `DELETE /patients/{slug}/consultations/{cid}` |
| Subir arquivo na consulta | `POST /patients/{slug}/consultations/{cid}/files` |
| Documento (ler/gravar/criar/apagar) | `GET` · `PUT` · `POST` · `DELETE …/documents[/{name}]` |
| Profissional (ler/editar) | `GET` · `PUT /professional` |
| Assistente | `GET /assistant/history` · `WS /assistant/ws` |
