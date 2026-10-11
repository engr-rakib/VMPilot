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
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name> --no-lan   # leave NICs disconnected
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name> --lan-up   # connect NICs + wait IP only
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name> --no-clean  # keep decrypted .auto.tfvars
#   ./scripts/deploy-vm.sh <vcenter> <env> <vm-name> --pipeline # show this VM's pipeline history
#
# Exit codes: 0 = deployed + LAN + hardening OK · 1 = error · 3 = VM deployed
# but HARDENING FAILED (marker deploy/<srv>/<vc>/<env>/.hardening-<vm>.failed;
# retry with --lan-up; deploy-sync R2 never skips marked VMs).
#   Example:
#     ./scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-02
#
#   Policy re-sync (default ON): before deploying, the target config is compared
#   against secure/<server>/<vcenter>/vcenter.tfvars + secure/<server>/<vcenter>/<env>/vcenter.tfvars.
#   If a key set in those files differs from the per-VM file, the policy value
#   is applied (VM-owned keys — hostname/ip/cpu/ram/disks/partitions/ssh — are
#   never touched). --plan previews the drift; --no-sync deploys the file as-is.
#
#   How it works:
#     1. Finds deploy/<server>/<vcenter>/<env>/vm-<name>_<ip>.tfvars for the requested VM.
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
  echo "Usage: $0 <vcenter> <env> <vm-name> [--plan|--no-clean|--no-sync|--no-lan|--lan-up]"
  echo "  $0 dc_pilot_192.0.2.10 dev web-02"
  exit 1
fi
shift 3
RESYNC="auto"   # auto (apply policy on drift) | plan (preview) | off
LANUP_ONLY=false  # --lan-up: skip terraform, just connect NICs + wait IP
NO_LAN=false      # --no-lan: deploy but leave NICs disconnected (LAN up later)
SHOW_PIPE=false   # --pipeline: print this VM's pipeline log and exit
for arg in "$@"; do
  case "$arg" in
    --plan)       MODE="plan"; RESYNC="plan" ;;
    --no-clean)   KEEP_CREDS=true ;;
    --no-sync)    RESYNC="off" ;;
    --lan-up)     LANUP_ONLY=true ;;
    --no-lan)     NO_LAN=true ;;
    --pipeline)   SHOW_PIPE=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

TF_DIR="${ROOT_DIR}/terraform"
# Nested layout: secure/<srv>/<vc>/ + deploy/<srv>/<vc>/ (tolerant reads).
vdir_for() {
  local _r="${ROOT_DIR:-.}"; if [ -d "${_r}/$1/${2##*_}/$2" ]; then echo "$1/${2##*_}/$2"; else echo "$1/$2"; fi
}
ENV_DIR="${ROOT_DIR}/$(vdir_for deploy "$VCENTER")/${ENV}"
# Per-VM pipeline log: EVERY STEP marker of EVERY run appends here (host-side
# lifecycle history). CLI: --pipeline prints it; UI parses the same lines.
PIPELINE_LOG="${ENV_DIR}/.pipeline-${VM_NAME}.log"
if [ "$SHOW_PIPE" = true ]; then
  if [ -f "$PIPELINE_LOG" ]; then
    grep -a ":: STEP" "$PIPELINE_LOG" | tail -60
  else
    echo "no pipeline history yet for ${VM_NAME} (runs here after the first deploy)"
  fi
  exit 0
fi
CONFIG_FILE=""
for f in "${ENV_DIR}"/vm-${VM_NAME}_*.tfvars; do
  [ -f "$f" ] && CONFIG_FILE="$f"
done

if [ -z "$CONFIG_FILE" ]; then
  error "No config file found for '${VM_NAME}' in $(vdir_for deploy "$VCENTER")/${ENV}/"
  echo "  Expected: $(vdir_for deploy "$VCENTER")/${ENV}/vm-${VM_NAME}_<ip>.tfvars"
  echo "  Generate one with: ./scripts/create-vm-config.sh ${VCENTER} ${ENV} ${VM_NAME}"
  exit 1
