#!/usr/bin/env bash
# Dnevni backup quant VPS podataka -> Cloudflare R2.
# Idempotentno; tajne samo iz /etc/quant/backup.env
set -euo pipefail

# --- Env vars (required unless noted) ---
# BACKUP_RCLONE_REMOTE       r2:quant-backups
# BACKUP_GPG_PASSPHRASE      symmetric GPG passphrase for secrets bundle
# JOURNAL_DATABASE_URL       Supabase Postgres DSN for pg_dump
# BACKUP_TELEGRAM_BOT_TOKEN  optional — alert on failure
# BACKUP_TELEGRAM_CHAT_ID    optional
# BACKUP_RETAIN_DAILY_DAYS   default 30
# BACKUP_RETAIN_WEEKLY_DAYS  default 365
# BACKUP_TMP_DIR             optional staging dir
# BACKUP_LOG_DIR             optional log dir

ENV_FILE="${ENV_FILE:-/etc/quant/backup.env}"
LOCK_FILE="/var/lock/quant-backup.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$msg" >>"$LOG_FILE"
  fi
}

send_telegram() {
  local message="$1"
  local token="${BACKUP_TELEGRAM_BOT_TOKEN:-}"
  local chat_id="${BACKUP_TELEGRAM_CHAT_ID:-}"
  [[ -n "$token" && -n "$chat_id" ]] || return 0
  curl -sfS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${message}" \
    -d "disable_web_page_preview=true" >/dev/null 2>&1 || true
}

cleanup() {
  local code=$?
  if [[ -n "${STAGING_DIR:-}" && -d "${STAGING_DIR:-}" ]]; then
    rm -rf "$STAGING_DIR"
  fi
  if [[ $code -ne 0 ]]; then
    send_telegram "quant-backup FAILED (${DATE:-unknown}): exit ${code}. Check ${LOG_FILE:-journalctl -u quant-backup.service}"
  fi
  exit "$code"
}

on_err() {
  log "ERROR: command failed at line ${1}"
}
trap cleanup EXIT
trap 'on_err ${LINENO}' ERR

# --- Load config ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

BACKUP_RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:?BACKUP_RCLONE_REMOTE required}"
BACKUP_GPG_PASSPHRASE="${BACKUP_GPG_PASSPHRASE:?BACKUP_GPG_PASSPHRASE required}"
JOURNAL_DATABASE_URL="${JOURNAL_DATABASE_URL:?JOURNAL_DATABASE_URL required}"
BACKUP_RETAIN_DAILY_DAYS="${BACKUP_RETAIN_DAILY_DAYS:-30}"
BACKUP_RETAIN_WEEKLY_DAYS="${BACKUP_RETAIN_WEEKLY_DAYS:-365}"
BACKUP_LOG_DIR="${BACKUP_LOG_DIR:-/var/log/quant-backup}"

DATE="$(date -u +%Y-%m-%d)"
STAGING_DIR="${BACKUP_TMP_DIR:-/tmp/quant-backup-$$}"
mkdir -p "$BACKUP_LOG_DIR"
LOG_FILE="${BACKUP_LOG_DIR}/backup-${DATE}.log"

VARLIB_SOURCES=(
  cot-positioning
  macro-rates
  vol-shield
  gex-gamma
)

SECRET_FILES=(
  /root/quant/quant/.env
  /root/quant/macro-rates/.env
  /root/quant/vol-shield/.env
  /root/quant/gex-gamma/.env
  /etc/quant-bridge/bridge.env
  /etc/caddy/dashboard.env
)

JOURNAL_TABLES=(
  tj_bias_analyses
  tj_market_context
  tj_cot_legs
  tj_positions
)

# --- Preflight ---
for cmd in rclone gpg pg_dump sqlite3 tar gzip flock; do
  command -v "$cmd" >/dev/null || { log "Missing command: $cmd"; exit 1; }
done

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another backup is running (lock: $LOCK_FILE)"
  exit 1
fi

log "=== quant-backup start (date=${DATE}, dry_run=${DRY_RUN}) ==="
mkdir -p "$STAGING_DIR"

# --- Stage /var/lib with SQLite .backup copies ---
stage_varlib() {
  local repo dest src_db name
  for repo in "${VARLIB_SOURCES[@]}"; do
    src="/var/lib/${repo}"
    dest="${STAGING_DIR}/var/lib/${repo}"
    if [[ ! -d "$src" ]]; then
      log "WARN: skip missing $src"
      continue
    fi
    mkdir -p "$dest"
    # Non-DB files (snapshots, validation, etc.) — exclude live DB + wal/shm + junk
    rsync -a \
      --exclude='__pycache__/' \
      --exclude='.venv/' \
      --exclude='*.log' \
      --exclude='*-wal' \
      --exclude='*-shm' \
      --exclude='*.db-wal' \
      --exclude='*.db-shm' \
      --exclude='*.db' \
      "$src/" "$dest/"
    # Crash-consistent SQLite copies
    while IFS= read -r -d '' src_db; do
      name="$(basename "$src_db")"
      log "sqlite3 .backup: $src_db"
      sqlite3 "$src_db" ".backup '${dest}/${name}'"
    done < <(find "$src" -maxdepth 1 -name '*.db' -print0 2>/dev/null || true)
  done
}

