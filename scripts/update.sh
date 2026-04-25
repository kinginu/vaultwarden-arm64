#!/usr/bin/env bash
# =============================================================================
# Vaultwarden 自動更新スクリプト
# cron または手動で実行。新しいリリースがあればバイナリを置き換えてサービスを再起動。
#
# 使い方 (手動):
#   sudo GITHUB_REPO="YOUR_USERNAME/vaultwarden" bash update.sh
# =============================================================================
set -euo pipefail

# ── 設定 ──────────────────────────────────────────────────────────────────────
GITHUB_REPO="${GITHUB_REPO:-YOUR_USERNAME/vaultwarden}"
INSTALL_DIR="/opt/vaultwarden"
DATA_DIR="/var/lib/vaultwarden"
SERVICE_NAME="vaultwarden"
BINARY_PATH="${INSTALL_DIR}/vaultwarden"
VERSION_FILE="${INSTALL_DIR}/.version"
LOG_DIR="/var/log/vaultwarden"
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"
LOGFILE="${LOG_DIR}/update.log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOGFILE" 2>/dev/null || true
}

die() { log "ERROR: $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "root 権限が必要です。sudo で実行してください。"

# ── 最新リリース情報を取得 ─────────────────────────────────────────────────────
log "リリース情報を取得中: ${GITHUB_REPO}"
RELEASE_JSON=$(curl -sf \
  --retry 3 --retry-delay 5 \
  "https://api.github.com/repos/${GITHUB_REPO}/releases/latest") \
  || die "GitHub API への接続に失敗しました。"

LATEST=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
[[ -z "$LATEST" || "$LATEST" == "null" ]] && die "タグ名を取得できませんでした。"

# ── 現在のバージョンと比較 ─────────────────────────────────────────────────────
CURRENT="none"
[[ -f "$VERSION_FILE" ]] && CURRENT=$(cat "$VERSION_FILE")

if [[ "$LATEST" == "$CURRENT" ]]; then
  log "既に最新版です: ${CURRENT}"
  exit 0
fi

log "更新あり: ${CURRENT} → ${LATEST}"

# ── バイナリ URL を抽出 ────────────────────────────────────────────────────────
BINARY_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("aarch64-linux\\.tar\\.gz$")) | .browser_download_url')
SHA256_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("aarch64-linux\\.tar\\.gz\\.sha256$")) | .browser_download_url')
WEB_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("bw_web_.*\\.tar\\.gz$")) | .browser_download_url')

[[ -z "$BINARY_URL" || "$BINARY_URL" == "null" ]] && \
  die "aarch64 バイナリアセットが見つかりません。リリースを確認してください。"

# ── ダウンロード & チェックサム検証 ───────────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "バイナリをダウンロード..."
curl -sL --retry 3 "$BINARY_URL" -o "$TMPDIR/vaultwarden.tar.gz"

if [[ -n "$SHA256_URL" && "$SHA256_URL" != "null" ]]; then
  log "チェックサムを検証..."
  curl -sL "$SHA256_URL" -o "$TMPDIR/vaultwarden.tar.gz.sha256"
  # sha256 ファイルのパスをカレントに合わせる
  (cd "$TMPDIR" && sed -i "s|dist/||g" vaultwarden.tar.gz.sha256 && \
    sha256sum -c vaultwarden.tar.gz.sha256) \
    || die "チェックサム検証に失敗しました！ダウンロードを確認してください。"
  log "チェックサム OK"
fi

log "アーカイブを展開..."
tar -xzf "$TMPDIR/vaultwarden.tar.gz" -C "$TMPDIR"
[[ ! -f "$TMPDIR/vaultwarden" ]] && die "アーカイブに vaultwarden バイナリが含まれていません。"

# ── サービス停止 → バイナリ入れ替え → サービス起動 ──────────────────────────
log "サービスを停止..."
systemctl stop "$SERVICE_NAME" || true

log "バイナリを更新..."
cp "$BINARY_PATH" "${BINARY_PATH}.bak.${CURRENT}" 2>/dev/null || true  # ロールバック用バックアップ
install -m 755 "$TMPDIR/vaultwarden" "$BINARY_PATH"
echo "$LATEST" > "$VERSION_FILE"

# ── web vault も更新 (オプション) ─────────────────────────────────────────────
if [[ -n "$WEB_URL" && "$WEB_URL" != "null" ]]; then
  log "Web vault を更新..."
  curl -sL --retry 3 "$WEB_URL" -o "$TMPDIR/bw_web.tar.gz"
  rm -rf "${INSTALL_DIR}/web-vault"
  tar -xzf "$TMPDIR/bw_web.tar.gz" -C "$INSTALL_DIR"
  log "Web vault を更新しました。"
fi

log "サービスを起動..."
systemctl start "$SERVICE_NAME"

# ── ヘルスチェック ────────────────────────────────────────────────────────────
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log "✓ 更新成功: ${CURRENT} → ${LATEST}"
  # 古いバックアップを削除 (最新 3 世代を保持)
  ls -t "${BINARY_PATH}.bak."* 2>/dev/null | tail -n +4 | xargs rm -f || true
else
  log "ERROR: サービスの起動に失敗しました。ロールバックします..."
  if [[ -f "${BINARY_PATH}.bak.${CURRENT}" ]]; then
    install -m 755 "${BINARY_PATH}.bak.${CURRENT}" "$BINARY_PATH"
    echo "$CURRENT" > "$VERSION_FILE"
    systemctl start "$SERVICE_NAME" || true
    log "ロールバック完了: ${LATEST} → ${CURRENT}"
  fi
  die "更新に失敗しました。journalctl -u ${SERVICE_NAME} を確認してください。"
fi
