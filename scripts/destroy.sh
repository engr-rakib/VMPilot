#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
set -euo pipefail

# ===========================================================================
# Script   : destroy.sh
# Path     : scripts/destroy.sh   (relative to project root)
# ---------------------------------------------------------------------------
# Purpose  : SAFE, explicit destroy of ONE VM. Nothing disappears by accident.
#
#            README §9 — safe destroy = remove from Terraform state, then
#            remove the VM in vCenter (govc). Both steps are done here, guarded:
#
#              W4  Terraform state rm      → the VM is orphaned (no plan/destroy)
#              W5  govc vm.destroy         → the VM is deleted in vCenter
#
#            Before any change the state file is backed up, and every
#            destructive action requires typing DESTROY (interactive) or
#            passing --yes (the web console shows its own typed confirm first).
#
# Usage
# ───────────────────────────────────────────────────────────────────────────
#   ./scripts/destroy.sh <vcenter> <env> <vm-name>            # interactive
#   ./scripts/destroy.sh <vcenter> <env> <vm-name> --yes      # non-interactive
#   ./scripts/destroy.sh <vcenter> <env> <vm-name> --plan     # dry-run preview
#   ./scripts/destroy.sh <vcenter> <env> <vm-name> --keep-config  # keep tfvars
#   ./scripts/destroy.sh <vcenter> <env> <vm-name> --no-clean      # keep creds
#
#   Example:
#     ./scripts/destroy.sh dc_pilot_192.0.2.10 dev web-02 --yes
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
vmpilot_banner

VCENTER="${1:-}"
ENV="${2:-}"
VM_NAME="${3:-}"
MODE="apply"
ASSUME_YES=false
KEEP_CONFIG=false
KEEP_CREDS=false

if [ -z "$VCENTER" ] || [ -z "$ENV" ] || [ -z "$VM_NAME" ]; then
  echo "Usage: $0 <vcenter> <env> <vm-name> [--plan|--yes|--keep-config|--no-clean]"
  echo "  $0 dc_pilot_192.0.2.10 dev web-02 --yes"
  exit 1
fi
shift 3
for arg in "$@"; do
  case "$arg" in
    --plan)          MODE="plan" ;;
    --yes)           ASSUME_YES=true ;;
    --keep-config)   KEEP_CONFIG=true ;;
    --no-clean)      KEEP_CREDS=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

TF_DIR="${ROOT_DIR}/terraform"
# Nested layout: secure/<srv>/<vc>/ + deploy/<srv>/<vc>/ (tolerant reads).
vdir_for() {
  local _r="${ROOT_DIR:-.}"; if [ -d "${_r}/$1/${2##*_}/$2" ]; then echo "$1/${2##*_}/$2"; else echo "$1/$2"; fi
}
ENV_DIR="${ROOT_DIR}/$(vdir_for deploy "$VCENTER")/${ENV}"
# Per-VM pipeline log (same file deploy-vm.sh appends to — full history).
# Header is written after the existence check below (no litter for ghosts).
PIPELINE_LOG="${ENV_DIR}/.pipeline-${VM_NAME}.log"
STATE_FILE="${TF_DIR}/terraform.${VCENTER}.${ENV}.tfstate"
CONFIG_FILE=""
for f in "${ENV_DIR}"/vm-${VM_NAME}_*.tfvars; do
  [ -f "$f" ] && CONFIG_FILE="$f"
done

[ -f "$STATE_FILE" ] || die "State file not found: terraform/$(basename "$STATE_FILE")"

# ─── Confirm the VM is actually tracked in state ──────────────────────────
VM_RESOURCE='module.vm["'"${VM_NAME}"'"].vsphere_virtual_machine.this'
IPAM_RESOURCE='data.external.next_free_ip["'"${VM_NAME}"'"]'
TRACKED="$(terraform -chdir="$TF_DIR" state list -state="${STATE_FILE}" 2>/dev/null | grep -E "module\.vm\[\"${VM_NAME}\"\]" || true)"
if [ -z "$TRACKED" ] && [ -z "$CONFIG_FILE" ]; then
  die "VM '${VM_NAME}' is not in state and has no config file — nothing to destroy."
fi
pipeline_log_header "destroy $VCENTER $ENV $VM_NAME"