fi
pipeline_log_header "deploy-vm $VCENTER $ENV $VM_NAME"

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
#   secure/<srv>/<vc>/vcenter.tfvars       (top-level policy)
#   secure/<srv>/<vc>/<env>/vcenter.tfvars (per-env override — WINS)
# At deploy time we re-apply current policy onto the per-VM file so a change
# to the common file propagates to existing VMs automatically (no per-VM edit).
# VM-owned keys (hostname/ip/cpu/ram/disks/partitions/ssh/annotation + the
# filename) are NEVER touched. Keys the policy files don't set are left alone.
POLICY_VAL=""; declare -A POLICY_DATA=()
# POLICY = ONLY the per-env file (secure/<srv>/<vc>/<env>/vcenter.tfvars). The
# top-level secure/<srv>/<vc>/vcenter.tfvars is INVENTORY (defaults + network_subnets
# the create-wizard reads); it is NOT policy and is never force-applied here.
# Per-env policy is applied to every VM config in deploy/<srv>/<vc>/<env>.
load_policy_files() {
  local _e="${ROOT_DIR}/$(vdir_for secure "$VCENTER")/${ENV}/vcenter.tfvars"
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
  local _e="${ROOT_DIR}/$(vdir_for secure "$VCENTER")/${ENV}/vcenter.tfvars"
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

  if [ "${#CHANGES[@]}" -eq 0 ]; then pstep deploy-vm resync skip "in-policy"; return 0; fi

  echo ""
  warn "vm-${VM_NAME} config is out of policy ($(vdir_for secure "$VCENTER")/${ENV}/vcenter.tfvars):"
  for c in "${CHANGES[@]}"; do echo "    $c"; done

  if [ "$RESYNC" = "plan" ]; then
    info "  [--plan] not applying — run without --plan to re-sync and deploy."
    echo ""
    pstep deploy-vm resync skip "plan-mode"
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
    pstep deploy-vm resync done
  else
    err "Re-sync produced an invalid file — NOT applied. Fix $(vdir_for secure "$VCENTER")/${ENV}/vcenter.tfvars."
    rm -f "$tmp"
    pstep deploy-vm resync fail "invalid-file"
  fi
  echo ""
}

if [ "$RESYNC" != "off" ] && [ -d "${ROOT_DIR}/$(vdir_for secure "$VCENTER")" ]; then
  apply_policy_resync
fi

# ─── Assemble combined config (all VMs of THIS env present) ─────────────
# Header + top-level vars come from the target VM's file (vCenter-shared).
# ─── Hardening profile (3-tier policy) ────────────────────────────────────
# Tier 1 template (binaries) + Tier 2 DC baseline
# (secure/<srv>/<vc>/hardening.tfvars) + Tier 3 env overwrite
# (secure/<srv>/<vc>/<env>/hardening.tfvars, per-KEY win). Unset keys fall
# back to module defaults. prod env guardrails are ENFORCED below.
# (operator hardening scripts concatenate below — no backend mapping.)

# Hardening script (operator-owned, verbatim): DC baseline
# (secure/<srv>/<vc>/hardening.sh) + env extras
# (secure/<srv>/<vc>/<env>/hardening.sh) appended in order. `${` escaped to
# `$${` so the terraform heredoc renders it back untouched.
build_hardening_script() {
  local _d="${ROOT_DIR}/$(vdir_for secure "$VCENTER")" _f _content=""
  # DC file always applies when present; env file applies ONLY when it
  # differs (a fresh env seed is byte-identical to the DC file — running both
  # would duplicate every step).
  for _f in "${_d}/hardening.sh" "${_d}/${ENV}/hardening.sh"; do
    [ -f "$_f" ] || continue
    if [ "$_f" != "${_d}/hardening.sh" ] && cmp -s "$_f" "${_d}/hardening.sh"; then continue; fi
    # inactive policy (comments/blank only) contributes nothing — skip loudly.
    # NOTE: info goes to STDERR here: this builder runs inside the
    # `{ ... } > COMBINED` group, so stdout would corrupt the tfvars file.
    if ! grep -qEv "^[[:space:]]*(#|$)" "$_f"; then info "hardening ${_f#${ROOT_DIR}/}: inactive - skipped" >&2; continue; fi
    # per-file ON/OFF switch: ENABLED=false short-circuits the whole file —
    # evaluate per file (DC and env decide independently).
    if grep -qE "^ENABLED=" "$_f" && ! grep -qE "^ENABLED=\"true\"" "$_f"; then info "hardening ${_f#${ROOT_DIR}/}: DISABLED by switch - skipped" >&2; continue; fi
    _content+="$(cat "$_f")"$'\n'
  done
  printf 'hardening_script = <<EOT_HARDEN\n%s\nEOT_HARDEN\n' "$(printf '%s' "$_content" | sed 's/\${/$${/g')"
}

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
  # operator hardening script (DC + env concatenated, terraform-escaped)
  build_hardening_script
} > "$COMBINED"

