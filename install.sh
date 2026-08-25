#!/usr/bin/env bash
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

###############################################################################
# install.sh — The ONE intelligent entry point (Linux / macOS / WSL)
###############################################################################
# PURPOSE
#   Detects the environment and does whatever is missing — dependency setup,
#   keys, and terraform init are all handled right here, all by itself:
#
#     curl -fsSL https://raw.githubusercontent.com/engr-rakib/VMPilot/main/install.sh | bash
#
#   Fresh / new machine  → base tools → clone the project → system packages →
#                          terraform → govc → sops → age key → ssh key →
#                          terraform init → "what's next" printout.
#   Existing install     → self-update (pull) → install ONLY what is missing.
#   Everything ready     → nothing re-done, just status + next step.
#
#   Idempotent by design: every step checks the current state and skips work
#   that is already done, so re-running is always safe.
#
# USAGE
#   bash install.sh                 # same detection, probably asks before installs
#   bash install.sh --yes           # non-interactive: do everything, no prompts
#   bash install.sh --deps          # dependencies-only (re-run setup on demand)
#   bash install.sh --no-keys       # skip age + ssh key generation
#   bash install.sh --no-init       # skip `terraform init`
#   bash install.sh --latest        # fetch the latest versions at runtime
#
# ENV OVERRIDES
#   VMPILOT_REPO   git URL to clone (default: public GitHub repo)
#   VMPILOT_BRANCH branch to clone   (default: main)
#   VMPILOT_DIR    target directory  (default: ~/VMPilot)
###############################################################################
set -euo pipefail

VMPILOT_REPO="${VMPILOT_REPO:-https://github.com/engr-rakib/VMPilot.git}"
VMPILOT_BRANCH="${VMPILOT_BRANCH:-main}"
VMPILOT_DIR="${VMPILOT_DIR:-${HOME}/VMPilot}"

# ─── pinned, known-good versions (override via env var) ───────────────────
TERRAFORM_MIN="1.6"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.8}"
GOVC_VERSION="${GOVC_VERSION:-0.55.1}"
SOPS_VERSION="${SOPS_VERSION:-3.13.3}"

# ─── flags ─────────────────────────────────────────────────────────────────
INTERACTIVE=false; [ -t 0 ] && INTERACTIVE=true     # piped stdin → never prompt
DEPS_ONLY=false                                     # --deps: dependency phase only
RUN_INIT=true                                       # --no-init: skip terraform init
GEN_KEYS=true                                       # --no-keys: skip key generation
USE_LATEST=false                                    # --latest: auto-detect versions
DEPLOY_WEBUI="ask"                                  # --webui / --no-webui: force / skip web UI

# ─── helpers (must precede flag parsing / usage) ────────────────────────────
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'; c_bold=$'\e[1m'; c_rst=$'\e[0m'
info()  { printf '%s::%s %s\n' "$c_cyn" "$c_rst" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$c_yel" "$c_rst" "$*"; }
err()   { printf '%s✗%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()   { err "$1"; exit 1; }
ok()    { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
have()  { command -v "$1" >/dev/null 2>&1; }
usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

Detect the environment and do whatever is missing — installs the project itself
plus every dependency, so "run install.sh" is the only command you need.

Options:
  --yes        Non-interactive: do everything, no prompts (safe via curl | bash)
  --deps       Dependencies only — skip clone/base tools (re-run setup on demand)
  --no-keys    Skip generating the SOPS age key and SSH key
  --no-init    Skip running `terraform init`
  --webui      Deploy the Docker Web Console — COMMERCIAL ADD-ON: requires the
               purchased vmpilot-webui/ package placed in the project root
  --no-webui   Never offer/deploy the web console
  --latest     Fetch latest tool versions at runtime instead of pinned ones
  --help | -h  Show this help

Environment:
  VMPILOT_REPO   git URL to clone   (default: https://github.com/engr-rakib/VMPilot.git)
  VMPILOT_BRANCH branch to checkout (default: main)
  VMPILOT_DIR    target directory   (default: ~/VMPilot)
  TERRAFORM_VERSION / GOVC_VERSION / SOPS_VERSION  (override pinned versions)
  WEBUI_PASSWORD password for the web console admin (with --webui)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --deps)      DEPS_ONLY=true ;;
    --yes|-y)    INTERACTIVE=false ;;
    --no-keys)   GEN_KEYS=false ;;
    --no-init)   RUN_INIT=false ;;
    --webui)     DEPLOY_WEBUI=true ;;
    --no-webui)  DEPLOY_WEBUI=false ;;
    --latest)    USE_LATEST=true ;;
    --help|-h)   usage; exit 0 ;;
    *)           err "Unknown option: $arg"; exit 1 ;;
  esac
