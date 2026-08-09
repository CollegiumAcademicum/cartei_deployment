#!/usr/bin/env bash
# Bootstrap script for the DB VM — run once on a fresh server.
# Can be executed before the repo exists:
#   curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/cartei_deployment/main/setup-db.sh | bash
set -euo pipefail

REPO_URL="https://github.com/CollegiumAcademicum/cartei_deployment.git"
SRV_DIR="/tank/cartei"
LINK_DIR="$HOME/cartei"
SERVICE_NAME="cartei-db"
SYSTEMD_DIR="/etc/systemd/system"

# ── helpers ────────────────────────────────────────────────────────────────
info() { echo "[setup-db] $*"; }
warn() { echo "[setup-db] WARNING: $*" >&2; }
die()  { echo "[setup-db] ERROR: $*" >&2; exit 1; }

# ── 1. prerequisites ────────────────────────────────────────────────────────
info "Checking prerequisites..."
command -v podman         >/dev/null 2>&1 || die "podman is not installed."
command -v podman-compose >/dev/null 2>&1 \
  || podman compose version >/dev/null 2>&1 \
  || die "podman-compose is not installed."
command -v git            >/dev/null 2>&1 || die "git is not installed."
command -v systemctl      >/dev/null 2>&1 || warn "systemctl not found — skipping service setup."
command -v age            >/dev/null 2>&1 || warn "age not installed — needed for encrypted backups (AGE_RECIPIENT)."
command -v rclone         >/dev/null 2>&1 || warn "rclone not installed — needed for R2 upload (R2_REMOTE)."

# ── 2. clone or update repo ─────────────────────────────────────────────────
if [ -d "$SRV_DIR/.git" ]; then
    info "Repo already exists at $SRV_DIR — pulling latest..."
    git -C "$SRV_DIR" pull
else
    info "Cloning repo to $SRV_DIR..."
    mkdir -p "$(dirname "$SRV_DIR")"
    git clone "$REPO_URL" "$SRV_DIR"
fi

if [ -L "$LINK_DIR" ]; then
    info "Symlink $LINK_DIR already exists — skipping."
elif [ -d "$LINK_DIR" ]; then
    warn "$LINK_DIR is a real directory. Remove it and re-run if needed."
else
    ln -s "$SRV_DIR" "$LINK_DIR"
    info "Created symlink: $LINK_DIR -> $SRV_DIR"
fi

cd "$SRV_DIR"

# ── 3. .env ──────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    cp .env.example .env
    info "Created .env from .env.example — fill in POSTGRES_* and DATABASE_URL before starting."
else
    info ".env already exists — skipping."
fi

# ── 4. data directories ───────────────────────────────────────────────────────
info "Ensuring data directories exist..."
mkdir -p data/postgres

# ── 5. systemd services ──────────────────────────────────────────────────────
if command -v systemctl >/dev/null 2>&1; then
    info "Installing systemd services..."
    cp "$SRV_DIR/$SERVICE_NAME.service"         "$SYSTEMD_DIR/$SERVICE_NAME.service"
    cp "$SRV_DIR/$SERVICE_NAME-update.service"  "$SYSTEMD_DIR/$SERVICE_NAME-update.service"
    cp "$SRV_DIR/cartei-backup.service"         "$SYSTEMD_DIR/cartei-backup.service"
    cp "$SRV_DIR/cartei-backup.timer"           "$SYSTEMD_DIR/cartei-backup.timer"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME.service"
    systemctl enable --now cartei-backup.timer
    info "Services enabled."
else
    warn "Skipped systemd setup — run manually if needed."
fi

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo "Setup complete. Next steps:"
echo ""
echo "  1. Edit .env — only POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD are needed:"
echo "       nano $SRV_DIR/.env"
echo ""
echo "  2. Pull image and start:"
echo "       cd $SRV_DIR && podman compose -f docker-compose.db.yaml pull && systemctl start $SERVICE_NAME.service"
echo ""
echo "  After that, the service auto-starts at every boot."
echo ""
echo "  NOTE: Ensure your firewall allows port 5432 only from the app VM's IP."