N=$(grep -cE '^[[:space:]]+[a-zA-Z0-9_-]+ = \{' "$COMBINED" || true)
info "Combined config: ${N} VM entry/ies (vcenter '${VCENTER}', env '${ENV}', own state)"
  pstep deploy-vm config done "${N}-entries"
info "VMs in combined config:"
VM_LIST=""
for f in "${ENV_DIR}"/vm-*.tfvars; do
  [ -f "$f" ] || continue
  k=$(grep -oE '^[[:space:]]{2}[a-zA-Z0-9_-]+' "$f" | head -n1 | tr -d ' \t')
  [ -n "$k" ] && VM_LIST+="${VM_LIST:+,}${k}"
done
echo "  ${VCENTER}/${ENV}: ${VM_LIST:-<none>}"
echo "  --> targeting ONLY: ${VM_NAME}"

# ─── LAN up (last step) ───────────────────────────────────────────────────
# VMs boot with the NIC cable DISCONNECTED (fast boot: nothing waits on the
# network — needs the template's "Connect at power on" OFF, one-time vCenter
# step). LAN goes up ONLY when the guest is fully ready: power on + VMware
# Tools running (checked via govc, no network needed) → connect every
# ethernet NIC → wait guest IPv4 → confirm cloud-init done over SSH.
# Auto-runs after apply; --no-lan skips it; --lan-up runs ONLY this.
lan_up() {
  local _tf="${ROOT_DIR}/terraform/credentials.auto.tfvars"
  # Exit contract: 0 = LAN + hardening OK; 3 = VM up but hardening FAILED
  # (marker .hardening-<vm>.failed). Callers must propagate, not swallow.
  _HARDEN_FAILED=0
  [ -f "$_tf" ] || { warn "no decrypted creds (${_tf}) — run sops-decrypt first"; return 1; }
  command -v govc >/dev/null || { warn "govc missing — connect NICs by hand in vCenter"; return 1; }
  command -v jq >/dev/null || { warn "jq missing — connect NICs by hand in vCenter"; return 1; }
  export GOVC_URL="$(grep -oP 'vsphere_server\s*=\s*"\K[^"]+' "$_tf" | head -1)"
  export GOVC_USERNAME="$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' "$_tf" | head -1)"
  export GOVC_PASSWORD="$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' "$_tf" | head -1)"
  export GOVC_INSECURE=true GOVC_PERSIST_SESSION=false TERM=dumb
  export GOVC_DATACENTER="$(cfg_topval datacenter)"
  # Phase 1: guest fully ready = powered on + Tools running (no network needed
  # for this check — govc talks to the host, not the guest).
  info "LAN: waiting for ${VM_NAME} to be fully ready (power + Tools)…"
  local _i=0 _st=""
  while [ "$_i" -lt 120 ]; do
    _st=$(govc vm.info -json "$VM_NAME" 2>/dev/null \
      | jq -r '[.virtualMachines[]? | "\(.runtime.powerState)/\(.guest.toolsStatus // "none")" ] | join(",")' 2>/dev/null || true)
    case "$_st" in
      *poweredOn/toolsOk*|*poweredOn/toolsOld*) break ;;
    esac
    sleep 5; _i=$((_i+1))
  done
  case "$_st" in
    *poweredOn/toolsOk*|*poweredOn/toolsOld*) ok "Guest ready: ${VM_NAME} (${_st})"; pstep deploy-vm guest-ready done "${_st}" ;;
    *) warn "guest not ready yet (${_st:-unknown}) — connecting LAN anyway (check VM console if IP never appears)" ;;
  esac
  # Phase 1b: ALL offline OS work complete? An offline first boot ends with
  # a clean poweroff (last runcmd step — power state is the signal, no guest
  # writes needed). Online boots never power off: they get an IP instead.
  # Poll BOTH: poweredOff → connect + power on; IPv4 present → normal flow.
  # (--lan-up skips this gate: the operator explicitly asks for connect NOW.)
  if [ "${LANUP_SKIP_GATE:-false}" != true ]; then
  info "LAN: waiting for OS installation to complete…"
  _i=0 _st="" _ip="" _mode=""
  while [ "$_i" -lt 180 ]; do
    _st=$(govc vm.info -json "$VM_NAME" 2>/dev/null \
      | jq -r '.virtualMachines[0].runtime.powerState // empty' 2>/dev/null || true)
    if [ "$_st" = "poweredOff" ]; then _mode="offline"; break; fi
    _ip=$(govc vm.ip -v4 "$VM_NAME" 2>/dev/null || true)
    if [ -n "$_ip" ]; then _mode="online"; break; fi
    sleep 5; _i=$((_i+1))
  done
  if [ "$_mode" = "offline" ]; then
    ok "OS installation complete (powered off clean) — bringing LAN up"
  elif [ "$_mode" = "online" ]; then
    info "guest already has IP ${_ip} (online boot) — ensuring LAN connected"
  else
    warn "no clean signal after 15 min (power=${_st:-unknown}, ip=${_ip:-none}) — connecting LAN anyway"
  fi
  fi
  local _nics _n
  _nics=$(govc device.info -vm "$VM_NAME" -json 2>/dev/null \
    | jq -r '.devices[]? | select(.name // "" | startswith("ethernet-")) | .name' 2>/dev/null || true)
  [ -z "$_nics" ] && _nics=$(govc device.ls -vm "$VM_NAME" 2>/dev/null | grep -oE 'ethernet-[0-9]+' || true)
  [ -n "$_nics" ] || { warn "no NICs found on ${VM_NAME}"; unset GOVC_PASSWORD; return 1; }
  for _n in $_nics; do
    if govc device.connect -vm "$VM_NAME" "$_n" >/dev/null 2>&1; then
      ok "LAN up: ${VM_NAME}/${_n} connected"
      pstep deploy-vm lan-connect done "${_n}"
    else
      info "LAN: ${VM_NAME}/${_n} already connected (nothing to do)"
    fi
  done
  # Offline path left the VM powered off → boot it now (fast second boot:
  # provisioning is done, cloud-init only runs per-boot stages).
  if [ "${_mode:-}" = "offline" ]; then
    govc vm.power -on "$VM_NAME" >/dev/null 2>&1 \
      && ok "Powered on: ${VM_NAME} (second boot, LAN connected)" \
      || warn "power-on failed — start it from vCenter console"
  fi
  local _ip="" _i=0
  while [ "$_i" -lt 60 ]; do
    _ip=$(govc vm.ip -v4 "$VM_NAME" 2>/dev/null || true)
    [ -n "$_ip" ] && break
    sleep 5; _i=$((_i+1))
  done
  if [ -n "$_ip" ]; then ok "Guest IPv4: ${_ip}"; pstep deploy-vm guest-ip done "${_ip}"; else warn "no guest IP yet — cloud-init may still run; retry: govc vm.ip -v4 ${VM_NAME}"; pstep deploy-vm guest-ip fail "timeout"; fi
  # SSH readiness: cloud-init finishes users/ssh AFTER the IP appears
  # (LVM/mkfs can take minutes first) — retry up to 10 min instead of
  # failing cloud-init confirm + hardening on first refusal.
  if [ -n "$_ip" ]; then
    # Fresh clone = new host keys: drop any stale known_hosts entry for this
    # IP, and never consult known_hosts (avoids MITM-fail on recycled IPs).
    ssh-keygen -R "$_ip" >/dev/null 2>&1 || true
    _i=0; _t0=$(date +%s); _last_err=""; _out=""
    while [ "$_i" -lt 40 ]; do
      _out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@${_ip}" "echo SSH-READY" 2>/tmp/lanup-ssherr || true)"
      _last_err="$(head -c 200 /tmp/lanup-ssherr 2>/dev/null || true)"
      case "$_out" in *SSH-READY*) break;; esac
      sleep 15; _i=$((_i+1))
    done
    info "LAN: SSH gate took $(( $(date +%s) - _t0 ))s over $((_i+1)) attempt(s)${_last_err:+; last error: ${_last_err}}"
    pstep deploy-vm ssh-gate done "$((_i+1))-attempts"
  fi
  # Phase 4 (best-effort): confirm cloud-init finished over SSH. Needs the
  # operator's key for ubuntu@IP (agent or ~/.ssh default) — failure here is
  # advisory only; the VM + LAN are already up.
  # Reboot-tolerant: cloud-init's package stage can reboot the guest AFTER
  # first SSH succeeds — a single check then hits a rebooting host. Poll
  # `cloud-init status` (no --wait) so each attempt is quick; SSH failures
  # mean "reboot in progress", retry. Track boot_id to log the reboot.
  if [ -n "$_ip" ]; then
    _SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 ubuntu@${_ip}"
    _boot1="$($_SSH "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
    _ci=""; _j=0; _t1=$(date +%s)
    while [ "$_j" -lt 40 ]; do
      _ci="$($_SSH "cloud-init status 2>/dev/null" 2>/dev/null || true)"
      case "$_ci" in
        *done*) break;;
        *error*) break;;
      esac
      sleep 15; _j=$((_j+1))
    done
    _boot2="$($_SSH "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
    case "$_ci" in
      *done*)
        if [ -n "$_boot1" ] && [ "$_boot1" != "$_boot2" ]; then
          ok "cloud-init done on ${VM_NAME} — fully ready (guest rebooted mid-deploy, took $(( $(date +%s) - _t1 ))s to settle)"
          pstep deploy-vm cloud-init done "rebooted-mid-deploy"
        else
          ok "cloud-init done on ${VM_NAME} — fully ready"
        pstep deploy-vm cloud-init done
        fi
        ;;
      *error*) warn "cloud-init errored on ${VM_NAME}: ${_ci} — check: ssh ubuntu@${_ip} 'cloud-init status --long'";;
      *) info "cloud-init status unconfirmed after $(( $(date +%s) - _t1 ))s (SSH key may differ) — check: ssh ubuntu@${_ip} 'cloud-init status'"; pstep deploy-vm cloud-init fail "unconfirmed";;
    esac
    # Hardening (operator policy): runs HERE, after LAN+IP — never at first
    # boot (offline). Full network available, so apt-backed steps work.
    # VM key exported for the script's common-user provisioning.
    _VMKEY="$(grep -oP 'ssh_public_key\s*=\s*"\K[^"]+' "$CONFIG_FILE" | head -1)"
    # Pre-hardening SSH settle: cloud-init's package stage can reboot the
    # guest even AFTER reporting done — wait for one clean SSH (up to 3 min)
    # before the single 25-min hardening run.
    _h=0
    while [ "$_h" -lt 12 ]; do
      if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@${_ip}" "echo H-READY" 2>/dev/null | grep -q "H-READY"; then break; fi
      sleep 15; _h=$((_h+1))
    done
    if timeout 1500 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@${_ip}" "export VMPILOT_SSH_KEY='${_VMKEY}'; sudo bash -c 'bash /etc/vmpilot/hardening.sh >> /var/log/vmpilot-hardening.log 2>&1'; echo \"HARDEN_RC=\$?\"" 2>/dev/null | grep -q "HARDEN_RC=0"; then
      ok "hardening applied on ${VM_NAME} (see /var/log/vmpilot-hardening.log)"
      pstep deploy-vm hardening done
      rm -f "${ENV_DIR}/.hardening-${VM_NAME}.failed" 2>/dev/null || true
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@${_ip}" "printf '# VMPilot hardening manifest\n# Source: secure/<server>/<vcenter>/hardening.sh (+ <env>/hardening.sh)\ndate: %s\nscript_exit=0\nlog=/var/log/vmpilot-hardening.log\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | sudo tee /etc/vmpilot-hardening.md >/dev/null" 2>/dev/null || true
      # Pipeline checks: surface the guest VERIFY lines in deploy/job output
      # (WebUI jobs display shows these — per-step PASS/FAIL/SKIP).
      echo "  --- hardening pipeline checks (${VM_NAME}) ---"
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@${_ip}" "grep -h '^CHECK ' /var/log/vmpilot-hardening.log 2>/dev/null | tail -20" 2>/dev/null | sed 's/^/  /' || true
      # Guest pipeline steps: provision (cloud-init) + harden markers → deploy
      # output (parsed by the same :: STEP contract) + per-VM pipeline log.
      _GUEST_STEPS="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@${_ip}" "grep -ah ':: STEP' /var/log/cloud-init-output.log /var/log/vmpilot-hardening.log 2>/dev/null | tail -40" 2>/dev/null || true)"
      if [ -n "$_GUEST_STEPS" ]; then
        echo "  --- guest pipeline steps (${VM_NAME}) ---"
        echo "$_GUEST_STEPS" | sed 's/^/  /'
        if [ -n "${PIPELINE_LOG:-}" ]; then
          echo "$_GUEST_STEPS" >> "$PIPELINE_LOG" 2>/dev/null || true
        fi
      fi
      pstep deploy-vm checks done
    else
      warn "hardening unreachable/failed (SSH key?) — run manually: sudo bash /etc/vmpilot/hardening.sh"
      # Host-side status marker: the VM exists but is UNHARDENED. deploy-sync
      # R2 must not treat it as done — clear with: hardening re-run (deploy
      # --lan-up) or manual run, which rm's this file on success.
      date -u +%Y-%m-%dT%H:%M:%SZ > "${ENV_DIR}/.hardening-${VM_NAME}.failed" 2>/dev/null || true
      _HARDEN_FAILED=1
      pstep deploy-vm hardening fail "see-log"
    fi
    # Phase 5 (offline-boot safety): first boot without LAN means cloud-init's
    # apt installs never ran. If the template lacks lvm2/growpart, the LVM
    # expand failed too — detect here (repair = preinstall in template, or
    # apt install + cloud-init clean + reboot this VM).
    _missing="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ubuntu@${_ip}" "for t in lvextend growpart mkfs.xfs mkfs.ext4 pvcreate vgextend; do command -v \$t >/dev/null || echo \$t; done" 2>/dev/null || true)"
    if [ -n "$_missing" ]; then
      warn "guest tools missing on ${VM_NAME}: ${_missing} (first boot was offline)"
      echo "  Fix template (one-time): boot it WITH lan, apt install lvm2 cloud-guest-utils, reseal to template."
      echo "  Repair this VM: ssh ubuntu@${_ip} → sudo apt-get install -y lvm2 cloud-guest-utils && sudo cloud-init clean --logs && sudo reboot"
    fi
  fi
  unset GOVC_PASSWORD GOVC_URL GOVC_USERNAME
  return "${_HARDEN_FAILED:-0}"
}

