# Test restore — quant-backup from Cloudflare R2

## 1. List and download

```bash
rclone ls r2:quant-backups/daily/2026-06-27/
mkdir -p /tmp/restore
rclone copy r2:quant-backups/daily/2026-06-27/ /tmp/restore/ --progress
```

## 2. Verify manifest

```bash
cd /tmp/restore
sha256sum -c manifest.sha256
cat manifest.json | jq .
```

## 3. Decrypt secrets (do NOT overwrite production until validated)

```bash
mkdir -p /tmp/restore-secrets
gpg --decrypt /tmp/restore/secrets.tar.gz.gpg | tar xzf - -C /tmp/restore-secrets/
ls -la /tmp/restore-secrets/
```

Passphrase is `BACKUP_GPG_PASSPHRASE` from `/etc/quant/backup.env`.

## 4. Restore and verify var/lib (SQLite)

```bash
mkdir -p /tmp/restore-varlib
tar xzf /tmp/restore/varlib.tar.gz -C /tmp/restore-varlib/

# Integrity check on critical gex DB
sqlite3 /tmp/restore-varlib/var/lib/gex-gamma/gex_gamma.db "PRAGMA integrity_check;"

# Online backup test (proves DB is readable)
sqlite3 /tmp/restore-varlib/var/lib/gex-gamma/gex_gamma.db ".backup '/tmp/gex-test.db'"
sqlite3 /tmp/gex-test.db "PRAGMA integrity_check;"
# Expected output: ok

# Repeat for other DBs if needed
for db in cot_positioning macro_rates vol_shield; do
  find /tmp/restore-varlib -name "${db}.db" -exec sqlite3 {} "PRAGMA integrity_check;" \;
done
```

## 5. Journal SQL (TradingJournal Supabase)

Preview dump:

```bash
zcat /tmp/restore/journal.sql.gz | head -50
```

Test restore into a local empty Postgres database:

```bash
createdb journal_restore_test
zcat /tmp/restore/journal.sql.gz | psql journal_restore_test
psql journal_restore_test -c "SELECT count(*) FROM tj_market_context;"
dropdb journal_restore_test
```

## 6. Production restore (destructive)

1. Stop writers: `systemctl stop gex-streamlit vol-shield-streamlit macro-streamlit cot-streamlit` (optional, reduces lock contention).
2. Backup current state locally before overwrite.
3. Replace `/var/lib/<repo>/` from extracted tar (preserve permissions: `chown -R root:root`).
4. Restore `.env` files from secrets tar only after verifying contents.
5. Restart services: `systemctl restart gex-streamlit vol-shield-streamlit macro-streamlit cot-streamlit`.
6. For **gex-gamma**: restore before any `gex-refresh` — historical option OI cannot be rebuilt.

## 7. R2 lifecycle (optional dashboard backup)

If `rclone delete` retention fails, configure in Cloudflare R2 bucket lifecycle:

- Prefix `daily/` — expire after 30 days
- Prefix `weekly/` — expire after 365 days

See `deploy/rclone.conf.example` and README for rclone remote setup.
