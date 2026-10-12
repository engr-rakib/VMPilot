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
#   and stores credentials ONCE per platform (secure/<server>/) +
#   inventory per-DC (secure/<server>/<vcenter>/vcenter.tfvars)
#   (credentials.tfvars = encrypted; vcenter.tfvars = plaintext inventory)
#
# LAYOUT (vCenter-wise)
#   secure/<server>/credentials.tfvars   (encrypted — server/user/password)
#   secure/<server>/<vcenter>/vcenter.tfvars       (plaintext — inventory + network + ipam)
#   secure/<server>/<vcenter>/{dev,prod,staging}/vcenter.tfvars
#                                         (per-env overrides — commented template;
#                                          uncomment a key to override the top-level
#                                          value for that env only; absent → inherit)
#   deploy/<server>/<vcenter>/{dev,prod,staging}/  (auto-created env dirs for VM configs)
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
#   existing vCenter they are pre-filled from secure/<server>/credentials.tfvars;
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
#      deploy/<datacenter>_<server>/{dev,prod,staging}/ + secure/<server>/<vcenter>/
#      (dir name = <datacenter>_<server>). Per-env override dirs are created
#      under secure/<server>/<vcenter>/{dev,prod,staging}/ with a commented template.
#   4. Prompts: server / user / password (typed, confirmed) / datacenter /
#      cluster / resource_pool / datastore / network / template / domain /
#      gateway / netmask / DNS / base IP — each shows [default].
#   5. Shows a summary diff and asks for confirmation before writing.
#   6. Writes plaintext to .tmp-sops-plain/<vcenter>/ (git-ignored, inside the
#      project so sops creation-rules match).
#   7. Encrypts credentials with sops --encrypt --age <public-key> →
#      secure/<server>/credentials.tfvars ; copies inventory plaintext →
#      secure/<server>/<vcenter>/vcenter.tfvars (readable, no secrets).
#   8. Deletes the plaintext staging dir automatically.
#
# OUTPUT / AFTER
#   secure/<server>/credentials.tfvars   (encrypted)
#   secure/<server>/<vcenter>/vcenter.tfvars       (plaintext — inventory, readable)
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

# required prompt — loops until a value exists (typed or default) instead of
# killing the whole wizard on an empty Enter. An aborted run loses everything
# typed so far, so required fields must re-ask, never exit.
ask_required() { # $1=label, $2=var-name, $3=default
  local label="$1" var="$2" def="${3:-}" cur=""
  while true; do
    ask "$label" "$var" "$def"
    eval "cur=\"\$$var\""
    [ -n "$cur" ] && return 0
    error "$label is required — type a value (Ctrl+C to abort)."
  done
}

# a vCenter = secure/<srv>/<name>/ (nested) or legacy flat secure/<name>/
# holding credentials.tfvars + vcenter.tfvars (the configured identity).
# deploy/<srv>/<name>/ (nested) or flat deploy/<name>/ only holds VM configs.
# vdir_for <root> <vc> → nested dir when present, else flat (tolerant reads).
vdir_for() {
  local _r="${ROOT_DIR:-.}"; if [ -d "${_r}/$1/${2##*_}/$2" ]; then echo "$1/${2##*_}/$2"; else echo "$1/$2"; fi
}
list_vcenters() {
  local d v
  for d in secure/*/ secure/*/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ "$v" = "README.md" ] || [ "$v" = "_master" ] && continue
    case "$v" in .* ) continue ;; esac
    [ -f "${d}.platform-creds" ] && continue
    [ -f "${d}credentials.tfvars" ] || [ -f "${d}vcenter.tfvars" ] || continue
    echo "$v"
  done
}

# Orphaned deploy/<name>/ dirs = VM config dirs whose vCenter no longer exists
# in secure/ (deleted/never onboarded). They can no longer be deployed and just
# hold stale per-VM configs → safe to remove.
list_orphans() {
  local d v
  for d in deploy/*/ deploy/*/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ "$v" = "examples" ] && continue
    # vCenter still configured → not orphaned
    _sv="$(vdir_for secure "$v")"
    [ -f "${_sv}/credentials.tfvars" ] || [ -f "${_sv}/vcenter.tfvars" ] && continue
    # has env sub-dirs (a real vCenter config dir, not a stray file)
    if ls -d "${d}"*/ >/dev/null 2>&1; then echo "$v"; fi
  done
}

# NOTE: orphan cleanup was removed — orphaned deploy/ dirs are NEVER deleted.
# Same platform re-onboarded hole auto-adopt hoy (configs + tfstate + history
# intact). See the menu info lines above.

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

