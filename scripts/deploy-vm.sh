#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
set -euo pipefail

# ===========================================================================
# Script   : deploy-vm.sh
# Path     : scripts/deploy-vm.sh   (relative to project root)
# ---------------------------------------------------------------------------
# Purpose  : Deploy / redeploy ONE VM, leaving all other VMs in the same
#            state completely untouched.
#
# Usage
# ───────────────────────────────────────────────────────────────────────────
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name>          # apply (auto-approve)
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name> --plan   # plan only
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name> --no-sync  # skip policy re-sync
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name> --no-clean  # keep decrypted .auto.tfvars
#
#   Example:
#     ./scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-02
#
#   Policy re-sync (default ON): before deploying, the target config is compared
#   against secure/<vcenter>/vcenter.tfvars + secure/<vcenter>/<env>/vcenter.tfvars.
#   If a key set in those files differs from the per-VM file, the policy value
#   is applied (VM-owned keys — hostname/ip/cpu/ram/disks/partitions/ssh — are
#   never touched). --plan previews the drift; --no-sync deploys the file as-is.
#
#   How it works:
#     1. Finds deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars for the requested VM.
#        (filename shows hostname + IP at a glance)
#     2. Assembles a temporary combined config (top-level vars from this
#        VM's file + the vm_configs entry of EVERY per-VM file in THIS env).
#        Each vCenter+env combo has its OWN state
#        (terraform/terraform.<vcenter>.<env>.tfstate), so other envs —
#        possibly on a different vCenter — are never merged in and a VM is
#        never seen as "missing from config".
#     3. Decrypts credentials → terraform/*.auto.tfvars
#     4. Runs: terraform apply -var-file=<combined> -target='module.vm["<name>"]'
#     5. Cleans up decrypted files + the temp combined config (unless --no-clean)
#
#   The -target flag limits the operation to exactly one VM. Because every
#   VM is still present in the combined config, no other VM is destroyed.
#
#   IPAM: the per-VM file is the source of truth for the IP. No separate
#   .<vm>_ip persist file is used — next_free_ip.sh reads the per-VM files
#   directly to know which IPs are already in use.
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
vmpilot_banner

VCENTER="${1:-}"
ENV="${2:-}"
VM_NAME="${3:-}"
MODE="apply"
KEEP_CREDS=false

if [ -z "$VCENTER" ] || [ -z "$ENV" ] || [ -z "$VM_NAME" ]; then
  echo "Usage: $0 <vcenter> <env> <vm-name> [--plan|--no-clean]"
  echo "  $0 dc_pilot_192.0.2.10 dev web-02"
  exit 1
fi
shift 3
RESYNC="auto"   # auto (apply policy on drift) | plan (preview) | off
for arg in "$@"; do
  case "$arg" in
    --plan)       MODE="plan"; RESYNC="plan" ;;
    --no-clean)   KEEP_CREDS=true ;;
    --no-sync)    RESYNC="off" ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

TF_DIR="${ROOT_DIR}/terraform"
ENV_DIR="${ROOT_DIR}/deploy/${VCENTER}/${ENV}"
CONFIG_FILE=""
for f in "${ENV_DIR}"/vm-${VM_NAME}_*.tfvars; do
  [ -f "$f" ] && CONFIG_FILE="$f"
done

if [ -z "$CONFIG_FILE" ]; then
  error "No config file found for '${VM_NAME}' in deploy/${VCENTER}/${ENV}/"
  echo "  Expected: deploy/${VCENTER}/${ENV}/vm-${VM_NAME}_<ip>.tfvars"
  echo "  Generate one with: ./scripts/create-vm-config.sh ${VCENTER} ${ENV} ${VM_NAME}"
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