echo ""
echo "=========================================================="
echo "  SAFE DESTROY — ${VM_NAME}"
echo "  vCenter : ${VCENTER}"
echo "  Env     : ${ENV}"
echo "  State   : terraform/$(basename "${STATE_FILE}")"
echo "  Config  : ${CONFIG_FILE:-<none>}"
echo "=========================================================="
if [ -n "$TRACKED" ]; then
  echo "  Tracked resources:"
  echo "$TRACKED" | sed 's/^/    /'
else
  echo "  (not in Terraform state — only vCenter removal applies)"
fi

# ─── Confirm / dry-run ────────────────────────────────────────────────────
if [ "$MODE" = "plan" ]; then
  echo ""
  warn "DRY RUN — no changes made. Would:"
  [ -n "$TRACKED" ] && { echo "  1. Backup state file"; echo "  2. Remove ${VM_RESOURCE#module.vm[\"]} from Terraform state"; }
  echo "  3. govc vm.destroy \"${VM_NAME}\" in vCenter"
  [ -n "$CONFIG_FILE" ] && [ "$KEEP_CONFIG" = false ] && echo "  4. Delete config file: ${CONFIG_FILE#${ROOT_DIR}/}"
  echo ""
  pstep destroy pipeline skip "plan-mode"
  exit 0
fi

if [ "$ASSUME_YES" = false ]; then
  echo ""
  echo -e "${RED}${BOLD}  This is DESTRUCTIVE — the VM will be REMOVED from vCenter.${NC}"
  read -rp "$(echo -e "${YELLOW}Type DESTROY to confirm: ${NC}")" ack
  if [ "$ack" != "DESTROY" ]; then
    info "Cancelled."
    pstep destroy pipeline skip "cancelled"
    exit 0
  fi
  [ -n "$CONFIG_FILE" ] && [ "$KEEP_CONFIG" = false ] && \
    read -rp "$(echo -e "${YELLOW}Also delete the config file? ${NC}(y/N): ")" delcfg && \
    [[ "$delcfg" =~ ^[Yy] ]] || KEEP_CONFIG=true
fi

# ─── Step 0: backup the state file ────────────────────────────────────────
if [ -n "$TRACKED" ]; then
  BACKUP_DIR="${ROOT_DIR}/backups"
  mkdir -p "$BACKUP_DIR"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  STATE_BACKUP="${BACKUP_DIR}/pre-destroy-${VCENTER}-${ENV}-${VM_NAME}-${STAMP}.tfstate"
  cp "$STATE_FILE" "$STATE_BACKUP"
  ok "State backed up: $(basename "${STATE_BACKUP}")"
  pstep destroy state-backup done
fi

# ─── Step 1: destroy the VM in vCenter via govc FIRST ─────────────────────
# State-rm comes AFTER verify-gone: if govc fails, the state entry (and the
# backup) still describe reality — no orphaned live VM. Never delete
# state-adjacent files while the VM may still exist.
DECRYPT_SCRIPT="${SCRIPT_DIR}/sops-decrypt.sh"
[ -f "$DECRYPT_SCRIPT" ] || { error "Missing: ${DECRYPT_SCRIPT}"; exit 1; }

cleanup() {
  if [ "$KEEP_CREDS" = false ]; then
    bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV" --clean >/dev/null 2>&1 || true
  fi
}
trap 'cleanup' EXIT

bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV" >/dev/null

CRED_FILE="${TF_DIR}/credentials.auto.tfvars"
if [ -f "$CRED_FILE" ]; then
  GOVC_URL="$(sed -n 's/^vsphere_server[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$CRED_FILE" | head -n1)"
  GOVC_USERNAME="$(sed -n 's/^vsphere_user[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$CRED_FILE" | head -n1)"
  GOVC_PASSWORD="$(sed -n 's/^vsphere_password[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$CRED_FILE" | head -n1)"
else
  warn "No decrypted credentials — check secure/<server>/<vcenter>/credentials.tfvars (or the platform store)"
fi