done

# ─── helpers (continued) ────────────────────────────────────────────────────
confirm() {  # $1=msg ; auto-yes when non-interactive
  if [ "$INTERACTIVE" = false ]; then return 0; fi
  local msg="$1" yn
  read -rp "$(printf '%s (y/N): ' "$msg")" yn
  [[ "${yn:-N}" =~ ^[Yy] ]]
}

arch() { uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/arm/' -e 's/i686/386/'; }
tarball_arch() { uname -m | sed -e 's/aarch64/aarch64/' -e 's/x86_64/x86_64/'; }
os_token() { case "$OS" in Darwin) echo darwin;; *) echo linux;; esac; }

# terraform >= X.Y ?  (exit 0 = good)
terraform_ok() {
  [ "$#" -eq 1 ] || return 1
  local v="$1" want_major want_minor cur_major cur_minor
  want_major="${TERRAFORM_MIN%%.*}"; want_minor="${TERRAFORM_MIN#*.}"
  cur_major="${v%%.*}"; cur_minor="${v#*.}"; cur_minor="${cur_minor%%.*}"
  [ "${cur_major:-0}" -gt "${want_major}" ] && return 0
  [ "${cur_major:-0}" -eq "${want_major}" ] && [ "${cur_minor:-0}" -ge "${want_minor}" ]
}

github_latest() { # $1=owner/repo → latest release tag (vX.Y.Z), or empty
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -oP '"tag_name"\s*:\s*"\K[^"]+' || true
}

# ─── vCenter presence + newest VM config detection ──────────────────────────
has_vcenter() {  # 0 = a real (non-example) vCenter is configured
  local v
  [ -d "secure" ] || return 1
  for v in secure/*/; do
    [ -d "$v" ] || continue
    v="${v#secure/}"; v="${v%/}"
    [ -n "$v" ] && [ "$v" != "dc_example_192.0.2.10" ] && return 0
  done
  return 1
}

find_newest_vm_config() {  # prints "vcenter env vm-name" of newest vm-*.tfvars
  local f newest=""
  f="$(ls -t deploy/*/*/vm-*.tfvars 2>/dev/null | head -n1 || true)"
  [ -n "$f" ] || return 1
  f="${f#deploy/}"; newest="${f%%/*}"                 # vcenter
  f="${f#*/}";    newest="$newest ${f%%/*}"           # env
  f="${f#*/}";    newest="$newest ${f#vm-}"; newest="${newest%.tfvars}"  # vm-name
  printf '%s' "$newest"
}