# ─── Credentials ──────────────────────────────────────────────────────────
# Trap BEFORE decrypt: no window where Ctrl-C leaves plaintext on disk.
# Same trap covers --lan-up (multi-minute SSH waits).
DECRYPT_SCRIPT="${SCRIPT_DIR}/sops-decrypt.sh"
[ -f "$DECRYPT_SCRIPT" ] || { error "Missing: ${DECRYPT_SCRIPT}"; exit 1; }
cleanup() {
  rm -f "${COMBINED:-}" 2>/dev/null || true
  if [ -n "${DECRYPT_SCRIPT:-}" ]; then
    bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV" --clean >/dev/null 2>&1 || true
  fi
}
trap 'cleanup' EXIT
if [ "$LANUP_ONLY" = true ]; then
  LANUP_SKIP_GATE=true
  bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV"
  lan_up; _lan_rc=$?
  bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV" --clean
  if [ "$_lan_rc" = "3" ]; then
    error "LAN is up but hardening FAILED for ${VM_NAME} — marker: ${ENV:-?}/.hardening-${VM_NAME}.failed. Re-run --lan-up after fixing SSH, or run hardening manually."
  fi
  exit "$_lan_rc"
fi
bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV"

# ─── Terraform ────────────────────────────────────────────────────────────
VAR_FILE="${COMBINED#${ROOT_DIR}/}"
[ -z "${VAR_FILE##deploy/*}" ] && VAR_FILE="../${VAR_FILE}"

