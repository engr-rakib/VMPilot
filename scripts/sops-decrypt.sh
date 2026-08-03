#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${1:-dev}"
SECURE_DIR="secure/${ENV}"
TF_DIR="terraform"

# ─── Flags ──────────────────────────────────────────────────────────────
FLAG="${2:-}"
TF_ARGS=()
if [ "$FLAG" = "--apply" ] || [ "$FLAG" = "-a" ]; then
  shift 2
  TF_ARGS=("$@")
elif [ "$FLAG" = "--clean" ] || [ "$FLAG" = "-c" ]; then
  shift 2
else
  shift
fi

cleanup() {
  echo "Cleaning up decrypted .auto.tfvars..."
  rm -f "${TF_DIR}"/*.auto.tfvars
  echo "Done."
}

decrypt() {
  if [ ! -f "${SECURE_DIR}/credentials.tfvars" ] || [ ! -f "${SECURE_DIR}/vcenter.tfvars" ]; then
    echo "Error: Encrypted files not found in ${SECURE_DIR}/"
    echo "Run: sops --encrypt secure/${ENV}/credentials.tfvars"
    exit 1
  fi
  echo "Decrypting ${SECURE_DIR}/*.tfvars → ${TF_DIR}/*.auto.tfvars ..."
  sops --decrypt "${SECURE_DIR}/credentials.tfvars" > "${TF_DIR}/credentials.auto.tfvars"
  sops --decrypt "${SECURE_DIR}/vcenter.tfvars"     > "${TF_DIR}/vcenter.auto.tfvars"
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
    terraform -chdir="${TF_DIR}" apply -auto-approve ${TF_ARGS[@]+"${TF_ARGS[@]}"}
    cleanup
    ;;
  *)
    decrypt
    echo ""
    echo "WARNING: Decrypted credentials on disk: ${TF_DIR}/*.auto.tfvars"
    echo "Run cleanup after apply:  bash sops-decrypt.sh ${ENV} --clean"
    echo "Or auto-clean:            bash sops-decrypt.sh ${ENV} --apply -- [terraform flags]"
    ;;
esac
