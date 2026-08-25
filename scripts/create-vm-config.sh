#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
set -euo pipefail

# ===========================================================================
# Script   : create-vm-config.sh
# Path     : scripts/create-vm-config.sh   (relative to project root)
# ---------------------------------------------------------------------------
# Purpose  : Quickly scaffold a ready-to-use VM config.
#            Asks only essentials (name, env), auto-assigns a free IP, then
#            generates a comprehensive VM entry with ALL options present as
#            commented blocks — uncomment what you need and deploy.
#
# Usage
# ───────────────────────────────────────────────────────────────────────────
#   ./scripts/create-vm-config.sh                    # fully interactive
#   ./scripts/create-vm-config.sh myvm               # name preset
#   ./scripts/create-vm-config.sh <vcenter> <env> myvm   # vCenter + env preset
#
#   Output: deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars  (per-VM config)
#           Existing VMs in the file are never touched.
#           Per-vCenter defaults auto-load from secure/<vcenter>/vcenter.tfvars.
#
#   After generation — review & deploy:
#     vi deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars   # uncomment what you need
#     bash scripts/deploy-vm.sh <vcenter> <env> <name>  # deploy THIS VM only
#
#   Add more VMs by running this script again — each VM gets its own file.
#
# Dependencies
# ───────────────────────────────────────────────────────────────────────────
#   - bash 4+            (for associative arrays)
#   - jq, ping          (for free-IP scan)
#   - terraform         (to apply)
# ===========================================================================
[ "${BASH_VERSINFO:-0}" -lt 4 ] && { echo "Error: bash 4+ required"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
vmpilot_banner

# Command-line presets for automation
BATCH_MODE=false
VCENTER=""
ENV=""
ENV_DIR=""
PRESET_VCENTER=""
PRESET_ENV=""
PRESET_VM_NAME=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --batch|--yes|-y)
      BATCH_MODE=true
      shift
      ;;
    --vcenter=*)
      PRESET_VCENTER="${1#*=}"
      shift
      ;;
    --env=*)
      PRESET_ENV="${1#*=}"
      shift
      ;;
    --vm-name=*)
      PRESET_VM_NAME="${1#*=}"
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"
if [ ${#POSITIONAL[@]} -ge 3 ]; then
  PRESET_VCENTER="${POSITIONAL[0]}"
  PRESET_ENV="${POSITIONAL[1]}"
  PRESET_VM_NAME="${POSITIONAL[2]}"
elif [ ${#POSITIONAL[@]} -eq 1 ]; then
  PRESET_VM_NAME="${POSITIONAL[0]}"
fi

if [ "$BATCH_MODE" = true ]; then
  prompt_required() {
    local var="$1" def="$3"
    local val="${!var:-$def}"
    printf -v "$var" '%s' "$val"
  }
  prompt_optional() {
    local var="$1" def="$3"
    local val="${!var:-$def}"
    printf -v "$var" '%s' "$val"
  }
  confirm() {
    local def="${2:-N}"
    case "${def^^}" in
      Y|YES) return 0 ;;
      *) return 1 ;;
    esac
  }
  prompt_fs() { echo "${1:-xfs}"; }
fi

# ─── Built-in default values (fallback) ───────────────────────────────
# Per-vCenter defaults live at secure/<vcenter>/vm-defaults.conf (gitignored,
# holds the extra-user default password). They are loaded AFTER the vCenter is
# selected and OVERRIDE these built-ins. If the file is missing, these built-in
# values below are used.
: "${DEFAULT_CPU:=2}"
: "${DEFAULT_RAM:=4}"
: "${DEFAULT_FIRMWARE:=efi}"
: "${DEFAULT_CPU_HOT_ADD:=Y}"
: "${DEFAULT_MEM_HOT_ADD:=Y}"
: "${DEFAULT_BOOT_SIZE:=500M}"
: "${DEFAULT_OS_DISK_GB:=40}"
: "${DEFAULT_DATA_DISK:=N}"
: "${DEFAULT_DATA_DISK_GB:=120}"
: "${DEFAULT_DATA_PROVISIONING:=1}"
: "${DEFAULT_EXTRA_USER_PASSWORD:=}"
: "${DEFAULT_DISABLE_AUTO_UPDATES:=Y}"
: "${DEFAULT_SWAP:=N}"
if [ -z "${DEFAULT_MOUNTS[*]:-}" ]; then DEFAULT_MOUNTS=("/:10" "/home:5" "/var:15" "/tmp:2"); fi
# vCenter inventory/network defaults — resolved in load_vcenter_defaults from
# secure/<vc>/vcenter.tfvars. Pre-initialize so the nested ${x:-$DEFAULT_*}
# merges never trip `set -u` when a key is absent from the file.
: "${DEFAULT_DATACENTER:=}"
: "${DEFAULT_CLUSTER:=}"
: "${DEFAULT_RESOURCE_POOL:=}"
: "${DEFAULT_DATASTORE:=}"
: "${DEFAULT_NETWORK:=}"
: "${DEFAULT_TEMPLATE:=}"
: "${DEFAULT_DOMAIN:=}"
: "${DEFAULT_GATEWAY:=}"
: "${DEFAULT_NETMASK:=}"
: "${DEFAULT_BASE_IP:=}"
: "${DEFAULT_DNS:=}"
: "${DEFAULT_IPAM_RESERVE:=30}"

# ===========================================================================
# 1. Quick identity
# ===========================================================================
clear
cat <<'LOGO'
╔══════════════════════════════════════════════════════════════╗
║           VM Config Quick Scaffold                           ║
║   Name + env → OS partitions active, data disk commented     ║
╚══════════════════════════════════════════════════════════════╝
LOGO

while true; do
  prompt_required VM_NAME "VM name (vCenter + hostname)" "${PRESET_VM_NAME:-${DEFAULT_VM_NAME:-myvm}}"
  if [[ "$VM_NAME" =~ \  ]]; then
    warn "VM name e space allowed na! Use hyphen instead (e.g. my-vm)."
  else
    break
  fi
done
VM_NAME="${VM_NAME//_/-}"
ok_inline "Name: ${VM_NAME}"

# vCenter + environment
# Layout: deploy/<vcenter>/<env>/vm-*.tfvars ; creds/inventory in secure/<vcenter>/.
# A vCenter = a secure/<vcenter>/ dir holding credentials.tfvars + vcenter.tfvars
# (the real configured identity). deploy/<vcenter>/ is where VM configs live.
# Only vCenters that exist in secure/ are offered — stale deploy/ dirs (leftover
# test setups) are never listed.
info "vCenter"
VCENTERS=()
for d in "${SCRIPT_DIR}"/../secure/*/; do
  [ -d "$d" ] || continue
  v=$(basename "$d")
  [ "$v" = "README.md" ] && continue
  [ -f "${d}credentials.tfvars" ] || [ -f "${d}vcenter.tfvars" ] || continue
  [[ " ${VCENTERS[*]} " == *" $v "* ]] || VCENTERS+=("$v")
done
if [ "${#VCENTERS[@]}" -eq 0 ]; then
  die "No vCenter configured yet — run: bash scripts/vcenter-setup.sh   (creates secure/<vcenter>/ + deploy/<vcenter>/)"
fi

if [ -n "$PRESET_VCENTER" ]; then
  if printf '%s\n' "${VCENTERS[@]}" | grep -Fxq -- "$PRESET_VCENTER"; then
    VCENTER="$PRESET_VCENTER"
    ok_inline "vCenter: ${VCENTER}"
  else
    if [ "$BATCH_MODE" = true ]; then
      VCENTER="$PRESET_VCENTER"
      ok_inline "vCenter: ${VCENTER} (preset)"
    else
      warn "Preset vCenter '${PRESET_VCENTER}' not found — selecting interactively."
    fi
  fi
fi

if [ -z "$VCENTER" ]; then
  i=1
  for v in "${VCENTERS[@]}"; do echo "  $i) $v"; i=$((i+1)); done
  while true; do
    read -rp "$(echo -e "${CYAN}Select vCenter${NC} [1]: ")" vc_sel
    vc_sel="${vc_sel:-1}"
    if [[ "$vc_sel" =~ ^[0-9]+$ ]] && [ "$vc_sel" -ge 1 ] && [ "$vc_sel" -le "${#VCENTERS[@]}" ]; then
      VCENTER="${VCENTERS[$((vc_sel-1))]}"
      break
    fi
    warn "Invalid selection '${vc_sel}' — enter 1..${#VCENTERS[@]}."
  done
fi
mkdir -p "${SCRIPT_DIR}/../deploy/${VCENTER}"
info "vCenter: ${VCENTER}"

# ─── Per-vCenter defaults (editable, gitignored) ─────────────────────
# secure/<vcenter>/vm-defaults.conf holds THIS vCenter's defaults (extra-user
# default password etc.). Loaded now (after selection) so each vCenter can
# have its own policy-like defaults; missing file → built-ins used above.
VCDEFAULTS="${SCRIPT_DIR}/../secure/${VCENTER}/vm-defaults.conf"
if [ -f "$VCDEFAULTS" ]; then
  set -a; source "$VCDEFAULTS"; set +a
  info "Per-vCenter defaults: secure/${VCENTER}/vm-defaults.conf (loaded)"
fi

info "Environment (on ${VCENTER})"
# Env sub-dirs under deploy/<vcenter>/ (dev/prod/staging/qa/...) → pick or create.
ENVS=()
for d in "${SCRIPT_DIR}"/../deploy/"${VCENTER}"/*/; do
  [ -d "$d" ] || continue
  e=$(basename "$d")
  [[ " ${ENVS[*]} " == *" $e "* ]] || ENVS+=("$e")
done
i=1
for e in "${ENVS[@]}"; do echo "  $i) $e"; i=$((i+1)); done
echo "  $i) Create NEW environment"
if [ "$BATCH_MODE" = true ] && [ -n "$PRESET_ENV" ]; then
  ENV="${PRESET_ENV// /_}"
  ok_inline "Environment: ${ENV}"
else
  while true; do
    read -rp "$(echo -e "${CYAN}Select${NC} [1]: ")" env_sel
    env_sel="${env_sel:-1}"
    if [[ "$env_sel" =~ ^[0-9]+$ ]] && [ "$env_sel" -ge 1 ] && [ "$env_sel" -le "$i" ]; then
      break
    fi
    warn "Invalid selection '${env_sel}' — enter 1..${i}."
  done
  if [ "$env_sel" = "$i" ]; then
    prompt_required ENV "New env name (dev/prod/staging/qa/...)" ""
    ENV="${ENV// /_}"
  else
    ENV="${ENVS[$((env_sel-1))]}"
  fi
fi
mkdir -p "${SCRIPT_DIR}/../deploy/${VCENTER}/${ENV}"
ENV_DIR="${SCRIPT_DIR}/../deploy/${VCENTER}/${ENV}"

# Per-env override dir under secure/<vcenter>/<env>/ — used when the operator
# wants per-env values (datastore/network/resource_pool/cluster/template OR
# dns/network/base-ip/...) to differ from the top-level
# secure/<vcenter>/vcenter.tfvars. Auto-created with a commented template;
# per-env keys WIN only when actually set (uncommented).
mkdir -p "${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}"
OVERRIDE_TEMPLATE="${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}/vcenter.tfvars"
if [ ! -f "$OVERRIDE_TEMPLATE" ]; then
  cat > "$OVERRIDE_TEMPLATE" <<EOF
# Per-env override — secure/${VCENTER}/${ENV}/vcenter.tfvars
# Uncomment + set a key to OVERRIDE the top-level secure/${VCENTER}/vcenter.tfvars
# for this environment only. Keys left commented fall back to the top-level value.
# (credentials are NEVER per-env — secrets stay in secure/${VCENTER}/credentials.tfvars)
#
# vCenter resource selections — OPTIONAL per-env pinning. By default these are
# auto-discovered by govc at VM-create time; uncomment only if THIS environment
# must force a specific datastore/network/resource_pool/cluster/template/host.
# datacenter     = "dc_pilot"
# clusters       = ["accesspilot_cluster"]
# templates      = ["ubuntu24-template"]
# datastores     = ["datastore76"]
# networks       = ["VM Network"]
# resource_pools = ["Resources"]
# host           = "192.0.2.76"    # pin ALL this env's VMs to this node
#
# Changes here apply to existing VMs at their next deploy (deploy-vm.sh
# re-syncs policy onto the vm-*.tfvars file automatically).
#
# Network / IPAM defaults
# domain        = "example.local"
# gateway       = "192.0.2.1"
# netmask       = 24
# dns_servers   = ["203.0.113.53", "203.0.113.54"]
# ipam_base_ip  = "198.51.100.106"
EOF
fi

# Per-env user-group policy (secure/<vc>/<env>/user-groups.tfvars) — auto-created
# with a default policy if this env has none yet (same standard groups as a new
# vCenter). Edit to tighten/loosen what each group can do; per-VM configs
# reference groups by name via extra_users[].groups.
if [ ! -f "${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}/user-groups.tfvars" ]; then
  cat > "${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}/user-groups.tfvars" <<EOF
# User group policy — secure/${VCENTER}/${ENV}/user-groups.tfvars
# Defines what OS-level access each GROUP grants to VM extra_users in THIS env.
# Users are members of groups (a user can be in MANY groups); permission lives
# on the group. Applied to every VM in this env at deploy time.
#
# Group fields:
#   os_groups   = OS groups the user joins (created automatically)
#   sudo        = sudoers rule string; "NONE" = no sudo at all
#   shell       = login shell (default /bin/bash)
#   description = why this group exists — REQUIRED, lands in the VM audit
#                 manifest (/etc/vmpilot-access.md)
#
# AUDIT: every VM gets /etc/vmpilot-access.md + sudo logging (/var/log/sudo.log).
# A user referencing an undefined group fails deployment (fail-fast).
#
# CUSTOMIZATION: copy a block below to add your own group.
# A user with NO groups = SSH-key only, no sudo, no extra OS groups.

user_groups = {
  admin = {
    os_groups   = ["sudo", "adm"]
    sudo        = "ALL=(ALL) NOPASSWD:ALL"
    shell       = "/bin/bash"
    description = "Infra admin — full sudo + sudo/adm groups"
  }
  app = {
    os_groups   = ["app"]
    sudo        = "ALL=(ALL) NOPASSWD:/usr/bin/systemctl, ALL=(ALL) NOPASSWD:/usr/bin/docker"
    shell       = "/bin/bash"
    description = "App deployer — systemctl + docker only"
  }
  db = {
    os_groups   = ["dbadmin"]
    sudo        = "ALL=(ALL) NOPASSWD:/usr/bin/mysql, ALL=(ALL) NOPASSWD:/usr/bin/psql"
    shell       = "/bin/bash"
    description = "DBA — mysql/psql only"
  }
  readonly = {
    os_groups   = []
    sudo        = "NONE"
    shell       = "/bin/bash"
    description = "Auditor/viewer — no sudo"
  }
}
EOF
  info "Created secure/${VCENTER}/${ENV}/user-groups.tfvars (default group policy — edit as needed)"
fi

# Warn early if credentials for this vCenter are missing — otherwise the config
# is created fine but deploy-vm.sh will fail later ("Encrypted files not found").
if [ ! -f "${SCRIPT_DIR}/../secure/${VCENTER}/credentials.tfvars" ]; then
  warn "No secure/${VCENTER}/credentials.tfvars yet — config will be created but DEPLOY WILL FAIL."
  echo "  Fix: bash scripts/vcenter-setup.sh   (pick/create ${VCENTER}, fill vCenter creds)"
fi
echo ""

# Per-vCenter defaults → auto-load from secure/<vcenter>/vcenter.tfvars
# (plaintext terraform-style file; only present when vcenter-setup.sh ran).
# Sets per-vCenter: inventory + domain + gateway/netmask/dns + ipam_base_ip.
# Per-env overrides: secure/<vcenter>/<env>/vcenter.tfvars (if present) WIN.
load_vcenter_defaults() {
  local f="$1"
  [ -f "$f" ] || return 0
  # Parse is never fatal: grep no-match returns 1, and with `set -euo pipefail`
  # a single absent key would silently kill the whole script right here
  # (seen: env select → empty prompt → shell, no error). Relax errexit/pipefail
  # only for this read; callers rely on the arrays we fill, not on grep status.
  set +e +o pipefail
  # scalar string/number keys
  eval "$(grep -E '^(datacenter|cluster|resource_pool|datastore|network|template|domain|gateway|netmask|ipam_base_ip)\s*=' "$f" | sed -E 's/\s*([a-z_]+)\s*=\s*"([^"]*)"/\1="\2"/; s/\s*([a-z_]+)\s*=\s*([0-9]+)/\1="\2"/')"
  # list-form keys (curated multi-options) — clusters/templates/datastores/networks/resource_pools
  VC_CLUSTERS=(); VC_TEMPLATES=(); VC_DATASTORES=(); VC_NETWORKS=(); VC_POOLS=()
  while IFS= read -r _c; do [ -n "$_c" ] && VC_CLUSTERS+=("$_c"); done \
    < <(grep -E '^clusters\s*=' "$f" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  while IFS= read -r _t; do [ -n "$_t" ] && VC_TEMPLATES+=("$_t"); done \
    < <(grep -E '^templates\s*=' "$f" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  while IFS= read -r _d; do [ -n "$_d" ] && VC_DATASTORES+=("$_d"); done \
    < <(grep -E '^datastores\s*=' "$f" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  while IFS= read -r _n; do [ -n "$_n" ] && VC_NETWORKS+=("$_n"); done \
    < <(grep -E '^networks\s*=' "$f" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  while IFS= read -r _p; do [ -n "$_p" ] && VC_POOLS+=("$_p"); done \
    < <(grep -E '^resource_pools\s*=' "$f" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  # legacy single keys → list (when no list given)
  [ "${#VC_CLUSTERS[@]}" -eq 0 ] && [ -n "${cluster:-}" ] && VC_CLUSTERS=("$cluster")
  [ "${#VC_TEMPLATES[@]}" -eq 0 ] && [ -n "${template:-}" ] && VC_TEMPLATES=("$template")
  [ "${#VC_DATASTORES[@]}" -eq 0 ] && [ -n "${datastore:-}" ] && VC_DATASTORES=("$datastore")
  [ "${#VC_NETWORKS[@]}" -eq 0 ] && [ -n "${network:-}" ] && VC_NETWORKS=("$network")
  [ "${#VC_POOLS[@]}" -eq 0 ] && [ -n "${resource_pool:-}" ] && VC_POOLS=("$resource_pool")
  DEFAULT_DATACENTER="${datacenter:-$DEFAULT_DATACENTER}"
  DEFAULT_CLUSTER="${VC_CLUSTERS[0]:-}"
  DEFAULT_RESOURCE_POOL="${VC_POOLS[0]:-}"
  DEFAULT_DATASTORE="${VC_DATASTORES[0]:-}"
  DEFAULT_NETWORK="${VC_NETWORKS[0]:-}"
  DEFAULT_TEMPLATE="${VC_TEMPLATES[0]:-}"
  DEFAULT_DOMAIN="${domain:-$DEFAULT_DOMAIN}"
  DEFAULT_GATEWAY="${gateway:-$DEFAULT_GATEWAY}"
  DEFAULT_NETMASK="${netmask:-$DEFAULT_NETMASK}"
  DEFAULT_BASE_IP="${ipam_base_ip:-$DEFAULT_BASE_IP}"
  # dns_servers list → DEFAULT_DNS array (only if this file sets it)
  if grep -qE '^dns_servers\s*=' "$f"; then
    DEFAULT_DNS=()
    while IFS= read -r _d; do
      [ -n "$_d" ] && DEFAULT_DNS+=("$_d")
    done < <(grep -E '^dns_servers\s*=' "$f" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  fi
  # network_subnets map → per-network gateway/netmask/ipam/dns (read after DNS)
  if grep -qE '^network_subnets\s*=' "$f"; then
    unset NET_SUBNETS
    declare -gA NET_SUBNETS=()
    while IFS= read -r _line; do
      # skip commented (curated-disabled) entries
      [[ "$_line" =~ ^[[:space:]]*# ]] && continue
      # block header line "network_subnets = {" — skip (entries have a quoted key)
      [[ "$_line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]] && continue
      # block closing brace "}" — skip
      [[ "$_line" =~ ^[[:space:]]*}[[:space:]]*$ ]] && continue
      _line="${_line//,/ }"
      _name=$(grep -oE '"[^"]+"[[:space:]]*=' <<< "$_line" | head -1 | sed -E 's/^"([^"]+)".*/\1/')
      [ -n "$_name" ] || continue
      _gw=$(grep -oE 'gateway[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _nm=$(grep -oE 'netmask[[:space:]]*=[[:space:]]*[0-9]+' <<< "$_line" | head -1 | grep -oE '[0-9]+')
      _base=$(grep -oE 'ipam_base[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _start=$(grep -oE 'range_start[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _end=$(grep -oE 'range_end[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _dns=$(grep -oE '\[[^]]*\]' <<< "$_line" | head -1 | tr -d '[]"' | tr ',' ' ')
      # per-network base (ipam_base canonical; range_start legacy alias)
      [ -n "$_base" ] || _base="$_start"
      NET_SUBNETS["$_name"]="gw=$_gw;nm=$_nm;base=$_base;end=$_end;dns=$_dns"
    done < <(sed -n '/^network_subnets[[:space:]]*=/,/^}/p' "$f")
  fi
  # network_hosts map → per-network host/node pinning { "<network>" = "<node>" }
  if grep -qE '^network_hosts\s*=' "$f"; then
    unset NET_HOSTS
    declare -gA NET_HOSTS=()
    while IFS= read -r _line; do
      [[ "$_line" =~ ^[[:space:]]*# ]] && continue
      # block header line "network_hosts = {" — skip (entries have a quoted key)
      [[ "$_line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]] && continue
      # block closing brace "}" — skip
      [[ "$_line" =~ ^[[:space:]]*}[[:space:]]*$ ]] && continue
      _line="${_line//,/ }"
      _name=$(grep -oE '"[^"]+"[[:space:]]*=' <<< "$_line" | head -1 | sed -E 's/^"([^"]+)".*/\1/')
      [ -n "$_name" ] || continue
      _node=$(grep -oE '=\s*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')
      [ -n "$_node" ] && NET_HOSTS["$_name"]="$_node"
    done < <(sed -n '/^network_hosts[[:space:]]*=/,/^}/p' "$f")
  fi
  # host_networks map → per-host gateway/netmask/ipam range for standard-vSwitch
  # port groups that are PER-HOST (e.g. "VM Network" on a different subnet per
  # node). Key = host name as reported by govc live hosts. Used when a VM is
  # pinned to a node on a network with NO network_subnets entry.
  if grep -qE '^host_networks\s*=' "$f"; then
    unset HOST_NETWORKS
    declare -gA HOST_NETWORKS=()
    while IFS= read -r _line; do
      [[ "$_line" =~ ^[[:space:]]*# ]] && continue
      [[ "$_line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]] && continue
      [[ "$_line" =~ ^[[:space:]]*}[[:space:]]*$ ]] && continue
      _line="${_line//,/ }"
      _hname=$(grep -oE '"[^"]+"[[:space:]]*=' <<< "$_line" | head -1 | sed -E 's/^"([^"]+)".*/\1/')
      [ -n "$_hname" ] || continue
      _gw=$(grep -oE 'gateway[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _nm=$(grep -oE 'netmask[[:space:]]*=[[:space:]]*[0-9]+' <<< "$_line" | head -1 | grep -oE '[0-9]+')
      _base=$(grep -oE 'ipam_base[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _end=$(grep -oE 'range_end[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      HOST_NETWORKS["$_hname"]="gw=$_gw;nm=$_nm;base=$_base;end=$_end"
    done < <(sed -n '/^host_networks[[:space:]]*=/,/^}/p' "$f")
  fi
  # Backward compat: old files kept per-host networks in a separate
  # `host_networks` block. Merge those entries into network_subnets (host-keyed)
  # so a single `network_subnets` map drives everything. Existing network_subnets
  # entries (port-group keys) are untouched.
  if declare -p HOST_NETWORKS >/dev/null 2>&1 && [ "${#HOST_NETWORKS[@]}" -gt 0 ]; then
    for _hn in "${!HOST_NETWORKS[@]}"; do
      [ -n "${NET_SUBNETS[$_hn]:-}" ] || NET_SUBNETS["$_hn"]="${HOST_NETWORKS[$_hn]}"
    done
  fi
  # hosts inventory block → VC_HOSTS (node names) + HOST_INFO (name → ip|ds|nets)
  # so CLI picks come from the cached file (same source as the Web UI).
  # NOTE: unset/init live INSIDE the `grep -qE` guard so per-env override files
  # without a block keep the top-level maps instead of wiping them (this is what
  # made network_subnets silently vanish → wrong gateway/range for a mapped port
  # group like "VM Network" whose entry only lives in the top-level vcenter.tfvars).
  if grep -qE '^hosts\s*=' "$f"; then
    unset VC_HOSTS HOST_INFO
    declare -gA HOST_INFO=()
    VC_HOSTS=()
    while IFS= read -r _line; do
      [[ "$_line" =~ ^[[:space:]]*# ]] && continue
      # block header line "hosts = {" — skip (entries have a quoted key)
      [[ "$_line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]] && continue
      # block closing brace "}" — skip
      [[ "$_line" =~ ^[[:space:]]*}[[:space:]]*$ ]] && continue
      _hname=$(grep -oE '^[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')
      [ -n "$_hname" ] || continue
      _hip=$(grep -oE 'ip[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _hds=$(grep -oE 'datastores[[:space:]]*=[[:space:]]*\[[^]]*\]' <<< "$_line" | head -1 | sed -E 's/datastores[[:space:]]*=[[:space:]]*//' | tr -d '[]"')
      _hnet=$(grep -oE 'networks[[:space:]]*=[[:space:]]*\[[^]]*\]' <<< "$_line" | head -1 | sed -E 's/networks[[:space:]]*=[[:space:]]*//' | tr -d '[]"')
      VC_HOSTS+=("$_hname")
      HOST_INFO["$_hname"]="ip=$_hip;ds=$_hds;net=$_hnet"
    done < <(sed -n '/^hosts[[:space:]]*=/,/^}/p' "$f")
  fi
  set -e -o pipefail
}

load_vcenter_defaults "${SCRIPT_DIR}/../secure/${VCENTER}/vcenter.tfvars"
info "vCenter defaults loaded from secure/${VCENTER}/vcenter.tfvars"
OVERRIDE_FILE="${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}/vcenter.tfvars"
if [ -f "$OVERRIDE_FILE" ]; then
  load_vcenter_defaults "$OVERRIDE_FILE"
  info "Per-env overrides loaded from secure/${VCENTER}/${ENV}/vcenter.tfvars (win over top-level)"
fi
echo ""

prompt_required VM_DOMAIN "Domain"                       "$DEFAULT_DOMAIN"
ok_inline "Domain: ${VM_DOMAIN}"
prompt_required VM_ANNOT  "Description"                  "${VM_NAME} Server"
echo ""

# ===========================================================================
# 2. vCenter resource selection (govc — fully dynamic)
# ===========================================================================
VCRED_FILE="${SCRIPT_DIR}/../secure/${VCENTER}/credentials.tfvars"

GOVC_READY=false
if [ -f "$VCRED_FILE" ] && command -v govc &>/dev/null; then
  # Decrypt with sops if encrypted, else read plaintext
  VCREAD="cat"
  command -v sops &>/dev/null && VCREAD="sops --decrypt"
  CRED_CONTENT=$($VCREAD "$VCRED_FILE" 2>/dev/null) || CRED_CONTENT=""
  VC_SERVER=$(echo "$CRED_CONTENT" | grep -oP 'vsphere_server\s*=\s*"\K[^"]+' || true)
  VC_USER=$(echo "$CRED_CONTENT" | grep -oP 'vsphere_user\s*=\s*"\K[^"]+' || true)
  VC_PASS=$(echo "$CRED_CONTENT" | grep -oP 'vsphere_password\s*=\s*"\K[^"]+' || true)
  if [ -n "$VC_SERVER" ] && [ -n "$VC_USER" ] && [ -n "$VC_PASS" ]; then
    export GOVC_URL="$VC_SERVER"
    export GOVC_USERNAME="$VC_USER"
    export GOVC_PASSWORD="$VC_PASS"
    export GOVC_INSECURE=true
    GOVC_READY=true
  fi
fi

govc_list() {
  local type_flag="$1" extra="" out
  # Templates only — plain VMs are NOT templates. govc find returns every
  # VirtualMachine for -type m, so filter on config.template = true.
  [ "$type_flag" = "-type m" ] && extra="-config.template true"
  out=$(govc find . ${type_flag} ${extra} 2>/dev/null | sed 's|.*/||')
  if [ "$type_flag" = "-type n" ]; then
    # Distributed-switch uplink bundles (DSwitch-DVUplinks-*) are not VM port
    # groups — never offer them as a network choice.
    out=$(printf '%s\n' "$out" | grep -vE 'DVUplinks' || true)
  fi
  printf '%s\n' "$out" | sort -u || true
}

# IP helpers (32-bit arithmetic in bash is 64-bit safe)
ip_add() { # $1=ip $2=delta
  local a b c d total
  IFS='.' read -r a b c d <<< "$1"
  total=$(( (a<<24) + (b<<16) + (c<<8) + d + ${2:-1} ))
  printf '%d.%d.%d.%d' $(( (total>>24)&255 )) $(( (total>>16)&255 )) $(( (total>>8)&255 )) $(( total&255 ))
}
ip_last_usable() { # $1=host-ip-in-subnet $2=prefix  → broadcast − 1
  local a b c d shift hostmask ip_int bcast last
  IFS='.' read -r a b c d <<< "$1"
  shift=$((32 - ${2:-24}))
  hostmask=$(( (1<<shift) - 1 ))
  ip_int=$(( (a<<24) + (b<<16) + (c<<8) + d ))
  bcast=$(( ip_int | hostmask ))
  last=$(( bcast - 1 ))
  printf '%d.%d.%d.%d' $(( (last>>24)&255 )) $(( (last>>16)&255 )) $(( (last>>8)&255 )) $(( last&255 ))
}

govc_pick() {
  local label="$1" type_flag="$2" default_val="$3"
  local allow="${5:-}" mark="${6:-0}" back_ok="${7:-0}"
  local items=() line curated=()
  # Single dedicated data provider — scripts/vcenter-inventory.sh (cache-first
  # from secure/<vc>/vcenter.tfvars + live govc gap-fill for options the file
  # lacks). Same source the Web UI reads, so CLI and UI always agree.
  local INV_SCRIPT="${SCRIPT_DIR}/vcenter-inventory.sh"
  if [ -f "$INV_SCRIPT" ]; then
    local _dc _key
    _dc="${GOVC_DATACENTER:-${DC:-}}"
    case "$type_flag" in
      "-type d") _key=dc ;;
      "-type c") _key=cluster ;;
      "-type s") _key=datastore ;;
      "-type n") _key=network ;;
      "-type m") _key=template ;;
      "-type p") _key=resource_pool ;;
      "-type h") _key=host ;;
      *) _key="" ;;
    esac
    if [ -n "$_key" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && items+=("$line")
      done < <(bash "$INV_SCRIPT" "${VCENTER}" list "$_key" --datacenter="${_dc}")
    fi
  else
    # fallback (script missing): live govc discovery, same filters as before
    if $GOVC_READY; then
      while IFS= read -r line; do
        [ -n "$line" ] && items+=("$line")
      done < <(govc_list "${type_flag}")
    fi
  fi
  # merge curated file lists for this pick type
  case "$type_flag" in
    "-type c") curated=("${VC_CLUSTERS[@]:-}") ;;
    "-type m") curated=("${VC_TEMPLATES[@]:-}") ;;
    "-type s") curated=("${VC_DATASTORES[@]:-}") ;;
    "-type n") curated=("${VC_NETWORKS[@]:-}") ;;
    "-type p") curated=("${VC_POOLS[@]:-}") ;;
    "-type h") curated=("${VC_HOSTS[@]:-}") ;;
  esac
  # union curated + items (script already returns cache-first, so this only
  # merges the file lists read for host pinning / per-env override above).
  # A NON-EMPTY curated list = per-env override → RESTRICT to those only
  # ("uncomment to FORCE for this env"). Empty curated = live govc discovery.
  # EXCEPT in mark mode (mark=1, node pinned): the operator needs to see the
  # FULL list (curated ∪ live) so node-served entries are visible — a curated
  # datastore that a pinned node cannot reach must not hide the node's real
  # datastores. Curated entries stay FIRST (so the env default is preselected).
  local union=() seen=() i j skip curated_nonempty=0
  for _c in "${curated[@]:-}"; do [ -n "$_c" ] && curated_nonempty=1 && break; done
  if [ "$curated_nonempty" -eq 1 ] && [ "$mark" != "1" ]; then
    for i in "${curated[@]}"; do
      [ -n "$i" ] || continue
      skip=0
      for j in "${seen[@]}"; do [ "$j" = "$i" ] && skip=1 && break; done
      [ "$skip" = 1 ] && continue
      seen+=("$i"); union+=("$i")
    done
  else
    # mark mode (or no curated list): curated first (default), then live items
    for i in "${curated[@]:-}" "${items[@]}"; do
      [ -n "$i" ] || continue
      skip=0
      for j in "${seen[@]}"; do [ "$j" = "$i" ] && skip=1 && break; done
      [ "$skip" = 1 ] && continue
      seen+=("$i"); union+=("$i")
    done
  fi
  if [ "${#union[@]}" -gt 0 ]; then
    # Node-scoped filter: when a node is pinned, only offer datastores/networks
    # that node can actually see. allow is a space-separated allow-list — but
    # port-group names can contain SPACES ("VM Network"), so a naive
    # `for _al in $allow` word-split would never match them. Match on the raw
    # allow string (substring on whole entries) instead.
    if [ -n "$allow" ] && [ "$mark" != "1" ]; then
      local filtered=() _it
      for _it in "${union[@]}"; do
        case " $allow " in
          *" $_it "*) filtered+=("$_it") ;;
        esac
      done
      [ "${#filtered[@]}" -gt 0 ] && union=("${filtered[@]}")
    fi
    echo ""
    echo "  ${label}:"
    for i in "${!union[@]}"; do
      if [ "$mark" = "1" ] && [ -n "$allow" ]; then
        # mark mode: show the FULL list, tag entries the pinned node can serve
        case " $allow " in
          *" ${union[$i]} "*) echo "  $((i+1))) ${union[$i]}  ← node-served" ;;
          *) echo "  $((i+1))) ${union[$i]}" ;;
        esac
      else
        echo "  $((i+1))) ${union[$i]}"
      fi
    done
    # mark mode + node pinned: default to the FIRST entry the node can serve,
    # not union[0] (which is the curated env default and may be unreachable
    # from the pinned node — that was an "Unable to access file [...]" clone
    # failure). Plain Enter must land on a datastore the node actually has.
    local dflt_idx=0
    if [ "$mark" = "1" ] && [ -n "$allow" ]; then
      for _di in "${!union[@]}"; do
        case " $allow " in
          *" ${union[$_di]} "*) dflt_idx="$_di"; break ;;
        esac
      done
    fi
    read -rp "$(echo -e "${CYAN}Select${NC} [$((${dflt_idx}+1))=${union[$dflt_idx]}]${back_ok:+ (b=back)}: ")" sel
    if [ "$back_ok" = "1" ] && [ "${sel,,}" = "b" ]; then
      return 1
    fi
    sel="${sel:-$((${dflt_idx}+1))}"
    if [ "$sel" -ge 1 ] && [ "$sel" -le "${#union[@]}" ]; then
      printf -v "$4" '%s' "${union[$((sel-1))]}"
    else
      prompt_required "$4" "${label}" "${default_val}"
    fi
  else
    prompt_required "$4" "${label}" "${default_val}"
  fi
  ok_inline "${label}: $(eval echo \$$4)"
}

info "vCenter resource selection"
# Datacenter first — no GOVC_DATACENTER set yet; pick from discovered list
govc_pick "Datacenter" "-type d" "$DEFAULT_DATACENTER" GOVC_DC_SEL
export GOVC_DATACENTER="$GOVC_DC_SEL"

# Now list within the selected datacenter (curated file lists + discovery merged)
govc_pick "Cluster"              "-type c" "$DEFAULT_CLUSTER" VM_CLUSTER

# Host / node — asked BEFORE datastore/network on purpose: the VM's placement
# decides everything downstream. If the node's network differs from the chosen
# port group the VM is unreachable; with DRS off a node without the datastore
# can't run it; and while vCenter is down only nodes that already host the VM
# keep it running. So pin first, then only offer what that node can serve.
#
# Node data is LIVE from govc (hosts + their reachable datastores/networks),
# so a brand-new node appears automatically — nothing to keep in vcenter.tfvars.
# The cached `hosts` block is only a fallback when govc is unavailable.
NODE_SCOPE=""   # "<hostname>" (pinned) or "" (DRS auto-placement)
VM_HOST=""

# Host → Datastore → Network pick with back navigation (b at any step = redo
# the previous one). The whole block repeats so a wrong choice is fixable
# without restarting the wizard.
while true; do

declare -a NODE_LIST=()
declare -A NODE_IP NODE_DS NODE_NET
# 1) live govc (cache-adjacent .cache file inside the inventory script)
if $GOVC_READY && [ -f "${SCRIPT_DIR}/vcenter-inventory.sh" ]; then
  LIVE_HOSTS="$(bash "${SCRIPT_DIR}/vcenter-inventory.sh" "${VCENTER}" live hosts 2>/dev/null || true)"
  if [ -n "$LIVE_HOSTS" ]; then
    while IFS= read -r _row; do
      [ -n "$_row" ] || continue
      _n="$(jq -r '.name // empty' <<<"$_row" 2>/dev/null)"
      [ -n "$_n" ] || continue
      NODE_LIST+=("$_n")
      NODE_IP["$_n"]="$(jq -r '.ip // ""' <<<"$_row" 2>/dev/null)"
      NODE_DS["$_n"]="$(jq -r '.datastores[]? // empty' <<<"$_row" 2>/dev/null | paste -sd' ')"
      NODE_NET["$_n"]="$(jq -r '.networks[]? // empty' <<<"$_row" 2>/dev/null | paste -sd' ')"
    done < <(printf '%s\n' "$LIVE_HOSTS" | jq -c '.[]' 2>/dev/null)
  fi
fi
# 2) cached inventory fallback (add nodes govc couldn't see / no govc)
for _hh in "${VC_HOSTS[@]:-}"; do
  [ -n "$_hh" ] || continue
  [[ " ${NODE_LIST[*]} " == *" $_hh "* ]] && continue
  NODE_LIST+=("$_hh")
  NODE_IP["$_hh"]="$(awk -F';' '{for(j=1;j<=NF;j++) if($j~/^ip=/) {sub("^ip=","",$j); print $j}}' <<< "${HOST_INFO[$_hh]:-}")"
  NODE_DS["$_hh"]="$(awk -F';' '{for(j=1;j<=NF;j++) if($j~/^ds=/) {sub("^ds=","",$j); print $j}}' <<< "${HOST_INFO[$_hh]:-}")"
  NODE_NET["$_hh"]="$(awk -F';' '{for(j=1;j<=NF;j++) if($j~/^net=/) {sub("^net=","",$j); print $j}}' <<< "${HOST_INFO[$_hh]:-}")"
done

if [ "${#NODE_LIST[@]}" -gt 0 ]; then
  echo ""
  echo "  Host (node) — live inventory [Enter] = DRS auto-placement:"
  for i in "${!NODE_LIST[@]}"; do
    _hh="${NODE_LIST[$i]}"
    printf '    %d) %s  (%s)\n' "$((i+1))" "$_hh" "${NODE_IP[$_hh]:-}"
  done
  read -rp "$(echo -e "${CYAN}Select [Enter = ${VM_HOST:-DRS auto-placement}]:${NC} ")" _hsel
  if [ -n "$_hsel" ] && [ "$_hsel" -ge 1 ] 2>/dev/null && [ "$_hsel" -le "${#NODE_LIST[@]}" ]; then
    VM_HOST="${NODE_LIST[$((_hsel-1))]}"
  elif [ -n "$_hsel" ]; then
    VM_HOST="$_hsel"
  fi
fi
if [ -z "$VM_HOST" ]; then
  info "No node pinned — DRS will auto-place '${VM_NAME}' within ${VM_CLUSTER}"
fi

# Per-node datastore/network allow-lists (live when available, else cache).
# Datastore is shown FULL (mark mode) so the operator sees every datastore in
# the vCenter; the pinned node's reachable ones are tagged. Network is filtered
# (only the node's networks) because a wrong port group makes the VM unreachable.
NODE_DATASTORES=""
NODE_NETWORKS=""
if [ -n "$VM_HOST" ]; then
  NODE_DATASTORES="${NODE_DS[$VM_HOST]:-}"
  NODE_NETWORKS="${NODE_NET[$VM_HOST]:-}"
  [ -n "$NODE_DATASTORES" ] && info "Node ${VM_HOST} can serve datastores: ${NODE_DATASTORES}"
fi

govc_pick "Datastore"          "-type s" "$DEFAULT_DATASTORE" VM_DATASTORE "${NODE_DATASTORES}" 1 1 || { info "Back to host/node selection..."; VM_HOST=""; continue; }
[ -n "$NODE_NETWORKS" ] && info "Node ${VM_HOST} can serve networks:   ${NODE_NETWORKS}"
govc_pick "Network port group" "-type n" "$DEFAULT_NETWORK"        NET_PORT_GROUP "${NODE_NETWORKS}" 0 1 || { info "Back to datastore selection..."; continue; }
break
done

# Per-network IPAM (single network_subnets map in vcenter.tfvars) — entries are
# keyed by port-group NAME (DVS, cluster-wide) or by HOST name (per-host
# standard-vSwitch subnet like "VM Network"). Lookup order:
#   1. chosen port group's entry (DVS — same subnet on every host) wins;
#   2. else pinned node's host-keyed entry wins (that host's own subnet);
#   3. else derive from the pinned node's mgmt IP / prompt.
# Missing base/end are DEFAULTED from the gateway: base = gateway+reserve,
# end = last usable host (broadcast−1). Explicit values always win.
RANGE_END=""
if [ -n "${NET_PORT_GROUP:-}" ] && [ -n "${NET_SUBNETS[${NET_PORT_GROUP}]:-}" ]; then
  # Chosen port group has its own entry (DVS cluster-wide) — wins over any
  # pinned-host entry because DVS is the same subnet on every host.
  NET_SUB="${NET_SUBNETS[$NET_PORT_GROUP]}"
  SUB_GW=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^gw=/) {sub("^gw=","",$i); print $i}}' <<< "$NET_SUB")
  SUB_NM=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^nm=/) {sub("^nm=","",$i); print $i}}' <<< "$NET_SUB")
  SUB_BASE=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^base=/) {sub("^base=","",$i); print $i}}' <<< "$NET_SUB")
  SUB_END=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^end=/) {sub("^end=","",$i); print $i}}' <<< "$NET_SUB")
  SUB_DNS=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^dns=/) {sub("^dns=","",$i); print $i}}' <<< "$NET_SUB")
  [ -n "$SUB_GW" ] && DEFAULT_GATEWAY="$SUB_GW"
  [ -n "$SUB_NM" ] && DEFAULT_NETMASK="$SUB_NM"
  [ -n "$SUB_DNS" ] && DEFAULT_DNS=($SUB_DNS)
  # range defaults derived from the (possibly overridden) gateway
  if [ -n "$SUB_BASE" ]; then
    DEFAULT_BASE_IP="$SUB_BASE"
  else
    DEFAULT_BASE_IP=$(ip_add "$DEFAULT_GATEWAY" "$DEFAULT_IPAM_RESERVE")
  fi
  if [ -n "$SUB_END" ]; then
    RANGE_END="$SUB_END"
  else
    RANGE_END=$(ip_last_usable "$DEFAULT_GATEWAY" "$DEFAULT_NETMASK")
  fi
  info "Network ${NET_PORT_GROUP}: per-network IPAM applied (gw=${DEFAULT_GATEWAY} netmask=${DEFAULT_NETMASK} base=${DEFAULT_BASE_IP} end=${RANGE_END})"
elif [ -n "${VM_HOST:-}" ] && [ -n "${NET_SUBNETS[$VM_HOST]:-}" ]; then
  # Chosen port group has NO entry (standard-vSwitch, per-host) but the pinned
  # node has a host-keyed entry in network_subnets ("198.51.100.169" = {…}) —
  # that host's own subnet ("VM Network" on 198.51.100.x vs the 192.0.2.x
  # default). Uses the host's gateway/netmask/ipam verbatim.
  HN_SUB="${NET_SUBNETS[$VM_HOST]}"
  HN_GW=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^gw=/) {sub("^gw=","",$i); print $i}}' <<< "$HN_SUB")
  HN_NM=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^nm=/) {sub("^nm=","",$i); print $i}}' <<< "$HN_SUB")
  HN_BASE=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^base=/) {sub("^base=","",$i); print $i}}' <<< "$HN_SUB")
  HN_END=$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^end=/) {sub("^end=","",$i); print $i}}' <<< "$HN_SUB")
  [ -n "$HN_GW" ]   && { DEFAULT_GATEWAY="$HN_GW";   VM_GATEWAY="$HN_GW"; }
  [ -n "$HN_NM" ]   && DEFAULT_NETMASK="$HN_NM"
  [ -n "$HN_BASE" ] && DEFAULT_BASE_IP="$HN_BASE"
  [ -n "$HN_END" ]  && RANGE_END="$HN_END"
  if [ -z "$HN_BASE" ]; then DEFAULT_BASE_IP=$(ip_add "$DEFAULT_GATEWAY" "$DEFAULT_IPAM_RESERVE"); fi
  if [ -z "$HN_END" ];  then RANGE_END=$(ip_last_usable "$DEFAULT_GATEWAY" "$DEFAULT_NETMASK"); fi
  info "Node ${VM_HOST} pinned — '${NET_PORT_GROUP}' uses host entry network_subnets['${VM_HOST}'] range: ${DEFAULT_BASE_IP:-?}..${RANGE_END:-?} (gw=${DEFAULT_GATEWAY} /${DEFAULT_NETMASK})"