build_varlib_tar() {
  local out="${STAGING_DIR}/varlib.tar.gz"
  tar -C "$STAGING_DIR" -czf "$out" \
    --exclude='__pycache__' \
    --exclude='.venv' \
    --exclude='*.log' \
    --exclude='*-wal' \
    --exclude='*-shm' \
    var/lib/
  log "varlib.tar.gz size=$(stat -c%s "$out") bytes exit=0"
  echo "$out"
}

build_secrets_gpg() {
  local out="${STAGING_DIR}/secrets.tar.gz.gpg"
  local -a existing=()
  local f
  for f in "${SECRET_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      existing+=("$f")
    else
      log "WARN: secret file missing, skipping: $f"
    fi
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    log "ERROR: no secret files found"
    exit 1
  fi
  tar -czf - "${existing[@]}" \
    | gpg --batch --yes --passphrase "$BACKUP_GPG_PASSPHRASE" -c -o "$out"
  log "secrets.tar.gz.gpg size=$(stat -c%s "$out") bytes exit=0"
  echo "$out"
}

build_journal_dump() {
  local out="${STAGING_DIR}/journal.sql.gz"
  local -a args=()
  local t
  for t in "${JOURNAL_TABLES[@]}"; do
    args+=(--table="$t")
  done
  pg_dump "$JOURNAL_DATABASE_URL" "${args[@]}" --no-owner --no-acl | gzip -9 >"$out"
  log "journal.sql.gz size=$(stat -c%s "$out") bytes exit=0"
  echo "$out"
}

build_manifest() {
  local out="${STAGING_DIR}/manifest.json"
  local host sha
  host="$(hostname -f 2>/dev/null || hostname)"
  {
    echo '{'
    echo "  \"date\": \"${DATE}\","
    echo "  \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"hostname\": \"${host}\","
    echo "  \"dry_run\": ${DRY_RUN},"
    echo '  "artifacts": {'
    local first=1
    for f in varlib.tar.gz secrets.tar.gz.gpg journal.sql.gz; do
      if [[ -f "${STAGING_DIR}/${f}" ]]; then
        sha="$(sha256sum "${STAGING_DIR}/${f}" | awk '{print $1}')"
        [[ $first -eq 1 ]] || echo ','
        first=0
        printf '    "%s": {"bytes": %s, "sha256": "%s"}' \
          "$f" "$(stat -c%s "${STAGING_DIR}/${f}")" "$sha"
      fi
    done
    echo ''
    echo '  }'
    echo '}'
  } >"$out"
  # checksum file for restore verification
  (cd "$STAGING_DIR" && sha256sum varlib.tar.gz secrets.tar.gz.gpg journal.sql.gz 2>/dev/null) >"${STAGING_DIR}/manifest.sha256" || true
  log "manifest.json size=$(stat -c%s "$out") bytes exit=0"
  echo "$out"
}

upload_to_r2() {
  local remote_daily="${BACKUP_RCLONE_REMOTE}/daily/${DATE}"
  log "rclone copy -> ${remote_daily}/"
  rclone copy "$STAGING_DIR/" "$remote_daily/" \
    --include 'varlib.tar.gz' \
    --include 'secrets.tar.gz.gpg' \
    --include 'journal.sql.gz' \
    --include 'manifest.json' \
    --include 'manifest.sha256' \
    --checksum --stats-one-line
  log "upload exit=0"
}

maybe_weekly_copy() {
  # UTC Sunday = 7
  if [[ "$(date -u +%u)" != "7" ]]; then
    return 0
  fi
  local src="${BACKUP_RCLONE_REMOTE}/daily/${DATE}"
  local dst="${BACKUP_RCLONE_REMOTE}/weekly/${DATE}"
  log "weekly copy: ${src} -> ${dst}"
  rclone copy "$src/" "$dst/" --checksum --stats-one-line
  log "weekly copy exit=0"
}

run_retention() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: skip retention"
    return 0
  fi
  BACKUP_RCLONE_REMOTE="$BACKUP_RCLONE_REMOTE" \
    BACKUP_RETAIN_DAILY_DAYS="$BACKUP_RETAIN_DAILY_DAYS" \
    BACKUP_RETAIN_WEEKLY_DAYS="$BACKUP_RETAIN_WEEKLY_DAYS" \
    BACKUP_LOG_DIR="$BACKUP_LOG_DIR" \
    "$SCRIPT_DIR/backup-retention.sh"
}

stage_varlib
build_varlib_tar >/dev/null
build_secrets_gpg >/dev/null
build_journal_dump >/dev/null
build_manifest >/dev/null

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: artifacts in $STAGING_DIR (no upload)"
  ls -la "$STAGING_DIR"
  # keep staging for inspection — disable cleanup
  trap - EXIT
  exit 0
fi

upload_to_r2
maybe_weekly_copy
run_retention

log "=== quant-backup OK (${DATE}) ==="