# User-group policy (OS access per group). Loaded if present — an extra
# -var-file so terraform's `user_groups` map comes straight from the policy
# layer. Absent file → terraform falls back to empty map → module uses legacy
# full-sudo.
ROLES_FILE="${ROOT_DIR}/$(vdir_for secure "$VCENTER")/${ENV}/user-groups.tfvars"
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
  pstep deploy-vm plan start
  terraform -chdir="$TF_DIR" plan \
    -state="${STATE_FILE}" \
    -var-file="${VAR_FILE}" "${ROLES_ARGS[@]}" "${TARGET_ARGS[@]}"
  pstep deploy-vm plan done
else
  # Pre-apply rollback snapshot: state + config, stamped. Rollback =
  # restore both files (commands printed) + `terraform refresh` (or re-apply
  # the previous config). Kept 30 days alongside pre-destroy backups.
  _BKDIR="${ROOT_DIR}/backups"
  mkdir -p "$_BKDIR" 2>/dev/null || true
  _STAMP="$(date +%Y%m%d-%H%M%S)"
  _BKSTATE="${_BKDIR}/pre-deploy-${VCENTER}-${ENV}-${VM_NAME}-${_STAMP}.tfstate"
  _BKCFG="${_BKDIR}/pre-deploy-${VCENTER}-${ENV}-${VM_NAME}-${_STAMP}.tfvars"
  [ -f "$STATE_FILE" ] && cp "$STATE_FILE" "$_BKSTATE" 2>/dev/null || true
  [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$_BKCFG" 2>/dev/null || true
  if [ -f "$_BKSTATE" ] || [ -f "$_BKCFG" ]; then
    info "Rollback snapshot: $(basename "${_BKSTATE:-<no-state>}") + $(basename "${_BKCFG:-<no-config>}")"
    echo "  Rollback: cp backups/<file>.tfstate ${STATE_FILE#${ROOT_DIR}/} && cp backups/<file>.tfvars <config> && terraform -chdir=terraform refresh -state=${STATE_FILE#${ROOT_DIR}/}"
    pstep deploy-vm backup done "${_STAMP}"
  fi
  info "Applying: ${VM_NAME}"
  pstep deploy-vm apply start
  terraform -chdir="$TF_DIR" apply -auto-approve \
    -state="${STATE_FILE}" \
    -var-file="${VAR_FILE}" "${ROLES_ARGS[@]}" "${TARGET_ARGS[@]}"
  ok "Done: ${VM_NAME} deployed"
  pstep deploy-vm apply done

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
  # Also record the last-APPLIED ip (.last-ip-<vm>) — deploy-sync R3 compares
  # the file against THIS (state outputs report null for guestinfo-set IPs).
  if [ -n "$ASSIGNED_IP" ]; then
    echo "$ASSIGNED_IP" > "${ENV_DIR}/.last-ip-${VM_NAME}" 2>/dev/null || true
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
      pstep deploy-vm config-rename done "${EXPECTED}"
    fi
  fi
  # LAN up LAST (fast boot happened disconnected): connect NICs + wait IPv4.
  # Exit 3 = VM deployed + reachable BUT hardening failed (marker file) —
  # CI/jobs/sync treat this as failure so unhardened VMs never pass silent.
  if [ "$NO_LAN" = true ]; then
    info "LAN left disconnected (--no-lan) — bring it up later: bash scripts/deploy-vm.sh ${VCENTER} ${ENV} ${VM_NAME} --lan-up"
    pstep deploy-vm pipeline skip "no-lan"
  else
    if lan_up; then
      ok "LAN + hardening complete: ${VM_NAME}"
      pstep deploy-vm pipeline done
    else
      _lan_rc=$?
      if [ "$_lan_rc" = "3" ]; then
        error "Deployed but HARDENING FAILED: ${VM_NAME} (marker .hardening-${VM_NAME}.failed) — retry: bash scripts/deploy-vm.sh ${VCENTER} ${ENV} ${VM_NAME} --lan-up"
        pstep deploy-vm pipeline fail "hardening-failed"
        exit 3
      fi
      warn "LAN auto-connect had issues (rc=${_lan_rc}) — retry manually (see above)"
    fi
    unset GOVC_PASSWORD GOVC_URL GOVC_USERNAME GOVC_DATACENTER 2>/dev/null || true
  fi
fi

if $KEEP_CREDS; then
  trap - EXIT
  warn "Decrypted credentials kept: ${TF_DIR}/*.auto.tfvars"
  echo "  Run cleanup: ./scripts/sops-decrypt.sh ${VCENTER} ${ENV} --clean"
fi