else
  # NO port-group entry AND no host-keyed entry → the vCenter-wide gateway
  # can't be trusted for a port group on a different subnet (e.g. 198.51.100.x vs
  # default 192.0.2.1). A standard-vSwitch port group is PER-HOST: the same
  # label (e.g. "Management Network") sits on a different subnet on each node.
  # So when a node is pinned, derive the range from THAT node's own subnet (its
  # management IP /24); only fall back to asking for a gateway when no node is
  # pinned.
  if [ -n "${NET_PORT_GROUP:-}" ]; then
    HOST_SUBNET=""
    if [ -n "${VM_HOST:-}" ] && [ -n "${NODE_IP[$VM_HOST]:-}" ]; then
      HOST_IP_SEL="$(tr ',' '\n' <<< "${NODE_IP[$VM_HOST]}" | grep -vE '^169\.254\.' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
      [ -n "$HOST_IP_SEL" ] && HOST_SUBNET="$(awk -F. '{print $1"."$2"."$3}' <<< "$HOST_IP_SEL")"
      if [ -n "$HOST_SUBNET" ]; then
        DEFAULT_GATEWAY="${HOST_SUBNET}.1"
        DEFAULT_NETMASK="${DEFAULT_NETMASK:-24}"
        DEFAULT_BASE_IP=$(ip_add "$DEFAULT_GATEWAY" "$DEFAULT_IPAM_RESERVE")
        RANGE_END=$(ip_last_usable "$DEFAULT_GATEWAY" "$DEFAULT_NETMASK")
        VM_GATEWAY="$DEFAULT_GATEWAY"
        info "Node ${VM_HOST} pinned — '${NET_PORT_GROUP}' range derived from node subnet ${HOST_SUBNET}.0/${DEFAULT_NETMASK}: ${DEFAULT_BASE_IP}..${RANGE_END}"
      fi
    fi
    if [ -z "$HOST_SUBNET" ]; then
      prompt_required VM_GATEWAY "Gateway for '${NET_PORT_GROUP}' (no network_subnets entry)" "${DEFAULT_GATEWAY:-}"
      prompt_required VM_NETMASK "Netmask for '${NET_PORT_GROUP}'" "${DEFAULT_NETMASK:-24}"
      DEFAULT_GATEWAY="$VM_GATEWAY"
      DEFAULT_NETMASK="$VM_NETMASK"
      DEFAULT_BASE_IP=$(ip_add "$DEFAULT_GATEWAY" "$DEFAULT_IPAM_RESERVE")
      RANGE_END=$(ip_last_usable "$DEFAULT_GATEWAY" "$DEFAULT_NETMASK")
      info "Network ${NET_PORT_GROUP}: no network_subnets entry — range derived from its gateway: ${DEFAULT_BASE_IP}..${RANGE_END} (add network_subnets in vcenter.tfvars to set explicitly)"
    fi
  elif [ -n "${DEFAULT_GATEWAY:-}" ]; then
    VM_GATEWAY="$DEFAULT_GATEWAY"
    DEFAULT_BASE_IP=$(ip_add "$DEFAULT_GATEWAY" "$DEFAULT_IPAM_RESERVE")
    RANGE_END=$(ip_last_usable "$DEFAULT_GATEWAY" "$DEFAULT_NETMASK")
    info "No port group selected — default range ${DEFAULT_BASE_IP}..${RANGE_END}"
  fi
