# M-Engine

Pipeline clínico-linguístico que transforma o áudio de uma sessão em artefatos
estruturados: **transcrição → normalização → ASL (análise sistêmica linguística)
→ análise dimensional → GEM → narrativa → documentos SOAP**.

O M-Engine fala **direto** com os providers de modelo (sem gateway intermediário):
Anthropic (default **Claude Opus 4.8**), xAI (Grok) e DeepSeek — estes dois últimos
apenas quando selecionados explicitamente. A transcrição usa ElevenLabs (Scribe).

Os dados de cada paciente (PHI — *Protected Health Information*) ficam em arquivos
sob `$M_BASE/pat`, em um volume dedicado.

---

## Arquitetura

### Stages do pipeline

Cada stage tem um contrato estável (ver `m_engine/stages/__init__.py`) e é
idempotente: se o artefato já existe e `force=False`, o caminho é retornado sem
reprocessar.

| Stage              | Entrada                         | Saída (em `$M_BASE/pat/<PID>/`)              |
|--------------------|---------------------------------|----------------------------------------------|
| `transcribe`       | arquivo de áudio                | `audio/transcriptions/*.json`                |
| `normalize`        | transcrição JSON                | cria/atualiza o dossiê + `transcriptions/`   |
| `asl`              | dossiê + data                   | `linguistic-analysis/<PID>_<DATE>_ASL.json`  |
| `dimensional`      | ASL                             | `dimensional-analysis/<PID>_<DATE>_DIMENSIONAL.json` |
| `gem`              | dimensional                     | `gem/<PID>_<DATE>_GEM.json`                  |
| `narrative`        | gem                             | `narrative/`                                 |
| `soap_trajetorial` | artefatos de uma data           | `clinical-documents/<PID>_SOAP_*.md`         |
| `soap_longitudinal`| artefatos de várias datas       | `clinical-documents/<PID>_SOAP_*.md`         |

Identidade do paciente: `PATIENT_ID = PAT_<INICIAIS>_<NN>` (sequencial),
gerado em `m_engine/store.py`.

### Componentes

- **CLI `m`** (Typer) — operação manual stage a stage.
- **API** (FastAPI) — `m_engine.api:app`, dispara/consulta jobs.
- **Worker** (Celery) — `m_engine.tasks`, executa stages longos fora do request.
- **Redis** — broker/result-backend do Celery.
- **`m_engine/config.py`** — ponto único de verdade: chaves de API, paths
  derivados de `M_BASE` e registro de modelos.
- **`m_engine/store.py`** — naming unificado dos artefatos e identidade do paciente.
- **`m_engine/providers/`** — `llm.py` (chamadas diretas + extração de JSON) e
  `transcription.py` (ElevenLabs).

```
áudio ──> transcribe ──> normalize ──> asl ──> dimensional ──> gem ──> narrative
                                                                  └──> soap_*
        (CLI `m` | API FastAPI | worker Celery)  ──>  $M_BASE/pat/<PID>/
```

---

## Instalação

Requer **Python 3.11+**.

```bash
git clone <repo> m-engine && cd m-engine

python3.11 -m venv .venv
source .venv/bin/activate

pip install .          # instala o pacote e o entrypoint `m`
# Para desenvolvimento, instale também as ferramentas de teste:
pip install pytest
```

O comando `m` fica disponível após a instalação (definido em `[project.scripts]`).

---

## Configuração (`.env`)

Copie o exemplo e preencha as chaves. O arquivo `.env` **não** vai para o git.

```bash
cp .env.example .env
```

| Variável             | Descrição                                                        |
|----------------------|------------------------------------------------------------------|
| `M_BASE`             | Raiz dos dados (dossiês em `$M_BASE/pat`, áudio em `$M_BASE/audio`). |
| `ANTHROPIC_API_KEY`  | Chave Anthropic (provider default).                              |
| `XAI_API_KEY`        | Chave xAI/Grok (opcional, só em seleção explícita).             |
| `DEEPSEEK_API_KEY`   | Chave DeepSeek (opcional, só em seleção explícita).             |
| `ELEVENLABS_API_KEY` | Chave de transcrição (Scribe).                                  |
| `REDIS_URL`          | Broker/result-backend do Celery.                               |
| `M_API_HOST`         | Host da API (default `0.0.0.0`).                                |
| `M_API_PORT`         | Porta da API (default `8000`).                                  |
| `M_DEFAULT_MODEL`    | Override opcional do modelo default. Aliases: `opus` (default), `sonnet`, `haiku`, `grok`, `deepseek`, `deepseekr`. |

O default de **todos** os stages é `opus` (Claude Opus 4.8). xAI e DeepSeek nunca
são default — só entram quando passados explicitamente via `--model`.

---

## Uso — CLI `m`

