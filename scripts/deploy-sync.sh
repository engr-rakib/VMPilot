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
#            Drops a per-VM config file into deploy/<server>/<vcenter>/<env>/ → this
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
#   ./scripts/deploy-sync.sh <vcenter> <env> --vm NAME # ONLY this VM (prod-safe:
#     other VMs untouched, R5 skipped)
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
vmpilot_banner

VCENTER="${1:-}"
ENV="${2:-}"
MODE="apply"
ONLY_VM=""
if [ $# -gt 2 ]; then
  shift 2
  while [ $# -gt 0 ]; do
    case "${1:-}" in
      --plan|plan|--list|list) MODE="$(echo "$1" | sed 's/^--//')" ;;
      --vm) ONLY_VM="${2:-}"; [ $# -ge 2 ] && shift ;;
      --vm=*) ONLY_VM="${1#--vm=}" ;;
      *) warn "ignoring unknown arg: $1" ;;
    esac
    shift || true
  done
fi

if [ -z "$VCENTER" ] || [ -z "$ENV" ]; then
  die "Usage: $0 <vcenter> <env> [--plan|--list] [--vm NAME]"
fi
if [ -n "$ONLY_VM" ]; then
  info "Scoped sync: ONLY '${ONLY_VM}' — other VMs untouched (no R5 scan)"
fi

TF_DIR="${ROOT_DIR}/terraform"
# Nested layout: secure/<srv>/<vc>/ + deploy/<srv>/<vc>/ (tolerant reads).
vdir_for() {
  local _r="${ROOT_DIR:-.}"; if [ -d "${_r}/$1/${2##*_}/$2" ]; then echo "$1/${2##*_}/$2"; else echo "$1/$2"; fi
}
ENV_DIR="${ROOT_DIR}/$(vdir_for deploy "$VCENTER")/${ENV}"
# Runtime per-env state (markers, IP memory — under .cache/state, not tfvars).
state_dir_for "$VCENTER" "$ENV" "$ENV_DIR"
# Env-wide lifecycle log: sync owns an ENVIRONMENT, not a single VM, so its run
# history is .pipeline-env.log. Without PIPELINE_LOG every deploy-sync marker
# went to stdout only — fine for a WebUI job (its job log captures stdout), but
# a CLI `deploy-sync.sh` run left NO trace at all, so the WebUI could not show
# it. Same contract as the per-VM logs (see lib/common.sh pipeline_log_header).
pipeline_log_for "$VCENTER" "$ENV" "env" "$ENV_DIR"
pipeline_log_header "deploy-sync $VCENTER $ENV env"
# Full run output into the shared log (WebUI imports this slice for CLI runs).
pipeline_tee_on

[ -d "$ENV_DIR" ] || die "Env dir not found: ${ENV_DIR}"

# Per-vCenter+env state file — isolates each vCenter+env's VMs.
STATE_FILE="${TF_DIR}/terraform.${VCENTER}.${ENV}.tfstate"

# ─── Read tracked VMs from state ───────────────────────────────────────────
STATE_LIST="$(terraform -chdir="$TF_DIR" state list -state="$STATE_FILE" 2>/dev/null || true)"
tracked_vm() {
  echo "$STATE_LIST" | grep -E '^module\.vm\["' | sed -E 's/^module\.vm\["([^"]+)"\].*/\1/' | sort -u
}

# ─── Gather per-VM config info ─────────────────────────────────────────────
# One file per VM: deploy/<server>/<vcenter>/<env>/vm-<hostname>_<ip>.tfvars
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
echo "  Sync scan: $(vdir_for deploy "$VCENTER")/${ENV}/  (mode: ${MODE})"
echo "=========================================================="

