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

#############################################################
# vcenter-setup.sh — Interactive vCenter Setup (vCenter-wise)
#############################################################
# PURPOSE
#   One-shot wizard to configure a vCenter for the project.
#   Prompts for credentials + inventory, encrypts them with SOPS/age,
#   and stores them as secure/<vcenter>/{credentials,vcenter}.tfvars
#   so that deploy-vm.sh / deploy-sync.sh can decrypt on demand.
#   (credentials.tfvars = encrypted; vcenter.tfvars = plaintext inventory)
#
# LAYOUT (vCenter-wise)
#   secure/<vcenter>/credentials.tfvars   (encrypted — server/user/password)
#   secure/<vcenter>/vcenter.tfvars       (plaintext — inventory + network + ipam)
#   secure/<vcenter>/{dev,prod,staging}/vcenter.tfvars
#                                         (per-env overrides — commented template;
#                                          uncomment a key to override the top-level
#                                          value for that env only; absent → inherit)
#   deploy/<vcenter>/{dev,prod,staging}/  (auto-created env dirs for VM configs)
#
#   The vCenter directory name = <datacenter>_<vsphere_server>, e.g.
#   dc_pilot_192.0.2.10 — so the datacenter identity is visible in
#   the dir name. A vCenter directory is detected as deploy/<name>/ containing
#   env sub-directories.
#
# CONFIGURABLE DEFAULTS
#   Inventory [default] values come from secure/vm-defaults.conf (key=value);
#   edit that file to change the defaults proposed by every prompt.
#   The vCenter SERVER + USER are always required here (per-vCenter). For an
#   existing vCenter they are pre-filled from secure/<vcenter>/credentials.tfvars;
#   for a NEW vCenter you must type them.
#
# WHEN TO USE
#   - First-time setup of a brand-new vCenter (auto-creates its env dirs).
#   - Switching to a DIFFERENT vCenter (new server, cluster, datastore).
#   - Rotating the vSphere password or moving inventory names.
#
# HOW TO USE
#   bash scripts/vcenter-setup.sh
#   (no arguments — everything is asked interactively; Enter = default)
#
# WHAT IT DOES
#   1. Shows a menu of existing vCenters + option to create new.
#   2. If an existing vCenter is chosen, reads its CURRENT values and uses
#      them as defaults (so a single change is a few Enter presses).
#   3. For a NEW vCenter: asks server FQDN/IP + datacenter, then auto-creates
#      deploy/<datacenter>_<server>/{dev,prod,staging}/ + secure/<vcenter>/
#      (dir name = <datacenter>_<server>). Per-env override dirs are created
#      under secure/<vcenter>/{dev,prod,staging}/ with a commented template.
#   4. Prompts: server / user / password (typed, confirmed) / datacenter /
#      cluster / resource_pool / datastore / network / template / domain /
#      gateway / netmask / DNS / base IP — each shows [default].
#   5. Shows a summary diff and asks for confirmation before writing.
#   6. Writes plaintext to .tmp-sops-plain/<vcenter>/ (git-ignored, inside the
#      project so sops creation-rules match).
#   7. Encrypts credentials with sops --encrypt --age <public-key> →
#      secure/<vcenter>/credentials.tfvars ; copies inventory plaintext →
#      secure/<vcenter>/vcenter.tfvars (readable, no secrets).
#   8. Deletes the plaintext staging dir automatically.
#
# OUTPUT / AFTER
#   secure/<vcenter>/credentials.tfvars   (encrypted)
#   secure/<vcenter>/vcenter.tfvars       (plaintext — inventory, readable)
#   Verify:  bash scripts/sops-decrypt.sh <vcenter> <env> --clean
#   Deploy:  bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>
#
# PREREQUISITES
#   - sops installed
#   - age key at $SOPS_AGE_KEY_FILE or ~/.config/sops/age/keys.txt
#   - .sops.yaml present at repo root (creation rules for secure/ + .tmp-sops-plain/)
#############################################################

# ─── helpers ───────────────────────────────────────────────
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'; c_bold=$'\e[1m'; c_rst=$'\e[0m'
info()  { printf '%s::%s %s\n' "$c_cyn" "$c_rst" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$c_yel" "$c_rst" "$*"; }
error() { printf '%s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
ok()    { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }

# prompt with default shown; if input empty → keep default
ask() { # $1=label, $2=var-name, $3=default
  local label="$1" var="$2" def="${3:-}" input
  read -rp "$(printf '%s [%s]: ' "$label" "${def:-<required>}")" input
  if [ -n "$input" ]; then eval "$var=\"\$input\""
  elif [ -n "$def" ]; then eval "$var=\"\$def\""
  fi
}

# a vCenter = secure/<name>/ holding credentials.tfvars + vcenter.tfvars
# (the configured identity). deploy/<name>/ only holds VM configs.
list_vcenters() {
  local d v
  for d in secure/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ "$v" = "README.md" ] && continue
    [ -f "${d}credentials.tfvars" ] || [ -f "${d}vcenter.tfvars" ] || continue
    echo "$v"
  done
}

# Orphaned deploy/<name>/ dirs = VM config dirs whose vCenter no longer exists
# in secure/ (deleted/never onboarded). They can no longer be deployed and just
# hold stale per-VM configs → safe to remove.
list_orphans() {
  local d v
  for d in deploy/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ "$v" = "examples" ] && continue
    # vCenter still configured → not orphaned
    [ -f "secure/${v}/credentials.tfvars" ] || [ -f "secure/${v}/vcenter.tfvars" ] && continue
    # has env sub-dirs (a real vCenter config dir, not a stray file)
    if ls -d "${d}"*/ >/dev/null 2>&1; then echo "$v"; fi
  done
}

# Remove orphaned deploy/<v>/ dirs after confirmation. Also removes any leftover
# secure/<v>/ subdir (per-env override only, no top-level identity files).
cleanup_orphans() {
  local v
  echo ""
  echo "  Orphaned deploy/ dirs (vCenter not in secure/ anymore):"
  while read -r v; do
    [ -z "$v" ] && continue
    printf '    - deploy/%s/   (%s env, %s vm files)\n' "$v" \
      "$(ls -d "deploy/${v}"/*/ 2>/dev/null | wc -l)" \
      "$(ls "deploy/${v}"/*/vm-*.tfvars 2>/dev/null | wc -l)"
  done <<< "$ORPHANS"
  read -rp "  Remove all of the above? (y=confirm / n=skip) [N]: " CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES)
      while read -r v; do
        [ -z "$v" ] && continue
        rm -rf "deploy/${v}" "secure/${v}"
        ok "Removed deploy/${v} + secure/${v}"
      done <<< "$ORPHANS"
      ;;
    *) info "Skipped — nothing removed." ;;
  esac
}