# ─── Deploy-time policy re-sync ───────────────────────────────────────────
# Single source of truth for placement decisions:
#   secure/<vc>/vcenter.tfvars       (top-level policy)
#   secure/<vc>/<env>/vcenter.tfvars (per-env override — WINS)
# At deploy time we re-apply current policy onto the per-VM file so a change
# to the common file propagates to existing VMs automatically (no per-VM edit).
# VM-owned keys (hostname/ip/cpu/ram/disks/partitions/ssh/annotation + the
# filename) are NEVER touched. Keys the policy files don't set are left alone.
POLICY_VAL=""; declare -A POLICY_DATA=()
# POLICY = ONLY the per-env file (secure/<vc>/<env>/vcenter.tfvars). The
# top-level secure/<vc>/vcenter.tfvars is INVENTORY (defaults + network_subnets
# the create-wizard reads); it is NOT policy and is never force-applied here.
# Per-env policy is applied to every VM config in deploy/<vc>/<env>.
load_policy_files() {
  local _e="${ROOT_DIR}/secure/${VCENTER}/${ENV}/vcenter.tfvars"
  [ -f "$_e" ] && read_policy_file "$_e"
}
read_policy_file() {
  local f="$1" _k _v _line
  set +e
  # scalar string/number keys
  while IFS= read -r _line; do
    _k="$(sed -E 's/^[[:space:]]*([a-z_]+)[[:space:]]*=.*/\1/' <<< "$_line")"
    _v="$(sed -E 's/^[[:space:]]*[a-z_]+[[:space:]]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' <<< "$_line")"
    [ -n "$_k" ] && [ -n "$_v" ] && POLICY_DATA["$_k"]="$_v"
  done < <(grep -E '^(datacenter|cluster|resource_pool|datastore|network|template|host|domain|gateway|netmask|ipam_base_ip)[[:space:]]*=' "$f")
  # list keys → only a SINGLE-element list is a force/pin (e.g. one network, one
  # datastore). Multiple values = interactive menu restriction → leave unset so
  # the VM snapshot keeps its value (no guessing which one to apply).
  for _k in clusters templates datastores networks resource_pools dns_servers; do
    _v="$(grep -E "^${_k}[[:space:]]*=" "$f" | head -1 | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep -v '^[[:space:]]*$')"
    _cnt=$(printf '%s\n' "$_v" | grep -c . || true)
    [ "$_cnt" -eq 1 ] && POLICY_DATA["$_k"]="$_v"
  done
  set -e -o pipefail
}

policy_get() {  # policy_get media_key → value or ""
  local media="$1" scalar
  case "$media" in
    cluster)       scalar="${POLICY_DATA[cluster]:-}" ; [ -n "$scalar" ] && { echo "$scalar"; return; }; echo "${POLICY_DATA[clusters]:-}" ;;
    template)      scalar="${POLICY_DATA[template]:-}"; [ -n "$scalar" ] && { echo "$scalar"; return; }; echo "${POLICY_DATA[templates]:-}" ;;
    datastore)     scalar="${POLICY_DATA[datastore]:-}"; [ -n "$scalar" ] && { echo "$scalar"; return; }; echo "${POLICY_DATA[datastores]:-}" ;;
    network)       scalar="${POLICY_DATA[network]:-}"  ; [ -n "$scalar" ] && { echo "$scalar"; return; }; echo "${POLICY_DATA[networks]:-}" ;;
    resource_pool) scalar="${POLICY_DATA[resource_pool]:-}"; [ -n "$scalar" ] && { echo "$scalar"; return; }; echo "${POLICY_DATA[resource_pools]:-}" ;;
    dns)           echo "${POLICY_DATA[dns_servers]:-}" ;;
    *)             echo "${POLICY_DATA[${media}]:-}" ;;
  esac
}

