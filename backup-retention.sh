#!/usr/bin/env bash
# R2 retention: daily 30d, weekly 365d (rclone --min-age).
set -euo pipefail

BACKUP_RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:?BACKUP_RCLONE_REMOTE required}"
BACKUP_RETAIN_DAILY_DAYS="${BACKUP_RETAIN_DAILY_DAYS:-30}"
BACKUP_RETAIN_WEEKLY_DAYS="${BACKUP_RETAIN_WEEKLY_DAYS:-365}"
BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-/var/log/quant-backup}"
DATE="$(date -u +%Y-%m-%d)"
LOG_FILE="${BACKUP_LOG_DIR}/backup-${DATE}.log"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [retention] $*"
  echo "$msg"
  [[ -f "$LOG_FILE" ]] && echo "$msg" >>"$LOG_FILE"
}

command -v rclone >/dev/null || { log "Missing rclone"; exit 1; }

log "delete daily older than ${BACKUP_RETAIN_DAILY_DAYS}d under ${BACKUP_RCLONE_REMOTE}/daily/"
rclone delete "${BACKUP_RCLONE_REMOTE}/daily/" \
  --min-age "${BACKUP_RETAIN_DAILY_DAYS}d" \
  --rmdirs \
  --stats-one-line || log "WARN: daily retention returned non-zero"

log "delete weekly older than ${BACKUP_RETAIN_WEEKLY_DAYS}d under ${BACKUP_RCLONE_REMOTE}/weekly/"
rclone delete "${BACKUP_RCLONE_REMOTE}/weekly/" \
  --min-age "${BACKUP_RETAIN_WEEKLY_DAYS}d" \
  --rmdirs \
  --stats-one-line || log "WARN: weekly retention returned non-zero"

log "retention done"
