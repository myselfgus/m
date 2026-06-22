# M-Engine — imagem de runtime (API / worker / CLI)
# Base enxuta com Python 3.11 (requires-python >=3.11 no pyproject).
FROM python:3.11-slim

# Boas práticas: sem .pyc, stdout/stderr sem buffer (logs imediatos em containers).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Dependências de SO mínimas. ffmpeg é útil para o pré-processamento de áudio
# antes da transcrição (ElevenLabs). curl serve ao HEALTHCHECK.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

# Usuário dedicado não-root (PHI: nunca rodar como root).
RUN groupadd --system mengine \
    && useradd --system --gid mengine --create-home --home-dir /home/mengine mengine

WORKDIR /app

# Copia metadados primeiro para aproveitar cache de camadas.
COPY pyproject.toml README.md ./
COPY m_engine ./m_engine

# Instala o projeto a partir do pyproject (hatchling). Sem dependências de dev.
RUN pip install .

# Volume de dados clínicos (PHI). Montado em runtime; padrão de config.py = /var/lib/m-engine.
# O diretório é criado e entregue ao usuário não-root para permitir escrita.
ENV M_BASE=/var/lib/m-engine
RUN mkdir -p "${M_BASE}" && chown -R mengine:mengine "${M_BASE}" /app

USER mengine

EXPOSE 8000

# Healthcheck simples da API (sobrescrito/ignorado nos serviços worker).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${M_API_PORT:-8000}/health" || exit 1

# CMD configurável: por padrão sobe a API FastAPI via uvicorn.
# Para o worker, sobrescreva o comando no compose/systemd:
#   celery -A m_engine.tasks worker --loglevel=info
CMD ["sh", "-c", "uvicorn m_engine.api:app --host ${M_API_HOST:-0.0.0.0} --port ${M_API_PORT:-8000}"]
