#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Script   : deploy-vm.sh
# Path     : /opt/terraform-lab/projects/project01/scripts/deploy-vm.sh
# ---------------------------------------------------------------------------
# Purpose  : Deploy / redeploy ONE VM, leaving all other VMs in the same
#            state completely untouched.
#
# Usage
# ───────────────────────────────────────────────────────────────────────────
#   ./scripts/deploy-vm.sh <env> <vm-name>          # apply (auto-approve)
#   ./scripts/deploy-vm.sh <env> <vm-name> --plan   # plan only
#   ./scripts/deploy-vm.sh <env> <vm-name> --no-clean  # keep decrypted .auto.tfvars
#
#   Example:
#     ./scripts/deploy-vm.sh dev web-02
#
#   How it works:
#     1. Finds deploy/<env>/vm-<name>_<ip>.tfvars for the requested VM.
#     2. Assembles a temporary combined config (top-level vars + the
#        vm_configs entry of EVERY per-VM file across ALL envs). This
#        guarantees Terraform never sees a VM as "missing from config" →
#        nothing gets scheduled for destroy.
#     3. Decrypts credentials → terraform/*.auto.tfvars
#     4. Runs: terraform apply -var-file=<combined> -target='module.vm["<name>"]'
#     5. Cleans up decrypted files + the temp combined config (unless --no-clean)
#
#   The -target flag limits the operation to exactly one VM. Because every
#   VM is still present in the combined config, no other VM is destroyed.
#
#   IPAM: the per-VM config file is the source of truth for the IP. No
#   separate .<vm>_ip persist file is used — next_free_ip.sh reads the
#   config files directly to know which IPs are already in use.
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ENV="${1:-}"
VM_NAME="${2:-}"
MODE="apply"
KEEP_CREDS=false

if [ -z "$ENV" ] || [ -z "$VM_NAME" ]; then
  echo "Usage: $0 <env> <vm-name> [--plan|--no-clean]"
  echo "  $0 dev web-02"
  exit 1
fi
shift 2
for arg in "$@"; do
  case "$arg" in
    --plan)  MODE="plan" ;;
    --no-clean) KEEP_CREDS=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

TF_DIR="${ROOT_DIR}/terraform"
ENV_DIR="${ROOT_DIR}/deploy/${ENV}"
CONFIG_FILE=""
for f in "${ENV_DIR}"/vm-${VM_NAME}_*.tfvars; do
  [ -f "$f" ] && CONFIG_FILE="$f"
done

if [ -z "$CONFIG_FILE" ]; then
  error "No config file found for '${VM_NAME}' in deploy/${ENV}/"
  echo "  Expected: deploy/${ENV}/vm-${VM_NAME}_<ip>.tfvars"
  echo "  Generate one with: ./scripts/create-vm-config.sh ${VM_NAME} ${ENV}"
  exit 1
fi

info "VM config: ${CONFIG_FILE}"

# ─── Auto-normalize vm_configs key to match the VM name ──────────────────
# The for_each map KEY inside vm_configs must equal the VM name, because the
# -target flag uses module.vm["<name>"]. When a config is copied and only the
# hostname changed, the key still points at the old VM → Terraform reports
# "No changes". Detect the mismatch and fix key + annotation + hostname here.
CONFIG_KEY="$(grep -E '^[[:space:]]+[a-zA-Z0-9_-]+[[:space:]]*=[[:space:]]*\{' "$CONFIG_FILE" | head -n1 | sed -E 's/^[[:space:]]*([a-zA-Z0-9_-]+).*/\1/')"

if [ -n "$CONFIG_KEY" ] && [ "$CONFIG_KEY" != "$VM_NAME" ]; then
  warn "Config key is '${CONFIG_KEY}' but VM name is '${VM_NAME}' — auto-fixing key + annotation + hostname"
  sed -i \
    -e "s/^\([[:space:]]*\)${CONFIG_KEY}\([[:space:]]*=[[:space:]]*{\)/\1${VM_NAME}\2/" \
    -e "s/^\([[:space:]]*\)annotation[[:space:]]*=[[:space:]]*\"[^\"]*\"/\1annotation = \"${VM_NAME} Server\"/" \
    -e "s/^\([[:space:]]*hostname[[:space:]]*=[[:space:]]*\"\)[^\"]*/\1${VM_NAME}/" \
    "$CONFIG_FILE"
  info "Auto-fixed: vm_configs key '${CONFIG_KEY}' → '${VM_NAME}' in $(basename "$CONFIG_FILE")"
fi

