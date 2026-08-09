#!/usr/bin/env bash
# CArtei database backup — dump, encrypt (age), upload to Cloudflare R2.
# Runs on the DB VM (pod0), invoked by cartei-backup.service. Manual run:
#   sudo /tank/cartei/backup.sh
# Config comes from the environment (cartei-backup.service loads it from .env).
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backup/cartei}"
PG_CONTAINER="${PG_CONTAINER:-cartei_postgres_1}"
POSTGRES_USER="${POSTGRES_USER:-cartei}"
POSTGRES_DB="${POSTGRES_DB:-cartei}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-90}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"   # age public key; required
R2_REMOTE="${R2_REMOTE:-}"           # rclone remote+bucket, e.g. r2:cartei-backups; empty = local only

info() { echo "[backup] $*"; }
warn() { echo "[backup] WARNING: $*" >&2; }
die()  { echo "[backup] ERROR: $*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || die "podman not found"
mkdir -p "$BACKUP_DIR"
stamp="$(date +%Y-%m-%d_%H%M%S)"

# ── dump + encrypt ────────────────────────────────────────────────────────────
# Encryption is mandatory: refuse to run rather than write a plaintext dump.
[ -n "$AGE_RECIPIENT" ] || die "AGE_RECIPIENT is not set — refusing to write an unencrypted backup."
command -v age >/dev/null 2>&1 || die "age not found (required for encryption)"

# set -o pipefail makes a pg_dump failure abort the whole pipe — without it a
# failed dump would still write a valid-looking (empty) gzip and "succeed".
# Write to .partial then atomic mv, so a crash never leaves a truncated backup.
out="$BACKUP_DIR/$stamp.sql.gz.age"
info "Dumping + encrypting → $out"
podman exec "$PG_CONTAINER" pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
    | gzip | age -r "$AGE_RECIPIENT" > "$out.partial"
mv "$out.partial" "$out"
info "Wrote $(du -h "$out" | cut -f1) $out"

# ── upload to R2 ──────────────────────────────────────────────────────────────
if [ -n "$R2_REMOTE" ]; then
    command -v rclone >/dev/null 2>&1 || die "rclone not found but R2_REMOTE is set"
    info "Uploading → $R2_REMOTE/$(basename "$out")"
    # --no-check-dest: filenames are unique timestamps, so never stat the remote
    # object first (that HeadObject would 403 a write-only token). One PutObject.
    rclone copyto --no-check-dest "$out" "$R2_REMOTE/$(basename "$out")"
    info "Uploaded."
else
    warn "R2_REMOTE unset — keeping local copy only."
fi

# ── prune local (R2 retention is a bucket lifecycle rule, see operations.md) ──
find "$BACKUP_DIR" -maxdepth 1 -name '*.sql.gz*' -mtime "+$RETENTION_DAYS" -delete
info "Pruned local backups older than $RETENTION_DAYS days."
