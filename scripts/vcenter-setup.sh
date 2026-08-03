#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

#############################################################
# vcenter-setup.sh — Interactive vCenter Secrets Setup
#############################################################
# PURPOSE
#   One-shot wizard to configure a (new) vCenter for the project.
#   Prompts for credentials + inventory, encrypts them with SOPS/age,
#   and stores them as secure/<env>/{credentials,vcenter}.tfvars
#   so that deploy-vm.sh / deploy-sync.sh can decrypt on demand.
#
# WHEN TO USE
#   - First-time setup of a brand-new environment (dev/prod/staging/qa).
#   - Switching to a DIFFERENT vCenter (new server, cluster, datastore).
#   - Rotating the vSphere password or moving inventory names.
#
# HOW TO USE
#   bash scripts/vcenter-setup.sh
#   (no arguments — everything is asked interactively; Enter = default)
#
# WHAT IT DOES
#   1. Shows a menu of existing environments + option to create new.
#   2. If an existing env is chosen, reads its CURRENT values and uses
#      them as defaults (so a single change is a few Enter presses).
#   3. Prompts: server / user / password (typed, confirmed) / datacenter /
#      cluster / datastore / network / template — each shows [default].
#   4. Shows a summary diff and asks for confirmation before writing.
#   5. Writes plaintext to .tmp-sops-plain/<env>/ (git-ignored, inside the
#      project so sops creation-rules match).
#   6. Encrypts with sops --encrypt --age <public-key> →
#      secure/<env>/{credentials,vcenter}.tfvars
#   7. Deletes the plaintext staging dir automatically.
#
# OUTPUT / AFTER
#   secure/<env>/credentials.tfvars   (encrypted)
#   secure/<env>/vcenter.tfvars       (encrypted)
#   Verify:  bash scripts/sops-decrypt.sh <env> --clean
#   Deploy:  bash scripts/deploy-vm.sh <env> <vm-name>
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

# ─── 1. environment selection (menu) ───────────────────────
EXISTING=$(ls -d secure/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | grep -v '^$' || true)

echo "${c_bold}  vCenter Secrets Setup${c_rst}"
echo "  ──────────────────────────────"
if [ -n "$EXISTING" ]; then
  echo "  Existing environments:"
  i=1
  while read -r e; do
    [ -z "$e" ] && continue
    printf '    %d) %s\n' "$i" "$e"
    ENVS[$i]="$e"; i=$((i+1))
  done <<< "$EXISTING"
  printf '    %d) %s\n' "$i" "Create NEW environment"
  read -rp "  Select (1-${i}): " SEL
  case "$SEL" in
    ''|*[!0-9]*) ENV="" ;;
    *) ENV="${ENVS[$SEL]:-}"; [ "$SEL" = "$i" ] && ENV="NEW" ;;
  esac
  if [ "$ENV" = "NEW" ]; then
    read -rp "  New env name (dev/prod/staging/qa/...): " ENV
    ENV="${ENV// /_}"
    [ -n "$ENV" ] || { error "Env name required"; exit 1; }
    if [ -d "secure/$ENV" ]; then warn "Env '$ENV' already exists — editing it."; fi
  elif [ -z "$ENV" ]; then
    error "Invalid selection."; exit 1
  fi
else
  read -rp "  Environment (dev/prod/staging/qa/...): " ENV
  ENV="${ENV// /_}"
  [ -n "$ENV" ] || { error "Env required"; exit 1; }
fi

# ─── 2. load existing values as defaults ───────────────────
SRC=".tmp-sops-plain/${ENV}"
mkdir -p "$SRC"

D_SERVER="192.0.2.10"; D_USER="administrator@example.local"
D_PASS=""; D_DC="dc_pilot"; D_CLUSTER="primary_cluster"
D_DS="datastore01"; D_NET="VM Network"; D_TPL="ubuntu-24-template"

