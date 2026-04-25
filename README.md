# Vaultwarden ARM64 — Automated builds for AWS t4g

A fork of [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden) that uses GitHub Actions to automatically build and release **aarch64 (ARM64)** binaries for AWS **t4g.nano** / Graviton instances.

---

## Overview

| Feature | How it works |
|---------|-------------|
| ARM64 binary build | Natively compiled on `ubuntu-22.04-arm` runner |
| Auto-sync with upstream | Checks for new tags daily and pushes them to the fork |
| Automated releases | Tag push → GitHub Actions → assets uploaded to GitHub Releases |
| EC2 auto-update | cron runs `update.sh`, pulls the latest release automatically |

---

## Setup

### 1. Fork the repository

Fork [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden) on GitHub.

### 2. Copy workflow and script files into your fork

```
.github/workflows/build-release.yml   ← ARM64 build & release
.github/workflows/sync-upstream.yml   ← upstream auto-sync
scripts/setup.sh                       ← EC2 initial setup
scripts/update.sh                      ← EC2 auto-update
scripts/vaultwarden.service            ← systemd unit file
```

### 3. Create and register a PAT (Personal Access Token)

`sync-upstream.yml` pushes tags to trigger `build-release.yml`.
This requires a PAT — `GITHUB_TOKEN` cannot trigger other workflows by design.

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. Grant: **Contents: Read & Write**, **Workflows: Read & Write**
3. In your fork: Settings → Secrets and variables → Actions
4. Add a secret named `SYNC_TOKEN` with the PAT value

### 4. Enable Actions

In your fork: Actions tab → "I understand my workflows, go ahead and enable them"

### 5. Trigger the first build

Actions → **Build and Release (ARM64)** → Run workflow → enter a tag (e.g. `v1.32.0`).

Alternatively, push upstream tags to your fork and the build will start automatically:

```bash
git remote add upstream https://github.com/dani-garcia/vaultwarden.git
git fetch upstream --tags
git push origin --tags
```

---

## EC2 Setup

### Prerequisites

- AWS t4g instance (Ubuntu 22.04 or 24.04 recommended)
- An HTTPS reverse proxy (nginx or Caddy) configured separately
- Vaultwarden listens on port 8080 (HTTP) on localhost

### Install

```bash
export GITHUB_REPO="YOUR_USERNAME/vaultwarden"

curl -sL \
  "https://raw.githubusercontent.com/${GITHUB_REPO}/main/scripts/setup.sh" \
  | sudo GITHUB_REPO="${GITHUB_REPO}" bash
```

This single command will:

- Place the binary and web vault under `/opt/vaultwarden/`
- Generate a config file at `/etc/vaultwarden/vaultwarden.env`
- Create the data directory at `/var/lib/vaultwarden/`
- Enable and start the systemd service
- Set up a daily cron job at 03:00 for automatic updates

### Required: edit the config file

```bash
sudo nano /etc/vaultwarden/vaultwarden.env
```

Minimum changes required:

```env
DOMAIN=https://vaultwarden.example.com   # set your actual domain
ADMIN_TOKEN=<replace with a secure password>
```

Then restart:

```bash
sudo systemctl restart vaultwarden
sudo systemctl status vaultwarden
```

---

## Manual update

```bash
sudo GITHUB_REPO="YOUR_USERNAME/vaultwarden" /usr/local/bin/vaultwarden-update
```

---

## nginx reverse proxy example

```nginx
server {
    listen 443 ssl http2;
    server_name vaultwarden.example.com;

    ssl_certificate     /etc/letsencrypt/live/vaultwarden.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vaultwarden.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # WebSocket (real-time notifications)
    location /notifications/hub {
        proxy_pass http://127.0.0.1:3012;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /notifications/hub/negotiate {
        proxy_pass http://127.0.0.1:8080;
    }
}

server {
    listen 80;
    server_name vaultwarden.example.com;
    return 301 https://$host$request_uri;
}
```

---

## Directory layout

```
/opt/vaultwarden/
├── vaultwarden          # binary
├── web-vault/           # web UI
└── .version             # currently installed version

/etc/vaultwarden/
└── vaultwarden.env      # config file (mode 600)

/var/lib/vaultwarden/
└── db.sqlite3           # database — back this up

/var/log/vaultwarden/
├── vaultwarden.log      # application log
└── update.log           # auto-update log
```

---

## Backup

Backing up the SQLite database is all you need:

```bash
# Example: back up to S3 (add to cron)
sqlite3 /var/lib/vaultwarden/db.sqlite3 ".backup /tmp/vw-backup.sqlite3"
aws s3 cp /tmp/vw-backup.sqlite3 s3://your-bucket/vaultwarden/$(date +%Y%m%d).sqlite3
rm /tmp/vw-backup.sqlite3
```

---

## License

Follows the upstream [vaultwarden](https://github.com/dani-garcia/vaultwarden) license (AGPL-3.0).