# Keys declared in the POLICY file's network_subnets map (port-group names AND
# host names). When a VM sits on such a network, its gateway/netmask/dns come
# from THAT per-network entry — the top-level vcenter.tfvars gateway is only a
# vCenter-wide DEFAULT and must NOT be force-applied onto it.
POLICY_SUBNET_KEYS=""
load_policy_subnet_keys() {
  local _e="${ROOT_DIR}/secure/${VCENTER}/${ENV}/vcenter.tfvars"
  POLICY_SUBNET_KEYS=""
  [ -f "$_e" ] || return 0
  while IFS= read -r _line; do
    [[ "$_line" =~ ^[[:space:]]*# ]] && continue
    _k=$(grep -oE '^[[:space:]]*"[^"]+"[[:space:]]*=' <<< "$_line" | head -1 | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')
    [ -n "$_k" ] && POLICY_SUBNET_KEYS+=" $_k "
  done < <(sed -n '/^network_subnets[[:space:]]*=/,/^}/p' "$_e")
}

# True when the VM's chosen network OR pinned host is a network_subnets key.
cfg_on_policy_subnet() {
  local net host
  net="$(cfg_topval network)"
  host="$(cfg_innerval host)"
  { [ -n "$net" ] && case " $POLICY_SUBNET_KEYS " in *" $net "*) return 0 ;; esac; } 2>/dev/null
  { [ -n "$host" ] && case " $POLICY_SUBNET_KEYS " in *" $host "*) return 0 ;; esac; } 2>/dev/null
  return 1
}

# Read a top-level scalar from the config file (before vm_configs block).
cfg_topval() {
  local med="$1"
  sed -n '1,/^vm_configs[[:space:]]*=/{/^'"${med}"'[[:space:]]*=/p}' "$CONFIG_FILE" \
    | sed -E 's/^[[:space:]]*[a-z_]+[[:space:]]*=[[:space:]]*"?([^"#]*)"?.*/\1/' | tr -d ' '
}
# Read a key from inside the vm_configs.<name> block.
cfg_innerval() {
  local med="$1"
  awk -v med="$med" -v name="$VM_NAME" '
    $0 ~ "^[[:space:]]*" name "[[:space:]]*=[[:space:]]*\\{" { inblk=1 }
    inblk && $0 ~ "^[[:space:]]*" med "[[:space:]]*=" {
      sub(/^[[:space:]]*[a-z_]+[[:space:]]*=[[:space:]]*/, "");
      gsub(/"/, ""); gsub(/[[:space:]#].*/, "");
      print; exit
    }
    inblk && /^[[:space:]]*\}/ { exit }
  ' "$CONFIG_FILE"
}
# Does the key line exist inside the VM block at all (even if value is empty)?
cfg_innerval_key_exists() {
  local med="$1"
  awk -v med="$med" -v name="$VM_NAME" '
    $0 ~ "^[[:space:]]*" name "[[:space:]]*=[[:space:]]*\\{" { inblk=1 }
    inblk && $0 ~ "^[[:space:]]*" med "[[:space:]]*=" { found=1; exit }
    inblk && /^[[:space:]]*\}/ { exit }
    END { exit (found ? 0 : 1) }
  ' "$CONFIG_FILE"
}

