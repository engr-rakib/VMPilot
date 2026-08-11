#!/bin/bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================

# ─── Author banner ───────────────────────────────────────────────────────
# Printed on every run so the origin of this project is always visible.
vmpilot_banner() {
  local B='\033[1m' C='\033[0;36m' G='\033[0;32m' NC='\033[0m'
  echo -e "${C}================================================================================${NC}"
  echo -e "${C}${B}  VMPilot${NC}  -  VMware vSphere Automation"
  echo -e "${G}${B}  (c) 2026 Rakibuzzaman (Engr. Rakib)${NC}  -  Original author"
  echo -e "  GitHub: https://github.com/engr-rakib   |   Web: https://engr-rakib.github.io/web"
  echo -e "${C}================================================================================${NC}"
}
vmpilot_banner

set -euo pipefail
cd "$(dirname "$0")/.."

# Usage: bash scripts/sops-decrypt.sh <vcenter> <env> [--clean|--apply ...]
#   Decrypts secure/<vcenter>/{credentials,vcenter}.tfvars into terraform/*.auto.tfvars.
#   credentials.tfvars = SECRET → decrypted via sops.
#   vcenter.tfvars     = inventory only (no secrets) → copied plaintext.
#   Per-env override: secure/<vcenter>/<env>/vcenter.tfvars (if present) is merged
#   ON TOP of the top-level file — a key set there wins; otherwise top-level wins.
#
# Examples:
#   bash scripts/sops-decrypt.sh dc_pilot_192.0.2.10 dev
#   bash scripts/sops-decrypt.sh dc_pilot_192.0.2.10 dev --clean
#   bash scripts/sops-decrypt.sh dc_pilot_192.0.2.10 dev --apply
#   bash scripts/sops-decrypt.sh dc_pilot_192.0.2.10 dev --apply -- -auto-approve

VCENTER="${1:-}"
ENV="${2:-dev}"
[ -n "$VCENTER" ] || { echo "Usage: $0 <vcenter> <env> [--clean|--apply ...]"; exit 1; }
SECURE_DIR="secure/${VCENTER}"
TF_DIR="terraform"

# ─── Flags ──────────────────────────────────────────────────────────────
FLAG="${3:-}"
TF_ARGS=()
if [ "$FLAG" = "--apply" ] || [ "$FLAG" = "-a" ]; then
  shift 3
  TF_ARGS=("$@")
elif [ "$FLAG" = "--clean" ] || [ "$FLAG" = "-c" ]; then
  shift 3
else
  shift 2
fi

cleanup() {
  echo "Cleaning up decrypted .auto.tfvars..."
  rm -f "${TF_DIR}"/*.auto.tfvars
  echo "Done."
}

# Merge per-env override (secure/<vcenter>/<env>/vcenter.tfvars) on top of the
# top-level file: any key actually SET in the override wins; otherwise inherit.
merge_vcenter() {
  local top="$1" override="$2" out="$3"
  cp "$top" "$out"
  [ -f "$override" ] || return 0
  local key line
  while IFS= read -r line; do
    key="$(echo "$line" | sed -E 's/^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=.*/\1/')"
    [ -n "$key" ] || continue
    sed -i "/^[[:space:]]*${key}[[:space:]]*=/d" "$out" 2>/dev/null || true
    echo "$line" >> "$out"
  done < <(grep -E '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=' "$override")
}

decrypt() {
  if [ ! -f "${SECURE_DIR}/credentials.tfvars" ] || [ ! -f "${SECURE_DIR}/vcenter.tfvars" ]; then
    echo "Error: Encrypted files not found in ${SECURE_DIR}/"
    echo "Run: sops --encrypt secure/${VCENTER}/credentials.tfvars"
    exit 1
  fi
  echo "Decrypting ${SECURE_DIR}/*.tfvars → ${TF_DIR}/*.auto.tfvars ..."
  # credentials.tfvars = SECRET → must be decrypted via sops
  sops --decrypt "${SECURE_DIR}/credentials.tfvars" > "${TF_DIR}/credentials.auto.tfvars"
  # vcenter.tfvars = inventory only (no secrets) → stored plaintext, just copy;
  # per-env override secure/<vcenter>/<env>/vcenter.tfvars merged on top (if present)
  if [ -f "${SECURE_DIR}/${ENV}/vcenter.tfvars" ]; then
    merge_vcenter "${SECURE_DIR}/vcenter.tfvars" "${SECURE_DIR}/${ENV}/vcenter.tfvars" "${TF_DIR}/vcenter.auto.tfvars"
    echo "Merged per-env override: secure/${VCENTER}/${ENV}/vcenter.tfvars (keys there win)"
  else
    cp "${SECURE_DIR}/vcenter.tfvars" "${TF_DIR}/vcenter.auto.tfvars"
  fi
  chmod 600 "${TF_DIR}/credentials.auto.tfvars" "${TF_DIR}/vcenter.auto.tfvars"
  echo "Done."
}

case "$FLAG" in
  --clean|-c)
    cleanup
    ;;
  --apply|-a)
    decrypt
    echo "Running: terraform apply ${TF_ARGS[*]}"
    terraform -chdir="${TF_DIR}" apply -auto-approve \
      -state="${TF_DIR}/terraform.${VCENTER}.${ENV}.tfstate" ${TF_ARGS[@]+"${TF_ARGS[@]}"}
    cleanup
    ;;
  *)
    decrypt
    echo ""
    echo "WARNING: Decrypted credentials on disk: ${TF_DIR}/*.auto.tfvars"
    echo "Run cleanup after apply:  bash sops-decrypt.sh ${VCENTER} ${ENV} --clean"
    echo "Or auto-clean:            bash sops-decrypt.sh ${VCENTER} ${ENV} --apply -- [terraform flags]"
    ;;
esac
