#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
# vmpilot-webui/scripts/setup.sh — create .env + secrets (idempotent)
#
#   bash scripts/setup.sh                 # prompts for admin password
#   bash scripts/setup.sh "S3cret!"       # one-shot (non-interactive)
#
# After this, run:  docker compose up -d --build
set -euo pipefail

cd "$(dirname "$0")/.."

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  docker info >/dev/null 2>&1 || SUDO="sudo"
fi
COMPOSE="$SUDO docker compose -f docker-compose.yml"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_cyn=$'\e[36m'; c_rst=$'\e[0m'
info() { printf '%s::%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

# 1) .env — non-secret settings
if [ -f .env ]; then
  info ".env already present — keeping it."
else
  cp .env.example .env
  sed -i "s|^WEBUI_SECRET=.*|WEBUI_SECRET=$(openssl rand -hex 32)|" .env
  ok ".env created (WEBUI_SECRET generated)."
fi

# 3) data dir for job logs + SQLite (container runs as uid 1000)
if [ ! -d data ]; then
  mkdir -p data
  $SUDO chown 1000:1000 data 2>/dev/null || chown 1000:1000 data 2>/dev/null || true
  ok "data/ created for job logs + DB."
fi

# 4) config/secrets.env — bcrypt hash (immune to Compose $ interpolation)
if grep -q '^WEBUI_PASS_HASH=.\+' config/secrets.env 2>/dev/null; then
  ok "config/secrets.env already configured."
  exit 0
fi
cp config/secrets.env.example config/secrets.env

if [ -n "${1:-}" ]; then
  pw="$1"
else
  read -rsp "Set VMPilot Web UI admin password: " pw; echo
fi
[ -n "$pw" ] || die "no password given"

info "Generating bcrypt hash (via server image)..."
# Build first (progress to stderr), then capture ONLY the run's stdout —
# otherwise docker build logs pollute the captured hash.
$COMPOSE build server >/dev/null
hash=$($COMPOSE run --rm --no-deps server node scripts/gen-pass.js "$pw" 2>/dev/null | tail -n 1)
[ -n "$hash" ] || die "failed to generate password hash"
# sed breaks on `$`/`/` inside the hash — use awk (safe for any characters)
awk -v h="$hash" 'BEGIN{FS=OFS="="} /^WEBUI_PASS_HASH=/{$2=h} {print}' config/secrets.env > config/secrets.env.tmp
mv config/secrets.env.tmp config/secrets.env
ok "config/secrets.env updated."

echo ""
info "Next:  $SUDO docker compose -f docker-compose.yml up -d --build"