if [ -f "secure/${ENV}/credentials.tfvars" ] && [ -f "secure/${ENV}/vcenter.tfvars" ]; then
  sops -d "secure/${ENV}/credentials.tfvars" > "$SRC/credentials.tfvars" 2>/dev/null || true
  sops -d "secure/${ENV}/vcenter.tfvars"     > "$SRC/vcenter.tfvars"     2>/dev/null || true
  if [ -s "$SRC/credentials.tfvars" ]; then
    source <(grep -E '^(vsphere_server|vsphere_user|vsphere_password)' "$SRC/credentials.tfvars" | sed 's/ *= */=/')
    D_SERVER="${vsphere_server:-$D_SERVER}"; D_USER="${vsphere_user:-$D_USER}"; D_PASS="${vsphere_password:-}"
  fi
  if [ -s "$SRC/vcenter.tfvars" ]; then
    source <(grep -E '^(datacenter|cluster|datastore|network|template)' "$SRC/vcenter.tfvars" | sed 's/ *= */=/')
    D_DC="${datacenter:-$D_DC}"; D_CLUSTER="${cluster:-$D_CLUSTER}"
    D_DS="${datastore:-$D_DS}"; D_NET="${network:-$D_NET}"; D_TPL="${template:-$D_TPL}"
  fi
  info "Loaded existing values for '$ENV' — Enter keeps them."
  rm -f "$SRC/credentials.tfvars" "$SRC/vcenter.tfvars"
fi

# ─── 3. collect values ─────────────────────────────────────
SERVER="$D_SERVER"; USER="$D_USER"; PASSWORD="$D_PASS"
DC="$D_DC"; CLUSTER="$D_CLUSTER"; DS="$D_DS"; NET="$D_NET"; TPL="$D_TPL"

echo ""
echo "  Fill values — Enter keeps the [default] shown:"
echo ""
ask "  vSphere server IP/FQDN"  SERVER  "$D_SERVER"
ask "  vSphere user"            USER    "$D_USER"

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
ask "  Datastore"   DS      "$D_DS"
ask "  Network"     NET     "$D_NET"
ask "  Template"    TPL     "$D_TPL"

# ─── 4. summary + confirm ──────────────────────────────────
echo ""
echo "  ──────────────────────────────────────────────"
echo "  Summary for env: ${c_bold}${ENV}${c_rst}"
echo "    server      = $SERVER"
echo "    user        = $USER"
echo "    password    = $([ -n "$PASSWORD" ] && echo '**** (set)' || echo '(missing)')"
echo "    datacenter  = $DC"
echo "    cluster     = $CLUSTER"
echo "    datastore   = $DS"
echo "    network     = $NET"
echo "    template    = $TPL"
echo "  ──────────────────────────────────────────────"
read -rp "  Save? [y/N]: " CONFIRM
case "$CONFIRM" in
  y|Y|yes|YES) ;;
  *) echo "  Aborted. Nothing saved."; rm -rf "$SRC"; exit 1;;
esac

# ─── 5-6. write plaintext + encrypt ───────────────────────
DEST="secure/${ENV}"
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
resource_pool = "Resources"
datastore  = "${DS}"
network    = "${NET}"
template   = "${TPL}"
EOF

AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
[ -f "$AGE_KEY" ] || { error "age key not found at $AGE_KEY"; exit 1; }
PUB_KEY=$(grep -oP '(?<=public key: )age1[0-9a-z]+' "$AGE_KEY" | head -1)
[ -n "$PUB_KEY" ] || { error "could not read public key"; exit 1; }

for f in credentials vcenter; do
  sops --encrypt --age "$PUB_KEY" "${SRC}/${f}.tfvars" > "${DEST}/${f}.tfvars"
  ok "Encrypted: ${DEST}/${f}.tfvars"
done

rm -rf "$SRC"

echo ""
ok "vCenter secrets saved for env '${ENV}'."
echo "  Verify: bash scripts/sops-decrypt.sh ${ENV} --clean"
echo "  Deploy: bash scripts/deploy-vm.sh ${ENV} <vm-name>"
echo "  Add VMs: bash scripts/create-vm-config.sh ${ENV} <vm-name> <base-ip>"
