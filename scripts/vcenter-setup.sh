#!/bin/bash
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
#   Inventory [default] values come from scripts/vm-defaults.conf (key=value);
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

# a vCenter dir = top-level deploy/<name>/ containing env sub-directories
list_vcenters() {
  local d v
  for d in deploy/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ "$v" = "examples" ] && continue
    if ls -d "${d}"*/ >/dev/null 2>&1; then echo "$v"; fi
  done
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
# Uncomment + set any key to OVERRIDE the top-level secure/${dir}/vcenter.tfvars
# for this environment only. Keys left commented fall back to the top-level value.
# (credentials are NEVER per-env — secrets stay in secure/${dir}/credentials.tfvars)
#
# datacenter    = "${DC:-dc_pilot}"
# cluster       = "${CLUSTER:-primary_cluster}"
# resource_pool = "${RP:-Resources}"
# datastore     = "${DS:-datastore01}"
# network       = "${NET:-VM Network}"
# template      = "${TPL:-ubuntu-24-template}"
# domain        = "${DOMAIN:-example.local}"
# gateway       = "${GW:-198.51.100.1}"
# netmask       = ${NM:-24}
# dns_servers   = [$(printf '"%s", ' "${DNS[@]}" | sed 's/, $//')]
# ipam_base_ip  = "${BASEIP:-198.51.100.106}"
EOF
}

# ─── Central defaults (editable) ───────────────────────────────────────
# Edit scripts/vm-defaults.conf to change the shared inventory defaults.
# vCenter SERVER + USER are per-vCenter → always required here; they never
# come from vm-defaults.conf. Existing values are auto-loaded from
# secure/<vcenter>/credentials.tfvars + vcenter.tfvars as defaults; a NEW
# vCenter starts empty (everything typed by hand).
info "Inventory defaults: per-vCenter secure/<vcenter>/vcenter.tfvars (no central defaults)"

# ─── 1. vCenter selection (menu) ───────────────────────────
EXISTING=$(list_vcenters)
NEW_SERVER=""
IS_NEW=0

echo "${c_bold}  vCenter Setup${c_rst}"
echo "  ──────────────────────────────"
if [ -n "$EXISTING" ]; then
  echo "  Existing vCenters:"
  i=1
  while read -r v; do
    [ -z "$v" ] && continue
    printf '    %d) %s\n' "$i" "$v"
    VCENTERS[$i]="$v"; i=$((i+1))
  done <<< "$EXISTING"
  printf '    %d) %s\n' "$i" "Create NEW vCenter"
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
    [ -n "$NEW_SERVER" ] || NEW_SERVER="$NEW_SERVER"
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
  read -rp "  vCenter server IP/FQDN (becomes dir name): " NEW_SERVER
  NEW_SERVER="${NEW_SERVER// /}"
  [ -n "$NEW_SERVER" ] || { error "vCenter server required"; exit 1; }
  NEW_SERVER="$(echo "$NEW_SERVER" | sed -E 's#^[a-zA-Z]+://##; s#[/:]+$##; s/[^a-zA-Z0-9._-]/_/g')"
  [ -n "$NEW_SERVER" ] || NEW_SERVER="$NEW_SERVER"
  VCENTER="$NEW_SERVER"
  IS_NEW=1
fi