# User-group policy template — secure/<server>/<vcenter>/<env>/user-groups.tfvars
# Created for EVERY env (dev/prod/staging) of a new vCenter. Defines what OS
# access each GROUP (admin/app/db/readonly) grants to VM extra_users. Users are
# members of groups (can be in MANY); per-VM configs reference groups by name
# via extra_users[].groups.
# Hardening templates (3-tier policy): DC baseline + per-env overwrite.
# Same keys as server buildHardeningDcTemplate/buildHardeningEnvTemplate.
create_hardening_dc_template() {
  local dir="$1"
  local out="secure/${dir}/hardening.sh"
  [ -f "$out" ] && return 0
  # stock template (single source: scripts/lib/hardening-template.sh)
  _lib="scripts/lib/hardening-template.sh"
  [ -f "$_lib" ] || { echo "missing $_lib" >&2; return 1; }
  cp "$_lib" "$out"
}
create_hardening_env_template() {
  local dir="$1" env="$2"
  local out="secure/${dir}/${env}/hardening.sh"
  [ -f "$out" ] && return 0
  # Seed from the ACTIVE DC file (same history everywhere)...
  _dc="secure/${dir}/hardening.sh"
  if [ -f "$_dc" ] && grep -qEv "^[[:space:]]*(#|$)" "$_dc"; then cp "$_dc" "$out" && return 0; fi
  # ...else sibling inherit: same server, same env already tuned? copy it.
  local sib
  for sib in secure/"${dir%%/*}"/*/"$env"/hardening.sh; do
    [ -f "$sib" ] || continue
    cp "$sib" "$out" && return 0
  done
  _lib="scripts/lib/hardening-env-template.sh"
  [ -f "$_lib" ] || { echo "missing $_lib" >&2; return 1; }
  cp "$_lib" "$out"
}
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
# Edit secure/<server>/<vcenter>/vm-defaults.conf to change shared VM defaults.
# vCenter SERVER + USER are per-vCenter → always required here; they never
# come from vm-defaults.conf. Existing values are auto-loaded from
# secure/<server>/credentials.tfvars + vcenter.tfvars as defaults; a NEW
# vCenter starts empty (everything typed by hand).
info "VM defaults: per-vCenter secure/<vcenter>/vm-defaults.conf (loaded by create-vm-config.sh)"

# ─── 1. vCenter selection (menu) ───────────────────────────
EXISTING=$(list_vcenters)
NEW_SERVER=""
IS_NEW=0

echo "${c_bold}  Platform Setup${c_rst}"
echo "  ──────────────────────────────"
ORPHANS=$(list_orphans)
if [ -n "$EXISTING" ]; then
  echo "  Existing Platforms:"
  i=1
  while read -r v; do
    [ -z "$v" ] && continue
    printf '    %d) %s\n' "$i" "$v"
    VCENTERS[$i]="$v"; i=$((i+1))
  done <<< "$EXISTING"
  printf '    %d) %s\n' "$i" "Add new Platform"
  if [ -n "$ORPHANS" ]; then
    echo "  Orphaned configs (platform removed — kept safe, auto-adopted on re-onboard):"
    while read -r v; do
      [ -z "$v" ] && continue
      printf '    - deploy/%s/\n' "$v"
    done <<< "$ORPHANS"
  fi
  read -rp "  Select (1-${i}): " SEL
  case "$SEL" in
    ''|*[!0-9]*) VCENTER="" ;;
    *) VCENTER="${VCENTERS[$SEL]:-}"; [ "$SEL" = "$i" ] && VCENTER="NEW" ;;
  esac
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
    # existing vCenter — ensure deploy/<srv>/<vcenter> exists (in case it only lived in secure/)
    mkdir -p "deploy/${VCENTER##*_}/${VCENTER}"
    IS_NEW=0
  fi
else
  if [ -n "$ORPHANS" ]; then
    echo "  No configured vCenters yet. Orphaned configs kept safe (auto-adopted on re-onboard):"
    while read -r v; do
      [ -z "$v" ] && continue
      printf '    - deploy/%s/\n' "$v"
    done <<< "$ORPHANS"
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

_SVD="$(vdir_for secure "$VCENTER")"
_PFCRED="${_SVD}/credentials.tfvars"
[ -f "$_PFCRED" ] || _PFCRED="secure/${VCENTER##*_}/credentials.tfvars"
if [ -f "$_PFCRED" ] && [ -f "${_SVD}/vcenter.tfvars" ]; then
  sops -d "$_PFCRED" > "$SRC/credentials.tfvars" 2>/dev/null || true
  cp "${_SVD}/vcenter.tfvars" "$SRC/vcenter.tfvars" 2>/dev/null || true
  if [ -s "$SRC/credentials.tfvars" ]; then
    source <(grep -E '^(vsphere_server|vsphere_user|vsphere_password)' "$SRC/credentials.tfvars" | sed 's/ *= */=/')
    D_SERVER="${vsphere_server:-$D_SERVER}"; D_USER="${vsphere_user:-$D_USER}"; D_PASS="${vsphere_password:-}"
  fi
  if [ -s "$SRC/vcenter.tfvars" ]; then
    # legacy single-value keys ONLY (anchored `=` so plural lists like
    # `datastores = [...]` never reach `source` — a multi-element `["a", "b"]`
    # line is NOT a valid assignment (bash runs the 2nd word as a command).
    # Plurals are parsed by the list loops below; block maps never sourced.
    source <(grep -E '^(datacenter|cluster|resource_pool|datastore|network|template|domain|gateway|netmask|ipam_base_ip)[[:space:]]*=' "$SRC/vcenter.tfvars" | sed 's/ *= */=/')
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
  # existing hosts{} inner lines (live refresh fail korle preserve — never wipe).
  D_HOSTS_BLOCK=""
  if [ -s "$SRC/vcenter.tfvars" ] && grep -qE '^hosts[[:space:]]*=' "$SRC/vcenter.tfvars" 2>/dev/null; then
    D_HOSTS_BLOCK=$(sed -n '/^hosts[[:space:]]*=/,/^}/p' "$SRC/vcenter.tfvars" 2>/dev/null | sed '1d;$d' || true)
  fi
  # host_networks map — per-host gateway/netmask/ipam for standard-vSwitch
  # port groups (per-host subnets). Preserved on edit.
  unset HNET_NAMES HNET_GW HNET_NM HNET_BASE HNET_END
  declare -A HNET_GW HNET_NM HNET_BASE HNET_END HNET_AUTO HNET_IP
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
# split_range "A-B" / "A" / "A-x" (last-octet shorthand) → "base|end"
split_range() {
  local _t="$1" _b="" _e=""
  if [[ "$_t" == *-* ]]; then
    _b="${_t%%-*}"; _e="${_t#*-}"; [ "$_e" = "$_t" ] && _e=""
    _b="$(echo "$_b" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    _e="$(echo "$_e" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -n "$_e" ] && [[ "$_e" != *.* ]] && [[ "$_b" == *.* ]]; then
      _e="${_b%.*}.$_e"
    fi
  else
    _b="$(echo "$_t" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  fi
  printf '%s|%s' "$_b" "$_e"
}
  local ip="$1" d="$2" a b c d3 n
  IFS='.' read -r a b c d3 <<< "$ip"
  n=$(( d3 + d ))
  echo "$a.$b.$c.$n"
}

# ─── 3. credentials once (server-level) + multi-DC loop ───────────
# One run onboards EVERY datacenter in two passes: Phase A discovers all DCs
# back-to-back (zero stops), Phase B takes input + saves per DC. Edit flow
# (existing entry) runs a single input pass. Only DC-scoped values reset
# between rounds; server-level creds are asked once.
SERVER="${D_SERVER:-$NEW_SERVER}"; USER="$D_USER"; PASSWORD="$D_PASS"

echo ""
echo "  Fill values — Enter keeps the [default] shown:"
echo ""
ask_required "  vSphere server IP/FQDN"  SERVER  "$SERVER"
ask_required "  vSphere user"            USER    "$USER"

while true; do
  read -rsp "  vSphere password (Enter to keep current): " PASSWORD_IN
  echo ""
  if [ -z "$PASSWORD_IN" ]; then
    [ -n "$PASSWORD" ] && break
    error "Password required — type it (Ctrl+C to abort)."; continue
  fi
  PASSWORD="$PASSWORD_IN"
  break
done

# Display label (WebUI left card shows this instead of the IP). Defaults to the
# name typed at the start (e.g. rakib_lab_center) — no separate field to fill.
_CUR_LABEL=""
if [ -f secure/server-labels.json ] && command -v jq &>/dev/null; then
  _CUR_LABEL=$(jq -r --arg s "$SERVER" '.[$s] // ""' secure/server-labels.json 2>/dev/null || true)
fi
_LABEL_DEF="${_CUR_LABEL:-}"
if [ -z "$_LABEL_DEF" ] && [ -n "$NEW_SERVER" ] && [ "$NEW_SERVER" != "$SERVER" ]; then
  _LABEL_DEF="$NEW_SERVER"
fi
read -rp "  Display label for WebUI [${_LABEL_DEF:-IP itself}]: " VC_LABEL
[ -z "$VC_LABEL" ] && VC_LABEL="$_LABEL_DEF"
if [ -n "$VC_LABEL" ] && command -v jq &>/dev/null; then
  [ -f secure/server-labels.json ] || echo "{}" > secure/server-labels.json
  jq --arg s "$SERVER" --arg l "$(printf '%s' "$VC_LABEL" | head -c 60)" '.[$s] = $l' secure/server-labels.json > secure/.labels.tmp && mv secure/.labels.tmp secure/server-labels.json
  ok "Label '${VC_LABEL}' saved for ${SERVER} (WebUI shows this)"
fi

# Domain is operator-selected (never derived) — prompt shows stored default only.