apply_policy_resync() {
  load_policy_files
  [ "${#POLICY_DATA[@]}" -eq 0 ] && return 0

  local -a CHANGES=()
  local -A NEWVAL=()
  local med pol cur
  # top-level placement keys
  for med in datacenter cluster datastore network template resource_pool; do
    pol="$(policy_get "$med")"
    [ -n "$pol" ] || continue
    cur="$(cfg_topval "$med")"
    if [ -n "$cur" ] && [ "$cur" != "$pol" ]; then
      NEWVAL["top:$med"]="$pol"; CHANGES+=("$med: $cur → $pol")
    fi
  done
  # ipam_base_ip top-level
  pol="$(policy_get ipam_base_ip)"; [ -n "$pol" ] || pol="${POLICY_DATA[ipam_base_ip]:-}"
  if [ -n "$pol" ]; then
    cur="$(cfg_topval ipam_base_ip)"
    [ -n "$cur" ] && [ "$cur" != "$pol" ] \
      && { NEWVAL["top:ipam_base_ip"]="$pol"; CHANGES+=("ipam_base_ip: $cur → $pol"); }
  fi
  # VM-block policy keys
  # gateway/netmask/dns are per-network values — if the VM sits on a
  # network_subnets network (port-group or host key), its gateway/netmask/dns
  # are NOT overridden by the top-level vCenter-wide default.
  load_policy_subnet_keys
  if cfg_on_policy_subnet; then
    local _nonet=true
  else
    local _nonet=false
  fi
  for med in host domain; do
    pol="$(policy_get "$med")"; [ -n "$pol" ] || continue
    if cfg_innerval_key_exists "$med"; then
      cur="$(cfg_innerval "$med")"
      [ "$cur" != "$pol" ] && { NEWVAL["in:$med"]="$pol"; CHANGES+=("${med}: ${cur:-<empty>} → $pol"); }
    fi
  done
  if [ "$_nonet" = true ]; then
    for med in gateway netmask; do
      pol="$(policy_get "$med")"; [ -n "$pol" ] || continue
      if cfg_innerval_key_exists "$med"; then
        cur="$(cfg_innerval "$med")"
        [ "$cur" != "$pol" ] && { NEWVAL["in:$med"]="$pol"; CHANGES+=("${med}: ${cur:-<empty>} → $pol"); }
      fi
    done
  fi
  # dns_servers (list form inside the VM block)
  pol="$(policy_get dns)"; [ -n "$pol" ] || pol="${POLICY_DATA[dns_servers]:-}"
  if [ "$_nonet" = true ] && [ -n "$pol" ] && cfg_innerval_key_exists dns_servers; then
    cur="$(cfg_innerval dns_servers)"
    if [ "$cur" != "$pol" ]; then
      NEWVAL["in:dns_servers"]="$pol"; CHANGES+=("dns_servers: ${cur:-<empty>} → $pol")
    fi
  fi

  [ "${#CHANGES[@]}" -eq 0 ] && return 0

  echo ""
  warn "vm-${VM_NAME} config is out of policy (secure/${VCENTER}/${ENV}/vcenter.tfvars):"
  for c in "${CHANGES[@]}"; do echo "    $c"; done

  if [ "$RESYNC" = "plan" ]; then
    info "  [--plan] not applying — run without --plan to re-sync and deploy."
    echo ""
    return 0
  fi

  # Apply: rewrite only changed policy keys, preserving everything else.
  local tmp="${CONFIG_FILE}.rsync"
  awk -v name="$VM_NAME" \
      -v t_dc="${NEWVAL[top:datacenter]:-}" \
      -v t_cl="${NEWVAL[top:cluster]:-}" \
      -v t_ds="${NEWVAL[top:datastore]:-}" \
      -v t_nw="${NEWVAL[top:network]:-}" \
      -v t_tp="${NEWVAL[top:template]:-}" \
      -v t_rp="${NEWVAL[top:resource_pool]:-}" \
      -v t_ip="${NEWVAL[top:ipam_base_ip]:-}" \
      -v i_host="${NEWVAL[in:host]:-}" \
      -v i_domain="${NEWVAL[in:domain]:-}" \
      -v i_gw="${NEWVAL[in:gateway]:-}" \
      -v i_nm="${NEWVAL[in:netmask]:-}" \
      -v i_dns="${NEWVAL[in:dns_servers]:-}" \
    '
    BEGIN { incfg=0; inblk=0; }
    /^vm_configs[[:space:]]*=/ { incfg=1 }
    {
      if (!incfg) {
        if (t_dc != "" && $0 ~ /^datacenter[[:space:]]*=/)          sub(/=.*/, "= \"" t_dc "\"");
        else if (t_cl != "" && $0 ~ /^cluster[[:space:]]*=/)        sub(/=.*/, "= \"" t_cl "\"");
        else if (t_ds != "" && $0 ~ /^datastore[[:space:]]*=/)      sub(/=.*/, "= \"" t_ds "\"");
        else if (t_nw != "" && $0 ~ /^network[[:space:]]*=/)        sub(/=.*/, "= \"" t_nw "\"");
        else if (t_tp != "" && $0 ~ /^template[[:space:]]*=/)       sub(/=.*/, "= \"" t_tp "\"");
        else if (t_rp != "" && $0 ~ /^resource_pool[[:space:]]*=/)  sub(/=.*/, "= \"" t_rp "\"");
        else if (t_ip != "" && $0 ~ /^ipam_base_ip[[:space:]]*=/)   sub(/=.*/, "= \"" t_ip "\"");
        print
        next
      }
      if ($0 ~ "^[[:space:]]*" name "[[:space:]]*=[[:space:]]*\\{") inblk=1
      if (inblk) {
        if (i_host != "" && $0 ~ /^[[:space:]]*host[[:space:]]*=/)         sub(/=.*/, "= \"" i_host "\"");
        else if (i_domain != "" && $0 ~ /^[[:space:]]*domain[[:space:]]*=/){ sub(/=.*/, "= \"" i_domain "\""); }
        else if (i_gw != "" && $0 ~ /^[[:space:]]*gateway[[:space:]]*=/)   sub(/=.*/, "= \"" i_gw "\"");
        else if (i_nm != "" && $0 ~ /^[[:space:]]*netmask[[:space:]]*=/)   sub(/=.*/, "= " i_nm);
        else if (i_dns != "" && $0 ~ /^[[:space:]]*dns_servers[[:space:]]*=/) sub(/=.*/, "= [\"" i_dns "\"]");
      }
      if (inblk && /^[[:space:]]*\}/) inblk=0
      print
    }
  ' "$CONFIG_FILE" > "$tmp"

  # confirm awk exits clean and the block shape is preserved, then apply
  if [ -s "$tmp" ] && [ "$(grep -cE '^vm_configs[[:space:]]*=[[:space:]]*\{' "$tmp" || true)" = "1" ] \
     && [ "$(grep -cE '^\}$' "$tmp" || true)" = "1" ]; then
    mv "$tmp" "$CONFIG_FILE"
    ok "Policy applied → $(basename "$CONFIG_FILE") (VM-owned keys untouched)"
  else
    err "Re-sync produced an invalid file — NOT applied. Fix secure/${VCENTER}/${ENV}/vcenter.tfvars."
    rm -f "$tmp"
  fi
  echo ""
}

