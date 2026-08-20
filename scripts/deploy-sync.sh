#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
set -euo pipefail

# ===========================================================================
# Script   : deploy-sync.sh
# Path     : scripts/deploy-sync.sh   (relative to project root)
# ---------------------------------------------------------------------------
# Purpose  : Auto-deploy loop that satisfies REQUIREMENTS.md.
#
#            Drops a per-VM config file into deploy/<vcenter>/<env>/ → this
#            script notices it and deploys that ONE VM (other VMs untouched).
#
# Behavior (per config file found):
#   R1  New hostname not in state       → deploy (IPAM assigns next free IP)
#   R2  hostname + IP both unchanged    → skip  (no-op, nothing redeployed)
#   R3  hostname changed / IP changed   → deploy (next free IP auto-assigned)
#   R4  for_each key forced to hostname → handled inside deploy-vm.sh
#   R5  state-tracked VM whose config file is missing → NOT destroyed,
#       surfaced as a warning/error instead.
#   R6  Idempotent: unchanged VMs skipped on every run.
#
# Usage
# ───────────────────────────────────────────────────────────────────────────
#   ./scripts/deploy-sync.sh <vcenter> <env>       # scan + deploy new/changed
#   ./scripts/deploy-sync.sh <vcenter> <env> --plan   # dry-run (plan each)
#   ./scripts/deploy-sync.sh <vcenter> <env> --list   # only show the diff table
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
vmpilot_banner