# Write a commented per-env override template (values commented → inherit top-level).
# secure/<dir>/<env>/vcenter.tfvars — uncomment + set a key to override the TOP-LEVEL
# secure/<dir>/vcenter.tfvars for that environment only. Never contains credentials.
create_override_template() {
  local dir="$1" env="$2"
  local out="secure/${dir}/${env}/vcenter.tfvars"
  [ -f "$out" ] && return 0
  cat > "$out" <<EOF
# Per-env override — secure/${dir}/${env}/vcenter.tfvars
# Uncomment + set a key to OVERRIDE the top-level secure/${dir}/vcenter.tfvars
# for this environment only. Keys left commented fall back to the top-level value.
# (credentials are NEVER per-env — secrets stay in secure/${dir}/credentials.tfvars)
#
# vCenter resource selections — OPTIONAL per-env pinning. By default these are
# auto-discovered by govc at VM-create time; uncomment only if THIS environment
# must force a specific datastore/network/resource_pool/cluster/template/host.
# datacenter     = "${DC}"
# clusters       = [$(printf '"%s", ' "${CLUSTERS[@]:-accesspilot_cluster}" | sed 's/, $//')]
# templates      = [$(printf '"%s", ' "${TEMPLATES[@]:-ubuntu24-template}" | sed 's/, $//')]
# datastores     = [$(printf '"%s", ' "${DATASTORES[@]:-datastore76}" | sed 's/, $//')]
# networks       = [$(printf '"%s", ' "${NETWORKS[@]:-VM Network}" | sed 's/, $//')]
# resource_pools = [$(printf '"%s", ' "${POOLS[@]:-Resources}" | sed 's/, $//')]
# host           = "node-ip"          # pin ALL this env's VMs to this node (e.g. 192.0.2.76)
#
# Changes here apply to existing VMs at their next deploy (deploy-vm.sh
# re-syncs policy onto the vm-*.tfvars file automatically).
#
# Network / IPAM defaults
# domain        = "${DOMAIN:-example.local}"
# gateway       = "${GW:-192.0.2.1}"
# netmask       = ${NM:-24}
# dns_servers   = [$(printf '"%s", ' "${DNS[@]}" | sed 's/, $//')]
#
# Per-network IPAM override — uncomment + set to REPLACE the whole top-level
# network_subnets map for THIS environment only (same format; per-host keys
# like "VM Network" on a host entry follow the same gateway/netmask/ipam_base
# shape). Blank here = inherit the top-level map.
# network_subnets = {
#   "DPortGroup_100" = { gateway = "${GW:-192.0.2.1}", netmask = ${NM:-24}, ipam_base = "192.0.2.31", range_end = "192.0.2.254" }
# }
EOF
}

# Write a per-vCenter VM-defaults template (policy-like VM defaults). This is
# created once per NEW vCenter at secure/<dir>/vm-defaults.conf and loaded by
# create-vm-config.sh after the vCenter is selected (missing file → built-ins).
# Holds the extra-user default password → gitignored, never committed.
create_vm_defaults_template() {
  local dir="$1"
  local out="secure/${dir}/vm-defaults.conf"
  [ -f "$out" ] && return 0
  cat > "$out" <<EOF
# vm-defaults.conf — VM defaults for vCenter: ${dir}
# Loaded by create-vm-config.sh AFTER this vCenter is selected; values here
# override the script's built-in defaults. One file per vCenter → policy-like
# per-datacenter defaults. Keep this file in secure/ (gitignored).
# Syntax: key=value lines. Empty password = accounts are SSH-key only.

# ── Identity ──────────────────────────────────────────────────────────────
DEFAULT_VM_NAME="myvm"                     # proposed VM name (can change)
DEFAULT_ANNOTATION="Server"                # "{VMNAME} Server" unless changed

# ── Hardware defaults ─────────────────────────────────────────────────────
DEFAULT_CPU="2"
DEFAULT_RAM="4"                            # GB
DEFAULT_FIRMWARE="efi"
DEFAULT_CPU_HOT_ADD="Y"                    # Y/N
DEFAULT_MEM_HOT_ADD="Y"                    # Y/N
DEFAULT_OS_DISK_GB="40"                    # min enforced = template disk size
DEFAULT_BOOT_SIZE="512M"                   # boot/efi partition (512M / 1G)
DEFAULT_PROVISIONING="1"                   # 1=thin 2=thick 3=eager

# ── OS partition default layout (mount_point:size, filesystem=xfs) ───────
DEFAULT_MOUNTS=("/:10" "/home:2" "/var:8" "/tmp:1")
TEMPLATE_DISK_GB=40                        # clone can't be smaller than this

# ── Data disk ─────────────────────────────────────────────────────────────
DEFAULT_DATA_DISK="N"                      # add data disk by default? Y/N
DEFAULT_DATA_DISK_GB="30"
DEFAULT_DATA_PROVISIONING="1"              # 1=thin 2=thick 3=eager

# ── SSH / users ───────────────────────────────────────────────────────────
# empty = script auto-detects ~/.ssh/id_*.pub and asks to use it
DEFAULT_SSH_KEY=""
# Set the default password for extra users created on THIS vCenter's VMs.
# First login forces a password change (cloud-init chpasswd expire).
DEFAULT_EXTRA_USER_PASSWORD=""

# ── Behavior ──────────────────────────────────────────────────────────────
DEFAULT_DISABLE_AUTO_UPDATES="Y"           # recommended for DB/prod
DEFAULT_SWAP="N"                           # swap suggestion prompt default

# ── IPAM ──────────────────────────────────────────────────────────────────
# Reserved host count at the bottom of every subnet (gateway/router/switches,
# DNS/DHCP, vCenter mgmt, special appliances). Explicit ipam_base wins.
DEFAULT_IPAM_RESERVE="30"
EOF
  info "Created secure/${dir}/vm-defaults.conf (edit for per-vCenter VM defaults)"
}