if [ "$RESYNC" != "off" ] && [ -d "${ROOT_DIR}/secure/${VCENTER}" ]; then
  apply_policy_resync
fi

# ─── Assemble combined config (all VMs of THIS env present) ─────────────
# Header + top-level vars come from the target VM's file (vCenter-shared).
# Then merge the vm_configs entry of EVERY per-VM file in THIS env only.
# Each vCenter+env has its OWN Terraform state
# (terraform/terraform.<vcenter>.<env>.tfstate), so other envs' VMs
# (possibly on a different vCenter) are never merged in.
#
# Blending guard: before merging, every per-VM file is validated for a
# well-formed vm_configs block. A broken file fails fast with a clear
# message — it can never silently corrupt the combined config used to
# deploy another VM.
COMBINED="${ENV_DIR}/.deploy-combined.tfvars"
{
  # everything before "vm_configs = {" (header + top-level vars)
  sed -n '1,/^vm_configs = {$/p' "$CONFIG_FILE" | grep -v '^vm_configs'
  echo "vm_configs = {"
  for f in "${ENV_DIR}"/vm-*.tfvars; do
    [ -f "$f" ] || continue
    # validate: exactly one "vm_configs = {" opener AND one closing "}" at col 0
    _OPEN=$(grep -cE '^vm_configs[[:space:]]*=[[:space:]]*\{' "$f" || true)
    _CLOSE=$(grep -cE '^\}$' "$f" || true)
    if [ "$_OPEN" != "1" ] || [ "$_CLOSE" != "1" ]; then
      error "Broken VM config: ${f#${ROOT_DIR}/}"
      echo "  Expected exactly one 'vm_configs = {' and one closing '}'. Found: ${_OPEN} opener(s), ${_CLOSE} closer(s)."
      echo "  Fix this file first — it would corrupt the combined config used to deploy ${VM_NAME}."
      exit 1
    fi
    # extract the entry body between "vm_configs = {" and the closing "}"
    sed -n '/^vm_configs = {$/,/^}$/p' "$f" | tail -n +2 | head -n -1
  done
  echo "}"
} > "$COMBINED"

