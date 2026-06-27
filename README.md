# quant-backup

Daily backup of the quant VPS stack to **Cloudflare R2**:

- `/var/lib/{cot-positioning,macro-rates,vol-shield,gex-gamma}/` — SQLite (`.backup` copies) + snapshots
- Encrypted secrets bundle (`.env`, bridge + Caddy config)
- TradingJournal Supabase `pg_dump` (`tj_*` tables)

## Quick start (VPS)

```bash
git clone https://github.com/0xsickre/quant-backup.git /opt/quant-backup
sudo bash /opt/quant-backup/scripts/vps-setup.sh
sudo cp /opt/quant-backup/deploy/rclone.conf.example /root/.config/rclone/rclone.conf
# edit /etc/quant/backup.env and rclone.conf
sudo /opt/quant-backup/backup-daily.sh --dry-run
sudo systemctl start quant-backup.service
sudo systemctl enable --now quant-backup.timer
```

Schedule: **03:30 UTC** daily. Retention: daily 30 days, weekly (Sunday copy) 12 months.

Restore: [docs/RESTORE.md](docs/RESTORE.md)

## Layout on R2

```
quant-backups/
  daily/YYYY-MM-DD/
    varlib.tar.gz
    secrets.tar.gz.gpg
    journal.sql.gz
    manifest.json
    manifest.sha256
  weekly/YYYY-MM-DD/   # Sunday copies only
```

## Config

| File | Purpose |
|------|---------|
| `/etc/quant/backup.env` | Secrets and settings (from `deploy/env.example`) |
| `/root/.config/rclone/rclone.conf` | R2 credentials (never uploaded to R2) |

## Manual run

```bash
/opt/quant-backup/backup-daily.sh           # full backup + upload
/opt/quant-backup/backup-daily.sh --dry-run # local staging only
systemctl start quant-backup.service
journalctl -u quant-backup.service -n 50
```
