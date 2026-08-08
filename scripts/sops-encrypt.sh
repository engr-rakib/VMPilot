#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: bash scripts/sops-encrypt.sh <vcenter> [plaintext-dir]
#   Encrypts the secret <vcenter> credentials into secure/<vcenter>/*.tfvars.
#
# Default plaintext source: .tmp-sops-plain/<vcenter>/   (git-ignored, safe)
#   credentials.tfvars   -> vsphere_server / vsphere_user / vsphere_password / allow_unverified_ssl
#                          → SOPS ENCRYPTED
#   vcenter.tfvars       -> datacenter / cluster / resource_pool / datastore / network / template
#                          → PLAINTEXT (inventory only, no secrets — readable)
#
# Example (new vCenter):
#   mkdir -p .tmp-sops-plain/dc_pilot_192.0.2.10
#   vim .tmp-sops-plain/dc_pilot_192.0.2.10/credentials.tfvars
#   vim .tmp-sops-plain/dc_pilot_192.0.2.10/vcenter.tfvars
#   bash scripts/sops-encrypt.sh dc_pilot_192.0.2.10

VCENTER="${1:-}"
[ -n "$VCENTER" ] || { echo "Usage: $0 <vcenter> [plaintext-dir]"; exit 1; }
SRC="${2:-.tmp-sops-plain/${VCENTER}}"
DEST="secure/${VCENTER}"

AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [ ! -f "$AGE_KEY" ]; then
  echo "Error: age key not found at $AGE_KEY"
  exit 1
fi

PUB_KEY=$(grep -oP '(?<=public key: )age1[0-9a-z]+' "$AGE_KEY" | head -1)
if [ -z "$PUB_KEY" ]; then
  echo "Error: could not read public key from $AGE_KEY"
  exit 1
fi

[ -d "$SRC" ] || { echo "Error: plaintext dir '$SRC' not found. Create it first (see header)."; exit 1; }
mkdir -p "$DEST"

# credentials.tfvars = SECRET → encrypt
[ -f "${SRC}/credentials.tfvars" ] || { echo "Error: missing ${SRC}/credentials.tfvars"; exit 1; }
sops --encrypt --age "$PUB_KEY" "${SRC}/credentials.tfvars" > "${DEST}/credentials.tfvars"
echo "Encrypted: ${DEST}/credentials.tfvars"

# vcenter.tfvars = inventory only (no secrets) → copy plaintext
[ -f "${SRC}/vcenter.tfvars" ] || { echo "Error: missing ${SRC}/vcenter.tfvars"; exit 1; }
cp "${SRC}/vcenter.tfvars" "${DEST}/vcenter.tfvars"
echo "Copied plaintext (readable): ${DEST}/vcenter.tfvars"

echo ""
echo "✓ New secrets encrypted for vCenter '${VCENTER}'."
echo "  Verify: bash scripts/sops-decrypt.sh ${VCENTER} dev --clean   (decrypts then removes)"
echo "  Deploy: bash scripts/deploy-vm.sh ${VCENTER} <env> <vm-name>"
echo ""
echo "  NOTE: plaintext still at ${SRC}/ — remove it now:"
echo "  rm -rf ${SRC}"