fi
echo ""

prompt_required BASE_IP "Starting IP for free-IP scan (range start; based on port group subnet)" "$DEFAULT_BASE_IP"
ok_inline "Scan from: ${BASE_IP}"
[ -n "${RANGE_END:-}" ] && ok_inline "Block ends at: ${RANGE_END}"
echo ""

# ===========================================================================
# 3. Auto-assign free IP
# ===========================================================================
info "Free IP scan (on ${NET_PORT_GROUP})"
FREE_IP=""
FREE_ATTEMPTED=""
for try_ip in "$BASE_IP" "$(echo "$BASE_IP" | awk -F. '{print $1"."$2"."$3"."$4+1}')"; do
  PAYLOAD="{\"base_ip\": \"$try_ip\"${RANGE_END:+,\"range_end\": \"$RANGE_END\"}}"
  result=$(echo "$PAYLOAD" | bash "$SCRIPT_DIR/next_free_ip.sh" 2>/dev/null || echo '{"error":"failed"}')
  FREE_IP=$(echo "$result" | jq -r '.free_ip // empty')
  FREE_ATTEMPTED=$(echo "$result" | jq -r '.attempted // empty')
  [ -n "$FREE_IP" ] && break
done
if [ -n "$FREE_IP" ]; then
  if [ "$FREE_IP" = "$BASE_IP" ]; then
    ok "IP ${BASE_IP} is FREE — selected for this VM (${NET_PORT_GROUP})"
  else
    warn "IP ${BASE_IP} is in use or reserved (ping reply / existing config)"
    ok "Next free IP selected: ${FREE_IP} (${NET_PORT_GROUP})"
  fi
  [ -n "$FREE_ATTEMPTED" ] && info "Checked ${FREE_ATTEMPTED} IP(s) from ${BASE_IP} to find ${FREE_IP}"