# User-group policy template — secure/<vcenter>/<env>/user-groups.tfvars
# Created for EVERY env (dev/prod/staging) of a new vCenter. Defines what OS
# access each GROUP (admin/app/db/readonly) grants to VM extra_users. Users are
# members of groups (can be in MANY); per-VM configs reference groups by name
# via extra_users[].groups.
create_user_groups_template() {
  local dir="$1" env="$2"
  local out="secure/${dir}/${env}/user-groups.tfvars"
  [ -f "$out" ] && return 0
  cat > "$out" <<EOF
# User group policy — secure/${dir}/${env}/user-groups.tfvars
# Defines what OS-level access each GROUP grants to VM extra_users in THIS env.
# Users are members of groups (a user can be in MANY groups); permission lives
# on the group. Applied to every VM in this env at deploy time (deploy-vm.sh
# loads this file).
#
# Group fields:
#   os_groups   = OS groups the user joins (created automatically)
#   sudo        = sudoers rule string; "NONE" = no sudo at all (sudo line omitted)
#   shell       = login shell (default /bin/bash)
#   description = why this group exists / who it is for — REQUIRED. Lands in the
#                 VM audit manifest (/etc/vmpilot-access.md).
#
# AUDIT: every VM gets /etc/vmpilot-access.md (who has access + group purpose)
# and sudo logging to /var/log/sudo.log. A user referencing an undefined group
# fails deployment (fail-fast) instead of silently losing access.
#
# IMPORTANT: after changing a group, redeploy VMs that use it
#   (bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>)
#
# A user with NO groups = SSH-key only, no sudo, no extra OS groups.
# Missing policy file = legacy full-sudo fallback.
#
# CUSTOMIZATION: copy the admin block to add your own group, e.g.
#   mygroup = {
#     os_groups   = ["mygroup"]
#     sudo        = "ALL=(ALL) NOPASSWD:/usr/bin/mytool"
#     shell       = "/bin/bash"
#     description = "What this group is for"
#   }

user_groups = {
  # ─── admin ─────────────────────────────────────────────────────────────
  # Full control. For infra admins who install packages, manage users,
  # reboot, read all logs. Grant ONLY to trusted operators.
  admin = {
    os_groups   = ["sudo", "adm"]
    sudo        = "ALL=(ALL) NOPASSWD:ALL"
    shell       = "/bin/bash"
    description = "Infra admin — full sudo + sudo/adm groups (trusted operators only)"
  }

  # ─── app ───────────────────────────────────────────────────────────────
  # Application owner/deployer. Can only manage services (systemctl) and
  # containers (docker) — no package install, no user management, no reboot.
  app = {
    os_groups   = ["app"]
    sudo        = "ALL=(ALL) NOPASSWD:/usr/bin/systemctl, ALL=(ALL) NOPASSWD:/usr/bin/docker"
    shell       = "/bin/bash"
    description = "App deployer — manage services (systemctl) + containers (docker) only"
  }

  # ─── db ────────────────────────────────────────────────────────────────
  # Database administrator. Can only run DB client commands (mysql/psql).
  # Does NOT get shell/file/package access. Pair with app for full DB+app work.
  db = {
    os_groups   = ["dbadmin"]
    sudo        = "ALL=(ALL) NOPASSWD:/usr/bin/mysql, ALL=(ALL) NOPASSWD:/usr/bin/psql"
    shell       = "/bin/bash"
    description = "DBA — DB client commands only (mysql/psql)"
  }

  # ─── readonly ──────────────────────────────────────────────────────────
  # Auditor/viewer. Can log in and inspect state, but CANNOT modify anything
  # (no sudo at all). Use for monitoring/audit accounts.
  readonly = {
    os_groups   = []
    sudo        = "NONE"
    shell       = "/bin/bash"
    description = "Auditor/viewer — no sudo, read-only access"
  }
}
EOF
  info "Created ${out} (edit for per-env user group policy)"
}

# ─── Central defaults (editable) ───────────────────────────────────────
# Edit secure/<vcenter>/vm-defaults.conf to change shared VM defaults.
# vCenter SERVER + USER are per-vCenter → always required here; they never
# come from vm-defaults.conf. Existing values are auto-loaded from
# secure/<vcenter>/credentials.tfvars + vcenter.tfvars as defaults; a NEW
# vCenter starts empty (everything typed by hand).
info "VM defaults: per-vCenter secure/<vcenter>/vm-defaults.conf (loaded by create-vm-config.sh)"

# ─── 1. vCenter selection (menu) ───────────────────────────
EXISTING=$(list_vcenters)
NEW_SERVER=""
IS_NEW=0

echo "${c_bold}  vCenter Setup${c_rst}"
echo "  ──────────────────────────────"
ORPHANS=$(list_orphans)
if [ -n "$EXISTING" ]; then
  echo "  Existing vCenters:"
  i=1
  while read -r v; do
    [ -z "$v" ] && continue
    printf '    %d) %s\n' "$i" "$v"
    VCENTERS[$i]="$v"; i=$((i+1))
  done <<< "$EXISTING"
  printf '    %d) %s\n' "$i" "Create NEW vCenter"
  if [ -n "$ORPHANS" ]; then
    printf '    %d) %s\n' "$((i+1))" "Remove orphaned deploy/ dirs ($(echo "$ORPHANS" | grep -c .) found)"
  fi
  read -rp "  Select (1-${i}${ORPHANS:+ or $((i+1))}): " SEL
  case "$SEL" in
    ''|*[!0-9]*) VCENTER="" ;;
    *) VCENTER="${VCENTERS[$SEL]:-}"; [ "$SEL" = "$i" ] && VCENTER="NEW" ;;
  esac
  if [ -n "$ORPHANS" ] && [ "$SEL" = "$((i+1))" ]; then
    cleanup_orphans
    exit 0
  fi
  if [ "$VCENTER" = "NEW" ]; then
    read -rp "  vCenter server IP/FQDN (becomes dir name): " NEW_SERVER
    NEW_SERVER="${NEW_SERVER// /}"
    [ -n "$NEW_SERVER" ] || { error "vCenter server required"; exit 1; }
    NEW_SERVER="$(echo "$NEW_SERVER" | sed -E 's#^[a-zA-Z]+://##; s#[/:]+$##; s/[^a-zA-Z0-9._-]/_/g')"
    # temp staging name = server only; final dir = <datacenter>_<server> (set later)
    VCENTER="$NEW_SERVER"
    IS_NEW=1
    warn "New vCenter — final dir name = <datacenter>_<server> (e.g. <dc>_${VCENTER})."
  elif [ -z "$VCENTER" ]; then
    error "Invalid selection."; exit 1
  else
    # existing vCenter — ensure deploy/<vcenter> exists (in case it only lived in secure/)
    mkdir -p "deploy/${VCENTER}"
    IS_NEW=0
  fi
else
  if [ -n "$ORPHANS" ]; then
    echo "  No configured vCenters yet. Found orphaned deploy/ dirs:"
    while read -r v; do
      [ -z "$v" ] && continue
      printf '    - deploy/%s/\n' "$v"
    done <<< "$ORPHANS"
    read -rp "  Remove them? (y=clean / n=skip, then create a vCenter) [N]: " ORPHAN_YN
    case "$ORPHAN_YN" in
      y|Y|yes|YES)
        cleanup_orphans
        ;;
    esac
    echo ""
  fi
  read -rp "  vCenter server IP/FQDN (becomes dir name): " NEW_SERVER
  NEW_SERVER="${NEW_SERVER// /}"
  [ -n "$NEW_SERVER" ] || { error "vCenter server required"; exit 1; }
  NEW_SERVER="$(echo "$NEW_SERVER" | sed -E 's#^[a-zA-Z]+://##; s#[/:]+$##; s/[^a-zA-Z0-9._-]/_/g')"
  VCENTER="$NEW_SERVER"
  IS_NEW=1
fi

# ─── 2. load existing values as defaults ───────────────────
SRC=".tmp-sops-plain/${VCENTER}"
mkdir -p "$SRC"
# Never leave plaintext credentials behind on any exit path (sops failure,
# abort, ctrl-c, etc.) — $SRC is reassigned after the dir-name fix in §3b,
# so the trap reads the CURRENT value at exit time.
trap 'rm -rf "${SRC:-}" 2>/dev/null || true' EXIT

D_SERVER=""; D_USER=""
D_PASS=""; D_DC=""; D_CLUSTER=""
D_DS=""; D_NET=""; D_TPL=""
D_RP=""
D_DOMAIN=""; D_GW=""; D_NM="24"; D_DNS=(); D_BASEIP=""