```bash
# 1) Transcrever um áudio (ElevenLabs, com diarização)
m transcribe /caminho/sessao.m4a

# 2) Normalizar a transcrição → cria/atualiza o dossiê do paciente
m normalize $M_BASE/audio/transcriptions/2026-06-22_transcription.json

# 3) Rodar stages individuais para um paciente/data
m asl          PAT_JS_01 2026-06-22
m dimensional  PAT_JS_01 2026-06-22
m gem          PAT_JS_01 2026-06-22
m narrative    PAT_JS_01 2026-06-22

# 4) Documentos SOAP
m soap PAT_JS_01 2026-06-22                       # trajetorial (uma data)
m soap PAT_JS_01 2026-06-01 2026-06-22 --long     # longitudinal (várias datas)

# Selecionar outro modelo (override do default Opus 4.8) e reprocessar:
m asl PAT_JS_01 2026-06-22 --model grok --force
```

> Os nomes exatos dos subcomandos seguem o `m_engine/cli.py`; o fluxo acima
> reflete o contrato dos stages.

---

## Execução via Docker / Compose

Os artefatos de deploy ficam em `deploy/`.

```bash
# Pré-requisitos: .env preenchido e um diretório de dados no host.
cp .env.example .env            # preencha as chaves
export M_BASE=/srv/m-engine/data   # volume de PHI (idealmente cifrado, ver abaixo)

docker compose -f deploy/docker-compose.yml up -d --build
```

Sobe três serviços: `redis`, `api` (uvicorn em `:8000`) e `worker` (Celery).
API e worker compartilham o **mesmo** volume `$M_BASE` montado em
`/var/lib/m-engine`, e ambos leem o `.env`.

Imagem isolada (base `python:3.11-slim`, usuário não-root): ver `deploy/Dockerfile`.
O `CMD` padrão sobe a API; o worker sobrescreve o comando com
`celery -A m_engine.tasks worker`.

---

## Execução via systemd (VM de produção)

Unidades em `deploy/systemd/`. Ambas usam usuário dedicado `mengine`,
`EnvironmentFile=/etc/m-engine.env`, `WorkingDirectory=/opt/m-engine` e
`Restart=always`.

```bash
# Usuário e diretório dedicados
sudo useradd --system --home /opt/m-engine --shell /usr/sbin/nologin mengine
sudo mkdir -p /opt/m-engine && sudo chown mengine:mengine /opt/m-engine

# venv + instalação
sudo -u mengine python3.11 -m venv /opt/m-engine/venv
sudo -u mengine /opt/m-engine/venv/bin/pip install /caminho/do/projeto

# Segredos: arquivo de ambiente com permissão restrita (0600), fora do git
sudo install -m 0600 -o mengine -g mengine .env /etc/m-engine.env

# Instalar e habilitar as unidades
sudo cp deploy/systemd/m-engine-api.service /etc/systemd/system/
sudo cp deploy/systemd/m-engine-worker.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now m-engine-api m-engine-worker
```

Logs: `journalctl -u m-engine-api -f` e `journalctl -u m-engine-worker -f`.

---

## Segurança e PHI

Os dados sob `$M_BASE/pat` são **PHI**. Trate o sistema como ambiente clínico.

- **Criptografia em repouso do volume.** O volume que contém `$M_BASE` deve ser
  cifrado no disco (ex.: LUKS/dm-crypt na VM, ou um volume gerenciado com
  *encryption at rest* habilitado). Backups do volume também devem ser cifrados.
- **Segredos só em env / secret manager.** Chaves de API nunca no código nem em
  imagem: vêm do `.env` (Docker) ou de `/etc/m-engine.env` (systemd, modo `0600`,
  dono `mengine`). Em produção, prefira um *secret manager* injetando o
  `EnvironmentFile`/variáveis em runtime. O `.env` está no `.gitignore` — não comitar.
- **Controle de acesso na API.** A API não deve ser exposta diretamente à internet:
  coloque-a atrás de um reverse proxy com TLS e autenticação, restrinja por rede/VPN,
  e limite a porta `8000` à rede interna. O Redis nunca deve ser exposto publicamente
  (no compose ele fica apenas na rede interna, sem porta publicada).
- **Privilégio mínimo.** Containers e serviços rodam como usuário não-root
  (`mengine`). As unidades systemd aplicam *hardening* (`ProtectSystem=strict`,
  `NoNewPrivileges`, `PrivateTmp`, `ReadWritePaths` restrito ao volume de dados,
  `UMask=0077`).
- **Retenção e anonimização.** Defina política de retenção dos dossiês e remova
  artefatos vencidos. O `PATIENT_ID` (`PAT_<INICIAIS>_<NN>`) já reduz exposição do
  nome nos nomes de arquivo; para uso secundário (pesquisa, métricas), exporte
  apenas dados anonimizados/agregados, sem identificadores diretos.
- **Logs e debug.** O `extract_json` pode gravar payloads malformados em
  `$M_BASE/_debug` para diagnóstico — esse diretório fica dentro do volume cifrado
  e deve ser limpo periodicamente, pois pode conter conteúdo clínico.
# m
