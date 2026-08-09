# CArtei — Operations

## Architecture

Two VMs:

| VM | Service | What it runs |
|----|---------|-------------|
| DB VM | `cartei-db.service` | PostgreSQL 16 (Podman, `docker-compose.db.yaml`) |
| App VM | `cartei.service` | DB migration + Django app (Podman, `docker-compose.yaml`) |

The app VM runs the `migrate` container first, then starts the `app` container. Both pull from `docker.io/philippbtz/`.

## Initial setup

**DB VM:**
```bash
curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/cartei_deployment/main/setup-db.sh | bash
nano /tank/cartei/.env   # fill in POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
podman compose -f docker-compose.db.yaml pull
systemctl start cartei-db.service
# Ensure port 5432 is firewalled to app VM IP only
```

**App VM:**
```bash
curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/cartei_deployment/main/setup.sh | bash
nano /tank/cartei/.env   # fill in all CHANGE_ME values (includes DATABASE_URL pointing to DB VM)
podman compose pull
systemctl start cartei.service
```

## Day-to-day

```bash
# Status
systemctl status cartei.service

# Start / stop
bash ~/cartei/start.sh
bash ~/cartei/stop.sh

# Logs
podman compose logs -f app
```

## Updates

Images are pulled and the service restarted automatically every night at **03:00** via `cartei-update.timer`.

Manual update:
```bash
podman compose pull && systemctl restart cartei.service
```

## Backups

Automatic daily pg_dump at **03:30** via `cartei-backup.timer`.

- Output: `/var/backup/cartei/YYYY-MM-DD.sql.gz`
- Retention: 90 days

Manual backup:
```bash
podman exec cartei_deployment-postgres-1 pg_dump -U cartei cartei \
  | gzip > /var/backup/cartei/$(date +%Y-%m-%d)-manual.sql.gz
```

Restore:
```bash
gunzip -c /var/backup/cartei/YYYY-MM-DD.sql.gz \
  | podman exec -i cartei_deployment-postgres-1 psql -U cartei cartei
```

## DB migrations (cartei_db)

Migrations run automatically on every deploy via the `migrate` container. To run manually (e.g. after a schema change in development):

```bash
cd cartei_db
uv run alembic upgrade head
```
