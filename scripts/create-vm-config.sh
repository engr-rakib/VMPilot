#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Script   : create-vm-config.sh
# Path     : /opt/terraform-lab/projects/project01/scripts/create-vm-config.sh
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

# ─── Central defaults (editable) ─────────────────────────────────────────
# Edit scripts/vm-defaults.conf to change the defaults proposed by every prompt.
# If the file is missing, fall back to the built-in values below.
CONF_FILE="${SCRIPT_DIR}/vm-defaults.conf"
if [ -f "$CONF_FILE" ]; then
  set -a; source "$CONF_FILE"; set +a
fi
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
info "Defaults: scripts/vm-defaults.conf${CONF_FILE:+ (loaded)}"

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
  prompt_required VM_NAME "VM name (vCenter + hostname)" "${1:-${DEFAULT_VM_NAME:-myvm}}"
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
# A vCenter = top-level deploy/<vcenter>/ dir that contains env SUB-directories
# (dev/prod/staging/...). Legacy flat env dirs (deploy/dev, secure/dev — the old
# layout kept parallel) have no env subdirs and are NOT treated as vCenters.
info "vCenter"
VCENTERS=()
for d in "${SCRIPT_DIR}"/../deploy/*/; do
  [ -d "$d" ] || continue
  v=$(basename "$d")
  [ "$v" = "examples" ] && continue
  ls -d "${d}"*/ >/dev/null 2>&1 || continue
  [[ " ${VCENTERS[*]} " == *" $v "* ]] || VCENTERS+=("$v")
done
if [ "${#VCENTERS[@]}" -eq 0 ]; then
  die "No vCenter configured yet — run: bash scripts/vcenter-setup.sh   (creates deploy/<vcenter>/ + secure/<vcenter>/)"
fi
i=1
for v in "${VCENTERS[@]}"; do echo "  $i) $v"; i=$((i+1)); done
echo "  $i) Create NEW vCenter (run vcenter-setup.sh)"
read -rp "$(echo -e "${CYAN}Select vCenter${NC} [1]: ")" vc_sel
vc_sel="${vc_sel:-1}"
if [ "$vc_sel" = "$i" ]; then
  echo "  New vCenter: run bash scripts/vcenter-setup.sh first, then re-run this script."
  exit 1
fi
VCENTER="${VCENTERS[$((vc_sel-1))]:-}"
[ -n "$VCENTER" ] || die "Invalid vCenter selection."
mkdir -p "${SCRIPT_DIR}/../deploy/${VCENTER}"
info "vCenter: ${VCENTER}"

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
read -rp "$(echo -e "${CYAN}Select${NC} [1]: ")" env_sel
env_sel="${env_sel:-1}"
if [ "$env_sel" = "$i" ]; then
  prompt_required ENV "New env name (dev/prod/staging/qa/...)" ""
  ENV="${ENV// /_}"
else
  ENV="${ENVS[$((env_sel-1))]:-dev}"
fi
mkdir -p "${SCRIPT_DIR}/../deploy/${VCENTER}/${ENV}"
ENV_DIR="${SCRIPT_DIR}/../deploy/${VCENTER}/${ENV}"

# Per-env override dir under secure/<vcenter>/<env>/ — used when the operator
# wants per-env values (dns/network/base-ip/datastore/...) to differ from the
# top-level secure/<vcenter>/vcenter.tfvars. Auto-created with a commented
# template; per-env keys WIN only when actually set.
mkdir -p "${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}"
OVERRIDE_TEMPLATE="${SCRIPT_DIR}/../secure/${VCENTER}/${ENV}/vcenter.tfvars"
if [ ! -f "$OVERRIDE_TEMPLATE" ]; then
  cat > "$OVERRIDE_TEMPLATE" <<EOF
