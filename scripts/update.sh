#!/usr/bin/env bash
# =============================================================================
# Vaultwarden auto-update script
# Run via cron or manually. Replaces the binary and restarts the service
# if a newer release is available.
#
# Usage (manual):
#   sudo GITHUB_REPO="YOUR_USERNAME/vaultwarden" bash update.sh
# =============================================================================
set -euo pipefail

# -- Configuration ------------------------------------------------------------
GITHUB_REPO="${GITHUB_REPO:-YOUR_USERNAME/vaultwarden}"
INSTALL_DIR="/opt/vaultwarden"
SERVICE_NAME="vaultwarden"
BINARY_PATH="${INSTALL_DIR}/vaultwarden"
VERSION_FILE="${INSTALL_DIR}/.version"
LOG_DIR="/var/log/vaultwarden"
# -----------------------------------------------------------------------------

mkdir -p "$LOG_DIR"
LOGFILE="${LOG_DIR}/update.log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOGFILE" 2>/dev/null || true
}

die() { log "ERROR: $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Must be run as root. Use sudo."

# -- Fetch latest release info ------------------------------------------------
log "Checking for updates: ${GITHUB_REPO}"
RELEASE_JSON=$(curl -sf \
  --retry 3 --retry-delay 5 \
  "https://api.github.com/repos/${GITHUB_REPO}/releases/latest") \
  || die "Failed to reach GitHub API."

LATEST=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
[[ -z "$LATEST" || "$LATEST" == "null" ]] && die "Could not retrieve tag name."

# -- Compare with current version ---------------------------------------------
CURRENT="none"
[[ -f "$VERSION_FILE" ]] && CURRENT=$(cat "$VERSION_FILE")

if [[ "$LATEST" == "$CURRENT" ]]; then
  log "Already on latest version: ${CURRENT}"
  exit 0
fi

log "Update available: ${CURRENT} -> ${LATEST}"

# -- Resolve asset URLs -------------------------------------------------------
BINARY_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("aarch64-linux\\.tar\\.gz$")) | .browser_download_url')
SHA256_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("aarch64-linux\\.tar\\.gz\\.sha256$")) | .browser_download_url')
WEB_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("bw_web_.*\\.tar\\.gz$")) | .browser_download_url')

[[ -z "$BINARY_URL" || "$BINARY_URL" == "null" ]] && \
  die "aarch64 binary asset not found. Check the release page."

# -- Download and verify ------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "Downloading binary..."
curl -sL --retry 3 "$BINARY_URL" -o "$TMPDIR/vaultwarden.tar.gz"

if [[ -n "$SHA256_URL" && "$SHA256_URL" != "null" ]]; then
  log "Verifying checksum..."
  curl -sL "$SHA256_URL" -o "$TMPDIR/vaultwarden.tar.gz.sha256"
  (cd "$TMPDIR" && sed -i "s|dist/||g" vaultwarden.tar.gz.sha256 && \
    sha256sum -c vaultwarden.tar.gz.sha256) \
    || die "Checksum verification failed. Aborting update."
  log "Checksum OK"
fi

log "Extracting archive..."
tar -xzf "$TMPDIR/vaultwarden.tar.gz" -C "$TMPDIR"
[[ ! -f "$TMPDIR/vaultwarden" ]] && die "Binary not found in archive."

# -- Stop service, swap binary, start service ---------------------------------
log "Stopping service..."
systemctl stop "$SERVICE_NAME" || true

log "Installing new binary..."
cp "$BINARY_PATH" "${BINARY_PATH}.bak.${CURRENT}" 2>/dev/null || true  # rollback backup
install -m 755 "$TMPDIR/vaultwarden" "$BINARY_PATH"
echo "$LATEST" > "$VERSION_FILE"

# -- Update web vault (if included in release) --------------------------------
if [[ -n "$WEB_URL" && "$WEB_URL" != "null" ]]; then
  log "Updating web vault..."
  curl -sL --retry 3 "$WEB_URL" -o "$TMPDIR/bw_web.tar.gz"
  rm -rf "${INSTALL_DIR}/web-vault"
  tar -xzf "$TMPDIR/bw_web.tar.gz" -C "$INSTALL_DIR"
  log "Web vault updated."
fi

log "Starting service..."
systemctl start "$SERVICE_NAME"

# -- Health check and rollback on failure -------------------------------------
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log "Update successful: ${CURRENT} -> ${LATEST}"
  # Keep only the 3 most recent backups
  ls -t "${BINARY_PATH}.bak."* 2>/dev/null | tail -n +4 | xargs rm -f || true
else
  log "ERROR: Service failed to start. Rolling back..."
  if [[ -f "${BINARY_PATH}.bak.${CURRENT}" ]]; then
    install -m 755 "${BINARY_PATH}.bak.${CURRENT}" "$BINARY_PATH"
    echo "$CURRENT" > "$VERSION_FILE"
    systemctl start "$SERVICE_NAME" || true
    log "Rollback complete: ${LATEST} -> ${CURRENT}"
  fi
  die "Update failed. Check: journalctl -u ${SERVICE_NAME}"
fi