VCENTER="${1:-}"
ENV="${2:-}"
MODE="apply"
[ $# -gt 2 ] && MODE="${3#--}"

if [ -z "$VCENTER" ] || [ -z "$ENV" ]; then
  die "Usage: $0 <vcenter> <env> [--plan|--list]"
fi

TF_DIR="${ROOT_DIR}/terraform"
ENV_DIR="${ROOT_DIR}/deploy/${VCENTER}/${ENV}"

[ -d "$ENV_DIR" ] || die "Env dir not found: ${ENV_DIR}"

# Per-vCenter+env state file — isolates each vCenter+env's VMs.
STATE_FILE="${TF_DIR}/terraform.${VCENTER}.${ENV}.tfstate"

# ─── Read tracked VMs from state ───────────────────────────────────────────
STATE_LIST="$(terraform -chdir="$TF_DIR" state list -state="$STATE_FILE" 2>/dev/null || true)"
tracked_vm() {
  echo "$STATE_LIST" | grep -E '^module\.vm\["' | sed -E 's/^module\.vm\["([^"]+)"\].*/\1/' | sort -u
}

# ─── Gather per-VM config info ─────────────────────────────────────────────
# One file per VM: deploy/<vcenter>/<env>/vm-<hostname>_<ip>.tfvars
# The filename itself shows hostname + IP at a glance.
# key        = for_each key (hostname)           → vm_configs.<key>.hostname
# base_ip    = ip_address base from the file     → scan starts here
declare -A CFG_KEY CFG_IP CFG_FILE
shopt -s nullglob
for file in "${ENV_DIR}"/vm-*.tfvars; do
  [ -f "$file" ] || continue
  key="$(grep -E '^[[:space:]]+[a-zA-Z0-9_-]+[[:space:]]*=[[:space:]]*\{' "$file" \
        | head -n1 | sed -E 's/^[[:space:]]*([a-zA-Z0-9_-]+).*/\1/')"
  host="$(grep -E '^[[:space:]]*hostname[[:space:]]*=' "$file" | head -n1 \
          | sed -E 's/.*"([^"]+)".*/\1/')"
  ip="$(grep -E '^[[:space:]]*ip_address[[:space:]]*=' "$file" | head -n1 \
        | sed -E 's/.*"([0-9.]+)".*/\1/')"
  [ -n "$key" ] || key="$host"
  CFG_KEY["$key"]="$key"
  CFG_IP["$key"]="${ip:-}"
  CFG_FILE["$key"]="$file"
done

echo ""
echo "=========================================================="
echo "  Sync scan: deploy/${VCENTER}/${ENV}/  (mode: ${MODE})"
echo "=========================================================="

CHANGED=0
SKIPPED=0
MISSING_CFG=0

# ─── R5: state-tracked VMs whose config is missing ────────────────────────
# If the VM is gone from vCenter too, the state entry is stale → remove it
# so Terraform never plans a destroy for a VM that no longer exists.
# If the VM still exists in vCenter, keep state and warn (config lost).
GOVC_CMD="govc"
if command -v "$GOVC_CMD" &>/dev/null && [ -n "${GOVC_URL:-}" ]; then
  VCENTER_VMS="$(govc find -type m 2>/dev/null || true)"
else
  VCENTER_VMS=""
  warn "govc / GOVC_URL not set — skipping vCenter reconciliation"
fi

for vm in $(tracked_vm); do
  CFG_FOUND=false
  for file in "${ENV_DIR}"/vm-*.tfvars; do
    [ -f "$file" ] || continue
    if grep -qE "^[[:space:]]*${vm}[[:space:]]*=[[:space:]]*\{[[:space:]]*$" "$file" 2>/dev/null; then
      CFG_FOUND=true; break
    fi
  done
  if [ "$CFG_FOUND" = false ]; then
    if [ -z "${CFG_KEY[$vm]:-}" ]; then
      if [ -n "$VCENTER_VMS" ] && ! grep -qE "/${vm}$" <<< "$VCENTER_VMS"; then
        warn "R5: VM '${vm}' not in vCenter and has no config — removing from state (stale entry)."
        terraform -chdir="$TF_DIR" state rm -state="$STATE_FILE" \
          "module.vm[\"${vm}\"].vsphere_virtual_machine.this" \
          "data.external.next_free_ip[\"${vm}\"]" \
          >/dev/null 2>&1 || true
        MISSING_CFG=1
      elif [ -n "$VCENTER_VMS" ]; then
        warn "R5: VM '${vm}' is in state + vCenter but has no config file — recreate its config or run destroy."
      fi
    fi
  fi
done

# ─── R1/R2/R3: iterate config files ───────────────────────────────────────
for host in "${!CFG_KEY[@]}"; do
  file="${CFG_FILE[$host]}"
  want_ip="${CFG_IP[$host]}"
  tracked_ip=""
  # Reserved IPs come from the config files themselves (source of truth).
  [ -n "$want_ip" ] && tracked_ip="$want_ip"

  if grep -q '^module\.vm\["'$host'"\]' <<< "$STATE_LIST"; then
    # VM already tracked
    if [ -n "$tracked_ip" ] && [ "$tracked_ip" = "$want_ip" ]; then
      info "R2 skip: ${host}  (ip ${tracked_ip} unchanged)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    info "R3 deploy: ${host}  (ip ${want_ip:-?} → next free)"
  else
    info "R1 deploy: ${host}  (new VM, next free IP)"
  fi

  CHANGED=$((CHANGED + 1))

  if [ "$MODE" = "list" ]; then
    continue
  fi

  if [ "$MODE" = "plan" ]; then
    bash "${SCRIPT_DIR}/deploy-vm.sh" "$VCENTER" "$ENV" "$host" --plan || true
  else
    bash "${SCRIPT_DIR}/deploy-vm.sh" "$VCENTER" "$ENV" "$host"
  fi
done

echo ""
echo "=========================================================="
echo "  Sync done: ${CHANGED} changed, ${SKIPPED} unchanged, ${MISSING_CFG} missing-config warning(s)"
echo "=========================================================="

if [ "$MISSING_CFG" -eq 1 ] && [ "$MODE" = "apply" ]; then
  echo "NOTE: some VMs are in state but have no config file — run destroy.sh explicitly if you want them gone."
fi
