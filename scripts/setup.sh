#!/usr/bin/env bash
# =============================================================================
# Vaultwarden ARM64 初期セットアップスクリプト
# 対象: AWS t4g (Ubuntu 22.04 / 24.04)
#
# 使い方:
#   export GITHUB_REPO="YOUR_USERNAME/vaultwarden"
#   curl -sL https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/setup.sh | sudo bash
#
# または:
#   sudo GITHUB_REPO="YOUR_USERNAME/vaultwarden" bash setup.sh
# =============================================================================
set -euo pipefail

# ── 設定 ──────────────────────────────────────────────────────────────────────
GITHUB_REPO="${GITHUB_REPO:-YOUR_USERNAME/vaultwarden}"  # fork のリポジトリ
INSTALL_DIR="/opt/vaultwarden"
DATA_DIR="/var/lib/vaultwarden"
CONFIG_DIR="/etc/vaultwarden"
LOG_DIR="/var/log/vaultwarden"
SERVICE_USER="vaultwarden"
SERVICE_NAME="vaultwarden"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn] ${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "root 権限が必要です。sudo で実行してください。"
[[ "$GITHUB_REPO" == "YOUR_USERNAME/vaultwarden" ]] && \
  die "GITHUB_REPO 環境変数を設定してください。例: export GITHUB_REPO=myuser/vaultwarden"

# ── 依存パッケージ ────────────────────────────────────────────────────────────
log "依存パッケージをインストール..."
apt-get update -qq
apt-get install -y --no-install-recommends curl jq tar gzip ca-certificates

# ── ユーザー・ディレクトリ作成 ────────────────────────────────────────────────
log "サービスユーザー '${SERVICE_USER}' を作成..."
if ! id "${SERVICE_USER}" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

for dir in "$INSTALL_DIR" "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
  mkdir -p "$dir"
done

# ── 最新リリースをダウンロード ────────────────────────────────────────────────
log "GitHub Releases から最新バイナリを取得..."
RELEASE_JSON=$(curl -sf "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")
TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
BINARY_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("aarch64-linux\\.tar\\.gz$")) | .browser_download_url')
WEB_URL=$(echo "$RELEASE_JSON" | jq -r \
  '.assets[] | select(.name | test("bw_web_.*\\.tar\\.gz$")) | .browser_download_url')

[[ -z "$BINARY_URL" ]] && die "バイナリ URL が見つかりません。リリースを確認してください。"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "バイナリをダウンロード: ${TAG}"
curl -sL "$BINARY_URL" -o "$TMPDIR/vaultwarden.tar.gz"
tar -xzf "$TMPDIR/vaultwarden.tar.gz" -C "$TMPDIR"
install -m 755 "$TMPDIR/vaultwarden" "$INSTALL_DIR/vaultwarden"
echo "$TAG" > "$INSTALL_DIR/.version"

if [[ -n "$WEB_URL" ]]; then
  log "Web vault をダウンロード..."
  curl -sL "$WEB_URL" -o "$TMPDIR/bw_web.tar.gz"
  rm -rf "$INSTALL_DIR/web-vault"
  tar -xzf "$TMPDIR/bw_web.tar.gz" -C "$INSTALL_DIR"
  log "Web vault を展開しました。"
else
  warn "Web vault アセットが見つかりませんでした。手動で配置してください。"
fi

# ── 設定ファイル ─────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_DIR/vaultwarden.env" ]]; then
  log "設定ファイルのひな形を作成: ${CONFIG_DIR}/vaultwarden.env"
  # 管理トークンを自動生成 (argon2 ハッシュ形式は vaultwarden v1.30+ 推奨)
  ADMIN_TOKEN=$(openssl rand -base64 48 | tr -d '\n')
  cat > "$CONFIG_DIR/vaultwarden.env" <<EOF
# Vaultwarden 設定ファイル
# 詳細: https://github.com/dani-garcia/vaultwarden/blob/main/.env.template

DATA_FOLDER=${DATA_DIR}

# ドメインを設定してください (HTTPS 必須)
DOMAIN=https://vaultwarden.example.com

# Web vault の場所
WEB_VAULT_FOLDER=${INSTALL_DIR}/web-vault
WEB_VAULT_ENABLED=true

# 管理パネルトークン (以下をハッシュ化するか、平文で設定)
# 平文の場合: ADMIN_TOKEN=<パスワード>
# 以下は生成された平文トークン (本番では必ず変更してください)
ADMIN_TOKEN=${ADMIN_TOKEN}

# 新規登録を制限する場合は false に
SIGNUPS_ALLOWED=false

# ログ
LOG_FILE=${LOG_DIR}/vaultwarden.log
LOG_LEVEL=warn

# SMTP (メール通知が必要な場合)
# SMTP_HOST=smtp.example.com
# SMTP_FROM=vaultwarden@example.com
# SMTP_PORT=587
# SMTP_SECURITY=starttls
# SMTP_USERNAME=user@example.com
# SMTP_PASSWORD=password
EOF
  chmod 600 "$CONFIG_DIR/vaultwarden.env"
fi

# ── パーミッション設定 ────────────────────────────────────────────────────────
chown -R "${SERVICE_USER}:${SERVICE_USER}" "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR"
chown root:root "$INSTALL_DIR/vaultwarden"
chmod 755 "$INSTALL_DIR/vaultwarden"

# ── systemd サービス ──────────────────────────────────────────────────────────
log "systemd サービスを設定..."
cp "$(dirname "$0")/vaultwarden.service" /etc/systemd/system/ 2>/dev/null || \
  curl -sL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/vaultwarden.service" \
    -o /etc/systemd/system/vaultwarden.service

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start  "${SERVICE_NAME}"

# ── 自動更新 cron ─────────────────────────────────────────────────────────────
log "自動更新 cron を設定 (毎日 03:00)..."
UPDATE_SCRIPT="/usr/local/bin/vaultwarden-update"
curl -sL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/update.sh" \
  -o "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"
sed -i "s|YOUR_USERNAME/vaultwarden|${GITHUB_REPO}|g" "$UPDATE_SCRIPT"

cat > /etc/cron.d/vaultwarden-update <<CRON
# Vaultwarden 自動更新 - 毎日 03:00
0 3 * * * root GITHUB_REPO=${GITHUB_REPO} ${UPDATE_SCRIPT} >> ${LOG_DIR}/update.log 2>&1
CRON

# ── 完了 ─────────────────────────────────────────────────────────────────────
log ""
log "========================================="
log " Vaultwarden ${TAG} のセットアップ完了！"
log "========================================="
log ""
log " 設定ファイル : ${CONFIG_DIR}/vaultwarden.env"
log " データ       : ${DATA_DIR}"
log " ログ         : ${LOG_DIR}/vaultwarden.log"
log ""
warn " 次に必ず行うこと:"
warn "   1. ${CONFIG_DIR}/vaultwarden.env の DOMAIN を正しいドメインに変更"
warn "   2. ADMIN_TOKEN を安全なパスワードに変更 (または argon2 ハッシュに)"
warn "   3. HTTPS リバースプロキシを設定 (nginx / Caddy 推奨)"
warn "   4. sudo systemctl restart vaultwarden"
log ""
log " サービス状態: sudo systemctl status vaultwarden"