if [ -n "${GOVC_URL:-}" ] && [ -n "${GOVC_USERNAME:-}" ] && [ -n "${GOVC_PASSWORD:-}" ]; then
  info "Destroying VM in vCenter: ${VM_NAME}"
  export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE=1 TERM=dumb
  # Multi-DC vCenters need an explicit datacenter scope (else govc refuses
  # with "please specify a datacenter"). Read it from the VM config file.
  if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then
    export GOVC_DATACENTER="$(grep -oE '^datacenter[[:space:]]*=[[:space:]]*"[^"]+"' "$CONFIG_FILE" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
  fi
  # Resolve the bare name to ONE inventory path — never act on an ambiguous
  # name (same-name VM in another folder/DC). 0 or 2+ matches = abort.
  _MATCHES="$(govc find / -type m -name "${VM_NAME}" 2>/dev/null || true)"
  _N="$(echo "$_MATCHES" | grep -c . || true)"
  if [ "$_N" -gt 1 ]; then
    error "Refusing destroy: name '${VM_NAME}' matches ${_N} VMs vCenter-wide (need 0 or 1). Matches:$(echo "$_MATCHES" | sed 's/^/\n  /')"
    pstep destroy vcenter-destroy fail "ambiguous-name"
    unset GOVC_PASSWORD GOVC_URL GOVC_USERNAME GOVC_DATACENTER
    exit 1
  fi
  if [ "$_N" = "0" ]; then
    # Already gone from vCenter (stale state or never deployed): nothing to
    # destroy — continue to state-rm + config handling below.
    warn "VM '${VM_NAME}' not found in vCenter — treating as already gone."
    pstep destroy vcenter-destroy skip "already-gone"
    unset GOVC_PASSWORD GOVC_URL GOVC_USERNAME GOVC_DATACENTER
  else
  _VMPATH="$(echo "$_MATCHES" | head -n1)"
  info "Target (fingerprint):"
  govc vm.info -e "$_VMPATH" 2>/dev/null | grep -E "(Name|Power state|IP address|Host|Memory|CPU):" | sed 's/^/    /' || true
  pstep destroy resolve done "${_VMPATH##*/vm/}"
  if govc vm.destroy "$_VMPATH" 2>/dev/null; then
    ok "VM destroyed: ${VM_NAME}"
  else
    warn "govc vm.destroy reported a problem — verifying whether ${VM_NAME} is really gone…"
  fi
  # Never delete state-adjacent files while the VM still exists: verify gone.
  if govc find / -type m -name "${VM_NAME}" 2>/dev/null | grep -q .; then
    error "VM '${VM_NAME}' STILL EXISTS in vCenter — destroy failed. State + config KEPT. Fix vCenter first, then re-run."
    pstep destroy vcenter-destroy fail "still-exists"
    unset GOVC_PASSWORD GOVC_URL GOVC_USERNAME GOVC_DATACENTER
    exit 1
  fi
  ok "Verified gone from vCenter: ${VM_NAME}"
  pstep destroy vcenter-destroy done
  unset GOVC_PASSWORD GOVC_URL GOVC_USERNAME GOVC_DATACENTER
  fi
else
  # No credentials = cannot verify anything: ABORT before touching state or
  # config (previously the script deleted the config while the VM still ran).
  error "Cannot destroy without credentials — state + config KEPT. Decrypt creds and re-run."
  pstep destroy vcenter-destroy skip "no-creds"
  pstep destroy pipeline fail "no-creds-abort"
  exit 1
fi

# ─── Step 2: remove from Terraform state (VM is verifiably gone) ───────────
if [ -n "$TRACKED" ]; then
  ok "Removing from Terraform state: module.vm[\"${VM_NAME}\"]"
  terraform -chdir="$TF_DIR" state rm -state="${STATE_FILE}" \
    "${VM_RESOURCE}" ${IPAM_RESOURCE} >/dev/null 2>&1 || \
    terraform -chdir="$TF_DIR" state rm -state="${STATE_FILE}" "${VM_RESOURCE}" >/dev/null
  ok "Removed from state."
  pstep destroy state-rm done
fi

# ─── Step 3: remove the per-VM config file (unless kept) ──────────────────
if [ -n "$CONFIG_FILE" ] && [ "$KEEP_CONFIG" = false ]; then
  rm -f "$CONFIG_FILE"
  ok "Config file removed: ${CONFIG_FILE#${ROOT_DIR}/}"
  pstep destroy config-delete done
elif [ -n "$CONFIG_FILE" ]; then
  warn "Config kept: ${CONFIG_FILE#${ROOT_DIR}/} — deploy-sync will redeploy it (R1)."
  pstep destroy config-delete skip "kept"
  pstep destroy config-delete skip "kept"
fi

echo ""
echo "=========================================================="
ok "Destroy complete: ${VM_NAME}"
pstep destroy pipeline done
echo "  (restore from a pre-destroy state file under backups/ if needed)"
echo "=========================================================="

if $KEEP_CREDS; then
  trap - EXIT
  warn "Decrypted credentials kept: ${TF_DIR}/*.auto.tfvars"
  echo "  Run cleanup: ./scripts/sops-decrypt.sh ${VCENTER} ${ENV} --clean"
fi