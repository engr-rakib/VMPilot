#!/bin/bash
# Generate a self-signed TLS cert on first boot if none is present.
# Drop a real cert at /etc/nginx/certs/server.crt + server.key to override.
set -euo pipefail

CERT_DIR=/etc/nginx/certs
CRT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"

if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "$KEY" -out "$CRT" \
    -subj "/C=BD/O=VMPilot/CN=vmpilot-webui" >/dev/null 2>&1
  chmod 600 "$KEY"
  echo "[vmpilot-webui] generated self-signed TLS certificate"
fi

exec "$@"