CHANGED=0
SKIPPED=0
MISSING_CFG=0
FAILED=""
FAILED_N=0
pstep deploy-sync scan start

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
  # Scoped mode: R5 is env-wide by nature — skip it entirely (zero touch).
  [ -n "$ONLY_VM" ] && continue
  CFG_FOUND=false
  for file in "${ENV_DIR}"/vm-*.tfvars; do
    [ -f "$file" ] || continue
    if grep -qE "^[[:space:]]*${vm}[[:space:]]*=[[:space:]]*\{[[:space:]]*$" "$file" 2>/dev/null; then
      CFG_FOUND=true; break
    fi
  done
  if [ "$CFG_FOUND" = false ]; then
    if [ -z "${CFG_KEY[$vm]:-}" ]; then
      if [ -n "$VCENTER_VMS" ] && ! grep -qE "/$(printf '%s' "$vm" | sed 's/[^a-zA-Z0-9_-]/\\&/g')$" <<< "$VCENTER_VMS"; then
        if [ "$MODE" = "apply" ]; then
          warn "R5: VM '${vm}' not in vCenter and has no config — removing from state (stale entry)."
          terraform -chdir="$TF_DIR" state rm -state="$STATE_FILE" \
            "module.vm[\"${vm}\"].vsphere_virtual_machine.this" \
            "data.external.next_free_ip[\"${vm}\"]" \
            >/dev/null 2>&1 || true
          pstep deploy-sync vm-untrack done "${vm}"
        else
          info "R5 (dry-run): VM '${vm}' not in vCenter and has no config — would remove from state."
          pstep deploy-sync vm-untrack skip "${vm}"
        fi
        MISSING_CFG=1
      elif [ -n "$VCENTER_VMS" ]; then
        warn "R5: VM '${vm}' is in state + vCenter but has no config file — recreate its config or run destroy."
        pstep deploy-sync vm-orphan skip "${vm}"
      fi
    fi
  fi
done

pstep deploy-sync scan done "${#CFG_KEY[@]}-configs"