# Phase control + per-DC snapshot store (declare -p dump, eval restore).
PASS=discover
[ "$IS_NEW" != "1" ] && PASS=input
DC_DONE=()
declare -gA SNAP=()
snap_dc_save() {
  local d="${1:-}" dump=""
  [ -z "$d" ] && return 0
  dump="$(declare -p CLUSTERS TEMPLATES DATASTORES NETWORKS POOLS CLUSTER TPL DS NET RP GOVC_DATASTORES SUBNET_NAMES SUBNET_GW SUBNET_NM SUBNET_START SUBNET_END SUBNET_DNS NET_HOST_NODE HNET_NAMES HNET_GW HNET_NM HNET_BASE HNET_END HNET_AUTO HNET_IP 2>/dev/null | sed -e 's/^declare -a /declare -ga /' -e 's/^declare -A /declare -gA /')" || true
  [ -n "$dump" ] && SNAP["$d"]="$dump"
}
snap_dc_has() { [ -n "${SNAP["${1:-}"]:-}" ]; }
snap_dc_load() {
  local d="${1:-}" dump="${SNAP["${1:-}"]:-}"
  [ -z "$d" ] || [ -z "$dump" ] && return 1
  eval "$dump"
}
# Saved per-network blocks from EXISTING entries of this same server (any DC):
# shown as reference + proposal defaults in the per-port prompts below.
# Format per network: gw|nm|base|end (first entry wins).
load_saved_subnets() {
  unset SAVED_SUB; declare -gA SAVED_SUB=()
  unset SAVED_SRC; declare -gA SAVED_SRC=()
  local f line name gw nm base start end
  for f in secure/*_"${SERVER}"/vcenter.tfvars secure/"${SERVER}"/*/vcenter.tfvars; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      name=$(grep -oE '"[^"]+"[[:space:]]*=' <<<"$line" | head -1 | sed -E 's/^"([^"]+)".*/\1/' || true)
      [ -n "$name" ] || continue
      gw=$(grep -oE 'gateway[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
      nm=$(grep -oE 'netmask[[:space:]]*=[[:space:]]*[0-9]+' <<<"$line" | head -1 | grep -oE '[0-9]+' || true)
      base=$(grep -oE 'ipam_base[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
      [ -n "$base" ] || base=$(grep -oE 'range_start[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
      end=$(grep -oE 'range_end[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
      [ -n "$name$gw$nm$base$end" ] || continue
      if [ -z "${SAVED_SUB[$name]:-}" ]; then
        SAVED_SUB["$name"]="${gw}|${nm:-24}|${base}|${end}"
        SAVED_SRC["$name"]="$(basename "$(dirname "$f")")"
      fi
    done < <(sed -n '/^network_subnets[[:space:]]*=/,/^}/p' "$f")
  done
}
load_saved_subnets
# Deployed facts from LOCAL vm configs of this same server (orphans included):
# per-network gateway/netmask + sample IPs — applied truth, beats guessing.
# `network = ` at column 0 = primary; indented `network_name` = extra attach.
unset DEPLOY_NET DEPLOY_IPS; declare -gA DEPLOY_NET=() DEPLOY_IPS=()
if command -v python3 &>/dev/null; then
  while IFS='|' read -r _dn _dg _dnm _dips; do
    [ -n "$_dn" ] || continue
    if [ -z "${DEPLOY_NET[$_dn]:-}" ] && [ -n "$_dg" ]; then DEPLOY_NET["$_dn"]="${_dg}|${_dnm:-24}"; fi
    if [ -n "$_dips" ]; then
      for _di in $_dips; do
        if [[ " ${DEPLOY_IPS[$_dn]:-} " != *" $_di "* ]]; then
          DEPLOY_IPS["$_dn"]="${DEPLOY_IPS[$_dn]:-}${DEPLOY_IPS[$_dn]:+ }$_di"
        fi
      done
    fi
  done < <(python3 - "$SERVER" <<'PYEOF' 2>/dev/null || true
import re, sys, glob
srv = sys.argv[1]
pats = {
    'net': re.compile(r'^ *network(_name)?\s*=\s*"(?P<v>[^"]+)"'),
    'gw': re.compile(r'gateway\s*=\s*"(?P<v>[^"]+)"'),
    'nm': re.compile(r'netmask\s*=\s*(?P<v>"[^"]+"|\d+)'),
    'ip': re.compile(r'ip_address\s*=\s*"(?P<v>[^"]+)"'),
}
out = {}
for f in glob.glob('deploy/*_' + srv + '/*/vm-*.tfvars') + glob.glob('deploy/' + srv + '/*/*/vm-*.tfvars'):
    try:
        txt = open(f, errors='ignore').read()
    except Exception:
        continue
    cur = None
    gw, nm, ips = "", "", []
    def flush():
        if cur and (gw or ips):
            e = out.setdefault(cur, {"gw": "", "nm": "", "ips": []})
            e["gw"] = e["gw"] or gw
            e["nm"] = e["nm"] or nm
            for x in ips:
                if x not in e["ips"]:
                    e["ips"].append(x)
    for line in txt.splitlines():
        m = pats['net'].match(line)
        if m:
            flush()
            cur = m.group('v')
            gw, nm, ips = "", "", []
            continue
        m = pats['gw'].search(line)
        if m and not gw:
            gw = m.group('v')
        m = pats['nm'].search(line)
        if m and not nm:
            nm = m.group('v').strip('"')
        m = pats['ip'].search(line)
        if m and m.group('v'):
            ips.append(m.group('v'))
    flush()
for net, e in out.items():
    print(net + '|' + e["gw"] + '|' + e["nm"] + '|' + ' '.join(e["ips"][:5]))
PYEOF
)
fi
while true; do
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
    # Discovered inventory auto-selected — the app runs on it, no prompt.
    # Stored curation (edit flow) is PRESERVED silently (no menu, no prompt):
    # curation changes happen in the files directly.
    if eval "[ \${#${defs}[@]} -gt 0 ]" 2>/dev/null; then
      eval "$out=(\"\${${defs}[@]}\")"
      info "${label}: keeping stored selection (edit — files directly to curate)"
    else
      eval "$out=(\"\${items[@]}\")"
      info "${label}: auto-selected all ${#items[@]} discovered"
    fi
    return 0
  elif eval "[ \${#${defs}[@]} -gt 0 ]" 2>/dev/null; then
    eval "$out=(\"\${${defs}[@]}\")"
  else
    # Nothing discovered, nothing stored — take empty (live govc fills at
    # VM-create). Only required operational inputs ever prompt.
    eval "$out=()"
    info "${label}: none in this DC — skipping (live at VM-create)"
  fi
}

# ─── 3a1b. autofill per-VLAN netmask/gateway/base from live guest NICs ───
# vCenter never stores subnet addressing (no gateway per portgroup), but live
# VMs with Tools report (portgroup, ipv4, prefix) via guest.net. Derive per
# picked network: netmask (mode prefix) + gateway proposal (subnet .1) +
# base (gw+30, existing convention) so the §3a2 loop shows real values.
# Manual entries and §2-loaded values are NEVER overwritten — only empty
# slots fill, and the operator still confirms every value below. Best-effort:
# no live guests/tools/python3 → silent no-op, operator types as before.
autofill_subnets_from_guests() {
  $GOVC_READY || return 0
  command -v python3 &>/dev/null || return 0
  [ "${#NETWORKS[@]}" -gt 0 ] || return 0
  if ! declare -p SUBNET_NAMES >/dev/null 2>&1; then
    SUBNET_NAMES=()
    declare -gA SUBNET_GW SUBNET_NM SUBNET_START SUBNET_END SUBNET_DNS
  fi
  [ -n "$DC" ] && export GOVC_DATACENTER="$DC"
  local vms=() info="" line derived=""
  # phase 0: host management addressing (EXACT — host route tables + vNIC).
  # Fills empty VLAN slots for vNIC portgroups; never overwrites. Disagreeing
  # hosts (same PG name, different subnets) are skipped — operator types those.
  if $GOVC_READY; then
    local _mg _mg_pre _mpg _mnm _mgw _e
    # Scoped to THIS datacenter (per-DC discovery — one DC finishes fully
    # before the next starts; no cross-DC mixing).
    unset PG_HOSTS; declare -gA PG_HOSTS=()
    _mgh=$(bash scripts/vcenter-inventory.sh __discover live hosts --datacenter="$DC" 2>/dev/null || echo "[]")
    _mg=$(printf '%s' "$_mgh" | jq -r '.[]? | (.mgmt // [])[]? | select(.portgroup != "" and (.ip // "") != "") | "\(.portgroup)|\(.mask)|\(.gateway)"' 2>/dev/null || true)
    # portgroup → hosts map (which hosts carry each PG — shown per-port below)
    while IFS=':' read -r _php _phh; do
      [ -n "$_php" ] && [ -n "$_phh" ] || continue
      if [[ " ${PG_HOSTS[$_php]:-} " != *" $_phh "* ]]; then
        PG_HOSTS["$_php"]="${PG_HOSTS[$_php]:-}${PG_HOSTS[$_php]:+ }$_phh"
      fi
    done < <(printf '%s' "$_mgh" | jq -r '.[]? | .name as $h | select($h != "") | .networks[]? | "\(.):\($h)"' 2>/dev/null || true)
    if [ -n "$_mg" ]; then
      _mg_pre=$(printf '%s\n' "$_mg" | python3 -c "
import sys
from ipaddress import IPv4Network
from collections import defaultdict
per = defaultdict(set)
for line in sys.stdin:
    p = line.strip().split('|')
    if len(p) != 3 or not p[0]:
        continue
    try:
        pre = IPv4Network('0.0.0.0/' + (p[1] or '255.255.255.0')).prefixlen
    except Exception:
        pre = 24
    per[p[0]].add(str(pre) + '|' + (p[2] or ''))
for pg, combos in per.items():
    if len(combos) == 1:
        print(pg + '|' + next(iter(combos)))
" 2>/dev/null || true)
      while IFS='|' read -r _mpg _mnm _mgw; do
        [ -n "$_mpg" ] || continue
        if [ -z "${SUBNET_NM[$_mpg]:-}" ]; then SUBNET_NM["$_mpg"]="$_mnm"; fi
        if [ -z "${SUBNET_GW[$_mpg]:-}" ] && [ -n "$_mgw" ]; then SUBNET_GW["$_mpg"]="$_mgw"; fi
        _e=0; for _n in "${SUBNET_NAMES[@]}"; do [ "$_n" = "$_mpg" ] && _e=1; done
        if [ "$_e" = "0" ] && [ -n "${_mgw}${_mnm}" ]; then SUBNET_NAMES+=("$_mpg"); info "auto: '${_mpg}' nm=${_mnm} gw=${_mgw} (host mgmt — base: operator defines below)"; fi
      done <<< "$_mg_pre"
    fi
  fi
  while IFS= read -r line; do [ -n "$line" ] && vms+=("$line"); done \
    < <(govc find . -type m 2>/dev/null | head -30)
  [ "${#vms[@]}" -gt 0 ] || return 0
  info=$(govc vm.info -json "${vms[@]}" 2>/dev/null | jq -c '
    (.virtualMachines // .VirtualMachines // [])[]?
    | select((.config.template // false) | not)
    | .guest.net[]? | select(.network != null and .network != "")
    | {net: .network} + (.ipConfig.ipAddress[]? | select(.ipAddress | test("^fe80:") | not) | select(.ipAddress | test("^169\\.254\\.") | not) | {ip: .ipAddress, prefix: .prefixLength})
    | select(.ip != null)' 2>/dev/null || true)
  [ -n "$info" ] || return 0
  derived=$(printf '%s\n' "$info" | python3 -c "
import sys, json, ipaddress
from collections import defaultdict
per = defaultdict(list)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get('ip') and o.get('prefix'):
        per[o['net']].append((o['ip'], int(o['prefix'])))
for net, lst in per.items():
    v4 = [(ip, p) for ip, p in lst if '.' in ip]
    if not v4:
        continue
    pref = max(set(p for _, p in v4), key=[p for _, p in v4].count)
    ip0 = v4[0][0]
    try:
        netw = ipaddress.ip_network(ip0 + '/' + str(pref), strict=False)
        gw = str(netw.network_address + 1)
        base = str(netw.network_address + 30)
        if int(ipaddress.ip_address(base)) >= int(netw.broadcast_address):
            base = ''
    except Exception:
        continue
    print(net + '|' + str(pref) + '|' + gw + '|' + base)
" 2>/dev/null || true)
  [ -n "$derived" ] || return 0
  local dnet dnm dgw dbase exists
  while IFS='|' read -r dnet dnm dgw dbase; do
    [ -n "$dnet" ] || continue
    if [ -z "${SUBNET_NM[$dnet]:-}" ]; then SUBNET_NM["$dnet"]="$dnm"; fi
    if [ -z "${SUBNET_GW[$dnet]:-}" ]; then SUBNET_GW["$dnet"]="$dgw"; fi
    # base: operator-defined only (saved/typed) — gw+30 guesses removed.
    exists=0; for _n in "${SUBNET_NAMES[@]}"; do [ "$_n" = "$dnet" ] && exists=1; done
    if [ "$exists" = "0" ]; then SUBNET_NAMES+=("$dnet"); info "auto: '${dnet}' nm=${dnm} gw=${dgw} (from live guest NICs — base: operator defines below)"; fi
  done <<< "$derived"
  # observed live IPs per portgroup (what is TAKEN — guides base choice)
  unset SUBNET_OBS; declare -gA SUBNET_OBS=()
  if [ -n "$info" ]; then
    local _ol _on _oip
    while IFS= read -r _ol; do
      [ -n "$_ol" ] || continue
      _on=$(jq -r '.net // empty' <<<"$_ol" 2>/dev/null || true)
      _oip=$(jq -r '.ip // empty' <<<"$_ol" 2>/dev/null || true)
      [[ "$_oip" == *.* ]] || continue
      [ -n "$_on" ] || continue
      if [[ " ${SUBNET_OBS[$_on]:-} " != *" $_oip "* ]]; then
        SUBNET_OBS["$_on"]="${SUBNET_OBS[$_on]:-}${SUBNET_OBS[$_on]:+ }$_oip"
      fi
    done <<< "$info"
  fi
  # top-level gateway default from the first derived network (still confirmed below)
  if [ -z "$GW" ] && [ -z "$D_GW" ]; then
    D_GW="$(cut -d'|' -f3 <<<"$(head -1 <<<"$derived")")"
    [ -n "$D_GW" ] && info "auto: top gateway default = ${D_GW} (confirm below)"
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

# Datacenter queue — NEW setups onboard EVERY discovered datacenter in turn
# (no pick prompt; the platform takes all DCs). The queue builds once from
# the first govc scan. No discovery → single manual ask. Edit flow keeps its
# keep/change menu below.
if [ -z "${DC_SCANNED:-}" ]; then
  DC_SCANNED=1
  DC_QUEUE=(); DC_TOTAL=0
  if [ "$IS_NEW" = "1" ] && [ "${#GOVC_DCS[@]}" -gt 0 ]; then
    DC_QUEUE=("${GOVC_DCS[@]}"); DC_TOTAL="${#DC_QUEUE[@]}"
    info "Discovered ${DC_TOTAL} datacenter(s) — onboarding ALL: ${DC_QUEUE[*]}"
  fi
fi
if [ "$IS_NEW" = "1" ]; then
  if [ "${#DC_QUEUE[@]}" -gt 0 ]; then
    DC="${DC_QUEUE[0]}"; DC_QUEUE=("${DC_QUEUE[@]:1}")
    DC_POS="$((DC_TOTAL - ${#DC_QUEUE[@]}))/${DC_TOTAL}"
    info "Datacenter: ${DC} (${DC_POS})"
  elif [ "${DC_ASKED:-0}" = "0" ]; then
    DC_ASKED=1
    ask "  Datacenter" DC "$D_DC"
  else
    break
  fi
elif [ -n "$DC" ]; then
  echo "  Datacenter [${DC}] (Enter=keep / number to change):"
  for i in "${!GOVC_DCS[@]}"; do printf '    %d) %s\n' "$((i+1))" "${GOVC_DCS[$i]}"; done
  read -rp "  → " dc_sel
  case "$dc_sel" in
    ''|*[!0-9]*) : ;;
    *) [ "$dc_sel" -ge 1 ] 2>/dev/null && [ "$dc_sel" -le "${#GOVC_DCS[@]}" ] && DC="${GOVC_DCS[$((dc_sel-1))]}" ;;
  esac
else
  ask "  Datacenter"  DC      "$D_DC"
fi

if [ "$PASS" = "input" ] && [ "$IS_NEW" = "1" ] && snap_dc_has "$DC"; then
  snap_dc_load "$DC" || true
  info "Datacenter: ${DC} (discovery restored — input below)"
else
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

# Auto-derive per-VLAN netmask/gateway/base from live guest NICs on the picked
# networks (port-group select korlei block propose hobe — operator confirms).
autofill_subnets_from_guests

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

# ─── Per-DC inventory recap (section-wise output with the DC name) ───
echo ""
echo "  ────────────────────────────────────────────"
echo "  DATACENTER: ${DC} ($(printf '%s' "${DC_POS:-?}"))"
echo "    Clusters : ${CLUSTERS[*]:-—}"
echo "    Templates: ${TEMPLATES[*]:-—}"
echo "    Datastores: ${DATASTORES[*]:-—}"
echo "    Networks : ${NETWORKS[*]:-—}"
echo "    Pools    : ${POOLS[*]:-—}"
echo "  ────────────────────────────────────────────"
  # VLAN map (per DC): portgroup → hosts carrying it, gateway, used IPs, pool.
  # Deciding base/end needs this whole picture — shown once, compactly.
  # VLAN map (per DC): portgroup → hosts, gateway, pool.
  # Uses ONE merged resolution (autofill/live > deployed > saved) so the map
  # and the per-port prompts below never disagree (gw=? vs known bug).
  # DVS portgroups span all hosts by design — shown as such, not per-host.
    # portgroup entry (DVS, cluster-wide) wins over any pinned-host entry
    # because DVS is the same subnet on every host.
    unset DVS_PGS; declare -gA DVS_PGS=()
    unset HOST_SUB; declare -gA HOST_SUB=()
    if $GOVC_READY; then
      _dvsraw=$(govc find . -type g 2>/dev/null || true)
      # Scoped find can miss DVS (e.g. empty-DC scope) — fall back vCenter-wide.
      if [ -z "$_dvsraw" ]; then
        _savedc="${GOVC_DATACENTER:-}"
        unset GOVC_DATACENTER
        _dvsraw=$(govc find . -type g 2>/dev/null || true)
        [ -n "$_savedc" ] && export GOVC_DATACENTER="$_savedc"
      fi
      while IFS= read -r _g; do [ -n "$_g" ] && DVS_PGS["$_g"]=1; done < <(printf '%s\n' "$_dvsraw" | sed 's|.*/||' | grep -vE 'DVUplinks' | sort -u)
      # host → mgmt subnet (first non-linklocal vnic): the assumed subnet for
      # that host's standard-vSwitch portgroups (operator confirms below).
      while IFS='|' read -r _hs _hgw _hnm; do
        [ -n "$_hs" ] || continue
        [ -n "${HOST_SUB[$_hs]:-}" ] || HOST_SUB["$_hs"]="${_hgw}|${_hnm}"
      done < <(bash scripts/vcenter-inventory.sh __discover live hosts --datacenter="$DC" 2>/dev/null \
        | python3 -c "
import sys, json
from ipaddress import IPv4Network
try:
    hosts = json.load(sys.stdin)
except Exception:
    hosts = []
if not isinstance(hosts, list):
    hosts = []
for h in hosts:
    name = (h.get('name') or '').strip()
    if not name:
        continue
    for m in h.get('mgmt') or []:
        ip = (m.get('ip') or '').strip()
        mask = (m.get('mask') or '').strip()
        gw = (m.get('gateway') or '').strip()
        if not ip or not gw or ip.startswith('169.254.') or ip.startswith('fe80:'):
            continue
        try:
            pre = IPv4Network('0.0.0.0/' + (mask or '255.255.255.0')).prefixlen
        except Exception:
            pre = 24
        print(name + '|' + gw + '|' + str(pre))
        break
" 2>/dev/null || true)
    fi
  for _pg in "${NETWORKS[@]}"; do
    if [ -n "${DEPLOY_NET[$_pg]:-}" ]; then
      IFS='|' read -r _dgw _dnm <<<"${DEPLOY_NET[$_pg]}"
      [ -z "${SUBNET_GW[$_pg]:-}" ] && [ -n "$_dgw" ] && SUBNET_GW["$_pg"]="$_dgw"
      [ -z "${SUBNET_NM[$_pg]:-}" ] && [ -n "$_dnm" ] && SUBNET_NM["$_pg"]="$_dnm"
    fi
    _sv="${SAVED_SUB[$_pg]:-}"
    if [ -n "$_sv" ]; then
      IFS='|' read -r _sgw _snm _sbase _send <<<"$_sv"
      [ -z "${SUBNET_GW[$_pg]:-}" ] && [ -n "$_sgw" ] && SUBNET_GW["$_pg"]="$_sgw"
      [ -z "${SUBNET_NM[$_pg]:-}" ] && [ -n "$_snm" ] && SUBNET_NM["$_pg"]="$_snm"
      [ -z "${SUBNET_START[$_pg]:-}" ] && [ -n "$_sbase" ] && SUBNET_START["$_pg"]="$_sbase"
      [ -z "${SUBNET_END[$_pg]:-}" ] && [ -n "$_send" ] && SUBNET_END["$_pg"]="$_send"
    fi
  done
  # Unified VLAN detect + input (discover pass): exact operator format.
  # DVS / single-subnet PG -> one range. Multi-subnet standard PG -> per-host
  # H-lines (covered = note only). gw/nm silent from autofill; ranges blank
  # (operator types, ex: shown). Two loops: DVS first so covered-by resolves.
  if [ "$PASS" = "discover" ] && [ "${#NETWORKS[@]}" -gt 0 ]; then
    if ! declare -p NET_HOST_NODE >/dev/null 2>&1; then unset NET_HOST_NODE; declare -gA NET_HOST_NODE=(); fi
    if ! declare -p BLOCK_DONE >/dev/null 2>&1; then unset BLOCK_DONE; declare -gA BLOCK_DONE=(); fi
    if ! declare -p HNET_GW >/dev/null 2>&1; then
      unset HNET_GW HNET_NM HNET_BASE HNET_END
      declare -gA HNET_GW HNET_NM HNET_BASE HNET_END HNET_AUTO HNET_IP
      HNET_NAMES=()
    fi
    echo "  Detect VLAN MAP as below:"
    for _pass in dvs std; do
    for _pg in "${NETWORKS[@]}"; do
      if [ "$_pass" = "dvs" ]; then
        [ -n "${DVS_PGS[$_pg]:-}" ] || continue
      else
        [ -n "${DVS_PGS[$_pg]:-}" ] && continue
      fi
      _pgw="${SUBNET_GW[$_pg]:-}"; _pnm="${SUBNET_NM[$_pg]:-24}"
      if [ -n "${DVS_PGS[$_pg]:-}" ]; then
        _mhosts="all hosts (DVS)"
      else
        _mhosts=""
        for _ph in ${PG_HOSTS[$_pg]:-}; do
          [ -n "$_ph" ] || continue
          [ -n "$_mhosts" ] && _mhosts="${_mhosts}, "
          _mhosts="${_mhosts}${_ph}"
        done
        [ -z "$_mhosts" ] && _mhosts="—"
      fi
      printf '  %-20s hosts: %s\n' "$_pg" "$_mhosts"
      if [ -n "${DVS_PGS[$_pg]:-}" ]; then
        _single=1
      else
        declare -A _pgrps=()
        for _ph in ${PG_HOSTS[$_pg]:-}; do
          _psn="${HOST_SUB[$_ph]:-}"
          [ -n "$_psn" ] && _pgrps["$_psn"]="${_pgrps[$_psn]:-} ${_ph}"
        done
        if [ "${#_pgrps[@]}" -le 1 ]; then _single=1; else _single=0; fi
      fi
      if [ "$_single" = "1" ]; then
        # one range for the whole portgroup
        if [ -z "$_pgw" ]; then
          read -rp "    gateway (required — undiscoverable): " _pgw
          [ -n "$_pgw" ] && SUBNET_GW["$_pg"]="$_pgw"
        fi
        [ -z "$_pgw" ] && { warn "no gateway — skipped"; unset _pgrps 2>/dev/null; continue; }
        read -rp "    please provide vm network ip distribution ipam range (ex: 192.168.100.106-166) = " _rg
        if [ -n "$_rg" ]; then
          IFS='|' read -r _ib _ie <<<"$(split_range "$_rg")"
          [ -n "$_ib" ] && SUBNET_START["$_pg"]="$_ib"
          SUBNET_END["$_pg"]="$_ie"
        fi
        if [ -n "${SUBNET_START[$_pg]:-}" ]; then
          [ -n "$_pnm" ] && SUBNET_NM["$_pg"]="$_pnm"
          _e=0; for _n in "${SUBNET_NAMES[@]}"; do [ "$_n" = "$_pg" ] && _e=1; done
          [ "$_e" = "0" ] && SUBNET_NAMES+=("$_pg")
          BLOCK_DONE["${_pgw}|${_pnm}"]="${SUBNET_START[$_pg]}|${SUBNET_END[$_pg]:-}"
          if [ -z "${FIRST_GW:-}" ]; then
            FIRST_GW="$_pgw"; FIRST_NM="$_pnm"; FIRST_BASE="${SUBNET_START[$_pg]}"
          fi
        fi
        unset _pgrps 2>/dev/null
      else
        # multi-subnet: per-host H-lines
        _hi=0
        for _psn in $(printf '%s\n' "${!_pgrps[@]}" | sort); do
          for _ph in ${_pgrps[$_psn]}; do
            _hi=$((_hi + 1))
            _hgw="${_psn%%|*}"; _hnm="${_psn##*|}"
            _cov=""
            if [ -n "${BLOCK_DONE[$_psn]:-}" ]; then
              # covered by any already-defined pool on this exact block
              for _cp2 in "${SUBNET_NAMES[@]}"; do
                if [ "${SUBNET_GW[$_cp2]:-}|${SUBNET_NM[$_cp2]:-24}" = "$_psn" ] && [ -n "${SUBNET_START[$_cp2]:-}" ]; then _cov="$_cp2"; break; fi
              done
              if [ -z "$_cov" ]; then
                for _cp2 in "${HNET_NAMES[@]}"; do
                  if [ "${HNET_GW[$_cp2]:-}|${HNET_NM[$_cp2]:-24}" = "$_psn" ] && [ -n "${HNET_BASE[$_cp2]:-}" ]; then _cov="$_cp2"; break; fi
                done
              fi
              [ -z "$_cov" ] && _cov="defined pool"
            fi
            if [ -n "$_cov" ]; then
              printf '\tH%d. please provide vm network ip distribution ipam range for %s (... = covered by %s\n' "$_hi" "$_ph" "$_cov"
            else
              read -rp "	H$_hi. please provide vm network ip distribution ipam range for $_ph (ex: 192.168.1.106-166) = " _hrg
              if [ -n "$_hrg" ]; then
                IFS='|' read -r _hb _he2 <<<"$(split_range "$_hrg")"
                if [ -n "$_hb" ]; then
                  HNET_NAMES+=("$_ph")
                  HNET_GW["$_ph"]="$_hgw"; HNET_NM["$_ph"]="$_hnm"
                  HNET_BASE["$_ph"]="$_hb"; HNET_END["$_ph"]="$_he2"
                  BLOCK_DONE["$_psn"]="$_hb|$_he2"
                fi
              fi
            fi
          done
        done
        unset _pgrps
      fi
    done
    done
  fi
  if [ "$IS_NEW" = "1" ] && [ -n "$DC" ]; then
    _dup=0; for _d in "${DC_DONE[@]}"; do [ "$_d" = "$DC" ] && _dup=1; done
    if [ "$_dup" = "0" ]; then DC_DONE+=("$DC"); snap_dc_save "$DC"; fi
  fi
fi

if [ "$PASS" = "input" ]; then
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
  declare -A HNET_GW HNET_NM HNET_BASE HNET_END HNET_AUTO HNET_IP
  HNET_NAMES=()
fi

# ─── 3a2. per-network IPAM blocks (optional) ────────────────
# Each port group can carry its OWN gateway/netmask/IP-range/DNS that WINS over
# the vCenter-wide defaults when a VM is created on it (create-vm-config.sh §2).
# New networks (not yet in network_subnets) simply fall back to the vCenter
# defaults — nothing breaks. Keys must match port-group names exactly as govc
# discovers them. Existing entries are pre-loaded above; Enter keeps a value.
# NEW flow covers per-network input in the discover section above; this full
# editor stays for EDIT flow (existing entries).
if [ "$IS_NEW" != "1" ]; then
echo ""
echo "  ─── Per-network IPAM (optional — auto-fills gateway/IP-range per VLAN) ───"
while true; do
  read -rp "  Add/update a per-network IPAM block? [y/N]: " add_sub
  case "$add_sub" in
    y|Y|yes|YES) ;;
    *) break ;;
  esac
  snet=""
  if [ "${#NETWORKS[@]}" -gt 0 ]; then
    echo "  Discovered portgroups for ${DC}:"
    for i in "${!NETWORKS[@]}"; do
      printf '    %d) %s%s\n' "$((i+1))" "${NETWORKS[$i]}" "$([ -n "${SUBNET_GW[${NETWORKS[$i]}]:-}" ] && echo " (gw=${SUBNET_GW[${NETWORKS[$i]}]})")"
    done
    read -rp "  Select number, type custom name, or Enter=skip: " snet
    if [[ "$snet" =~ ^[0-9]+$ ]] && [ "$snet" -ge 1 ] 2>/dev/null && [ "$snet" -le "${#NETWORKS[@]}" ]; then
      snet="${NETWORKS[$((snet-1))]}"
    fi
  else
    read -rp "  Network/port-group name: " snet
  fi
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
fi

# ─── 3a3. per-host network IPAM (standard-vSwitch, per-host subnets) ──
# Hosts behind a standard vSwitch each sit on their OWN subnet ("VM Network"
# on node A = 198.51.100.0/24, node B = 192.0.2.0/24). Define each host's
# gateway/netmask/ipam so a VM pinned to it gets the right range (no govc
# dependency). Key = host name as govc reports it.
# Same: NEW flow auto-covers hosts in discover; interactive editor for EDIT.
if [ "$IS_NEW" != "1" ]; then
echo ""
echo "  ─── Per-host network config (optional — per-host subnets for standard-vSwitch networks) ───"
DC_HOSTS=()
while IFS= read -r line; do [ -n "$line" ] && DC_HOSTS+=("$line"); done < <(govc_list_in h)
while true; do
  read -rp "  Add/update a per-host network block? [y/N]: " add_hnet
  case "$add_hnet" in
    y|Y|yes|YES) ;;
    *) break ;;
  esac
  hnet=""
  if [ "${#DC_HOSTS[@]}" -gt 0 ]; then
    echo "  Discovered hosts for ${DC}:"
    for i in "${!DC_HOSTS[@]}"; do
      printf '    %d) %s%s\n' "$((i+1))" "${DC_HOSTS[$i]}" "$([ -n "${HNET_GW[${DC_HOSTS[$i]}]:-}" ] && echo " (gw=${HNET_GW[${DC_HOSTS[$i]}]})")"
    done
    read -rp "  Select number, type custom name, or Enter=skip: " hnet
    if [[ "$hnet" =~ ^[0-9]+$ ]] && [ "$hnet" -ge 1 ] 2>/dev/null && [ "$hnet" -le "${#DC_HOSTS[@]}" ]; then
      hnet="${DC_HOSTS[$((hnet-1))]}"
    fi
  else
    read -rp "  Host name (as govc reports — e.g. 192.0.2.74): " hnet
  fi
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
  HNET_BASE["$hnet"]="$hbase"; HNET_END["$hnet"]="$hend"; unset "HNET_AUTO[$hnet]"
  ok "host_networks['${hnet}'] set (gw=${hgw} nm=${hnm} base=${hbase:-<auto>} end=${hend:-<auto>})"
done
fi

# ─── Network defaults + base IP (LAST — fallback role; prefilled from the
# first VLAN entry when the top level is still empty).
if [ "${#SUBNET_NAMES[@]}" -gt 0 ]; then
  _f="${SUBNET_NAMES[0]}"
  [ -z "$D_GW" ] && [ -n "${SUBNET_GW[$_f]:-}" ] && D_GW="${SUBNET_GW[$_f]}"
  if [ "${#D_DNS[@]}" -eq 0 ] && [ -n "${SUBNET_DNS[$_f]:-}" ]; then D_DNS=(${SUBNET_DNS[$_f]}); fi
  # base = first non-empty subnet base (the VLAN block decides the pool)
  if [ -z "$D_BASEIP" ]; then
    for _f in "${SUBNET_NAMES[@]}"; do
      if [ -n "${SUBNET_START[$_f]:-}" ]; then D_BASEIP="${SUBNET_START[$_f]}"; break; fi
    done
  fi
fi
# Sibling-DC fallback (same server run): first pool seen this run fills
# still-empty top defaults, so empty DCs (DR) inherit instead of blank.
[ -z "$D_GW" ] && [ -n "${FIRST_GW:-}" ] && D_GW="$FIRST_GW"
[ -z "$D_BASEIP" ] && [ -n "${FIRST_BASE:-}" ] && D_BASEIP="$FIRST_BASE"
if [ "$IS_NEW" = "1" ]; then
# Operator identity input (NEW only): gateway/netmask/base auto-fill from the
# first defined pool (VM-create negotiates per selected subnet block anyway).
# Only domain + DNS are typed here.
for _pn in "${SUBNET_NAMES[@]}"; do
  if [ -n "${SUBNET_START[$_pn]:-}" ]; then
    [ -z "$GW" ] && GW="${SUBNET_GW[$_pn]:-}"
    [ -z "$NM" ] && NM="${SUBNET_NM[$_pn]:-24}"
    [ -z "$BASEIP" ] && BASEIP="${SUBNET_START[$_pn]}"
    break
  fi
done
[ -n "$GW" ] || GW="$D_GW"
[ -n "$NM" ] || NM="${D_NM:-24}"
[ "${#DNS[@]}" -gt 0 ] || DNS=("${D_DNS[@]}")
[ -n "$BASEIP" ] || BASEIP="$D_BASEIP"
[ -n "$DOMAIN" ] || DOMAIN="$D_DOMAIN"
echo ""
echo "  --- Network identity (operator input) ---"
while [ -z "$DOMAIN" ]; do read -rp "  Domain: " DOMAIN; done
while [ "${#DNS[@]}" -eq 0 ]; do
  read -rp "  DNS servers, comma: " _dnsin2
  DNS=()
  while IFS= read -r _d; do [ -n "$_d" ] && DNS+=("$_d"); done < <(echo "$_dnsin2" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
done
info "  network auto (gw=${GW:-?} nm=${NM} base=${BASEIP:-?}) — per-subnet at VM-create"
# Empty-DC fallback (no pools defined anywhere): these become required once.
while [ -z "$GW" ]; do read -rp "  Gateway (required — no pool defined): " GW; done
while [ -z "$BASEIP" ]; do read -rp "  Base IP (required — no pool defined): " BASEIP; done
else
# Per-vCenter network defaults (each vCenter/VLAN has its own)
echo ""
echo "  ─── Network defaults (per vCenter VLAN) ───"
ask_required "  Domain"      DOMAIN  "$D_DOMAIN"
ask_required "  Gateway"     GW      "$D_GW"
ask "  Netmask (CIDR, e.g. 24)" NM "$D_NM"
while true; do
  read -rp "$(printf '  DNS servers [%s]: ' "${DNS[*]:-comma-separated, e.g. 8.8.8.8,1.1.1.1}")" DNS_IN
  if [ -n "$DNS_IN" ]; then
    DNS=()
    while IFS= read -r _d; do [ -n "$_d" ] && DNS+=("$_d"); done < <(echo "$DNS_IN" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  fi
  [ "${#DNS[@]}" -gt 0 ] && break
  error "At least one DNS server is required (per-vCenter) — type one (Ctrl+C to abort)."
done

echo ""
echo "  ─── IPAM (new-VM free-IP scan start) ───"
ask_required "  Base IP for free-IP scan" BASEIP "$D_BASEIP"
fi

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
  if [ "${#HNET_NAMES[@]}" -gt 0 ]; then
    echo "    host entries (per-host subnets):"
    for _n in "${HNET_NAMES[@]}"; do
      echo "      ${_n} → gw=${HNET_GW[$_n]} nm=${HNET_NM[$_n]:-24} start=${HNET_BASE[$_n]:-$BASEIP}${HNET_END[$_n]:+ end=${HNET_END[$_n]}}${HNET_AUTO[$_n]:+ (auto)}"
    done
  fi
  # overlap detector: same subnet (gw+nm), intersecting pools (VMs on either
  # entry could get the SAME IP → duplicate risk).
  _ovwarn=$({
    for _n in "${SUBNET_NAMES[@]}"; do
      printf '%s|%s|%s|%s|%s\n' "$_n" "${SUBNET_GW[$_n]:-}" "${SUBNET_NM[$_n]:-24}" "${SUBNET_START[$_n]:-}" "${SUBNET_END[$_n]:-${SUBNET_START[$_n]:-}}"
    done
    for _n in "${HNET_NAMES[@]}"; do
      printf '%s (host)|%s|%s|%s|%s\n' "$_n" "${HNET_GW[$_n]:-}" "${HNET_NM[$_n]:-24}" "${HNET_BASE[$_n]:-}" "${HNET_END[$_n]:-${HNET_BASE[$_n]:-}}"
    done
  } | python3 -c "
import sys
from ipaddress import ip_address
rows = []
for line in sys.stdin:
    p = line.strip().split('|')
    if len(p) != 5 or not p[0] or not p[2]:
        continue
    rows.append(p)
warns = []
for i in range(len(rows)):
    for j in range(i + 1, len(rows)):
        a, b = rows[i], rows[j]
        if a[1] != b[1] or a[2] != b[2]:
            continue
        # Identical pool (shared block, same base+end) = intentional, skip.
        if a[3] == b[3] and a[4] == b[4]:
            continue
        try:
            a1, a2 = ip_address(a[3]), ip_address(a[4])
            b1, b2 = ip_address(b[3]), ip_address(b[4])
        except Exception:
            continue
        if max(a1, b1) <= min(a2, b2):
            warns.append(a[0] + ' <-> ' + b[0] + ' (subnet ' + a[1] + '/' + a[2] + ')')
for w in warns:
    print(w)
" 2>/dev/null || true)
  [ -n "$_ovwarn" ] && warn "OVERLAPPING pools (duplicate-IP risk): ${_ovwarn}"
echo "  ──────────────────────────────────────────────"
read -rp "  Save? (y=confirm / Enter or n=abort) [N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "  Aborted. Nothing saved."; rm -rf "$SRC"; exit 1;;
esac

# ─── 4a. refresh hosts{} block from live (organized file) ────────
# Static snapshot stale hoye jay (host pore add hole file e othe na) — tai
# confirm er POR, write er AGE live govc theke node-wise block rebuild.
# Live fail / govc nai → purano preserve (never wipe on failure).
HOSTS_BLOCK=""
if $GOVC_READY; then
  info "Refreshing node-wise hosts block from live govc…"
  HOSTS_BLOCK=$(bash scripts/vcenter-inventory.sh __discover live hosts 2>/dev/null \
    | jq -r --arg dc "$DC" '.[]? | select(.datacenter == $dc)
      | "\"\(.name)\" = { ip = \"\(.ip // "")\", datastores = [\(.datastores // [] | map("\"\(.)\"") | join(", "))], networks = [\(.networks // [] | map("\"\(.)\"") | join(", "))] }"' 2>/dev/null || true)
  [ -n "$HOSTS_BLOCK" ] && ok "hosts{} refreshed ($(printf '%s\n' "$HOSTS_BLOCK" | grep -c .) node(s))" \
    || info "hosts{}: live empty — preserved/commented"
fi

# ─── 4b. auto-create dirs ONLY after confirmation ─────────
# (an aborted run must leave no orphan dirs / override templates behind)
if [ "$IS_NEW" = "1" ]; then
  _NDIR="${VCENTER##*_}/${VCENTER}"
  mkdir -p "deploy/${_NDIR}"/{dev,prod,staging} "secure/${_NDIR}"
  for _e in dev prod staging; do
    mkdir -p "secure/${_NDIR}/${_e}"
    create_override_template "$_NDIR" "$_e"
    create_user_groups_template "$_NDIR" "$_e"
    create_hardening_env_template "$_NDIR" "$_e"
  done
  # Per-vCenter VM defaults (policy-like). Auto-created from built-in defaults;
  # the operator edits secure/<server>/<vcenter>/vm-defaults.conf afterwards. Holds the
  # extra-user default password → lives in secure/ (gitignored), never committed.
  create_vm_defaults_template "${VCENTER##*_}/${VCENTER}"
  create_hardening_dc_template "${VCENTER##*_}/${VCENTER}"
  ok "Created deploy/${VCENTER##*_}/${VCENTER}/{dev,prod,staging} and secure/… (override dirs)"
else
  # existing vCenter — ensure per-env override dirs + user-groups policy exist
  # for EVERY env. Collect the union of deploy/ and secure/ env dirs so an env
  # that only exists on one side still gets its policy file.
  _envs=()
  _NDIR="${VCENTER##*_}/${VCENTER}"
  for _d in "$(vdir_for deploy "$VCENTER")"/*/ "$(vdir_for secure "$VCENTER")"/*/; do
    [ -d "$_d" ] || continue
    _e="$(basename "$_d")"
    case " ${_envs[*]:-} " in *" $_e "*) ;; *) _envs+=("$_e");; esac
  done
  for _e in "${_envs[@]}"; do
    mkdir -p "secure/${_NDIR}/${_e}"
    create_override_template "$_NDIR" "$_e"
    create_user_groups_template "$_NDIR" "$_e"
    create_hardening_env_template "$_NDIR" "$_e"
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

DEST="secure/${VCENTER##*_}/${VCENTER}"
mkdir -p "$DEST"

# Pre-save backup (re-save overwrites): copy current entry to trash first.
if [ -d "$DEST" ] && { [ -f "${DEST}/credentials.tfvars" ] || [ -f "${DEST}/vcenter.tfvars" ]; }; then
  TRASH_PRE="secure/.trash/$(date -u +%Y-%m-%dT%H-%M-%SZ)_${VCENTER}-pre-save"
  mkdir -p "$TRASH_PRE/secure" "$TRASH_PRE/deploy"
  cp -r "${DEST}/." "$TRASH_PRE/secure/" 2>/dev/null || true
  PDEST="secure/${VCENTER##*_}"
  [ "$PDEST" != "$DEST" ] && [ -d "$PDEST" ] && mkdir -p "$TRASH_PRE/secure-platform" && cp -r "${PDEST}/." "$TRASH_PRE/secure-platform/" 2>/dev/null || true
  _DTRASH="$(vdir_for deploy "$VCENTER")"
  [ -d "$_DTRASH" ] && cp -r "${_DTRASH}/." "$TRASH_PRE/deploy/" 2>/dev/null || true
  ok "Pre-save backup → ${TRASH_PRE}"
fi

cat > "${SRC}/credentials.tfvars" <<EOF
vsphere_server       = "${SERVER}"
vsphere_user         = "${USER}"
vsphere_password     = "${PASSWORD}"
allow_unverified_ssl = true
EOF

# Picked inventory lists as HCL (curated priority at VM-create; empty = []).
H_CLUSTERS="";   [ "${#CLUSTERS[@]}" -gt 0 ]   && H_CLUSTERS=$(printf '"%s", ' "${CLUSTERS[@]}" | sed 's/, $//')
H_TEMPLATES="";  [ "${#TEMPLATES[@]}" -gt 0 ]  && H_TEMPLATES=$(printf '"%s", ' "${TEMPLATES[@]}" | sed 's/, $//')
H_DATASTORES=""; [ "${#DATASTORES[@]}" -gt 0 ] && H_DATASTORES=$(printf '"%s", ' "${DATASTORES[@]}" | sed 's/, $//')
H_NETWORKS="";   [ "${#NETWORKS[@]}" -gt 0 ]   && H_NETWORKS=$(printf '"%s", ' "${NETWORKS[@]}" | sed 's/, $//')
H_POOLS="";      [ "${#POOLS[@]}" -gt 0 ]      && H_POOLS=$(printf '"%s", ' "${POOLS[@]}" | sed 's/, $//')

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
      "$_n" "${SUBNET_GW[$_n]}" "${SUBNET_NM[$_n]:-24}" "${SUBNET_START[$_n]:-$(ip_add "${SUBNET_GW[$_n]}" "${DEFAULT_IPAM_RESERVE:-30}")}" "${SUBNET_END[$_n]:-}")"$'\n'
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
# INVENTORY LISTS (picked at onboarding — curated priority at VM-create time;
# blank = auto-discover all via live govc). Same shape the WebUI backend
# writes; per-env overrides can further restrict.
# ─────────────────────────────────────────────────────────────────────────────
clusters       = [${H_CLUSTERS}]
templates      = [${H_TEMPLATES}]
datastores     = [${H_DATASTORES}]
networks       = [${H_NETWORKS}]
resource_pools = [${H_POOLS}]

# Per-vCenter network defaults (used by create-vm-config.sh + terraform)
domain      = "${DOMAIN}"
gateway     = "${GW}"
netmask     = ${NM}
dns_servers = [$(printf '"%s", ' "${DNS[@]}" | sed 's/, $//')]

# ─────────────────────────────────────────────────────────────────────────────
# NODE-WISE INVENTORY (refreshed from live govc at every save — §4a).
# Live fail korle ager block preserve hoy (kokhono wipe na).
# ─────────────────────────────────────────────────────────────────────────────
hosts = {
${HOSTS_BLOCK:-${D_HOSTS_BLOCK:-  # "node-01" = { ip = "192.168.1.11", datastores = ["datastore01"], networks = ["VM Network"] }}
}

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

# IPAM — legacy fallback base IP (per-network ipam_base WINS when the network
# has a network_subnets entry)
ipam_base_ip = "${BASEIP}"
EOF

# credentials.tfvars = SECRET → encrypt to the PLATFORM store (ONE copy per
# server: secure/<srv>/ — every DC of the platform shares it; a per-DC file
# still wins when present (legacy/override). The per-DC dupe is removed here
# (it held the same fresh creds just written to the platform store).
PLATDIR="secure/${VCENTER##*_}"
mkdir -p "$PLATDIR"
sops --encrypt --age "$PUB_KEY" "${SRC}/credentials.tfvars" > "${PLATDIR}/credentials.tfvars"
echo "platform credential store for ${VCENTER##*_}" > "${PLATDIR}/.platform-creds"
rm -f "${DEST}/credentials.tfvars"
ok "Encrypted: ${PLATDIR}/credentials.tfvars (shared by all DCs of this platform)"

# vcenter.tfvars = inventory only (no secrets) → copy plaintext (readable)
cp "${SRC}/vcenter.tfvars" "${DEST}/vcenter.tfvars"
ok "Copied plaintext (readable): ${DEST}/vcenter.tfvars"

rm -rf "$SRC"

echo ""
ok "vCenter secrets saved for '${VCENTER}'."
echo "  Verify: bash scripts/sops-decrypt.sh ${VCENTER} dev --clean"
echo "  Deploy: bash scripts/deploy-vm.sh ${VCENTER} <env> <vm-name>"
echo "  Add VMs: bash scripts/create-vm-config.sh ${VCENTER} <env> <vm-name>"
fi

# ─── loop control: discover pass → input pass → done ───
# Edit flow runs once. NEW flow: queue empty after discover = rebuild from
# DC_DONE and take input per DC; empty after input = all saved, done.
if [ "$IS_NEW" != "1" ]; then break; fi
if [ "${#DC_QUEUE[@]}" -eq 0 ]; then
  if [ "$PASS" = "discover" ]; then
    if [ "${#DC_DONE[@]}" -eq 0 ]; then break; fi
    PASS=input; DC_QUEUE=("${DC_DONE[@]}"); DC_TOTAL="${#DC_QUEUE[@]}"
    info "Discovery done for ${DC_TOTAL} datacenter(s) — now input per DC."
  else
    break
  fi
fi
# carry over: connection + network defaults become the next round's defaults
D_SERVER="$SERVER"; D_USER="$USER"; D_PASS="$PASSWORD"
NEW_SERVER="$SERVER"
D_DOMAIN="$DOMAIN"; D_GW="$GW"; D_NM="$NM"; D_DNS=("${DNS[@]}"); D_BASEIP="$BASEIP"
# reset: everything datacenter-scoped (fresh picks for the next DC)
DC=""; D_DC=""; D_CLUSTER=""; D_DS=""; D_NET=""; D_TPL=""; D_RP=""
D_CLUSTERS=(); D_TEMPLATES=(); D_DATASTORES=(); D_NETWORKS=(); D_POOLS=()
CLUSTER=""; TPL=""; DS=""; NET=""; RP=""
CLUSTERS=(); TEMPLATES=(); DATASTORES=(); NETWORKS=(); POOLS=()
GOVC_DCS=()
SUBNET_NAMES=(); declare -A SUBNET_GW=() SUBNET_NM=() SUBNET_START=() SUBNET_END=() SUBNET_DNS=() BLOCK_DONE=()
declare -A NET_HOST_NODE=()
HNET_NAMES=(); declare -A HNET_GW=() HNET_NM=() HNET_BASE=() HNET_END=() HNET_AUTO=() HNET_IP=()
[ "${#DC_QUEUE[@]}" -gt 0 ] && info "Next datacenter on '${SERVER}' — credentials + network defaults carried over."
done
