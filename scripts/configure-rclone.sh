#!/usr/bin/env bash
# Write /root/.config/rclone/rclone.conf from BACKUP_R2_* vars in backup.env.
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/quant/backup.env}"
RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

for v in BACKUP_R2_ACCOUNT_ID BACKUP_R2_ACCESS_KEY_ID BACKUP_R2_SECRET_ACCESS_KEY; do
  if [[ -z "${!v:-}" ]]; then
    echo "Set $v in $ENV_FILE first." >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$RCLONE_CONF")"
chmod 700 "$(dirname "$RCLONE_CONF")"
cat >"$RCLONE_CONF" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${BACKUP_R2_ACCESS_KEY_ID}
secret_access_key = ${BACKUP_R2_SECRET_ACCESS_KEY}
endpoint = https://${BACKUP_R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
chmod 600 "$RCLONE_CONF"
echo "Wrote $RCLONE_CONF"
rclone lsd r2: 2>/dev/null || rclone lsd r2:quant-backups 2>/dev/null || echo "Test with: rclone lsd r2:quant-backups"