else
  warn "Could not auto-find free IP — you will need to set it manually."
  FREE_IP="$BASE_IP"
fi
if [ -z "${VM_GATEWAY:-}" ]; then
  prompt_optional VM_GATEWAY "Gateway" "$DEFAULT_GATEWAY"
fi
ok_inline "Gateway: ${VM_GATEWAY}"
echo ""

govc_pick "Template (VM)"      "-type m" "$DEFAULT_TEMPLATE" VM_TEMPLATE
govc_pick "Resource pool"      "-type p" "$DEFAULT_RESOURCE_POOL" VM_RESOURCE_POOL
VM_RESOURCE_POOL="${VM_RESOURCE_POOL:-Resources}"

# ---------------------------------------------------------------------------
# Placement sanity check (fail-fast, BEFORE the config is written).
# A cloned VM must live on a datastore the pinned node can actually reach.
# Two datastores matter: the one the VM's disk lands on (VM_DATASTORE) and the
# one the TEMPLATE lives on (clone reads its disks from there). If the pinned
# node can't see either, apply fails later with a cryptic
# "Unable to access file [<ds>]" — catch it here instead.
# ---------------------------------------------------------------------------
if [ -n "$VM_HOST" ]; then
  _node_ds="${NODE_DS[$VM_HOST]:-}"
  if [ -n "$_node_ds" ]; then
    _bad=""
    # chosen target datastore reachable from the pinned node?
    case " $_node_ds " in
      *" ${VM_DATASTORE} "*) ;;
      *) _bad="${VM_DATASTORE}" ;;
    esac
    # template's own datastore reachable from the pinned node?
    if $GOVC_READY; then
      _tmpl_ds="$(govc vm.info -json "${VM_TEMPLATE}" 2>/dev/null \
        | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)["virtualMachines"][0]
  p=d["config"]["files"]["vmPathName"]
  print(p[1:p.index("]")])