# ─── 2. load existing values as defaults ───────────────────
SRC=".tmp-sops-plain/${VCENTER}"
mkdir -p "$SRC"

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
    source <(grep -E '^(datacenter|cluster|resource_pool|datastore|network|template|domain|gateway|netmask|ipam_base_ip)' "$SRC/vcenter.tfvars" | sed 's/ *= */=/')
    D_DC="${datacenter:-$D_DC}"; D_CLUSTER="${cluster:-$D_CLUSTER}"
    D_RP="${resource_pool:-$D_RP}"
    D_DS="${datastore:-$D_DS}"; D_NET="${network:-$D_NET}"; D_TPL="${template:-$D_TPL}"
    D_DOMAIN="${domain:-$D_DOMAIN}"; D_GW="${gateway:-$D_GW}"; D_NM="${netmask:-$D_NM}"
    D_BASEIP="${ipam_base_ip:-$D_BASEIP}"
    D_DNS=(); while IFS= read -r _d; do [ -n "$_d" ] && D_DNS+=("$_d"); done \
      < <(grep -E '^dns_servers' "$SRC/vcenter.tfvars" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
  fi
  info "Loaded existing values for '$VCENTER' — Enter keeps them."
  rm -f "$SRC/credentials.tfvars" "$SRC/vcenter.tfvars"
fi

# ─── 3. collect values ─────────────────────────────────────
SERVER="${D_SERVER:-$NEW_SERVER}"; USER="$D_USER"; PASSWORD="$D_PASS"
DC="$D_DC"; CLUSTER="$D_CLUSTER"; RP="$D_RP"; DS="$D_DS"; NET="$D_NET"; TPL="$D_TPL"
DOMAIN="${D_DOMAIN:-}"; GW="${D_GW:-}"; NM="${D_NM:-24}"; DNS=("${D_DNS[@]}")
BASEIP="${D_BASEIP:-}"

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

ask "  Datacenter"  DC      "$D_DC"
ask "  Cluster"     CLUSTER "$D_CLUSTER"
ask "  Resource pool" RP    "$D_RP"
ask "  Datastore"   DS      "$D_DS"
ask "  Network"     NET     "$D_NET"
ask "  Template"    TPL     "$D_TPL"

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

# ─── 3b. finalize dir name (<datacenter>_<server>) + auto-create dirs ──
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
  # auto-create env child dirs + per-env override dirs
  mkdir -p "deploy/${VCENTER}"/{dev,prod,staging} "secure/${VCENTER}"
  for _e in dev prod staging; do
    mkdir -p "secure/${VCENTER}/${_e}"
    create_override_template "$VCENTER" "$_e"
  done
  ok "Created deploy/${VCENTER}/{dev,prod,staging} and secure/${VCENTER}/{dev,prod,staging} (override dirs)"
else
  # existing vCenter — ensure per-env override dirs exist for its envs
  for _d in "deploy/${VCENTER}"/*/; do
    [ -d "$_d" ] || continue
    _e="$(basename "$_d")"
    mkdir -p "secure/${VCENTER}/${_e}"
    create_override_template "$VCENTER" "$_e"
  done
fi

# ─── 4. summary + confirm ──────────────────────────────────
echo ""
echo "  ──────────────────────────────────────────────"
echo "  Summary for vCenter: ${c_bold}${VCENTER}${c_rst}"
echo "    server        = $SERVER"
echo "    user          = $USER"
echo "    password      = $([ -n "$PASSWORD" ] && echo '**** (set)' || echo '(missing)')"
echo "    datacenter    = $DC"
echo "    cluster       = $CLUSTER"
echo "    resource_pool = $RP"
echo "    datastore     = $DS"
echo "    network       = $NET"
echo "    template      = $TPL"
echo "    domain        = $DOMAIN"
echo "    gateway       = $GW"
echo "    netmask       = $NM"
echo "    dns_servers   = [${DNS[*]}]"
echo "    base_ip       = $BASEIP"
echo "  ──────────────────────────────────────────────"
read -rp "  Save? [y/N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "  Aborted. Nothing saved."; rm -rf "$SRC"; exit 1;;
esac

# ─── 5-6. write plaintext + encrypt ───────────────────────
DEST="secure/${VCENTER}"
mkdir -p "$DEST"

cat > "${SRC}/credentials.tfvars" <<EOF
vsphere_server       = "${SERVER}"
vsphere_user         = "${USER}"
vsphere_password     = "${PASSWORD}"
allow_unverified_ssl = true
EOF

cat > "${SRC}/vcenter.tfvars" <<EOF
datacenter = "${DC}"
cluster    = "${CLUSTER}"
resource_pool = "${RP}"
datastore  = "${DS}"
network    = "${NET}"
template   = "${TPL}"

# Per-vCenter network defaults (used by create-vm-config.sh + terraform)
domain      = "${DOMAIN}"
gateway     = "${GW}"
netmask     = ${NM}
dns_servers = [$(printf '"%s", ' "${DNS[@]}" | sed 's/, $//')]

# IPAM — starting IP for new-VM free-IP scan
ipam_base_ip = "${BASEIP}"
EOF

AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
[ -f "$AGE_KEY" ] || { error "age key not found at $AGE_KEY"; exit 1; }
PUB_KEY=$(grep -oP '(?<=public key: )age1[0-9a-z]+' "$AGE_KEY" | head -1)
[ -n "$PUB_KEY" ] || { error "could not read public key"; exit 1; }

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
