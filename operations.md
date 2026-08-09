# CArtei — Operations

Runbook for deploying and running CArtei. Runtime is **Podman + systemd** on
two VMs. All commands assume the deploy dir `/tank/cartei` (symlinked `~/cartei`).

## Architecture

| VM | systemd unit | Runs | Compose file |
|----|--------------|------|--------------|
| **DB VM** | `cartei-db.service` | PostgreSQL 16 | `docker-compose.db.yaml` |
| **App VM** | `cartei.service` | `migrate` container (Alembic), then `app` (Django + gunicorn) | `docker-compose.yaml` |

The `app` container depends on `migrate`: on every start, `migrate` runs the
`cartei_db` Alembic migrations to `head`, then `app` boots. App images come
from `docker.io/philippbtz/` (`cartei-web`, `cartei-db`); the DB VM uses stock
`docker.io/postgres:16`.

## Initial setup

Both scripts are idempotent and clone/update the repo into `/tank/cartei`.

**DB VM:**
```bash
curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/cartei_deployment/main/setup-db.sh | bash
nano /tank/cartei/.env          # POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
podman compose -f docker-compose.db.yaml pull
systemctl start cartei-db.service
```
Then **firewall port 5432 to the app VM's IP only** — the DB port is published on the host.

**App VM:**
```bash
curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/cartei_deployment/main/setup.sh | bash
nano /tank/cartei/.env          # fill every CHANGE_ME (incl. DATABASE_URL → DB VM)
podman compose pull
systemctl start cartei.service
```

Both `setup*.sh` also install and enable their systemd units: the update timer
on the app VM, the backup timer on the DB VM.

## Day-to-day

```bash
systemctl status cartei.service        # or cartei-db.service on the DB VM
bash ~/cartei/start.sh                  # pull images + start (app VM)
bash ~/cartei/stop.sh                   # stop
podman compose logs -f app             # app logs  (migrate logs: logs migrate)
podman compose -f docker-compose.db.yaml logs -f postgres   # DB VM
```

## Updates

App images are pulled and the service restarted **nightly at 03:00** via
`cartei-update.timer` (`pull` → `restart cartei.service`, which re-runs
migrations). Manual:
```bash
podman compose pull && systemctl restart cartei.service
```
The DB VM has no update timer — Postgres is pinned to `16`; update it
deliberately with `podman compose -f docker-compose.db.yaml pull && systemctl restart cartei-db.service`.

## DB migrations

Migrations live in the **`cartei_db`** repo and run automatically via the
`migrate` container on every app start/restart. To apply manually (e.g. during
development against a running DB):
```bash
cd cartei_db
DATABASE_URL=... uv run alembic upgrade head
```

## Backups

Runs on the **DB VM**. `cartei-backup.timer` fires `backup.sh` **daily at 03:30**
(`cartei-backup.service`, config loaded from `.env`). Each run:

```
pg_dump → gzip → age -r $AGE_RECIPIENT → /var/backup/cartei/<ts>.sql.gz.age → rclone → R2
```

- Encrypted with **age** (asymmetric): the DB VM holds only the *public* key, so a
  compromised server or R2 bucket cannot decrypt any backup. Only the offline
  private key can. Encryption is **mandatory** — if `AGE_RECIPIENT` is unset the
  backup aborts rather than writing plaintext.
- Local retention: `BACKUP_RETENTION_DAYS` (default 90). Remote retention: an R2
  **bucket lifecycle rule** (below) — the script does not prune R2.

Manual backup: `sudo /tank/cartei/backup.sh`

Self-check (age round-trip + prune logic, no DB/R2): `./test-backup.sh`

### One-time setup

**1. Encryption key** — generate the keypair **on your workstation, not the server**:
```bash
age-keygen -o cartei-backup-key.txt          # store this file in a password manager
```
Copy the `# public key: age1...` value into `AGE_RECIPIENT` in `/tank/cartei/.env`
on the DB VM. The private key file never touches the server.

**2. Cloudflare R2** — create a bucket (e.g. `cartei-backups`) and an R2 API token
(Object Read & Write), then configure the rclone remote on the DB VM:
```bash
RCLONE_CONFIG=/tank/cartei/rclone.conf rclone config
#  name: r2 | storage: s3 | provider: Cloudflare
#  access_key_id / secret_access_key: the R2 token
#  endpoint: https://<ACCOUNT_ID>.r2.cloudflarestorage.com | region: auto
chmod 600 /tank/cartei/rclone.conf
```
Set `R2_REMOTE=r2:cartei-backups` and `RCLONE_CONFIG=/tank/cartei/rclone.conf` in `.env`.

**3. Remote retention** — in the R2 dashboard add a lifecycle rule to expire objects
after N days (matches local retention; keeps R2 from growing forever).

Verify after the first run:
```bash
ls -lh /var/backup/cartei/
sudo journalctl -u cartei-backup.service --no-pager | tail
rclone ls r2:cartei-backups
```

### Restore

Fetch the dump (from R2 or local), then decrypt with the **offline private key** and
pipe into psql:
```bash
rclone copyto r2:cartei-backups/2026-08-09_033000.sql.gz.age ./restore.sql.gz.age   # or use a local file
age -d -i cartei-backup-key.txt restore.sql.gz.age | gunzip \
  | podman exec -i cartei_postgres_1 psql -U cartei cartei
```