except Exception: print("")')"
      if [ -n "$_tmpl_ds" ]; then
        case " $_node_ds " in
          *" $_tmpl_ds "*) ;;
          *) [ -n "$_bad" ] && _bad+=", " ; _bad+="template DS '${_tmpl_ds}'" ;;
        esac
      fi
    fi
    if [ -n "$_bad" ]; then
      warn "Node ${VM_HOST} can serve: ${_node_ds}"
      die "Placement conflict: ${_bad} is NOT reachable from pinned node ${VM_HOST} — pick a node that serves it, or a datastore this node has."
    fi
  fi
fi

# ===========================================================================
# 4. Hardware quick-ask (minimal)
# ===========================================================================
info "Hardware (defaults OK, edit later)"
prompt_required VM_CPU    "vCPU"              "$DEFAULT_CPU"
ok_inline "CPU: ${VM_CPU} vCPU"
prompt_required VM_RAM    "RAM (e.g. 4G or 4)"  "$DEFAULT_RAM"
ok_inline "RAM: ${VM_RAM}"
prompt_optional VM_FIRM   "Firmware"          "$DEFAULT_FIRMWARE"
ok_inline "Firmware: ${VM_FIRM}"
confirm "CPU hot-add?" "$DEFAULT_CPU_HOT_ADD" && CPU_HOT=true || CPU_HOT=false
ok_inline "CPU hot-add: ${CPU_HOT}"
confirm "RAM hot-add?" "$DEFAULT_MEM_HOT_ADD" && MEM_HOT=true || MEM_HOT=false
ok_inline "RAM hot-add: ${MEM_HOT}"
VM_RAM=$(to_mb  "$VM_RAM")

# Swap suggestion
ram_gb=$(( VM_RAM / 1024 ))
if   [ "$ram_gb" -le 2 ];  then SWAP_SUG=$(( ram_gb * 2 ))
elif [ "$ram_gb" -le 8 ];  then SWAP_SUG="${ram_gb}"
elif [ "$ram_gb" -le 32 ]; then SWAP_SUG=$(( ram_gb / 2 ))
else                            SWAP_SUG=8
fi
echo -e "  Swap suggestion: $(human_size $(( SWAP_SUG * 1024 ))) (based on ${ram_gb} GB RAM)"
read -rp "$(echo -e "${CYAN}  Add swap?${NC} (y=Yes ${SWAP_SUG}G / n=No / c=Custom): ")" swap_yn
swap_yn="${swap_yn:-N}"
case "${swap_yn,,}" in
  y|yes)
    SWAP_SIZE="$(normalize_size "${SWAP_SUG}G")"
    ok "Swap: ${SWAP_SIZE}"
    ;;
  n|no)
    SWAP_SIZE="0"
    info "No swap"
    ;;
  c|custom)
    prompt_optional SWAP_SIZE_RAW "  Swap size (e.g. ${SWAP_SUG}G, or 4096M)" "${SWAP_SUG}G"
    SWAP_SIZE=$(normalize_size "$SWAP_SIZE_RAW")
    ok "Swap: ${SWAP_SIZE}"
    ;;
  *)
    # Bare number (e.g. "6") = use directly as GB
    SWAP_SIZE=$(normalize_size "${swap_yn}G")
    ok "Swap: ${SWAP_SIZE}"
    ;;
esac

# OS Partition preset or custom — outer loop for back navigation
while true; do
OS_PARTS=()
swap_gb=0
swap_check="${SWAP_SIZE%G}"
if [ "${swap_check:-0}" != "0" ]; then
  swap_val="${SWAP_SIZE%G}"
  [[ "$swap_val" =~ ^[0-9]+$ ]] && swap_gb=$swap_val
  OS_PARTS+=("swap|lv_swap|${SWAP_SIZE}|swap")
fi
echo ""
info "OS partitions on vg_os"
echo "  1) Default  (root 10G, home 5G, var 15G, tmp 2G)"
echo "  2) Custom   (choose your own mount points & sizes)"
read -rp "  Select [1=default/2=custom]: " os_mode
os_mode="${os_mode:-1}"

DEFAULT_MOUNTS_ARR=("${DEFAULT_MOUNTS[@]}")
if [ "$os_mode" = "1" ]; then
  picked_lvs=0
  for entry in "${DEFAULT_MOUNTS_ARR[@]}"; do
    IFS=':' read -r mp sz <<< "$entry"
    [ "$mp" = "/" ] && lv="lv_root" || lv="lv_${mp#/}"
    OS_PARTS+=("${mp}|${lv}|${sz}G|xfs")
    picked_lvs=$((picked_lvs + 1))
  done
  ok "Default partitions: $(printf '%s ' "${DEFAULT_MOUNTS_ARR[@]}")"