# ─── R1/R2/R3: iterate config files ───────────────────────────────────────
# R3 needs the last-APPLIED IP (.cache/state/<vc>/<env>/.last-ip-<vm>, written by deploy-vm post-apply).
# State outputs report null for guestinfo-set IPs, and comparing the file to
# itself always "matches" (the old dead-code bug) — the marker file is truth.
for host in "${!CFG_KEY[@]}"; do
  # Scoped mode: only this VM is reconciled — the rest of the env is untouched.
  if [ -n "$ONLY_VM" ] && [ "$host" != "$ONLY_VM" ]; then continue; fi
  file="${CFG_FILE[$host]}"
  want_ip="${CFG_IP[$host]}"
  tracked_ip=""
  if [ -f "${STATE_DIR}/.last-ip-${host}" ]; then
    tracked_ip="$(head -n1 "${STATE_DIR}/.last-ip-${host}" 2>/dev/null | tr -d ' \t\r\n' || true)"
  fi
  [ "$tracked_ip" = "null" ] && tracked_ip=""

  if grep -q '^module\.vm\["'$host'"\]' <<< "$STATE_LIST"; then
    # VM already tracked — but a hardening-failure marker means it is
    # UNHARDENED: never R2-skip, fall through to R3 retry instead.
    if [ -f "${STATE_DIR}/.hardening-${host}.failed" ]; then
      info "R3 retry: ${host}  (previous hardening failed — retrying deploy + hardening)"
      [ "$MODE" = "plan" ] || pstep deploy-sync vm-retry start "${host}"
    elif [ -n "$tracked_ip" ] && [ "$tracked_ip" = "$want_ip" ]; then
      info "R2 skip: ${host}  (ip ${tracked_ip} unchanged)"
      pstep deploy-sync vm-skip done "${host}"
      SKIPPED=$((SKIPPED + 1))
      continue
    elif [ -z "$tracked_ip" ]; then
      # Legacy (pre-marker) tracked VM: adopt the current file IP as baseline
      # instead of redeploying the fleet once — future edits ARE detected.
      echo "$want_ip" > "${STATE_DIR}/.last-ip-${host}" 2>/dev/null || true
      chmod 666 "${STATE_DIR}/.last-ip-${host}" 2>/dev/null || true
      info "R2 skip: ${host}  (baseline adopted: ${want_ip})"
      pstep deploy-sync vm-skip done "${host}"
      SKIPPED=$((SKIPPED + 1))
      continue
    else
      info "R3 deploy: ${host}  (ip ${tracked_ip} → ${want_ip})"
      [ "$MODE" = "plan" ] || pstep deploy-sync vm-deploy start "${host}"
    fi
  else
    info "R1 deploy: ${host}  (new VM, next free IP)"
    [ "$MODE" = "plan" ] || pstep deploy-sync vm-deploy start "${host}"
  fi

  # Completeness gate (all modes incl. list-preview): a skeleton config
  # (empty ip/cluster/template/datastore/network) can never deploy — skip
  # with a clear marker instead of burning minutes in terraform.
  _incomplete=""
  for _k in ip_address cluster template datastore network; do
    if ! grep -qE "^[[:space:]]*${_k}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$file" 2>/dev/null; then
      _incomplete="${_incomplete} ${_k}"
    fi
  done
  if [ -n "$_incomplete" ]; then
    warn "R0 skip: ${host} (incomplete config, missing:${_incomplete} — finish it first, no deploy attempted)"
    pstep deploy-sync vm-incomplete skip "${host}"
    [ "$MODE" = "plan" ] && pstep deploy-sync vm-plan skip "${host}-incomplete"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  CHANGED=$((CHANGED + 1))

  if [ "$MODE" = "plan" ]; then pstep deploy-sync vm-plan start "${host}"; fi

  if [ "$MODE" = "list" ]; then
    continue
  fi

  if [ "$MODE" = "plan" ]; then
    if bash "${SCRIPT_DIR}/deploy-vm.sh" "$VCENTER" "$ENV" "$host" --plan; then
      pstep deploy-sync vm-plan done "${host}"
    else
      _drc=$?
      warn "plan failed for ${host} (rc=${_drc}) — continuing with remaining VMs"
      pstep deploy-sync vm-plan fail "${host}-rc=${_drc}"
      FAILED="${FAILED} ${host}(rc=${_drc})"
      FAILED_N=$((FAILED_N + 1))
    fi
  else
    # A deploy that exits 3 (hardening failed) must NOT abort the loop —
    # record it and continue; the summary below fails loudly instead.
    if bash "${SCRIPT_DIR}/deploy-vm.sh" "$VCENTER" "$ENV" "$host"; then
      rm -f "${STATE_DIR}/.hardening-${host}.failed" 2>/dev/null || true
      pstep deploy-sync vm-deploy done "${host}"
    else
      _drc=$?
      warn "deploy failed for ${host} (rc=${_drc}) — continuing with remaining VMs"
      pstep deploy-sync vm-deploy fail "${host}-rc=${_drc}"
      FAILED="${FAILED} ${host}(rc=${_drc})"
      FAILED_N=$((FAILED_N + 1))
    fi
  fi
done

echo ""
echo "=========================================================="
echo "  Sync done: ${CHANGED} changed, ${SKIPPED} unchanged, ${MISSING_CFG} missing-config warning(s), ${FAILED_N} failed"
[ "$FAILED_N" -gt 0 ] && echo "  Failed:${FAILED}"
echo "=========================================================="

if [ "$FAILED_N" -gt 0 ]; then
  error "sync finished with ${FAILED_N} failure(s) — fix above, then re-run"
  pstep deploy-sync pipeline fail "${FAILED_N}-failed"
  exit 1
fi
pstep deploy-sync pipeline done "${CHANGED}-changed"

if [ "$MISSING_CFG" -eq 1 ] && [ "$MODE" = "apply" ]; then
  echo "NOTE: some VMs are in state but have no config file — run destroy.sh explicitly if you want them gone."
fi
