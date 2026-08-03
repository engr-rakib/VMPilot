#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: bash scripts/sops-encrypt.sh <env> [plaintext-dir]
#   Encrypts the plaintext <env>.tfvars files into secure/<env>/*.tfvars.
#
# Default plaintext source: .tmp-sops-plain/<env>/   (git-ignored, safe)
#   credentials.tfvars   -> vsphere_server / vsphere_user / vsphere_password / allow_unverified_ssl
#   vcenter.tfvars       -> datacenter / cluster / resource_pool / datastore / network / template
#
# Example (new vCenter):
#   mkdir -p .tmp-sops-plain/dev
#   vim .tmp-sops-plain/dev/credentials.tfvars     # paste new vCenter creds
#   vim .tmp-sops-plain/dev/vcenter.tfvars         # new inventory names
#   bash scripts/sops-encrypt.sh dev

ENV="${1:-dev}"
SRC="${2:-.tmp-sops-plain/${ENV}}"
DEST="secure/${ENV}"

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

for f in credentials vcenter; do
  [ -f "${SRC}/${f}.tfvars" ] || { echo "Error: missing ${SRC}/${f}.tfvars"; exit 1; }
  sops --encrypt --age "$PUB_KEY" "${SRC}/${f}.tfvars" > "${DEST}/${f}.tfvars"
  echo "Encrypted: ${DEST}/${f}.tfvars"
done

echo ""
echo "✓ New secrets encrypted for env '${ENV}'."
echo "  Verify: bash scripts/sops-decrypt.sh ${ENV} --clean   (decrypts then removes)"
echo "  Deploy: bash scripts/deploy-vm.sh ${ENV} <vm-name>"
echo ""
echo "  NOTE: plaintext still at ${SRC}/ — remove it now:"
echo "  rm -rf ${SRC}"