# ─── Assemble combined config (all VMs present) ──────────────────────────
# Header + top-level vars come from the target VM's file (env-shared).
# Then merge the vm_configs entry of EVERY per-VM file across ALL envs
# (dev, staging, prod). This is required because there is a SINGLE shared
# Terraform state: a VM missing from config would be scheduled for destroy.
COMBINED="${ENV_DIR}/.deploy-combined.tfvars"
{
  # everything before "vm_configs = {" (header + top-level vars)
  sed -n '1,/^vm_configs = {$/p' "$CONFIG_FILE" | grep -v '^vm_configs'
  echo "vm_configs = {"
  for f in "${ROOT_DIR}"/deploy/*/vm-*.tfvars; do
    [ -f "$f" ] || continue
    # extract the entry body between "vm_configs = {" and the closing "}"
    sed -n '/^vm_configs = {$/,/^}/p' "$f" | tail -n +2 | head -n -1
  done
  echo "}"
} > "$COMBINED"

N=$(grep -cE '^[[:space:]]+[a-zA-Z0-9_-]+ = \{' "$COMBINED" || true)
info "Combined config: ${N} VM entry/ies (all present, none destroyed)"

# ─── Credentials ──────────────────────────────────────────────────────────
DECRYPT_SCRIPT="${SCRIPT_DIR}/sops-decrypt.sh"
[ -f "$DECRYPT_SCRIPT" ] || { error "Missing: ${DECRYPT_SCRIPT}"; exit 1; }
bash "$DECRYPT_SCRIPT" "$ENV"

cleanup() {
  rm -f "$COMBINED"
  bash "$DECRYPT_SCRIPT" "$ENV" --clean
}
trap 'cleanup' EXIT

# ─── Terraform ────────────────────────────────────────────────────────────
VAR_FILE="${COMBINED#${ROOT_DIR}/}"
[ -z "${VAR_FILE##deploy/*}" ] && VAR_FILE="../${VAR_FILE}"

# Target the VM module only. IPAM resolution is done from the config files
# (source of truth) by next_free_ip.sh — no persist-file resources to target.
TARGETS=(
  "module.vm[\"${VM_NAME}\"]"
)

TARGET_ARGS=()
for t in "${TARGETS[@]}"; do
  TARGET_ARGS+=( -target="$t" )
done

if [ "$MODE" = "plan" ]; then
  info "Planning: ${VM_NAME}"
  terraform -chdir="$TF_DIR" plan \
    -var-file="${VAR_FILE}" "${TARGET_ARGS[@]}"
else
  info "Applying: ${VM_NAME}"
  terraform -chdir="$TF_DIR" apply -auto-approve \
    -var-file="${VAR_FILE}" "${TARGET_ARGS[@]}"
  ok "Done: ${VM_NAME} deployed"

  # ─── Print hostname + IP ────────────────────────────────────────
  # Source of truth = the per-VM config file's ip_address (deploy-vm.sh
  # updates it + renames the file after apply). No .<vm>_ip persist file.
  ASSIGNED_IP="$(grep -oE 'ip_address[[:space:]]*=[[:space:]]*"[0-9.]+"' "$CONFIG_FILE" | grep -oE '[0-9.]+' | head -n1 || true)"
  echo ""
  echo "=================================================="
  echo "  VM: ${VM_NAME}"
  echo "  IP: ${ASSIGNED_IP:-<not assigned yet — check: terraform output vm_ip_addresses>}"
  echo "  SSH: ssh ubuntu@${ASSIGNED_IP:-<ip>}"
  echo "=================================================="

  # ─── Update config file with the actual assigned IP ────────────────
  # The IPAM assigns the next free IP at apply time; reflect that back in
  # the per-VM config (ip_address + filename) so the file stays in sync
  # with reality and future deploys/renews pick the same IP via skip_ip.
  if [ -n "$ASSIGNED_IP" ]; then
    CUR_IP="$(grep -oE 'ip_address[[:space:]]*=[[:space:]]*"[0-9.]+"' "$CONFIG_FILE" | grep -oE '[0-9.]+' | head -n1 || true)"
    if [ -n "$CUR_IP" ] && [ "$CUR_IP" != "$ASSIGNED_IP" ]; then
      sed -i "s/^\([[:space:]]*ip_address[[:space:]]*=[[:space:]]*\"\)[0-9.]*/\1${ASSIGNED_IP}/" "$CONFIG_FILE"
      ok "Config ip_address updated: ${CUR_IP} → ${ASSIGNED_IP}"
    fi
    BASE="$(basename "$CONFIG_FILE")"
    EXPECTED="vm-${VM_NAME}_${ASSIGNED_IP}.tfvars"
    if [ "$BASE" != "$EXPECTED" ]; then
      NEW_FILE="$(dirname "$CONFIG_FILE")/${EXPECTED}"
      mv "$CONFIG_FILE" "$NEW_FILE"
      info "Config file renamed: ${BASE} → ${EXPECTED}"
      CONFIG_FILE="$NEW_FILE"
    fi
  fi
fi

if $KEEP_CREDS; then
  trap - EXIT
  warn "Decrypted credentials kept: ${TF_DIR}/*.auto.tfvars"
  echo "  Run cleanup: ./scripts/sops-decrypt.sh ${ENV} --clean"
fi