# ─── "what's next" printout — adapts to what is already configured ──────────
next_steps() {
  local v vcenters=""
  if [ -d "secure" ]; then
    for v in secure/*/; do
      [ -d "$v" ] || continue
      v="${v#secure/}"; v="${v%/}"
      [ -n "$v" ] && [ "$v" != "dc_example_192.0.2.10" ] && vcenters+=" $v"
    done
  fi
  echo ""
  echo "${c_bold}══════════════════════════════════════════════════════${c_rst}"
  echo "${c_bold}   VMPilot ready — where to go next${c_rst}"
  echo "${c_bold}══════════════════════════════════════════════════════${c_rst}"
  if [ -n "$vcenters" ]; then
    info "Configured vCenters:${vcenters} — onboarding already done."
    echo ""
    info "  1. Create a VM config:  bash scripts/create-vm-config.sh <vcenter> <env> <vm-name>"
    info "  2. Deploy it:            bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>"
  else
    info "  1. Onboard YOUR vCenter (the only config you need):"
    echo "     ${c_bold}bash scripts/vcenter-setup.sh${c_rst}"
    echo "       (a committed dc_example_192.0.2.10 is a dummy — always 'Create NEW')"
    echo ""
    info "  2. Create a VM config:  bash scripts/create-vm-config.sh <vcenter> <env> <vm-name>"
    info "  3. Deploy it:            bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>"
  fi
  echo ""
  info "More help: README.md · secure/README.md · docs/"
  info "Web console (browser UI): bash vmpilot-webui/scripts/setup.sh && docker compose --profile nginx -f vmpilot-webui/docker-compose.yml up -d --build"

  # one-script promise: walk the whole journey now (interactive only)
  if [ "$INTERACTIVE" = true ]; then guided_chain; fi
  return 0   # never trip `set -e` from the short-circuit above
}

# ─── interactive guided journey: vCenter → VM config → deploy ──────────────
guided_chain() {
  local yn vc env name cfg

  # stage A — onboard a vCenter if none exists yet
  if ! has_vcenter; then
    echo ""
    read -rp "$(printf '%s (y/N): ' 'Onboard your vCenter now (interactive wizard)?')" yn
    if [[ "${yn:-N}" =~ ^[Yy] ]]; then
      echo ""; info "Launching vcenter-setup.sh ..."
      bash scripts/vcenter-setup.sh
    else
      info "OK — run it later with: bash scripts/vcenter-setup.sh"
      return
    fi
  fi

  # stage B — create a VM config (fully interactive)
  echo ""
  read -rp "$(printf '%s (y/N): ' 'Create a VM config now (interactive wizard)?')" yn
  if [[ "${yn:-N}" =~ ^[Yy] ]]; then
    echo ""; info "Launching create-vm-config.sh ..."
    bash scripts/create-vm-config.sh
  else
    info "OK — run it later with: bash scripts/create-vm-config.sh"
    return
  fi

  # stage C — deploy the config just created (auto-detect the newest one)
  cfg="$(find_newest_vm_config || true)"
  if [ -z "$cfg" ]; then
    info "No VM config found yet — deploy later with: bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>"
    return
  fi
  set -- $cfg
  vc="$1"; env="$2"; name="$3"
  echo ""
  read -rp "$(printf '%s (y/N): ' "Deploy '$name' on '$vc/$env' now?")" yn
  if [[ "${yn:-N}" =~ ^[Yy] ]]; then
    echo ""; info "Launching deploy-vm.sh ${vc} ${env} ${name} ..."
    bash scripts/deploy-vm.sh "$vc" "$env" "$name"
  else
    info "OK — run it later with: bash scripts/deploy-vm.sh ${vc} ${env} ${name}"
  fi

  # stage D — the web console (browser UI, Docker + nginx). Skipped when the
  # --webui / --no-webui flags already decide.
  if [ "$DEPLOY_WEBUI" = "ask" ]; then
    echo ""
    read -rp "$(printf '%s (y/N): ' 'Deploy the VMPilot Web UI (browser console)?')" yn
    if [[ "${yn:-N}" =~ ^[Yy] ]]; then
      if ! webui_deploy; then warn "Web UI not deployed — see message above."; fi
    else
      info "OK — run it later with: bash vmpilot-webui/scripts/setup.sh && docker compose --profile nginx -f vmpilot-webui/docker-compose.yml up -d --build"
    fi
  fi
}

# ─── web UI deployment (vmpilot-webui) — Docker + nginx console ─────────────
# Called explicitly (--webui) or as the final guided stage. Handles Docker
# install, secret bootstrap, and compose up. Never prompts when non-interactive.
require_docker() {
  have docker || {
    info "Docker is required for the web console."
    if confirm "Install Docker now (official get.docker.com script)?"; then
      curl -fsSL https://get.docker.com | sh
    else
      warn "Skipping Docker — run 'vmpilot-webui/scripts/setup.sh' + 'docker compose --profile nginx up' manually later."
      return 1
    fi
  }
  if ! docker info >/dev/null 2>&1; then
    if [ "$(id -u)" -ne 0 ] && confirm "Add your user to the docker group (requires re-login)?"; then
      sudo usermod -aG docker "$USER" && warn "Re-login, then run: bash vmpilot-webui/scripts/setup.sh"
      return 1
    fi
  fi
}

webui_deploy() {
  [ -d "vmpilot-webui" ] || die "vmpilot-webui/ not found — the Web Console is a COMMERCIAL ADD-ON (not in the public repo). Purchase includes the vmpilot-webui/ package: place it in the project root and re-run with --webui. Contact: https://engr-rakib.github.io/web"
  echo ""
  info "Deploying the VMPilot Web UI (vmpilot-webui/) ..."

  # graceful skip when Docker is unavailable / declined (already warned inside)
  require_docker || return 2

  # non-interactive runs get a generated password; interactive users set it themselves
  if [ "$INTERACTIVE" = true ]; then
    bash vmpilot-webui/scripts/setup.sh
  else
    local pw="${WEBUI_PASSWORD:-}"
    [ -z "$pw" ] && pw="$(openssl rand -base64 18 | tr -d '\n')"
    bash vmpilot-webui/scripts/setup.sh "$pw"
    echo ""
    warn "Generated admin password (save it, change it later): ${pw}"
  fi

  # hardened edge: TLS + rate limiting via the nginx profile (matches the
  # https:// URL below and docker-compose's optional web service).
  SUDO=""; [ "$(id -u)" -ne 0 ] && ! docker info >/dev/null 2>&1 && SUDO=sudo
  $SUDO docker compose --profile nginx -f vmpilot-webui/docker-compose.yml up -d --build

  local hport="" suffix=""
  hport="$(sed -n 's/^WEBUI_HTTPS_PORT=//p' vmpilot-webui/.env 2>/dev/null | tr -d '\r')"
  [ -n "$hport" ] && [ "$hport" != 443 ] && suffix=":${hport}"

  ok "Web UI deployed."
  ok "Open it at: https://<this-host>${suffix}/  (self-signed cert; replace under vmpilot-webui/nginx/certs/)"
}

# ─── 0. environment detection ───────────────────────────────────────────────
OS="$(uname -s)"
OS_ARCH="$(arch)"
HAS_REPO_OR_CLONE=false     # a real checkout is present in the current dir

PM=""
case "$OS" in
  Linux)
    if have apt-get; then PM=apt
    elif have dnf; then PM=dnf
    elif have yum; then PM=yum
    else die "Unsupported distro: need apt-get, dnf or yum."
    fi ;;
  Darwin) PM=brew ;;
  *) die "Unsupported OS '$OS'. Use Linux or macOS (or Windows via WSL)." ;;
esac

# where tools land — Homebrew uses its own prefix on macOS
BIN_DIR="/usr/local/bin"
[ "$OS" = "Darwin" ] && have brew && BIN_DIR="$(brew --prefix)/bin"

[ "${BASH_VERSINFO:-0}" -ge 4 ] || die "bash 4+ is required."

echo ""
echo "${c_bold}══════════════════════════════════════════════════════${c_rst}"
echo "${c_bold}   VMPilot — environment detect${c_rst}"
echo "${c_bold}══════════════════════════════════════════════════════${c_rst}"
info "OS: ${OS}  |  package manager: ${PM}  |  arch: ${OS_ARCH}"

# current state — what's already here? (this is the "intelligence")
MISSING_DEPS=""
for cmd in terraform govc sops age jq python3 git; do
  have "$cmd" || MISSING_DEPS+=" $cmd"
done
AGE_KEY="${HOME}/.config/sops/age/keys.txt"
SSH_PUB="$([ -f "$HOME/.ssh/id_ed25519.pub" ] && echo "$HOME/.ssh/id_ed25519.pub" || true)"
TERRAFORM_INIT_DONE=false
[ -d "terraform/.terraform" ] && TERRAFORM_INIT_DONE=true

if [ -z "$MISSING_DEPS" ] && [ -f "$AGE_KEY" ] && [ -n "$SSH_PUB" ] && [ "$TERRAFORM_INIT_DONE" = true ]; then
  info "Environment already fully prepared — nothing to install."
  if [ "$DEPS_ONLY" = false ]; then next_steps; fi
  # explicit --webui still deploys the console even when the CLI env is ready
  if [ "$DEPS_ONLY" = false ] && [ "$DEPLOY_WEBUI" = true ]; then
    if ! webui_deploy; then warn "Web UI not deployed — see message above."; fi
  fi
  exit 0
else
  [ -n "$MISSING_DEPS" ] && warn "Missing tools:${MISSING_DEPS}"
  [ ! -f "$AGE_KEY" ]  && warn "Missing: SOPS age key → will generate"
  [ -z "$SSH_PUB" ]    && warn "Missing: SSH key → will generate"
  [ "$TERRAFORM_INIT_DONE" = false ] && [ -d "terraform" ] && warn "Missing: terraform init → will run"
fi

# ─── 1. base tools (git / curl / unzip) ─────────────────────────────────────
NOT_BASE=""
for t in git curl unzip; do have "$t" || NOT_BASE+=" $t"; done
if [ -n "$NOT_BASE" ]; then
  info "Installing base tools:${NOT_BASE} ..."
  case "$PM" in
    apt) sudo apt-get update -y && sudo apt-get install -y git curl unzip ;;
    dnf) sudo dnf install -y git curl unzip ;;
    yum) sudo yum install -y git curl unzip ;;
    brew) have brew || die "Install Homebrew first: https://brew.sh"; brew install git curl unzip ;;
  esac
fi

# ─── 2. get the project ─────────────────────────────────────────────────────
if [ "$DEPS_ONLY" = true ]; then
  VMPILOT_DIR="$(pwd)"   # --deps is only meaningful inside a checkout
  info "Dependencies-only mode — project assumed in: ${VMPILOT_DIR}"
elif [ -f "scripts/lib/common.sh" ] && [ -d ".git" ]; then
  VMPILOT_DIR="$(pwd)"
  info "Already inside a VMPilot checkout — using: ${VMPILOT_DIR}"
  HAS_REPO_OR_CLONE=true
elif [ -d "${VMPILOT_DIR}/.git" ] && [ -f "${VMPILOT_DIR}/scripts/lib/common.sh" ]; then
  info "Existing VMPilot clone found — pulling latest..."
  git -C "${VMPILOT_DIR}" pull --ff-only origin "${VMPILOT_BRANCH}"
  HAS_REPO_OR_CLONE=true
else
  info "Fresh machine — cloning ${VMPILOT_REPO} (branch ${VMPILOT_BRANCH}) → ${VMPILOT_DIR} ..."
  mkdir -p "$(dirname "${VMPILOT_DIR}")"
  git clone --depth 1 --branch "${VMPILOT_BRANCH}" "${VMPILOT_REPO}" "${VMPILOT_DIR}"
  HAS_REPO_OR_CLONE=true
fi
cd "${VMPILOT_DIR}"
[ "$DEPS_ONLY" = false ] && ok "Project at: ${VMPILOT_DIR}"

# ─── 3. dependencies (terraform / govc / sops + system packages) ────────────
info "Dependency check + install (terraform / govc / sops / age / jq ...)"
PACKAGES="jq git curl wget unzip openssl ca-certificates"
[ "$PM" = "apt" ] && PACKAGES="$PACKAGES age gnupg software-properties-common"
[ "$PM" = "dnf" ] && PACKAGES="$PACKAGES age epel-release"
[ "$PM" = "yum" ] && PACKAGES="$PACKAGES age epel-release"
[ "$PM" = "brew" ] && PACKAGES="jq git curl wget unzip age openssl"

if confirm "Install system packages via ${PM} (${PACKAGES})?"; then
  case "$PM" in
    apt) sudo apt-get update -y && sudo apt-get install -y $PACKAGES ;;
    dnf) sudo dnf install -y $PACKAGES ;;
    yum) sudo yum install -y $PACKAGES ;;
    brew) brew install $PACKAGES ;;
  esac
  ok "System packages ready."
else
  warn "Skipping system packages (some tools may be missing)."
fi

# Terraform
if have terraform; then
  TF_VER="$(terraform version | head -n1 | grep -oP 'v\K[0-9.]+' || true)"
  if terraform_ok "${TF_VER:-0}"; then
    ok "Terraform ${TF_VER} already installed (>= ${TERRAFORM_MIN}) — skipping."
  else
    warn "Terraform ${TF_VER:-?} too old (< ${TERRAFORM_MIN}) — reinstalling."
    sudo rm -f "$(command -v terraform)" || true
  fi
fi
if ! have terraform; then
  if confirm "Install Terraform ${TERRAFORM_VERSION}?"; then
    [ "$USE_LATEST" = true ] && { _rel="$(github_latest hashicorp/terraform || true)"; [ -n "$_rel" ] && TERRAFORM_VERSION="${_rel#v}"; }
    info "Downloading Terraform ${TERRAFORM_VERSION}..."
    curl -fL -o /tmp/tf.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_$(os_token)_$(arch).zip"
    sudo unzip -o /tmp/tf.zip -d "${BIN_DIR}/"
    rm -f /tmp/tf.zip
    ok "Terraform installed: $(terraform version | head -n1)"
  else
    warn "Skipping Terraform install."
  fi
fi

# govc
if ! have govc; then
  if confirm "Install govc ${GOVC_VERSION}?"; then
    [ "$USE_LATEST" = true ] && { _rel="$(github_latest vmware/govmomi || true)"; [ -n "$_rel" ] && GOVC_VERSION="${_rel#v}"; }
    info "Downloading govc v${GOVC_VERSION}..."
    curl -fL -o /tmp/govc.tar.gz \
      "https://github.com/vmware/govmomi/releases/download/v${GOVC_VERSION}/govc_$(case "$OS" in Darwin) echo Darwin;; *) echo Linux;; esac)_$(tarball_arch).tar.gz"
    sudo tar -C "${BIN_DIR}" -xzf /tmp/govc.tar.gz govc
    rm -f /tmp/govc.tar.gz
    ok "govc installed: $(govc version)"
  else
    warn "Skipping govc install."
  fi
else
  ok "govc already installed: $(govc version)"
fi

# sops
if ! have sops; then
  if confirm "Install SOPS ${SOPS_VERSION}?"; then
    [ "$USE_LATEST" = true ] && { _rel="$(github_latest getsops/sops || true)"; [ -n "$_rel" ] && SOPS_VERSION="${_rel#v}"; }
    info "Downloading SOPS v${SOPS_VERSION}..."
    curl -fL -o /tmp/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.$(os_token).$(arch)"
    chmod +x /tmp/sops && sudo mv /tmp/sops "${BIN_DIR}/sops"
    ok "SOPS installed: $(sops --version | head -n1)"
  else
    warn "Skipping SOPS install."
  fi
else
  ok "SOPS already installed: $(sops --version | head -n1)"
fi

# ─── 4. keys ────────────────────────────────────────────────────────────────
if [ "$GEN_KEYS" = true ] && [ -z "${SOPS_AGE_KEY_FILE:-}" ] && [ ! -f "$AGE_KEY" ]; then
  if confirm "Generate an age key for SOPS (${AGE_KEY})?"; then
    mkdir -p "$(dirname "$AGE_KEY")"
    age-keygen -o "$AGE_KEY"
    chmod 600 "$AGE_KEY"
    ok "age key created: ${AGE_KEY}"
    echo "    public key: $(age-keygen -y "$AGE_KEY")"
  else
    warn "Skipping age key — SOPS decrypt will fail until one exists."
  fi
elif [ -f "$AGE_KEY" ]; then
  ok "age key already present: ${AGE_KEY}"
fi

if [ "$GEN_KEYS" = true ] && [ -z "$SSH_PUB" ]; then
  if confirm "Generate an SSH key (login to deployed VMs)?"; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -q
    ok "SSH key created: ${HOME}/.ssh/id_ed25519"
  else
    warn "Skipping SSH key."
  fi
elif [ -n "$SSH_PUB" ]; then
  ok "SSH key already present: ${SSH_PUB}"
fi

# ─── 5. terraform init ──────────────────────────────────────────────────────
if [ "$RUN_INIT" = true ] && [ -d "terraform" ] && have terraform && [ ! -d "terraform/.terraform" ]; then
  if confirm "Run 'terraform init' in ./terraform?"; then
    info "terraform init..."
    terraform -chdir=terraform init
    ok "terraform init done."
  else
    warn "Skipping terraform init."
  fi
elif [ "$TERRAFORM_INIT_DONE" = true ]; then
  ok "terraform init already done."
fi

# ─── 6. summary + next steps ────────────────────────────────────────────────
deps_summary() {
  info "Dependency check:"
  for cmd in terraform govc sops age jq python3 git; do
    if have "$cmd"; then ok "$cmd → $($cmd --version 2>&1 | head -n1)"; else warn "$cmd → MISSING"; fi
  done
}

deps_summary
echo ""
ok "Setup complete."

if [ "$DEPS_ONLY" = false ]; then
  next_steps
fi

# explicit --webui: deploy the web console now (idempotent; interactive runs
# were already offered inside guided_chain).
if [ "$DEPS_ONLY" = false ] && [ "$DEPLOY_WEBUI" = true ]; then
  if ! webui_deploy; then warn "Web UI not deployed — see message above."; fi
fi