# Per-env override — secure/${VCENTER}/${ENV}/vcenter.tfvars
# Uncomment + set any key to OVERRIDE the top-level secure/${VCENTER}/vcenter.tfvars
# for this environment only. Keys left commented fall back to the top-level value.
# (credentials are NEVER per-env — secrets stay in secure/${VCENTER}/credentials.tfvars)
#
# datacenter    = "dc_pilot"
# cluster       = "primary_cluster"
# resource_pool = "Resources"
# datastore     = "datastore01"
# network       = "VM Network"
# template      = "ubuntu-24-template"
# domain        = "example.local"
# gateway       = "198.51.100.1"
# netmask       = 24
# dns_servers   = ["203.0.113.53", "203.0.113.54"]
# ipam_base_ip  = "198.51.100.106"
EOF
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
  # scalar string/number keys
  eval "$(grep -E '^(datacenter|cluster|resource_pool|datastore|network|template|domain|gateway|netmask|ipam_base_ip)\s*=' "$f" | sed -E 's/\s*([a-z_]+)\s*=\s*"([^"]*)"/\1="\2"/; s/\s*([a-z_]+)\s*=\s*([0-9]+)/\1="\2"/')"
  DEFAULT_DATACENTER="${datacenter:-$DEFAULT_DATACENTER}"
  DEFAULT_CLUSTER="${cluster:-$DEFAULT_CLUSTER}"
  DEFAULT_RESOURCE_POOL="${resource_pool:-$DEFAULT_RESOURCE_POOL}"
  DEFAULT_DATASTORE="${datastore:-$DEFAULT_DATASTORE}"
  DEFAULT_NETWORK="${network:-$DEFAULT_NETWORK}"
  DEFAULT_TEMPLATE="${template:-$DEFAULT_TEMPLATE}"
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
  local type_flag="$1"
  govc find . "${type_flag}" 2>/dev/null | sed 's|.*/||' | sort -u || true
}

govc_pick() {
  local label="$1" type_flag="$2" default_val="$3"
  local items=()
  if $GOVC_READY; then
    while IFS= read -r line; do
      [ -n "$line" ] && items+=("$line")
    done < <(govc_list "${type_flag}")
  fi
  if [ "${#items[@]}" -gt 0 ]; then
    echo ""
    echo "  ${label}:"
    for i in "${!items[@]}"; do echo "  $((i+1))) ${items[$i]}"; done
    echo "  $(( ${#items[@]} + 1 ))) Custom (type manually)"
    read -rp "$(echo -e "${CYAN}Select${NC} [1=${items[0]}]: ")" sel
    sel="${sel:-1}"
    if [ "$sel" -ge 1 ] && [ "$sel" -le "${#items[@]}" ]; then
      printf -v "$4" '%s' "${items[$((sel-1))]}"
    else
      prompt_required "$4" "${label}" "${default_val}"
    fi
  else
    prompt_required "$4" "${label}" "${default_val}"
  fi
  ok_inline "${label}: $(eval echo \$$4)"
}

info "vCenter resource selection"
# Datacenter first — no GOVC_DATACENTER set yet
govc_pick "Datacenter" "-type d" "$DEFAULT_DATACENTER" GOVC_DC_SEL
export GOVC_DATACENTER="$GOVC_DC_SEL"

# Now list within the selected datacenter
govc_pick "Cluster"              "-type c" "$DEFAULT_CLUSTER" VM_CLUSTER
govc_pick "Datastore"            "-type s" "$DEFAULT_DATASTORE" VM_DATASTORE
govc_pick "Network port group"   "-type n" "$DEFAULT_NETWORK"        NET_PORT_GROUP
govc_pick "Template (VM)"        "-type m" "$DEFAULT_TEMPLATE" VM_TEMPLATE
echo ""

prompt_required BASE_IP "Starting IP for free-IP scan (based on port group subnet)" "$DEFAULT_BASE_IP"
ok_inline "Scan from: ${BASE_IP}"
echo ""

# ===========================================================================
# 3. Auto-assign free IP
# ===========================================================================
info "Free IP scan (on ${NET_PORT_GROUP})"
FREE_IP=""
for try_ip in "$BASE_IP" "$(echo "$BASE_IP" | awk -F. '{print $1"."$2"."$3"."$4+1}')"; do
  result=$(echo "{\"base_ip\": \"$try_ip\"}" | bash "$SCRIPT_DIR/next_free_ip.sh" 2>/dev/null || echo '{"error":"failed"}')
  FREE_IP=$(echo "$result" | jq -r '.free_ip // empty')
  [ -n "$FREE_IP" ] && break
done
if [ -n "$FREE_IP" ]; then
  ok "Free IP found: ${FREE_IP} (port group: ${NET_PORT_GROUP})"
else
  warn "Could not auto-find free IP — you will need to set it manually."
  FREE_IP="$BASE_IP"
fi
prompt_optional VM_GATEWAY "Gateway" "$DEFAULT_GATEWAY"
ok_inline "Gateway: ${VM_GATEWAY}"
echo ""

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
    OS_PARTS_LINES+=("  { mount_point = \"/\",      size = \"${sz}\" }${sep}")
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
EXTRA_USERS=()
info "Additional OS users (create VM owner accounts)"
echo "  Enter usernames one by one. Leave empty to finish."
echo "  Default password: ${DEFAULT_EXTRA_USER_PASSWORD} (user must change on first login)"
while true; do
  read -rp "  Username [empty=done]: " extra_user
  [ -z "$extra_user" ] && break
  if id "$extra_user" &>/dev/null; then
    warn "Local user '$extra_user' exists — skipped"
    continue
  fi
  EXTRA_USERS+=("$extra_user")
  ok "Added ${extra_user} (password: ${DEFAULT_EXTRA_USER_PASSWORD} — change on first login)"
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
    EU_LINES+=("  { username = \"${EXTRA_USERS[$i]}\", password = \"${DEFAULT_EXTRA_USER_PASSWORD}\" }${sep}")
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
  }
ENTRY
}

# ===========================================================================
# 8. Per-VM config file (deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars)
# ===========================================================================
CONFIG_FILE="${ENV_DIR}/vm-${VM_NAME}_${FREE_IP}.tfvars"

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
#
# Git note: this file is gitignored (deploy/*/*/vm-*.tfvars).
# Its values (inventory, SSH key, IPs) are NOT pushed to GitHub.
#############################################################

# ══════════════════════════════════════════════════════════════
# ⚡ COMPUTE  (vCenter inventory — per-vCenter, shared)
# ══════════════════════════════════════════════════════════════
datacenter    = "${GOVC_DC_SEL}"
cluster       = "${VM_CLUSTER}"
datastore     = "${VM_DATASTORE}"
network       = "${NET_PORT_GROUP}"
template      = "${VM_TEMPLATE}"
resource_pool = "${DEFAULT_RESOURCE_POOL:-Resources}"

# IPAM fallback scan start (first IP tried when no ip pin). Per-vCenter value.
ipam_base_ip = "${DEFAULT_BASE_IP}"

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

# Tree diagrams
show_os_tree "${VM_DISK}"
if [ "$DATA_DISKS_BLOCK" != "[]" ]; then
  show_data_tree "$data_sz"
else
  show_data_tree 120
fi

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