if [ -f "secure/${VCENTER}/credentials.tfvars" ] && [ -f "secure/${VCENTER}/vcenter.tfvars" ]; then
  sops -d "secure/${VCENTER}/credentials.tfvars" > "$SRC/credentials.tfvars" 2>/dev/null || true
  cp "secure/${VCENTER}/vcenter.tfvars" "$SRC/vcenter.tfvars" 2>/dev/null || true
  if [ -s "$SRC/credentials.tfvars" ]; then
    source <(grep -E '^(vsphere_server|vsphere_user|vsphere_password)' "$SRC/credentials.tfvars" | sed 's/ *= */=/')
    D_SERVER="${vsphere_server:-$D_SERVER}"; D_USER="${vsphere_user:-$D_USER}"; D_PASS="${vsphere_password:-}"
  fi
  if [ -s "$SRC/vcenter.tfvars" ]; then
    # legacy single-value keys
    source <(grep -E '^(datacenter|cluster|resource_pool|datastore|network|template|domain|gateway|netmask|ipam_base_ip)' "$SRC/vcenter.tfvars" | sed 's/ *= */=/')
    # new list-form keys (curated multi-options)
    D_CLUSTERS=(); D_TEMPLATES=(); D_DATASTORES=(); D_NETWORKS=(); D_POOLS=()
    while IFS= read -r _c; do [ -n "$_c" ] && D_CLUSTERS+=("$_c"); done \
      < <(grep -E '^clusters\s*=' "$SRC/vcenter.tfvars" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    while IFS= read -r _t; do [ -n "$_t" ] && D_TEMPLATES+=("$_t"); done \
      < <(grep -E '^templates\s*=' "$SRC/vcenter.tfvars" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    while IFS= read -r _d; do [ -n "$_d" ] && D_DATASTORES+=("$_d"); done \
      < <(grep -E '^datastores\s*=' "$SRC/vcenter.tfvars" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    while IFS= read -r _n; do [ -n "$_n" ] && D_NETWORKS+=("$_n"); done \
      < <(grep -E '^networks\s*=' "$SRC/vcenter.tfvars" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    while IFS= read -r _p; do [ -n "$_p" ] && D_POOLS+=("$_p"); done \
      < <(grep -E '^resource_pools\s*=' "$SRC/vcenter.tfvars" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    [ "${#D_CLUSTERS[@]}" -eq 0 ] && [ -n "${cluster:-}" ] && D_CLUSTERS=("$cluster")
    [ "${#D_TEMPLATES[@]}" -eq 0 ] && [ -n "${template:-}" ] && D_TEMPLATES=("$template")
    [ "${#D_DATASTORES[@]}" -eq 0 ] && [ -n "${datastore:-}" ] && D_DATASTORES=("$datastore")
    [ "${#D_NETWORKS[@]}" -eq 0 ] && [ -n "${network:-}" ] && D_NETWORKS=("$network")
    [ "${#D_POOLS[@]}" -eq 0 ] && [ -n "${resource_pool:-}" ] && D_POOLS=("$resource_pool")
    D_DC="${datacenter:-$D_DC}"
    D_DOMAIN="${domain:-$D_DOMAIN}"; D_GW="${gateway:-$D_GW}"; D_NM="${netmask:-$D_NM}"
    D_BASEIP="${ipam_base_ip:-$D_BASEIP}"
    D_DNS=(); while IFS= read -r _d; do [ -n "$_d" ] && D_DNS+=("$_d"); done \
      < <(grep -E '^dns_servers' "$SRC/vcenter.tfvars" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  fi
  # existing per-network IPAM (network_subnets map) — preserved on edit
  unset SUBNET_NAMES SUBNET_GW SUBNET_NM SUBNET_START SUBNET_END SUBNET_DNS
  declare -A SUBNET_GW SUBNET_NM SUBNET_START SUBNET_END SUBNET_DNS
  SUBNET_NAMES=()
  if grep -qE '^network_subnets\s*=' "$SRC/vcenter.tfvars" 2>/dev/null; then
    while IFS= read -r _line; do
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
      # ipam_base is the canonical per-network base; range_start is the legacy alias
      _start=$(grep -oE 'ipam_base[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      [ -n "$_start" ] || _start=$(grep -oE 'range_start[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _end=$(grep -oE 'range_end[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _dns=$(grep -oE '\[[^]]*\]' <<< "$_line" | head -1 | tr -d '[]"' | tr ',' ' ')
      [ -n "$_name$_gw$_nm$_start$_end$_dns" ] || continue
      SUBNET_NAMES+=("$_name")
      SUBNET_GW["$_name"]="$_gw"; SUBNET_NM["$_name"]="$_nm"
      SUBNET_START["$_name"]="$_start"; SUBNET_END["$_name"]="$_end"
      SUBNET_DNS["$_name"]="$_dns"
    done < <(sed -n '/^network_subnets[[:space:]]*=/,/^}/p' "$SRC/vcenter.tfvars")
  fi
  # network_hosts map — network → node pinning (DRS auto-placement when absent)
  unset NET_HOST_NODE
  declare -A NET_HOST_NODE=()
  if grep -qE '^network_hosts\s*=' "$SRC/vcenter.tfvars" 2>/dev/null; then
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
      [ -n "$_node" ] && NET_HOST_NODE["$_name"]="$_node"
    done < <(sed -n '/^network_hosts[[:space:]]*=/,/^}/p' "$SRC/vcenter.tfvars")
  fi
  # host_networks map — per-host gateway/netmask/ipam for standard-vSwitch
  # port groups (per-host subnets). Preserved on edit.
  unset HNET_NAMES HNET_GW HNET_NM HNET_BASE HNET_END
  declare -A HNET_GW HNET_NM HNET_BASE HNET_END
  HNET_NAMES=()
  if grep -qE '^host_networks\s*=' "$SRC/vcenter.tfvars" 2>/dev/null; then
    while IFS= read -r _line; do
      [[ "$_line" =~ ^[[:space:]]*# ]] && continue
      [[ "$_line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]] && continue
      [[ "$_line" =~ ^[[:space:]]*}[[:space:]]*$ ]] && continue
      _line="${_line//,/ }"
      _name=$(grep -oE '"[^"]+"[[:space:]]*=' <<< "$_line" | head -1 | sed -E 's/^"([^"]+)".*/\1/')
      [ -n "$_name" ] || continue
      _gw=$(grep -oE 'gateway[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _nm=$(grep -oE 'netmask[[:space:]]*=[[:space:]]*[0-9]+' <<< "$_line" | head -1 | grep -oE '[0-9]+')
      _base=$(grep -oE 'ipam_base[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      _end=$(grep -oE 'range_end[[:space:]]*=[[:space:]]*"[^"]+"' <<< "$_line" | head -1 | sed -E 's/.*"([^"]+)"/\1/')
      [ -n "$_name$_gw$_nm$_base$_end" ] || continue
      HNET_NAMES+=("$_name")
      HNET_GW["$_name"]="$_gw"; HNET_NM["$_name"]="$_nm"
      HNET_BASE["$_name"]="$_base"; HNET_END["$_name"]="$_end"
    done < <(sed -n '/^host_networks[[:space:]]*=/,/^}/p' "$SRC/vcenter.tfvars")
  fi
  info "Loaded existing values for '$VCENTER' — Enter keeps them."
  rm -f "$SRC/credentials.tfvars" "$SRC/vcenter.tfvars"
fi

ip_add() { # $1=ip $2=delta (0/+/−)
  local ip="$1" d="$2" a b c d3 n
  IFS='.' read -r a b c d3 <<< "$ip"
  n=$(( d3 + d ))
  echo "$a.$b.$c.$n"
}

# ─── 3. collect values ─────────────────────────────────────
SERVER="${D_SERVER:-$NEW_SERVER}"; USER="$D_USER"; PASSWORD="$D_PASS"
DC="$D_DC"; CLUSTER="$D_CLUSTER"; RP="$D_RP"; DS="$D_DS"; NET="$D_NET"; TPL="$D_TPL"
DOMAIN="${D_DOMAIN:-}"; GW="${D_GW:-}"; NM="${D_NM:-24}"; DNS=("${D_DNS[@]}")
BASEIP="${D_BASEIP:-}"
CLUSTERS=("${D_CLUSTERS[@]}"); TEMPLATES=("${D_TEMPLATES[@]}")
DATASTORES=("${D_DATASTORES[@]}"); NETWORKS=("${D_NETWORKS[@]}"); POOLS=("${D_POOLS[@]}")
[ "${#CLUSTERS[@]}" -eq 0 ] && [ -n "$CLUSTER" ] && CLUSTERS=("$CLUSTER")
[ "${#TEMPLATES[@]}" -eq 0 ] && [ -n "$TPL" ] && TEMPLATES=("$TPL")
[ "${#DATASTORES[@]}" -eq 0 ] && [ -n "$DS" ] && DATASTORES=("$DS")
[ "${#NETWORKS[@]}" -eq 0 ] && [ -n "$NET" ] && NETWORKS=("$NET")
[ "${#POOLS[@]}" -eq 0 ] && [ -n "$RP" ] && POOLS=("$RP")

echo ""
echo "  Fill values — Enter keeps the [default] shown:"
echo ""
ask "  vSphere server IP/FQDN"  SERVER  "$SERVER"
ask "  vSphere user"            USER    "$USER"
[ -n "$SERVER" ] || { error "vSphere server is required (per-vCenter)"; exit 1; }
[ -n "$USER" ]   || { error "vSphere user is required (per-vCenter)"; exit 1; }

read -rsp "  vSphere password (Enter to keep current): " PASSWORD_IN
echo ""
if [ -n "$PASSWORD_IN" ]; then
  read -rsp "  Confirm password: " PASSWORD_CONF
  echo ""
  [ "$PASSWORD_IN" = "$PASSWORD_CONF" ] || { error "Passwords do not match"; exit 1; }
  PASSWORD="$PASSWORD_IN"
fi
[ -n "$PASSWORD" ] || { error "Password required"; exit 1; }

# ─── 3a. govc auto-discovery (when creds valid) ─────────────
# Live vCenter → enumerate datacenters/clusters/datastores/networks/templates/
# resource pools so the operator picks from REAL inventory instead of typing.
# Clusters & templates are stored as LISTS (multi); datastore/network/
# resource_pool are auto-discovered at VM-creation time (create-vm-config.sh),
# so they are NOT persisted as single "chosen" values here.
GOVC_READY=false
GOVC_DCS=()
if command -v govc &>/dev/null; then
  export GOVC_URL="$SERVER" GOVC_USERNAME="$USER" GOVC_PASSWORD="$PASSWORD" GOVC_INSECURE=1 TERM=dumb
  if GOVC_DCS_RAW=$(govc find . -type d 2>/dev/null); then
    while IFS= read -r _d; do [ -n "$_d" ] && GOVC_DCS+=("$(basename "$_d")"); done <<< "$GOVC_DCS_RAW"
    [ "${#GOVC_DCS[@]}" -gt 0 ] && { GOVC_READY=true; info "govc connected — auto-discovering vCenter inventory"; }
  fi
fi
# list items within a datacenter (set GOVC_DATACENTER like create-vm-config.sh).
# $@ = govc find flags — "-type c" or "-type m -config.template true".
govc_list_in() { # $1+ = govc find flags
  $GOVC_READY || return 0
  [ -n "$DC" ] && export GOVC_DATACENTER="$DC"
  local out
  out=$(govc find . "$@" 2>/dev/null | sed 's|.*/||')
  if [[ "$*" == *"-type n"* ]]; then
    # Distributed-switch uplink bundles (DSwitch-DVUplinks-*) are not VM port
    # groups — never offer them as a network choice.
    out=$(printf '%s\n' "$out" | grep -vE 'DVUplinks' || true)
  fi
  printf '%s\n' "$out" | sort -u
}
# multi-pick helper: list discovered options, allow comma-separated selection
pick_multi() { # $1=label $2=type $3=out-array-name $4=defaults-array-name
  local label="$1" typ="$2" out="$3" defs=$4
  local items=() line find_args="-type $typ"
  # Templates only — plain VMs are NOT templates. govc find returns every
  # VirtualMachine for -type m, so filter on config.template = true.
  [ "$typ" = "m" ] && find_args="-type m -config.template true"
  while IFS= read -r line; do [ -n "$line" ] && items+=("$line"); done < <(govc_list_in $find_args)
  if [ "${#items[@]}" -gt 0 ]; then
    echo "  ${label} (discovered — comma-separated to select multiple, Enter=all):"
    for i in "${!items[@]}"; do printf '    %d) %s\n' "$((i+1))" "${items[$i]}"; done
    read -rp "  → " sel
    sel="${sel//,/ }"
    local picked=()
    if [ -z "$sel" ]; then picked=("${items[@]}")
    else
      for n in $sel; do
        [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#items[@]}" ] && picked+=("${items[$((n-1))]}")
      done
      [ "${#picked[@]}" -eq 0 ] && picked=("${items[0]}")
    fi
    eval "$out=(\"\${picked[@]}\")"
  elif eval "[ \${#${defs}[@]} -gt 0 ]" 2>/dev/null; then
    eval "$out=(\"\${${defs}[@]}\")"
  else
    read -rp "  ${label} (comma-separated, one+): " multi
    eval "$out=(\$multi)"
  fi
}

# ─── 3a1. full inventory discovery (live govc) ─────────────
# Enumerates the vCenter datastores in ONE pass for the §3a picks below.
# Host/node inventory is NOT collected here anymore — it is loaded LIVE from
# govc at VM-create time by scripts/vcenter-inventory.sh (create-vm-config.sh).
govc_discover_inventory() {
  $GOVC_READY || return 0
  [ -n "$DC" ] && export GOVC_DATACENTER="$DC"
  GOVC_DATASTORES=()
  # datacenter-wide datastores — the authoritative dropdown list (§2)
  while IFS= read -r _d; do [ -n "$_d" ] && GOVC_DATASTORES+=("$(basename "$_d")"); done \
    < <(govc find . -type s 2>/dev/null)
}

# Datacenter — single, but if discovered offer a pick
if [ "${#GOVC_DCS[@]}" -gt 0 ]; then
  if [ -n "$DC" ]; then
    echo "  Datacenter [${DC}] (Enter=keep / number to change):"
    for i in "${!GOVC_DCS[@]}"; do printf '    %d) %s\n' "$((i+1))" "${GOVC_DCS[$i]}"; done
    read -rp "  → " dc_sel
    case "$dc_sel" in
      ''|*[!0-9]*) : ;;
      *) [ "$dc_sel" -ge 1 ] 2>/dev/null && [ "$dc_sel" -le "${#GOVC_DCS[@]}" ] && DC="${GOVC_DCS[$((dc_sel-1))]}" ;;
    esac
  else
    DC="${GOVC_DCS[0]}"
    echo "  Datacenter: ${DC} (discovered)"
  fi
else
  ask "  Datacenter"  DC      "$D_DC"
fi

pick_multi "Cluster" c CLUSTERS D_CLUSTERS
CLUSTER="${CLUSTERS[0]:-}"
pick_multi "Template" m TEMPLATES D_TEMPLATES
TPL="${TEMPLATES[0]:-}"
pick_multi "Datastore" s DATASTORES D_DATASTORES
DS="${DATASTORES[0]:-}"
pick_multi "Network" n NETWORKS D_NETWORKS
NET="${NETWORKS[0]:-}"
pick_multi "Resource pool" p POOLS D_POOLS
RP="${POOLS[0]:-}"

# Full inventory (datacenter-wide datastores + per-node hosts) — live discovery
govc_discover_inventory
# Auto-fill a previously-empty datastore list from discovery so the file always
# carries the identified datastores (the operator can still curate via the pick
# above; an explicit pick wins).
if [ "${#DATASTORES[@]}" -eq 0 ] && [ "${#GOVC_DATASTORES[@]}" -gt 0 ]; then
  DATASTORES=("${GOVC_DATASTORES[@]}")
  DS="${DATASTORES[0]:-}"
  ok "Datastores auto-filled from discovery: [${DATASTORES[*]}]"
fi

# Per-vCenter network defaults (each vCenter/VLAN has its own)
echo ""
echo "  ─── Network defaults (per vCenter VLAN) ───"
ask "  Domain"      DOMAIN  "$D_DOMAIN"
ask "  Gateway"     GW      "$D_GW"
ask "  Netmask (CIDR, e.g. 24)" NM "$D_NM"
read -rp "$(printf '  DNS servers [%s]: ' "${D_DNS[*]:-comma-separated, e.g. 8.8.8.8,1.1.1.1}")" DNS_IN
if [ -n "$DNS_IN" ]; then
  DNS=()
  while IFS= read -r _d; do [ -n "$_d" ] && DNS+=("$_d"); done < <(echo "$DNS_IN" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
elif [ "${#D_DNS[@]}" -gt 0 ]; then
  DNS=("${D_DNS[@]}")
fi
[ -n "$DOMAIN" ] || { error "Domain is required (per-vCenter)"; exit 1; }
[ -n "$GW" ]     || { error "Gateway is required (per-vCenter)"; exit 1; }
[ "${#DNS[@]}" -gt 0 ] || { error "At least one DNS server is required (per-vCenter)"; exit 1; }

echo ""
echo "  ─── IPAM (new-VM free-IP scan start) ───"
ask "  Base IP for free-IP scan" BASEIP "$D_BASEIP"
[ -n "$BASEIP" ] || { error "Base IP is required (per-vCenter)"; exit 1; }

# per-network IPAM map (network_subnets) — preserved if loaded in §2
if ! declare -p SUBNET_NAMES >/dev/null 2>&1; then
  SUBNET_NAMES=()
  unset SUBNET_GW SUBNET_NM SUBNET_START SUBNET_END SUBNET_DNS
  declare -A SUBNET_GW SUBNET_NM SUBNET_START SUBNET_END SUBNET_DNS
fi
# network_hosts map (network → node pinning) — preserved if loaded in §2
if ! declare -p NET_HOST_NODE >/dev/null 2>&1; then
  unset NET_HOST_NODE
  declare -A NET_HOST_NODE=()
fi
# host_networks map (host → gateway/netmask/ipam for per-host standard-vSwitch
# networks) — preserved if loaded in §2; init for new setups.
if ! declare -p HNET_GW >/dev/null 2>&1; then
  unset HNET_GW HNET_NM HNET_BASE HNET_END
  declare -A HNET_GW HNET_NM HNET_BASE HNET_END
  HNET_NAMES=()
fi

# ─── 3a2. per-network IPAM blocks (optional) ────────────────
# Each port group can carry its OWN gateway/netmask/IP-range/DNS that WINS over
# the vCenter-wide defaults when a VM is created on it (create-vm-config.sh §2).
# New networks (not yet in network_subnets) simply fall back to the vCenter
# defaults — nothing breaks. Keys must match port-group names exactly as govc
# discovers them. Existing entries are pre-loaded above; Enter keeps a value.
echo ""
echo "  ─── Per-network IPAM (optional — auto-fills gateway/IP-range per VLAN) ───"
while true; do
  read -rp "  Add/update a per-network IPAM block? [y/N]: " add_sub
  case "$add_sub" in
    y|Y|yes|YES) ;;
    *) break ;;
  esac
  snet=""
  read -rp "  Network/port-group name: " snet
  [ -n "$snet" ] || { warn "empty — skipped"; continue; }
  for _n in "${SUBNET_NAMES[@]}"; do [ "$_n" = "$snet" ] && exists=1; done
  [ "${exists:-0}" = "1" ] && info "Existing entry for '${snet}' (gw=${SUBNET_GW[$snet]:-none}) — Enter keeps"
  unset exists
  read -rp "  Gateway: " sgw; [ -n "$sgw" ] || sgw="${SUBNET_GW[$snet]:-}"
  [ -n "$sgw" ] || { warn "gateway required — skipped"; continue; }
  read -rp "  Netmask (CIDR) [${SUBNET_NM[$snet]:-24}]: " snm; [ -n "$snm" ] || snm="${SUBNET_NM[$snet]:-24}"
  read -rp "  ipam_base (first deployable IP of THIS network — gateway+reserve, default 30) [${SUBNET_START[$snet]:-$(ip_add "$sgw" "${DEFAULT_IPAM_RESERVE:-30}")}]: " ss; [ -n "$ss" ] || ss="${SUBNET_START[$snet]:-$(ip_add "$sgw" "${DEFAULT_IPAM_RESERVE:-30}")}"
  read -rp "  range_end (last deployable IP) [blank = single IP]: " se; [ -n "$se" ] || se="${SUBNET_END[$snet]:-}"
  read -rp "  DNS (comma-separated): " sdns; [ -n "$sdns" ] || sdns="${SUBNET_DNS[$snet]:-}"
  read -rp "  Host/node pin (blank = DRS auto-placement) [${NET_HOST_NODE[$snet]:-}]: " shost
  if [ -n "${NET_HOST_NODE[$snet]:-}" ]; then
    # has an existing node — blank keeps it; '_none_' explicitly clears it
    [ -n "$shost" ] && [ "$shost" != "_none_" ] && NET_HOST_NODE["$snet"]="$shost"
    [ "$shost" = "_none_" ] && unset "NET_HOST_NODE[$snet]"
  else
    [ -n "$shost" ] && [ "$shost" != "_none_" ] && NET_HOST_NODE["$snet"]="$shost"
  fi
  add=1
  for _n in "${SUBNET_NAMES[@]}"; do [ "$_n" = "$snet" ] && add=0; done
  [ "$add" = "1" ] && SUBNET_NAMES+=("$snet")
  SUBNET_GW["$snet"]="$sgw"; SUBNET_NM["$snet"]="$snm"
  SUBNET_START["$snet"]="$ss"; SUBNET_END["$snet"]="$se"
  SUBNET_DNS["$snet"]="$sdns"
  ok "network_subnets['${snet}'] set (gw=${sgw} nm=${snm} start=${ss:-<base_ip>}${se:+ end=${se}})"
done

# ─── 3a3. per-host network IPAM (standard-vSwitch, per-host subnets) ──
# Hosts behind a standard vSwitch each sit on their OWN subnet ("VM Network"
# on node A = 198.51.100.0/24, node B = 192.0.2.0/24). Define each host's
# gateway/netmask/ipam so a VM pinned to it gets the right range (no govc
# dependency). Key = host name as govc reports it.
echo ""
echo "  ─── Per-host network config (optional — per-host subnets for standard-vSwitch networks) ───"
while true; do
  read -rp "  Add/update a per-host network block? [y/N]: " add_hnet
  case "$add_hnet" in
    y|Y|yes|YES) ;;
    *) break ;;
  esac
  hnet=""
  read -rp "  Host name (as govc reports — e.g. 192.0.2.74): " hnet
  [ -n "$hnet" ] || { warn "empty — skipped"; continue; }
  hgw=""
  read -rp "  Gateway for ${hnet} [${HNET_GW[$hnet]:-}]: " hgw; [ -n "$hgw" ] || hgw="${HNET_GW[$hnet]:-}"
  [ -n "$hgw" ] || { warn "gateway required — skipped"; continue; }
  read -rp "  Netmask (CIDR) [${HNET_NM[$hnet]:-24}]: " hnm; [ -n "$hnm" ] || hnm="${HNET_NM[$hnet]:-24}"
  read -rp "  ipam_base (first deployable IP of ${hnet} subnet — gateway+reserve, default 30) [${HNET_BASE[$hnet]:-$(ip_add "$hgw" "${DEFAULT_IPAM_RESERVE:-30}")}]: " hbase; [ -n "$hbase" ] || hbase="${HNET_BASE[$hnet]:-$(ip_add "$hgw" "${DEFAULT_IPAM_RESERVE:-30}")}"
  read -rp "  range_end (last deployable IP) [${HNET_END[$hnet]:-}]: " hend; [ -n "$hend" ] || hend="${HNET_END[$hnet]:-}"
  add=1
  for _n in "${HNET_NAMES[@]}"; do [ "$_n" = "$hnet" ] && add=0; done
  [ "$add" = "1" ] && HNET_NAMES+=("$hnet")
  HNET_GW["$hnet"]="$hgw"; HNET_NM["$hnet"]="$hnm"
  HNET_BASE["$hnet"]="$hbase"; HNET_END["$hnet"]="$hend"
  ok "host_networks['${hnet}'] set (gw=${hgw} nm=${hnm} base=${hbase:-<auto>} end=${hend:-<auto>})"
done

# ─── 3b. finalize dir name (<datacenter>_<server>) ──────────
# NOTE: directories are NOT created here — only AFTER the user confirms
# (see 4b below). Otherwise an aborted run would leave orphan dirs + override
# templates with no parent credentials.tfvars/vcenter.tfvars behind.
if [ "$IS_NEW" = "1" ]; then
  # dir name = <datacenter>_<server> so the datacenter identity is visible
  DC_SAN="$(echo "$DC" | sed -E 's/[^a-zA-Z0-9._-]/_/g')"
  [ -n "$DC_SAN" ] || DC_SAN="$DC"
  NEW_SERVER_SAFE="$(echo "$NEW_SERVER" | sed -E 's#^[a-zA-Z]+://##; s#[/:]+$##; s/[^a-zA-Z0-9._-]/_/g')"
  FINAL="${DC_SAN}_${NEW_SERVER_SAFE}"
  if [ "$FINAL" != "$VCENTER" ]; then
    [ -d "$SRC" ] && mv "$SRC" ".tmp-sops-plain/${FINAL}" 2>/dev/null || true
    VCENTER="$FINAL"
    SRC=".tmp-sops-plain/${VCENTER}"
    mkdir -p "$SRC"
  fi
fi

# ─── 4. summary + confirm ──────────────────────────────────
echo ""
echo "  ──────────────────────────────────────────────"
echo "  Summary for vCenter: ${c_bold}${VCENTER}${c_rst}"
  echo "    server        = $SERVER"
  echo "    user          = $USER"
  echo "    password      = $([ -n "$PASSWORD" ] && echo '**** (set)' || echo '(missing)')"
  echo "    datacenter    = $DC"
  echo "    clusters      = [${CLUSTERS[*]}]"
  echo "    templates     = [${TEMPLATES[*]}]"
  echo "    datastores    = [${DATASTORES[*]}]  (auto-discovered at VM create)"
  echo "    networks      = [${NETWORKS[*]}]  (auto-discovered at VM create)"
  echo "    resource_pools= [${POOLS[*]}]  (auto-discovered at VM create)"
  echo "    domain        = $DOMAIN"
  echo "    gateway       = $GW"
  echo "    netmask       = $NM"
  echo "    dns_servers   = [${DNS[*]}]"
  echo "    base_ip       = $BASEIP"
  if [ "${#SUBNET_NAMES[@]}" -gt 0 ]; then
    echo "    network_subnets (per-VLAN IPAM):"
    for _n in "${SUBNET_NAMES[@]}"; do
      echo "      ${_n} → gw=${SUBNET_GW[$_n]} nm=${SUBNET_NM[$_n]:-24} start=${SUBNET_START[$_n]:-$BASEIP}${SUBNET_END[$_n]:+ end=${SUBNET_END[$_n]}}"
    done
  fi
echo "  ──────────────────────────────────────────────"
read -rp "  Save? (y=confirm / Enter or n=abort) [N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "  Aborted. Nothing saved."; rm -rf "$SRC"; exit 1;;
esac

# ─── 4b. auto-create dirs ONLY after confirmation ─────────
# (an aborted run must leave no orphan dirs / override templates behind)
if [ "$IS_NEW" = "1" ]; then
  mkdir -p "deploy/${VCENTER}"/{dev,prod,staging} "secure/${VCENTER}"
  for _e in dev prod staging; do
    mkdir -p "secure/${VCENTER}/${_e}"
    create_override_template "$VCENTER" "$_e"
    create_user_groups_template "$VCENTER" "$_e"
  done
  # Per-vCenter VM defaults (policy-like). Auto-created from built-in defaults;
  # the operator edits secure/<vcenter>/vm-defaults.conf afterwards. Holds the
  # extra-user default password → lives in secure/ (gitignored), never committed.
  create_vm_defaults_template "$VCENTER"
  ok "Created deploy/${VCENTER}/{dev,prod,staging} and secure/${VCENTER}/{dev,prod,staging} (override dirs)"
else
  # existing vCenter — ensure per-env override dirs + user-groups policy exist
  # for EVERY env. Collect the union of deploy/ and secure/ env dirs so an env
  # that only exists on one side still gets its policy file.
  _envs=()
  for _d in "deploy/${VCENTER}"/*/ "secure/${VCENTER}"/*/; do
    [ -d "$_d" ] || continue
    _e="$(basename "$_d")"
    case " ${_envs[*]:-} " in *" $_e "*) ;; *) _envs+=("$_e");; esac
  done
  for _e in "${_envs[@]}"; do
    mkdir -p "secure/${VCENTER}/${_e}"
    create_override_template "$VCENTER" "$_e"
    create_user_groups_template "$VCENTER" "$_e"
  done
fi

# ─── 5-6. write plaintext + encrypt ───────────────────────
# Age key verified BEFORE any plaintext hits disk — a missing/broken key must
# abort here, never after credentials are written (the EXIT trap still cleans
# the staging dir on failure).
AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
[ -f "$AGE_KEY" ] || { error "age key not found at $AGE_KEY"; exit 1; }
PUB_KEY=$(grep -oP '(?<=public key: )age1[0-9a-z]+' "$AGE_KEY" | head -1)
[ -n "$PUB_KEY" ] || { error "could not read public key"; exit 1; }

DEST="secure/${VCENTER}"
mkdir -p "$DEST"

cat > "${SRC}/credentials.tfvars" <<EOF
vsphere_server       = "${SERVER}"
vsphere_user         = "${USER}"
vsphere_password     = "${PASSWORD}"
allow_unverified_ssl = true
EOF

# Build the network_subnets block — active per-network IPAM entries the
# operator added (or that existed already); a commented example otherwise.
# Each entry carries its OWN gateway/netmask/ipam_base (first deployable IP).
# Keys are a port-group NAME (DVS, cluster-wide) or a HOST name (per-host
# standard-vSwitch subnet like "VM Network"). DNS is NOT here — the VM config
# carries its own dns_servers.
SUBNET_BLOCK=""
if [ "${#SUBNET_NAMES[@]}" -gt 0 ]; then
  for _n in "${SUBNET_NAMES[@]}"; do
    [ -n "$_n" ] || continue
    SUBNET_BLOCK+="$(printf '  "%s" = { gateway = "%s", netmask = %s, ipam_base = "%s", range_end = "%s" }' \
      "$_n" "${SUBNET_GW[$_n]}" "${SUBNET_NM[$_n]:-24}" "${SUBNET_START[$_n]:-$(ip_add "${SUBNET_GW[$_n]}" "${DEFAULT_IPAM_RESERVE:-30}")}" "${SUBNET_END[$_n]}")"$'\n'
  done
else
  SUBNET_BLOCK="# \"${NETWORKS[0]:-DPortGroup_100}\" = { gateway = \"${GW:-192.0.2.1}\", netmask = ${NM:-24}, ipam_base = \"$(ip_add "${GW:-192.0.2.1}" "${DEFAULT_IPAM_RESERVE:-30}")\", range_end = \"${BASEIP:-198.51.100.106}\" }"
fi
# Per-host entries (HNET_NAMES) merge into the same network_subnets map —
# keyed by host name.
HOST_SUBNETS_BLOCK=""
for _h in "${HNET_NAMES[@]:-}"; do
  [ -n "$_h" ] || continue
  HOST_SUBNETS_BLOCK+="$(printf '  "%s" = { gateway = "%s", netmask = %s, ipam_base = "%s", range_end = "%s" }' \
    "$_h" "${HNET_GW[$_h]}" "${HNET_NM[$_h]:-24}" "${HNET_BASE[$_h]:-$(ip_add "${HNET_GW[$_h]}" "${DEFAULT_IPAM_RESERVE:-30}")}" "${HNET_END[$_h]:-}")"$'\n'
done

# network_hosts block — network → node pinning (DRS auto-placement when absent)
# Only written when the operator pinned nodes during setup; else commented.
NET_HOSTS_BLOCK=""
for _n in "${SUBNET_NAMES[@]}"; do
  _node="${NET_HOST_NODE[$_n]:-}"
  [ -n "$_node" ] || continue
  NET_HOSTS_BLOCK+="$(printf '  "%s" = "%s"' "$_n" "$_node")"$'\n'
done
[ -n "$NET_HOSTS_BLOCK" ] && NET_HOSTS_BLOCK="network_hosts = {
${NET_HOSTS_BLOCK}}
" || NET_HOSTS_BLOCK=$'# network_hosts = {\n#   "DPortGroup_100" = "192.0.2.74"\n# }\n'

cat > "${SRC}/vcenter.tfvars" <<EOF
# ═══════════════════════════════════════════════════════════════════════════
# ✓ IDENTITY (operator-set at onboarding)
# ═══════════════════════════════════════════════════════════════════════════
datacenter = "${DC}"

# ─────────────────────────────────────────────────────────────────────────────
# INVENTORY LISTS (clusters/templates/datastores/networks/resource_pools/hosts)
# are NOT stored here anymore — they are loaded LIVE from govc at VM-create time
# by scripts/vcenter-inventory.sh (see \`live hosts\` / \`list\` modes). Nothing to
# maintain when a node/network/datastore is added.
# Per-env overrides still work: set a key in secure/<vc>/<env>/vcenter.tfvars to
# PIN/RESTRICT that env to specific options (e.g. networks = ["stage_100"]).
# ─────────────────────────────────────────────────────────────────────────────

# Per-vCenter network defaults (used by create-vm-config.sh + terraform)
domain      = "${DOMAIN}"
gateway     = "${GW}"
netmask     = ${NM}
dns_servers = [$(printf '"%s", ' "${DNS[@]}" | sed 's/, $//')]

# ═══════════════════════════════════════════════════════════════════════════
# ✓ LAN NETWORK CONFIG (one section — ALL networks of this vCenter) — each
#   entry carries gateway/netmask/IPAM for one network. ipam_base = FIRST
#   deployable IP (gateway+reserve reserved for routers/switches/DNS/vCenter);
#   range_end = last deployable IP. DNS is NOT here (the VM config carries its
#   own dns_servers). Keys are either a port-group NAME (DVS, cluster-wide) or
#   a HOST name (that host's standard-vSwitch subnet, e.g. its "VM Network").
# ═══════════════════════════════════════════════════════════════════════════
network_subnets = {
${SUBNET_BLOCK}
${HOST_SUBNETS_BLOCK}}

# per-network host/node pinning — selecting a mapped network auto-fills the
# Host (node) in CLI/UI; blank = DRS auto-placement.
${NET_HOSTS_BLOCK}

# NO vCenter-wide ipam_base_ip fallback is stored here — each network carries
# its own ipam_base (above), and unmapped standard-vSwitch networks derive
# their range from the pinned node's subnet (host-keyed entry or node mgmt IP).
EOF

# credentials.tfvars = SECRET → encrypt
sops --encrypt --age "$PUB_KEY" "${SRC}/credentials.tfvars" > "${DEST}/credentials.tfvars"
ok "Encrypted: ${DEST}/credentials.tfvars"

# vcenter.tfvars = inventory only (no secrets) → copy plaintext (readable)
cp "${SRC}/vcenter.tfvars" "${DEST}/vcenter.tfvars"
ok "Copied plaintext (readable): ${DEST}/vcenter.tfvars"

rm -rf "$SRC"

echo ""
ok "vCenter secrets saved for '${VCENTER}'."
echo "  Verify: bash scripts/sops-decrypt.sh ${VCENTER} dev --clean"
echo "  Deploy: bash scripts/deploy-vm.sh ${VCENTER} <env> <vm-name>"
echo "  Add VMs: bash scripts/create-vm-config.sh ${VCENTER} <env> <vm-name>"
