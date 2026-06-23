#!/usr/bin/env bash
# M-Engine — backup do m-data (Block volume) para o Object Storage NATIVO da Magalu.
#
# Usa o mgc CLI (mgc object-storage objects sync) — nada de AWS; o bucket é da
# própria Magalu (br-se1). Sincroniza $M_BASE/pat e $M_BASE/audio (incremental:
# só envia o que é novo/alterado). Idempotente; pensado para cron.
#
# Pré-requisitos na VM:
#   - mgc CLI instalado e autenticado (API key headless). Ver deploy/magalu.md §6.
#   - Bucket já criado (ex.: mgc object-storage buckets create --bucket m-engine-backups --private).
#   - Variáveis (ou edite os defaults abaixo):
#       M_BASE   raiz do m-data            (default: /var/lib/m-data)
#       BUCKET   nome do bucket de destino (default: m-engine-backups)
#       MGC      caminho do binário mgc    (default: mgc no PATH)
#
# Uso:
#   M_BASE=/var/lib/m-data BUCKET=m-engine-backups deploy/backup.sh
#   (cron) 30 3 * * *  /opt/m-engine/deploy/backup.sh >> /var/log/m-backup.log 2>&1

set -euo pipefail

M_BASE="${M_BASE:-/var/lib/m-data}"
BUCKET="${BUCKET:-m-engine-backups}"
MGC="${MGC:-mgc}"

log() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*"; }

command -v "$MGC" >/dev/null 2>&1 || { log "ERRO: mgc não encontrado no PATH."; exit 1; }
[ -d "$M_BASE" ] || { log "ERRO: M_BASE inexistente: $M_BASE"; exit 1; }

log "início — M_BASE=$M_BASE → bucket '$BUCKET' (Magalu Object Storage)"

# Limpeza de artefatos de debug antigos (>30 dias) antes do sync.
[ -d "$M_BASE/_debug" ] && find "$M_BASE/_debug" -type f -mtime +30 -delete 2>/dev/null || true

# Sync aditivo (sem --delete): o bucket tem versionamento ligado, então mantém
# histórico de versões; arquivos removidos localmente não somem do backup.
sync_dir() {
  local sub="$1"
  [ -d "$M_BASE/$sub" ] || { log "pulando $sub/ (inexistente)"; return 0; }
  log "sync $sub/ …"
  "$MGC" object-storage objects sync --local "$M_BASE/$sub" --bucket "$BUCKET/$sub" --no-confirm
}

sync_dir pat      # dossiês clínicos (PHI) — crítico
sync_dir audio    # uploads + transcrições — blobs grandes

log "fim — ok"
