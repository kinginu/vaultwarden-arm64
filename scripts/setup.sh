#!/usr/bin/env bash
# =============================================================================
# Vaultwarden ARM64 — initial setup script
# Target: AWS t4g (Ubuntu 22.04 / 24.04)
#
# Usage:
#   export GITHUB_REPO="YOUR_USERNAME/vaultwarden"
#   curl -sL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/setup.sh | sudo bash
#
# Or:
#   sudo GITHUB_REPO="YOUR_USERNAME/vaultwarden" bash setup.sh
# =============================================================================
set -euo pipefail

# -- Configuration ------------------------------------------------------------
GITHUB_REPO="${GITHUB_REPO:-YOUR_USERNAME/vaultwarden}"  # your fork
INSTALL_DIR="/opt/vaultwarden"
DATA_DIR="/var/lib/vaultwarden"
CONFIG_DIR="/etc/vaultwarden"
LOG_DIR="/var/log/vaultwarden"
SERVICE_USER="vaultwarden"
SERVICE_NAME="vaultwarden"
# -----------------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn] ${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Must be run as root. Use sudo."
[[ "$GITHUB_REPO" == "YOUR_USERNAME/vaultwarden" ]] && \
  die "Set the GITHUB_REPO env variable. Example: export GITHUB_REPO=myuser/vaultwarden"

# -- Install dependencies -----------------------------------------------------
log "Installing dependencies..."
if command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y --no-install-recommends curl jq tar gzip ca-certificates
elif command -v dnf &>/dev/null; then
  # Amazon Linux ships curl-minimal which conflicts with curl; skip it if already present
  PKGS="jq tar gzip ca-certificates cronie"
  command -v curl &>/dev/null || PKGS="curl $PKGS"
  dnf install -y $PKGS
elif command -v yum &>/dev/null; then
  PKGS="jq tar gzip ca-certificates"
  command -v curl &>/dev/null || PKGS="curl $PKGS"
  yum install -y $PKGS
else
  die "No supported package manager found (apt-get / dnf / yum)."
fi

# -- Create service user and directories --------------------------------------
log "Creating service user '${SERVICE_USER}'..."
if ! id "${SERVICE_USER}" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

for dir in "$INSTALL_DIR" "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
  mkdir -p "$dir"
done

# -- Download latest release --------------------------------------------------
log "Fetching latest release from GitHub..."
RELEASE_JSON=$(curl -sf "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")
TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
BINARY_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("aarch64-linux\\.tar\\.gz$")) | .browser_download_url')
WEB_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("bw_web_.*\\.tar\\.gz$")) | .browser_download_url')

[[ -z "$BINARY_URL" ]] && die "Binary URL not found. Check that a release exists."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "Downloading binary: ${TAG}"
curl -sL "$BINARY_URL" -o "$TMPDIR/vaultwarden.tar.gz"
tar -xzf "$TMPDIR/vaultwarden.tar.gz" -C "$TMPDIR"
install -m 755 "$TMPDIR/vaultwarden" "$INSTALL_DIR/vaultwarden"
echo "$TAG" > "$INSTALL_DIR/.version"

if [[ -n "$WEB_URL" ]]; then
  log "Downloading web vault..."
  curl -sL "$WEB_URL" -o "$TMPDIR/bw_web.tar.gz"
  rm -rf "$INSTALL_DIR/web-vault"
  tar -xzf "$TMPDIR/bw_web.tar.gz" -C "$INSTALL_DIR"
  log "Web vault extracted."
else
  warn "Web vault asset not found. Place it manually."
fi

# -- Generate config file -----------------------------------------------------
if [[ ! -f "$CONFIG_DIR/vaultwarden.env" ]]; then
  log "Generating config file: ${CONFIG_DIR}/vaultwarden.env"
  ADMIN_TOKEN=$(openssl rand -base64 48 | tr -d '\n')
  cat > "$CONFIG_DIR/vaultwarden.env" <<EOF
# Vaultwarden configuration
# Full reference: https://github.com/dani-garcia/vaultwarden/blob/main/.env.template

DATA_FOLDER=${DATA_DIR}

# Set your actual domain (HTTPS required)
DOMAIN=https://vaultwarden.example.com

# Web vault
WEB_VAULT_FOLDER=${INSTALL_DIR}/web-vault
WEB_VAULT_ENABLED=true

# Admin panel token — change this to a secure password before use
ADMIN_TOKEN=${ADMIN_TOKEN}

# Disable open registration
SIGNUPS_ALLOWED=false

# Logging
LOG_FILE=${LOG_DIR}/vaultwarden.log
LOG_LEVEL=warn

# SMTP (optional — needed for email notifications)
# SMTP_HOST=smtp.example.com
# SMTP_FROM=vaultwarden@example.com
# SMTP_PORT=587
# SMTP_SECURITY=starttls
# SMTP_USERNAME=user@example.com
# SMTP_PASSWORD=password
EOF
  chmod 600 "$CONFIG_DIR/vaultwarden.env"
fi

# -- Set permissions ----------------------------------------------------------
chown -R "${SERVICE_USER}:${SERVICE_USER}" "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"
chown root:root "$INSTALL_DIR/vaultwarden"
chmod 755 "$INSTALL_DIR/vaultwarden"

# -- Register systemd service -------------------------------------------------
log "Setting up systemd service..."
cp "$(dirname "$0")/vaultwarden.service" /etc/systemd/system/ 2>/dev/null || \
  curl -sL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/vaultwarden.service" \
    -o /etc/systemd/system/vaultwarden.service

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start  "${SERVICE_NAME}"

# -- Set up auto-update cron --------------------------------------------------
log "Setting up daily auto-update cron (03:00)..."
UPDATE_SCRIPT="/usr/local/bin/vaultwarden-update"
curl -sL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/update.sh" \
  -o "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"
sed -i "s|YOUR_USERNAME/vaultwarden|${GITHUB_REPO}|g" "$UPDATE_SCRIPT"

cat > /etc/cron.d/vaultwarden-update <<CRON
# Vaultwarden auto-update — runs daily at 03:00
0 3 * * * root GITHUB_REPO=${GITHUB_REPO} ${UPDATE_SCRIPT} >> ${LOG_DIR}/update.log 2>&1
CRON

# -- Done ---------------------------------------------------------------------
log ""
log "========================================="
log " Vaultwarden ${TAG} setup complete!"
log "========================================="
log ""
log " Config : ${CONFIG_DIR}/vaultwarden.env"
log " Data   : ${DATA_DIR}"
log " Logs   : ${LOG_DIR}/vaultwarden.log"
log ""
warn " Required next steps:"
warn "   1. Set DOMAIN in ${CONFIG_DIR}/vaultwarden.env"
warn "   2. Change ADMIN_TOKEN to a secure password"
warn "   3. Configure an HTTPS reverse proxy (nginx / Caddy / Tailscale serve)"
warn "   4. sudo systemctl restart vaultwarden"
log ""
log " Service status: sudo systemctl status vaultwarden"