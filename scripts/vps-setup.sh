#!/usr/bin/env bash
# Idempotent VPS setup for quant-backup (deps + systemd timer).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="/etc/quant/backup.env"
ENV_EXAMPLE="${REPO_ROOT}/deploy/env.example"

log() { echo "[vps-setup] $*"; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "Run as root: sudo $0"
  exit 1
fi

log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq rclone gnupg rsync curl ca-certificates lsb-release

# pg_dump must match Supabase Postgres 17.x
if ! command -v pg_dump >/dev/null || ! pg_dump --version | grep -q " 17\."; then
  log "Installing PostgreSQL 17 client (pgdg)..."
  install -d /usr/share/postgresql-common/pgdg
  curl -sfSLo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    >/etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq postgresql-client-17
fi

apt-get install -y -qq sqlite3

mkdir -p /etc/quant /var/log/quant-backup /var/lock
chmod 700 /etc/quant

if [[ ! -f "$ENV_FILE" ]]; then
  log "Creating $ENV_FILE from deploy/env.example..."
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "Edit $ENV_FILE — set BACKUP_GPG_PASSPHRASE, JOURNAL_DATABASE_URL, R2 via rclone."
else
  log "$ENV_FILE already exists — not overwriting."
fi

log "Installing scripts to ${REPO_ROOT}..."
chmod +x "${REPO_ROOT}/backup-daily.sh" "${REPO_ROOT}/backup-retention.sh" "${REPO_ROOT}/scripts/configure-rclone.sh"

log "Installing systemd units..."
cp "${REPO_ROOT}/deploy/systemd/"* /etc/systemd/system/
systemctl daemon-reload
systemctl enable quant-backup.timer

if [[ -f /root/.config/rclone/rclone.conf ]]; then
  log "rclone config found at /root/.config/rclone/rclone.conf"
elif grep -q '^BACKUP_R2_ACCESS_KEY_ID=' "$ENV_FILE" 2>/dev/null && \
     grep -v '^#' "$ENV_FILE" | grep -q 'BACKUP_R2_ACCESS_KEY_ID=.' ; then
  log "Generating rclone config from backup.env..."
  ENV_FILE="$ENV_FILE" "${REPO_ROOT}/scripts/configure-rclone.sh"
else
  log "No rclone config — set BACKUP_R2_* in $ENV_FILE and run scripts/configure-rclone.sh"
fi

echo ""
echo "=== quant-backup setup complete ==="
echo "  Config:  $ENV_FILE"
echo "  Logs:    /var/log/quant-backup/"
echo "  Timer:   quant-backup.timer (03:30 UTC daily)"
echo ""
echo "Next steps:"
echo "  1. Edit $ENV_FILE"
echo "  2. Configure rclone (see deploy/rclone.conf.example)"
echo "  3. Test:  ${REPO_ROOT}/backup-daily.sh --dry-run"
echo "  4. Run:   systemctl start quant-backup.service"
echo "  5. Enable timer: systemctl start quant-backup.timer"
systemctl list-timers quant-backup.timer --no-pager 2>/dev/null || true