N=$(grep -cE '^[[:space:]]+[a-zA-Z0-9_-]+ = \{' "$COMBINED" || true)
info "Combined config: ${N} VM entry/ies (vcenter '${VCENTER}', env '${ENV}', own state)"
info "VMs in combined config:"
VM_LIST=""
for f in "${ENV_DIR}"/vm-*.tfvars; do
  [ -f "$f" ] || continue
  k=$(grep -oE '^[[:space:]]{2}[a-zA-Z0-9_-]+' "$f" | head -n1 | tr -d ' \t')
  [ -n "$k" ] && VM_LIST+="${VM_LIST:+,}${k}"
done
echo "  ${VCENTER}/${ENV}: ${VM_LIST:-<none>}"
echo "  --> targeting ONLY: ${VM_NAME}"

# ─── Credentials ──────────────────────────────────────────────────────────
DECRYPT_SCRIPT="${SCRIPT_DIR}/sops-decrypt.sh"
[ -f "$DECRYPT_SCRIPT" ] || { error "Missing: ${DECRYPT_SCRIPT}"; exit 1; }
bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV"

cleanup() {
  rm -f "$COMBINED"
  bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV" --clean
}
trap 'cleanup' EXIT

# ─── Terraform ────────────────────────────────────────────────────────────
VAR_FILE="${COMBINED#${ROOT_DIR}/}"
[ -z "${VAR_FILE##deploy/*}" ] && VAR_FILE="../${VAR_FILE}"

# User-group policy (OS access per group). Loaded if present — an extra
# -var-file so terraform's `user_groups` map comes straight from the policy
# layer. Absent file → terraform falls back to empty map → module uses legacy
# full-sudo.
ROLES_FILE="${ROOT_DIR}/secure/${VCENTER}/${ENV}/user-groups.tfvars"
ROLES_ARGS=()
if [ -f "$ROLES_FILE" ]; then
  ROLES_VAR="${ROLES_FILE#${ROOT_DIR}/}"
  [ -z "${ROLES_VAR##secure/*}" ] && ROLES_VAR="../${ROLES_VAR}"
  ROLES_ARGS+=( -var-file="${ROLES_VAR}" )
  info "User-group policy: ${ROLES_VAR}"
fi

# Per-vCenter+env state: terraform/terraform.<vcenter>.<env>.tfstate —
# isolates VMs per vCenter+env, so each combo can target a DIFFERENT vCenter
# without state conflicts.
STATE_FILE="${TF_DIR}/terraform.${VCENTER}.${ENV}.tfstate"
info "State file: ${STATE_FILE#${ROOT_DIR}/}"

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
    -state="${STATE_FILE}" \
    -var-file="${VAR_FILE}" "${ROLES_ARGS[@]}" "${TARGET_ARGS[@]}"
else
  info "Applying: ${VM_NAME}"
  terraform -chdir="$TF_DIR" apply -auto-approve \
    -state="${STATE_FILE}" \
    -var-file="${VAR_FILE}" "${ROLES_ARGS[@]}" "${TARGET_ARGS[@]}"
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
      # Replace only the ip_address line inside this VM's entry block.
      awk -v name="${VM_NAME}" -v newip="${ASSIGNED_IP}" '
        $0 ~ "^[[:space:]]*" name "[[:space:]]*=[[:space:]]*\\{" { inblock=1 }
        inblock && /ip_address[[:space:]]*=/ { sub(/"[0-9.]+"/, "\"" newip "\""); print; next }
        inblock && /^[[:space:]]*\}/ { inblock=0 }
        { print }
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
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
  echo "  Run cleanup: ./scripts/sops-decrypt.sh ${VCENTER} ${ENV} --clean"
fi