else
  echo "  Enter mount points one by one. Leave empty to finish."
  while true; do
    echo ""
    read -rp "  Mount point (e.g. /opt) [empty=done, b=back]: " mp
    [ -z "$mp" ] && break
    [ "${mp,,}" = "b" ] && info "Back to mode selection..." && continue 2
    [[ "$mp" != "/" && "$mp" != /* ]] && mp="/$mp"
    [ "$mp" = "/" ] && lv="lv_root" || { lv="lv_${mp#/}"; lv="${lv//\//_}"; }
    read -rp "  ${lv} → ${mp}  size (e.g. 10G) [b=back]: " sz
    [ "${sz,,}" = "b" ] && info "Skipped ${mp}" && continue
    sz=$(normalize_size "$sz")
    fs=$(prompt_fs)
    [ "${fs,,}" = "b" ] && info "Skipped ${mp}" && continue
    OS_PARTS+=("${mp}|${lv}|${sz}|${fs}")
    ok "Added ${lv} (${sz}) → ${mp} [${fs}]"
  done
fi

echo ""
only_swap=false
if [ ${#OS_PARTS[@]} -eq 0 ]; then only_swap=true
elif [ "${OS_PARTS[0]%%|*}" = "swap" ] && [ ${#OS_PARTS[@]} -eq 1 ]; then only_swap=true
fi
$only_swap && info "Only swap configured — no extra LVs" || ok "${#OS_PARTS[@]} partition(s) configured"

# Build os_partitions HCL block
OS_PARTS_LINES=()
OS_PARTS_LAST_IDX=$((${#OS_PARTS[@]} - 1))
for i in "${!OS_PARTS[@]}"; do
  IFS='|' read -r mp lv sz fs <<< "${OS_PARTS[$i]}"
  sep=","
  [ "$i" -eq "$OS_PARTS_LAST_IDX" ] && sep=""
  if [ "$mp" = "swap" ]; then
    OS_PARTS_LINES+=("  { mount_point = \"swap\",   size = \"${sz}\",        lv_name = \"${lv}\" }${sep}")
  elif [ "$mp" = "/" ]; then
    OS_PARTS_LINES+=("  { mount_point = \"/\",      size = \"${sz}\",        lv_name = \"${lv}\", filesystem = \"${fs}\" }${sep}")
  else
    OS_PARTS_LINES+=("  { mount_point = \"${mp}\",  size = \"${sz}\",        lv_name = \"${lv}\", filesystem = \"${fs}\" }${sep}")
  fi
done
if [ ${#OS_PARTS_LINES[@]} -gt 0 ]; then
  printf -v OS_PARTS_BLOCK "[\n%s\n]" "$(IFS=$'\n'; echo "${OS_PARTS_LINES[*]}")"
else
  OS_PARTS_BLOCK="[]"
fi

# Check if root in OS_PARTS
root_in_parts=false
for entry in "${OS_PARTS[@]}"; do
  IFS='|' read -r mp lv sz fs <<< "$entry"
  [ "$mp" = "/" ] && root_in_parts=true && break
done

# Boot partition (sda1) — default 500MB, option for 1GB
read -rp "$(echo -e "${CYAN}  Boot partition sda1 size${NC} (500M / 1G) [${DEFAULT_BOOT_SIZE}]: ")" boot_raw
boot_raw="${boot_raw:-$DEFAULT_BOOT_SIZE}"
boot_raw_upper="${boot_raw^^}"
boot_display="$boot_raw"
case "$boot_raw_upper" in
  *GB) BOOT_MB=$(( ${boot_raw_upper%GB} * 1024 )) ;;
  *G)  BOOT_MB=$(( ${boot_raw_upper%G} * 1024 ))  ;;
  *MB) BOOT_MB="${boot_raw_upper%MB}" ;;
  *M)  BOOT_MB="${boot_raw_upper%M}" ;;
  *)   BOOT_MB="$boot_raw_upper" ;;
esac

# Calculate minimum OS disk size
part_sum=0
for entry in "${OS_PARTS[@]}"; do
  IFS='|' read -r mp lv sz fs <<< "$entry"
  sz="${sz%G}"
  [[ "$sz" =~ ^[0-9]+$ ]] && part_sum=$((part_sum + sz))
done
_boot_gb=$(( (BOOT_MB + 1023) / 1024 ))  # ceil to GB for disk sizing
if $root_in_parts; then
  min_disk=$(( _boot_gb + part_sum + 1 ))
else
  min_disk=$(( _boot_gb + 8 + part_sum + 1 ))
fi
# The clone cannot be smaller than the template's OS disk (40 GB).
: "${TEMPLATE_DISK_GB:=40}"
[ "$min_disk" -lt "$TEMPLATE_DISK_GB" ] && min_disk=$TEMPLATE_DISK_GB
echo ""
info "OS disk: boot(${boot_display}) + root($($root_in_parts && echo "${part_sum}" || echo "8+${part_sum}")G) + buffer(1G) → min ${min_disk} GB (template disk ${TEMPLATE_DISK_GB} GB)"
while true; do
  read -rp "$(echo -e "${CYAN}  OS disk size (GB, min ${min_disk})${NC} [${min_disk}] (b=back): ")" VM_DISK
  [ "${VM_DISK,,}" = "b" ] && info "Restarting partition selection..." && continue 2
  VM_DISK="${VM_DISK:-$min_disk}"
  VM_DISK=$(to_gb "$VM_DISK")
  [ "$VM_DISK" -ge "$min_disk" ] && break
  warn "OS disk must be at least ${min_disk} GB (got ${VM_DISK})"
done
ok "OS disk: ${VM_DISK} GB"
break  # exit outer loop
done

echo ""
info "OS disk provisioning type"
echo "  1) thin              (default — saves space, faster clone)"
echo "  2) thick lazy zeroed (traditional, no zero-on-delete)"
echo "  3) thick eager zero  (DB/secure — zeroes allocated up front)"
read -rp "$(echo -e "${CYAN}  Select${NC} [1=thin/2=thick/3=eager]: ")" prov_sel
prov_sel="${prov_sel:-$DEFAULT_PROVISIONING}"
case "$prov_sel" in
  1) DISK_THIN=true;  DISK_EAGER=false ;;
  2) DISK_THIN=false; DISK_EAGER=false ;;
  3) DISK_THIN=false; DISK_EAGER=true  ;;
  *) DISK_THIN=true;  DISK_EAGER=false ;;
esac
ok_inline "OS disk: thin=${DISK_THIN} eagerly_scrub=${DISK_EAGER}"

echo ""
DATA_DISKS_BLOCK="[]"
LVM_CONFIG_BLOCK="[]"
MOUNT_BLOCK="[]"
LVM_ENTRIES=()
DATA_DISK_TEMPLATE='# OS(sda)=thin | Data(sdb): DB→eagerly_scrub, App→thin
# ── Uncomment below to add a data disk (adjust sizes/workload) ──
# data_disks = [{
#   label = "lvm"  size = 120  unit_number = 1
#   thin_provisioned = true   eagerly_scrub = false    # DB → false/true
# }]
# lvm_config = [
#   { vg_name="vg_data"  lv_name="lv_opt"   lv_size="30G"  mount_point="/opt"   filesystem="xfs"  devices=["/dev/sdb"] },
#   { vg_name="vg_data"  lv_name="lv_data"  lv_size="50G"  mount_point="/data"  filesystem="xfs"  devices=["/dev/sdb"] },
# ]
# ─────────────────────────────────────────────────────────────────'
DATA_DISK_TEMPLATE=""
if confirm "  Add a data disk?" "$DEFAULT_DATA_DISK"; then
  # ── Collect LVM volumes FIRST (so disk size can be calculated from them) ──
  echo ""
  info "Data disk LVM volumes (vg_data on sdb)"
  echo "  Add mount points for vg_data — e.g. /opt, /var/log, /srv"
  while true; do
    echo ""
    read -rp "  Mount point (e.g. /opt) [empty=done]: " data_mp
    [ -z "$data_mp" ] && break
    [[ "$data_mp" != "/" && "$data_mp" != /* ]] && data_mp="/$data_mp"
    [ "$data_mp" = "/" ] && data_lv="lv_root" || { data_lv="lv_${data_mp#/}"; data_lv="${data_lv//\//_}"; }
    read -rp "  ${data_lv} → ${data_mp}  size (e.g. 10G) [b=back]: " data_sz2
    [ "${data_sz2,,}" = "b" ] && continue
    data_sz2=$(normalize_size "$data_sz2")
    data_fs=$(prompt_fs)
    [ "${data_fs,,}" = "b" ] && continue
    LVM_ENTRIES+=("${data_mp}|${data_lv}|${data_sz2}|${data_fs}")
    ok "Added ${data_lv} (${data_sz2}) → ${data_mp} [${data_fs}]"
  done

  # Calculate total required disk (GB) from LV sizes with 15% safety margin
  total_lv_gb=0
  for entry in "${LVM_ENTRIES[@]}"; do
    IFS='|' read -r _ _ sz _ <<< "$entry"
    num=${sz%[A-Za-z]*}
    num=${num:-0}
    total_lv_gb=$(( total_lv_gb + num ))
  done
  min_disk=$(( total_lv_gb * 115 / 100 + 2 ))  # +15% + 2GB buffer

  # ── Now ask for disk size — minimum enforced, larger = free space in VG ──
  echo ""
  info "Data disk provisioning"
  if [ $total_lv_gb -gt 0 ]; then
    echo "  Total LV sizes: ${total_lv_gb} GiB → minimum disk: ${min_disk} GB"
  fi
  while true; do
    if [ $total_lv_gb -gt 0 ]; then
      read -rp "$(echo -e "${CYAN}  Data disk size (GB)${NC} [${min_disk}]: ")" data_sz
      data_sz="${data_sz:-$min_disk}"
    else
      read -rp "$(echo -e "${CYAN}  Data disk size (GB)${NC} [${DEFAULT_DATA_DISK_GB}]: ")" data_sz
      data_sz="${data_sz:-$DEFAULT_DATA_DISK_GB}"
    fi
    data_sz=$(to_gb "$data_sz")
    if [ $total_lv_gb -gt 0 ] && [ "$data_sz" -lt "$min_disk" ]; then
      warn "Disk ${data_sz}GB too small — need at least ${min_disk} GB for ${total_lv_gb} GiB LVs"
    else
      break
    fi
  done
  # Extra space (disk - LV total) stays unallocated in VG — available for future LVs

  echo "  Data disk provisioning:"
  echo "    1) thin              (default — space-efficient)"
  echo "    2) thick lazy zeroed"
  echo "    3) thick eager zero  (DB/secure — zero on delete)"
  read -rp "$(echo -e "${CYAN}  Select${NC} [1=thin/2=thick/3=eager]: ")" data_prov
  data_prov="${data_prov:-$DEFAULT_DATA_PROVISIONING}"
  case "$data_prov" in
    1) data_thin=true;  data_eager=false ;;
    2) data_thin=false; data_eager=false ;;
    3) data_thin=false; data_eager=true  ;;
    *) data_thin=true;  data_eager=false ;;
  esac
  # Build data_disks block
  DATA_DISKS_BLOCK="[
  {
    label            = \"lvm\"
    size             = ${data_sz}
    unit_number      = 1
    thin_provisioned = ${data_thin}
    eagerly_scrub    = ${data_eager}
  }
]"
  # Build lvm_config block
  if [ ${#LVM_ENTRIES[@]} -gt 0 ]; then
    LVM_LINES=()
    LVM_LAST_IDX=$((${#LVM_ENTRIES[@]} - 1))
    for i in "${!LVM_ENTRIES[@]}"; do
      IFS='|' read -r mp lv sz fs <<< "${LVM_ENTRIES[$i]}"
      sep=","
      [ "$i" -eq "$LVM_LAST_IDX" ] && sep=""
      LVM_LINES+=("  {
    vg_name     = \"vg_data\"
    lv_name     = \"${lv}\"
    lv_size     = \"${sz}\"
    mount_point = \"${mp}\"
    filesystem  = \"${fs}\"
    devices     = [\"/dev/sdb\"]
  }${sep}")
    done
    printf -v LVM_CONFIG_BLOCK "[\n%s\n]" "$(IFS=$'\n'; echo "${LVM_LINES[*]}")"
  fi
  DATA_DISK_TEMPLATE=""  # configured, no need for commented example
  ok "Data disk: ${data_sz} GB with ${#LVM_ENTRIES[@]} volume(s)"
else
  info "No data disk — commented template left in config for later use"
fi

# ===========================================================================
# 5. SSH key
# ===========================================================================
DEFAULT_KEY=""
for f in ~/.ssh/id_*.pub; do [ -f "$f" ] && DEFAULT_KEY="$(cat "$f")" && break; done
if [ -n "$DEFAULT_KEY" ]; then
  ok "Key found: ${DEFAULT_KEY::50}..."
  confirm "Use this key?" "Y" && SSH_KEY="$DEFAULT_KEY" || SSH_KEY=""
fi
[ -z "${SSH_KEY:-}" ] && prompt_required SSH_KEY "Paste SSH public key" ""
echo ""

# ===========================================================================
# 6. Additional users (created via cloud-init)
# ===========================================================================
# Load user-group policy (secure/<vc>/<env>/user-groups.tfvars) so the wizard
# can offer the groups that actually exist in this environment.
USER_GROUP_KEYS=()
GROUPS_FILE="${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}/user-groups.tfvars"
if [ -f "$GROUPS_FILE" ]; then
  # Only TOP-LEVEL group keys are valid — a line `name = {` at column 0 inside
  # the user_groups block. Nested keys (os_groups/sudo/shell/description), the
  # closing `}` and comment lines must NOT be treated as groups.
  while IFS= read -r _gl; do
    _gk=$(printf '%s' "$_gl" | sed -E 's/^[[:space:]]*"?([a-zA-Z0-9_-]+)"?[[:space:]]*=[[:space:]]*\{.*$/\1/; t; s/.*//')
    [ -n "$_gk" ] && [ "$_gk" != "user_groups" ] && USER_GROUP_KEYS+=("$_gk")
  done < <(sed -n '/^user_groups[[:space:]]*=/,/^}/p' "$GROUPS_FILE")
fi
[ ${#USER_GROUP_KEYS[@]} -eq 0 ] && USER_GROUP_KEYS=("admin")

EXTRA_USERS=()
info "Additional OS users (create VM owner accounts)"
if [ -n "${DEFAULT_EXTRA_USER_PASSWORD}" ]; then
  echo "  Default password: ${DEFAULT_EXTRA_USER_PASSWORD} (from secure/${VCENTER}/vm-defaults.conf — user must change on first login)"
else
  echo "  No default password set — accounts are SSH-key only (recommended)"
fi
# Numbered group menu — built once, shown at every pick. Numbers make the
# selection stable ("pick #2 then #4"), and the description + sudo rule show
# EXACTLY what each group can do before the user commits.
GROUP_MENU=()
for _g in "${USER_GROUP_KEYS[@]}"; do
  _gblk=$(sed -n "/^[[:space:]]*${_g}[[:space:]]*=[[:space:]]*{/,/^[[:space:]]*}/p" "$GROUPS_FILE" 2>/dev/null)
  _gdesc=$(printf '%s' "$_gblk" | sed -n 's/^[[:space:]]*description[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' | head -1)
  _gsudo=$(printf '%s' "$_gblk" | sed -n 's/^[[:space:]]*sudo[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' | head -1)
  _gos=$(printf '%s' "$_gblk" | sed -n 's/^[[:space:]]*os_groups[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' | head -1 | tr -d '"' | tr ',' ' ')
  [ -n "$_gdesc" ] || _gdesc="(no description)"
  [ -n "$_gsudo" ] || _gsudo="NONE"
  GROUP_MENU+=("${_g}|${_gdesc}|${_gsudo}|${_gos}")
done
show_group_menu() {
  echo "  Available groups — pick by NUMBER. ${GROUP_MENU[0]%%|*} = most privileged."
  for _i in "${!GROUP_MENU[@]}"; do
    IFS='|' read -r _gn _gd _gss _gso <<< "${GROUP_MENU[$_i]}"
    printf '    %d) %-10s %s\n' "$((_i+1))" "$_gn" "$_gd"
    [ "$_gss" = "NONE" ] && echo "       → read-only: login + inspect, NO sudo" || echo "       → can run: ${_gss//ALL=(ALL) NOPASSWD:/}"
  done
}
while true; do
  read -rp "  Usernames (comma-separated) [empty=done]: " extra_users_in
  [ -z "${extra_users_in// /}" ] && break
  # Parse comma-separated user list (trim spaces, drop empties)
  _new_users=()
  IFS=',' read -r -a _raw_users <<< "$extra_users_in"
  for _u in "${_raw_users[@]}"; do
    _u="${_u//[[:space:]]/}"
    [ -n "$_u" ] || continue
    if id "$_u" &>/dev/null; then
      warn "Local user '$_u' exists — skipped"
      continue
    fi
    _new_users+=("$_u")
  done
  [ ${#_new_users[@]} -eq 0 ] && { warn "No valid usernames in that list — try again"; continue; }
  echo "  Users to add: ${_new_users[*]}"
  # Group membership — pick by NUMBER (comma-separated, e.g. 1,3). Empty = no
  # groups = SSH-key only, no sudo, no extra OS groups.
  show_group_menu
  read -rp "  Group numbers for these users (comma-separated, e.g. 1,3) [1=${GROUP_MENU[0]%%|*}]: " group_nums
  # Map picked numbers → group names (ignore invalid/out-of-range entries)
  extra_groups=""
  if [ -n "${group_nums// /}" ]; then
    IFS=',' read -r -a _gnums <<< "$group_nums"
    for _gnum in "${_gnums[@]}"; do
      _gnum="${_gnum//[[:space:]]/}"
      [ -n "$_gnum" ] || continue
      if [ "$_gnum" -ge 1 ] 2>/dev/null && [ "$_gnum" -le "${#GROUP_MENU[@]}" ]; then
        extra_groups+="${GROUP_MENU[$((_gnum-1))]%%|*}, "
      else
        warn "Group #${_gnum} doesn't exist — skipped"
      fi
    done
    extra_groups="${extra_groups%, }"
  fi
  [ -z "$extra_groups" ] && extra_groups="admin"
  # Preview exactly what access these groups grant (union across all groups)
  _os_union=(); _sudo_union=()
  IFS=',' read -r -a _ga <<< "$extra_groups"
  for _g in "${_ga[@]}"; do
    _g="${_g//[[:space:]]/}"
    [ -n "$_g" ] || continue
    _gblk=$(sed -n "/^[[:space:]]*${_g}[[:space:]]*=[[:space:]]*{/,/^[[:space:]]*}/p" "$GROUPS_FILE" 2>/dev/null)
    _g_os=$(printf '%s' "$_gblk" | sed -n 's/^[[:space:]]*os_groups[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' | head -1 | tr -d '"' | tr ',' ' ')
    [ -n "$_g_os" ] && for _o in $_g_os; do
      case " ${_os_union[*]:-} " in *" $_o "*) ;; *) _os_union+=("$_o");; esac
    done
    _g_sudo=$(printf '%s' "$_gblk" | sed -n 's/^[[:space:]]*sudo[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' | head -1)
    [ -n "$_g_sudo" ] && [ "$_g_sudo" != "NONE" ] && _sudo_union+=("$_g_sudo")
  done
  ok "Will grant: OS groups [${_os_union[*]:-none}]  sudo: ${_sudo_union[*]:-NONE}"
  for _u in "${_new_users[@]}"; do
    EXTRA_USERS+=("${_u}:${extra_groups}")
  done
  if [ -n "${DEFAULT_EXTRA_USER_PASSWORD}" ]; then
    ok "Added ${_new_users[*]} (groups: ${extra_groups}, password: ${DEFAULT_EXTRA_USER_PASSWORD} — change on first login)"
  else
    ok "Added ${_new_users[*]} (groups: ${extra_groups}, SSH-key only, no password)"
  fi
  confirm "  Create more users?" "N" || break
done
[ ${#EXTRA_USERS[@]} -gt 0 ] && ok "${#EXTRA_USERS[@]} additional user(s) configured" || info "No additional users"

echo ""

# ===========================================================================
# 6b. Disable auto-updates (for DB/prod servers — prevents slow downs)
# ===========================================================================
warn "Auto-updates (apt-daily, unattended-upgrades) can slow DB/prod servers"
if confirm "  Disable auto-updates? (recommended)" "$DEFAULT_DISABLE_AUTO_UPDATES"; then
  DISABLE_AUTO_UPDATES=true
  ok "Auto-updates disabled"
else
  DISABLE_AUTO_UPDATES=false
  warn "Auto-updates enabled — may delay shutdown"
fi

echo ""

# Build extra_users HCL block
if [ ${#EXTRA_USERS[@]} -gt 0 ]; then
  EU_LINES=()
  EU_LAST_IDX=$((${#EXTRA_USERS[@]} - 1))
  for i in "${!EXTRA_USERS[@]}"; do
    sep=","
    [ "$i" -eq "$EU_LAST_IDX" ] && sep=""
    EU_NAME="${EXTRA_USERS[$i]%%:*}"
    EU_GROUPS="${EXTRA_USERS[$i]#*:}"
    [ -z "$EU_GROUPS" ] && EU_GROUPS="admin"
    # groups as quoted list: "a,b" → ["a", "b"]
    IFS=',' read -r -a EU_GA <<< "$EU_GROUPS"
    EU_GROUPS_LIST="["
    for _g in "${EU_GA[@]}"; do
      _g="${_g// /}"
      [ -n "$_g" ] && EU_GROUPS_LIST+="\"${_g}\", "
    done
    EU_GROUPS_LIST="${EU_GROUPS_LIST%, }]"
    EU_LINES+=("  { username = \"${EU_NAME}\", groups = ${EU_GROUPS_LIST}, password = \"${DEFAULT_EXTRA_USER_PASSWORD}\" }${sep}")
  done
  printf -v EXTRA_USERS_BLOCK "[\n%s\n]" "$(IFS=$'\n'; echo "${EU_LINES[*]}")"
else
  EXTRA_USERS_BLOCK="[]"
fi

# ===========================================================================
# 7. Generate new VM entry HCL block
# ===========================================================================
generate_vm_entry() {
  local name="$1" domain="$2" annot="$3" cpu="$4" mem="$5" disk="$6"
  local firm="$7" cpu_hot="$8" mem_hot="$9" thin="${10}" eager="${11}"
  local ip="${12}" gw="${13}" parts="${14}" data="${15}" lvm="${16}" mnt="${17}"
  local users="${18}" no_updates="${19}"

  cat <<ENTRY
  ${name} = {
    hostname   = "${name}"
    host       = "${VM_HOST}"
    domain     = "${domain}"
    annotation = "${annot}"
    cpu         = ${cpu}
    memory      = ${mem}
    disk_size   = ${disk}
    firmware    = "${firm}"
    enable_cpu_hot_add    = ${cpu_hot}
    enable_memory_hot_add = ${mem_hot}
    thin_provisioned      = ${thin}
    eagerly_scrub         = ${eager}
    ip_address   = "${ip}"
    netmask      = ${DEFAULT_NETMASK}
    gateway      = "${gw}"
    dns_servers  = [$(printf '"%s", ' "${DEFAULT_DNS[@]}" | sed 's/, $//')]
    ipam_enabled = true
    os_partitions = ${parts}
    data_disks = ${data}
    lvm_config = ${lvm}
    mount_points = ${mnt}
    extra_users = ${users}
    disable_auto_updates = ${no_updates}

    # ── Future provisioning (uncomment + edit what you need, then re-deploy) ──
    # folder                     = "${ENV_DIR#${SCRIPT_DIR}/../}"   # vSphere folder
    # wait_for_guest_net_timeout = 300                               # secs before giving up on guest IP
    # enable_node_exporter       = true                              # prometheus node_exporter
    #
    # Add a second NIC:
    # extra_networks = [
    #   { network_name = "VM Network", ip_address = "198.51.100.20", netmask = 24 }
    # ]
    #
    # Add extra data disks (each = new VMDK on the datastore):
    # data_disks = [
    #   { label = "data01", size = 120, thin_provisioned = true },
    #   { label = "data02", size = 200, unit_number = 14, eagerly_scrub = false }
    # ]
    #
    # Advanced LVM on a data disk (PV/VG custom layout):
    # lvm_config = [
    #   { vg_name = "vg_data", lv_name = "lv_data", lv_size = "100%FREE",
    #     mount_point = "/data", filesystem = "xfs", devices = ["/dev/sdb"] }
    # ]
    #
    # Raw device mount (non-LVM), e.g. a partition:
    # mount_points = [
    #   { device = "/dev/sda3", mount_point = "/opt", filesystem = "ext4" }
    # ]
    #
    # Extra users (password optional — blank = SSH key only; groups from
    # secure/<vc>/<env>/user-groups.tfvars — admin/app/db/readonly, one or more):
    # extra_users = [
    #   { username = "devops", groups = ["app"], password = "" }
    #   { username = "rakib",  groups = ["app", "db"], password = "" }
    # ]
  }
ENTRY
}

# ===========================================================================
# 8. Per-VM config file (deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars)
# ===========================================================================
CONFIG_FILE="${ENV_DIR}/vm-${VM_NAME}_${FREE_IP}.tfvars"

# Each tree line is both printed to the console and collected into TREE_BLOCK
# (ANSI codes stripped) so the config file gets the same layout as a comment.
TREE_BLOCK=""
_tree_line() {
  local line="$1"
  printf '%s\n' "$line" | sed -e 's/\\033\[[0-9;]*[a-zA-Z]//g' >> "${TREE_BLOCK_TMP}"
  echo -e "$line"
}

# Tree diagrams
# ============= OS =============
show_os_tree() {
  local os_total="$1"
  local sda2_size=$((os_total - _boot_gb))
  local root_in_tree=false
  _tree_line ""
  _tree_line "  ${BOLD}┌─────────────────────────────────────────────┐${NC}"
  _tree_line "  ${BOLD}│  OS Disk Layout (your selections)              │${NC}"
  _tree_line "  ${BOLD}└─────────────────────────────────────────────┘${NC}"
  _tree_line "  /dev/sda — ${os_total} GB"
  _tree_line "  ├── sda1 (${boot_display}) → /boot/efi"
  _tree_line "  └── sda2 (~$(human_size "${sda2_size}G")) → PV → vg_os"
  local lines=()
  local used=0
  # Check if root is in OS_PARTS
  for entry in "${OS_PARTS[@]}"; do
    IFS='|' read -r mp lv sz fs <<< "$entry"
    [ "$mp" = "/" ] && root_in_tree=true && break
  done
  $root_in_tree || lines+=("lv_root ($(human_size 8G)) → / [xfs]")
  $root_in_tree || used=$((used + 8))
  for entry in "${OS_PARTS[@]}"; do
    IFS='|' read -r mp lv sz fs <<< "$entry"
    local num="${sz%G}"
    [[ "$num" =~ ^[0-9]+$ ]] && used=$((used + num))
    [ "$mp" = "swap" ] && lines+=("${lv} ($(human_size "$sz")) → swap") && continue
    lines+=("${lv} ($(human_size "$sz")) → ${mp} [${fs}]")
  done
  local free=$((sda2_size - used))
  [ "$free" -lt 0 ] && free=0
  lines+=("FREE ~$(human_size "${free}G")  (remaining)")
  local last_idx=$(( ${#lines[@]} - 1 ))
  for i in "${!lines[@]}"; do
    local br="├──"
    [ "$i" -eq "$last_idx" ] && br="└──"
    _tree_line "  │   ${br} ${lines[$i]}"
  done
  _tree_line ""
}

# ========== DATA ==========
show_data_tree() {
  local sz="${1:-120}"
  [ "$sz" = "0" ] && return
  _tree_line ""
  _tree_line "  ${BOLD}┌─────────────────────────────────────────────┐${NC}"
  _tree_line "  ${BOLD}│  Data Disk Layout${DATA_DISKS_BLOCK:+" (active)"}              │${NC}"
  if [ "$DATA_DISKS_BLOCK" != "[]" ] && [ ${#LVM_ENTRIES[@]} -gt 0 ]; then
    _tree_line "  /dev/sdb — ${sz} GB → PV → vg_data"
    local used=0
    for entry in "${LVM_ENTRIES[@]}"; do
      IFS='|' read -r mp lv sz2 fs <<< "$entry"
      local n="${sz2%G}"; [[ "$n" =~ ^[0-9]+$ ]] && used=$((used + n))
      _tree_line "  │   ├── ${lv} ($(human_size "$sz2")) → ${mp} [${fs}]"
    done
    local free=$((sz - used))
    [ "$free" -lt 0 ] && free=0
    _tree_line "  │   └── FREE ~$(human_size "${free}G")"
  else
    _tree_line "  /dev/sdb — ${sz} GB (not configured — uncomment data_disks above)"
  fi
  _tree_line ""
}

# Render trees now — console output + fed into the config file comment below.
TREE_BLOCK_TMP="$(mktemp)"
trap 'rm -f "${TREE_BLOCK_TMP}"' EXIT
show_os_tree "${VM_DISK}"
if [ "$DATA_DISKS_BLOCK" != "[]" ]; then
  show_data_tree "$data_sz"
else
  show_data_tree 120
fi
TREE_COMMENT="$(
  while IFS= read -r line; do
    printf '# %s\n' "$line"
  done < "${TREE_BLOCK_TMP}"
)"
rm -f "${TREE_BLOCK_TMP}"

NEW_ENTRY=$(generate_vm_entry \
  "$VM_NAME" "$VM_DOMAIN" "$VM_ANNOT" "$VM_CPU" "$VM_RAM" "$VM_DISK" \
  "$VM_FIRM" "$CPU_HOT" "$MEM_HOT" "$DISK_THIN" "$DISK_EAGER" \
  "$FREE_IP" "$VM_GATEWAY" "$OS_PARTS_BLOCK" "$DATA_DISKS_BLOCK" \
  "$LVM_CONFIG_BLOCK" "$MOUNT_BLOCK" "$EXTRA_USERS_BLOCK" "$DISABLE_AUTO_UPDATES")

cat > "$CONFIG_FILE" <<PERVM
#############################################################
# VM config — ${VM_NAME} (${FREE_IP})
# vCenter: ${VCENTER}   Env: ${ENV}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
#
# HOW TO USE
# ───────────────────────────────────────────────────────────
# Deploy this VM only (other VMs untouched):
#   bash scripts/deploy-vm.sh ${VCENTER} ${ENV} ${VM_NAME}
#   bash scripts/deploy-vm.sh ${VCENTER} ${ENV} ${VM_NAME} --plan   # preview first
#
# Destroy (safe — explicit, nothing disappears by accident):
#   bash scripts/destroy.sh ${VCENTER} ${ENV} ${VM_NAME} --plan     # preview
#   bash scripts/destroy.sh ${VCENTER} ${ENV} ${VM_NAME} --yes      # destroy
#
# Reconcile ALL VMs in this env with the deploy/<vcenter>/<env>/*.tfvars files
# (applies plan-only drift shows, destroys only state-tracked VMs that are gone):
#   bash scripts/deploy-sync.sh ${VCENTER} ${ENV} --plan
#   bash scripts/deploy-sync.sh ${VCENTER} ${ENV}
#
# Manually, from the terraform dir:
#   cd terraform
#   terraform plan   -state=terraform.${VCENTER}.${ENV}.tfstate -var-file="../deploy/${VCENTER}/${ENV}/vm-${VM_NAME}_${FREE_IP}.tfvars" -target='module.vm["${VM_NAME}"]'
#   terraform apply  -state=terraform.${VCENTER}.${ENV}.tfstate -var-file="../deploy/${VCENTER}/${ENV}/vm-${VM_NAME}_${FREE_IP}.tfvars" -target='module.vm["${VM_NAME}"]'
#
# Git note: this file is gitignored (deploy/*/*/vm-*.tfvars).
# Its values (inventory, SSH key, IPs) are NOT pushed to GitHub.
#############################################################

# ══════════════════════════════════════════════════════════════
# 📊 DISK LAYOUT  (what you selected when generating this config)
# ══════════════════════════════════════════════════════════════
${TREE_COMMENT}

# ══════════════════════════════════════════════════════════════
# ⚡ COMPUTE  (vCenter inventory — per-vCenter, shared)
# ══════════════════════════════════════════════════════════════
datacenter    = "${GOVC_DC_SEL}"
cluster       = "${VM_CLUSTER}"
datastore     = "${VM_DATASTORE}"
network       = "${NET_PORT_GROUP}"
template      = "${VM_TEMPLATE}"
resource_pool = "${VM_RESOURCE_POOL:-Resources}"

# ══════════════════════════════════════════════════════════════
# 🔑 SSH
# ══════════════════════════════════════════════════════════════
ssh_public_key = "${SSH_KEY}"

# ══════════════════════════════════════════════════════════════
# 📦 VM CONFIG  (this VM)
# ══════════════════════════════════════════════════════════════
vm_configs = {
${NEW_ENTRY}
}
PERVM
ok "Created ${CONFIG_FILE}"

echo ""
info "Deploy this VM with:"
echo "  bash scripts/deploy-vm.sh ${VCENTER} ${ENV} ${VM_NAME}"
echo "  # or manually:"
echo "  cd terraform"
echo "  terraform plan   -state=terraform.${VCENTER}.${ENV}.tfstate -var-file=\"../deploy/${VCENTER}/${ENV}/vm-${VM_NAME}_${FREE_IP}.tfvars\" -target='module.vm[\"${VM_NAME}\"]'"
echo "  terraform apply  -state=terraform.${VCENTER}.${ENV}.tfstate -var-file=\"../deploy/${VCENTER}/${ENV}/vm-${VM_NAME}_${FREE_IP}.tfvars\" -target='module.vm[\"${VM_NAME}\"]'"

show_os_tree() {
  local os_total="$1"
  local sda2_size=$((os_total - _boot_gb))
  local root_in_tree=false
  echo ""
  echo -e "  ${BOLD}┌─────────────────────────────────────────────┐${NC}"
  echo -e "  ${BOLD}│  OS Disk Layout (your selections)              │${NC}"
  echo -e "  ${BOLD}└─────────────────────────────────────────────┘${NC}"
  echo "  /dev/sda — ${os_total} GB"
  echo "  ├── sda1 (${boot_display}) → /boot/efi"
  echo "  └── sda2 (~$(human_size "${sda2_size}G")) → PV → vg_os"
  local lines=()
  local used=0
  # Check if root is in OS_PARTS
  for entry in "${OS_PARTS[@]}"; do
    IFS='|' read -r mp lv sz fs <<< "$entry"
    [ "$mp" = "/" ] && root_in_tree=true && break
  done
  $root_in_tree || lines+=("lv_root ($(human_size 8G)) → / [xfs]")
  $root_in_tree || used=$((used + 8))
  for entry in "${OS_PARTS[@]}"; do
    IFS='|' read -r mp lv sz fs <<< "$entry"
    local num="${sz%G}"
    [[ "$num" =~ ^[0-9]+$ ]] && used=$((used + num))
    [ "$mp" = "swap" ] && lines+=("${lv} ($(human_size "$sz")) → swap") && continue
    lines+=("${lv} ($(human_size "$sz")) → ${mp} [${fs}]")
  done
  local free=$((sda2_size - used))
  [ "$free" -lt 0 ] && free=0
  lines+=("FREE ~$(human_size "${free}G")  (remaining)")
  local last_idx=$(( ${#lines[@]} - 1 ))
  for i in "${!lines[@]}"; do
    local br="├──"
    [ "$i" -eq "$last_idx" ] && br="└──"
    echo "  │   ${br} ${lines[$i]}"
  done
  echo ""
}

show_data_tree() {
  local sz="${1:-120}"
  [ "$sz" = "0" ] && return
  echo ""
  echo -e "  ${BOLD}┌─────────────────────────────────────────────┐${NC}"
  echo -e "  ${BOLD}│  Data Disk Layout${DATA_DISKS_BLOCK:+" (active)"}              │${NC}"
  if [ "$DATA_DISKS_BLOCK" != "[]" ] && [ ${#LVM_ENTRIES[@]} -gt 0 ]; then
    echo "  /dev/sdb — ${sz} GB → PV → vg_data"
    local used=0
    for entry in "${LVM_ENTRIES[@]}"; do
      IFS='|' read -r mp lv sz2 fs <<< "$entry"
      local n="${sz2%G}"; [[ "$n" =~ ^[0-9]+$ ]] && used=$((used + n))
      echo "  │   ├── ${lv} ($(human_size "$sz2")) → ${mp} [${fs}]"
    done
    local free=$((sz - used))
    [ "$free" -lt 0 ] && free=0
    echo "  │   └── FREE ~$(human_size "${free}G")"
  else
    echo "  /dev/sdb — ${sz} GB (not configured — uncomment data_disks above)"
  fi
  echo ""
}

# Auto-decrypt credentials so terraform works immediately
DECRYPT_SCRIPT="${SCRIPT_DIR}/sops-decrypt.sh"
if [ -f "$DECRYPT_SCRIPT" ]; then
  bash "$DECRYPT_SCRIPT" "$VCENTER" "$ENV" 2>/dev/null && ok "Credentials decrypted → terraform/${VCENTER}/${ENV} ready" || warn "sops-decrypt failed — run manually later"
fi

# Done
echo ""
ok "Config file → ${CONFIG_FILE}"
echo ""
echo -e "  ${BOLD}Deploy:${NC}"
echo "    bash scripts/deploy-vm.sh ${VCENTER} ${ENV} ${VM_NAME}"
echo ""
echo "  Note: deploy-vm.sh uses -target, so ONLY this VM is applied —"
echo "  other VMs in the same state are never touched."
echo ""
echo "  Add more VMs: run this script again — each VM gets its own file."
echo ""
