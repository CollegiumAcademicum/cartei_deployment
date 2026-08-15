#!/usr/bin/env bash
set -euo pipefail
systemctl start cartei-db.service

# Wait for Postgres to accept connections before the vision run (db.service
# returns before the DB is ready on a cold start).
for _ in $(seq 30); do
    podman exec cartei_postgres_1 pg_isready -q && break
    sleep 1
done

# Also run vision once now; its quadlet has Pull=newer so this updates the image too.
systemctl start cartei-vision.service
