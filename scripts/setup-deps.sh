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

set -euo pipefail

#############################################################
# setup-deps.sh — One-shot dependency installer for this project
#############################################################
# PURPOSE
#   Installs every tool required to deploy VMs on any fresh Linux
#   host (Ubuntu/Debian via apt, or RHEL/CentOS/Fedora via dnf/yum):
#     - system packages: jq, git, curl, wget, unzip, age, openssl, ...
#     - Terraform binary (>= 1.6)
#     - govc (VMware CLI)
#     - SOPS (encryption)
#   Optionally also:
#     - generates an age key for SOPS (~/.config/sops/age/keys.txt)
#     - generates an SSH key (~/.ssh/id_ed25519)
#     - runs `terraform init` in ./terraform
#
# HOW TO USE
#   bash scripts/setup-deps.sh            # interactive (asks before each step)
#   bash scripts/setup-deps.sh --yes      # non-interactive: install everything
#   bash scripts/setup-deps.sh --no-keys  # skip SSH/age key generation
#   bash scripts/setup-deps.sh --no-init  # skip terraform init
#
#   Override a pinned version per tool:
#     TERRAFORM_VERSION=1.9.8 GOVC_VERSION=0.55.1 SOPS_VERSION=3.13.3 \
#       bash scripts/setup-deps.sh --yes
#
#   Latest version auto-detection (GitHub API) can be enabled with --latest;
#   otherwise pinned, known-good versions below are used.
#
# IDEMPOTENT
#   Already-installed tools that satisfy the minimum version are skipped.
#   Safe to re-run any time.
#############################################################

# ─── pinned defaults (override via env var) ─────────────────────────────
TERRAFORM_MIN="1.6"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.9.8}"
GOVC_VERSION="${GOVC_VERSION:-0.55.1}"
SOPS_VERSION="${SOPS_VERSION:-3.13.3}"

INTERACTIVE=true
GEN_KEYS=true
RUN_INIT=true
USE_LATEST=false

for arg in "$@"; do
  case "$arg" in
    --yes|-y)   INTERACTIVE=false ;;
    --no-keys)  GEN_KEYS=false ;;
    --no-init)  RUN_INIT=false ;;
    --latest)   USE_LATEST=true ;;
    --help|-h)
      echo "Usage: $0 [--yes] [--no-keys] [--no-init] [--latest]"
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# ─── helpers ─────────────────────────────────────────────────────────────
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'; c_bold=$'\e[1m'; c_rst=$'\e[0m'
info()  { printf '%s::%s %s\n' "$c_cyn" "$c_rst" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$c_yel" "$c_rst" "$*"; }
err()   { printf '%s✗%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()   { err "$1"; exit 1; }
ok()    { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }

confirm() { # $1=msg ; default yes in non-interactive
  if [ "$INTERACTIVE" = false ]; then return 0; fi
  local msg="$1" yn
  read -rp "$(printf '%s (y/N): ' "$msg")" yn
  [[ "${yn:-N}" =~ ^[Yy] ]]
}

have()  { command -v "$1" >/dev/null 2>&1; }
arch()  { uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/arm/' -e 's/i686/386/'; }
tarball_arch() { uname -m | sed -e 's/aarch64/aarch64/' -e 's/x86_64/x86_64/'; }

# terraform >= X.Y ?  ($1 = installed version like "1.9.8")
terraform_ok() {
  [ "$#" -eq 1 ] || return 1
  local v="$1" want_major want_minor cur_major cur_minor
  want_major="${TERRAFORM_MIN%%.*}"; want_minor="${TERRAFORM_MIN#*.}"
  cur_major="${v%%.*}"; cur_minor="${v#*.}"; cur_minor="${cur_minor%%.*}"
  [ "${cur_major:-0}" -gt "${want_major}" ] && return 0
  [ "${cur_major:-0}" -eq "${want_major}" ] && [ "${cur_minor:-0}" -ge "${want_minor}" ]
}

# binary download platform tokens (terraform/govc/sops all name files by OS+arch)
# OS_KERNEL → "linux" | "darwin" ; arch() → amd64/arm64 ; tarball_arch → x86_64/aarch64
os_token() { case "$OS_KERNEL" in Darwin) echo darwin;; *) echo linux;; esac; }

github_latest() { # $1=owner/repo ; prints latest release tag (vX.Y.Z)
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -oP '"tag_name"\s*:\s*"\K[^"]+' || true
}

# ─── OS / package manager detection ──────────────────────────────────────
OS_KERNEL="$(uname -s)"
OS_ARCH="$(arch)"
BIN_DIR="/usr/local/bin"
PM=""
case "$OS_KERNEL" in
  Darwin)
    PM="brew"
    have brew || die "macOS requires Homebrew — install from https://brew.sh first."
    BIN_DIR="$(brew --prefix)/bin"
    ;;
  Linux)
    if have apt-get; then PM="apt"
    elif have dnf; then PM="dnf"
    elif have yum; then PM="yum"
    else die "Unsupported distro: need apt-get, dnf or yum."
    fi
    ;;
  *) die "Unsupported OS: $OS_KERNEL (use Linux or macOS)." ;;
esac

# ─── header ──────────────────────────────────────────────────────────────
clear 2>/dev/null || true
cat <<LOGO
══════════════════════════════════════════════════════════
    VMPilot — Dependency Installer
    OS pkg manager : $PM
    Target tools    : jq git curl wget unzip age openssl
                      + terraform (>=$TERRAFORM_MIN) + govc + sops
══════════════════════════════════════════════════════════
LOGO

# ─── 1. system packages ──────────────────────────────────────────────────
PACKAGES="jq git curl wget unzip openssl ca-certificates"
[ "$PM" = "apt" ] && PACKAGES="$PACKAGES age gnupg software-properties-common"
[ "$PM" = "dnf" ] && PACKAGES="$PACKAGES age epel-release"
[ "$PM" = "yum" ] && PACKAGES="$PACKAGES age epel-release"
[ "$PM" = "brew" ] && PACKAGES="jq git curl wget unzip age openssl"

if confirm "Install system packages (${PM}: ${PACKAGES})?"; then
  info "Installing system packages via ${PM}..."
  case "$PM" in
    apt) sudo apt-get update -y && sudo apt-get install -y $PACKAGES ;;
    dnf) sudo dnf install -y $PACKAGES ;;
    yum) sudo yum install -y $PACKAGES ;;
    brew) brew install $PACKAGES ;;
  esac
  ok "System packages installed."
else
  warn "Skipping system packages (some tools may be missing)."
fi

# ─── 2. Terraform ────────────────────────────────────────────────────────
if have terraform; then
  TF_VER="$(terraform version | head -n1 | grep -oP 'v\K[0-9.]+' || true)"
  if terraform_ok "${TF_VER:-0}"; then
    ok "Terraform ${TF_VER} already installed (>= ${TERRAFORM_MIN}) — skipping."
  else
    warn "Terraform ${TF_VER:-?} too old (< ${TERRAFORM_MIN}) — reinstalling."
    have terraform && sudo rm -f "$(command -v terraform)"
    have terraform && true
  fi
fi
if ! have terraform || [ "$(terraform version >/dev/null 2>&1; echo $?)" != "0" ]; then
  if confirm "Install Terraform ${TERRAFORM_VERSION}?"; then
    if [ "$USE_LATEST" = true ]; then
      _rel="$(github_latest hashicorp/terraform || true)"; _rel="${_rel#v}"
      [ -n "$_rel" ] && TERRAFORM_VERSION="$_rel"
    fi
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

# ─── 3. govc ─────────────────────────────────────────────────────────────
if ! have govc; then
  if confirm "Install govc ${GOVC_VERSION}?"; then
    if [ "$USE_LATEST" = true ]; then
      _rel="$(github_latest vmware/govmomi || true)"; _rel="${_rel#v}"
      [ -n "$_rel" ] && GOVC_VERSION="$_rel"
    fi
    info "Downloading govc v${GOVC_VERSION}..."
    curl -fL -o /tmp/govc.tar.gz \
      "https://github.com/vmware/govmomi/releases/download/v${GOVC_VERSION}/govc_$(case "$OS_KERNEL" in Darwin) echo Darwin;; *) echo Linux;; esac)_$(tarball_arch).tar.gz"
    sudo tar -C "${BIN_DIR}" -xzf /tmp/govc.tar.gz govc
    rm -f /tmp/govc.tar.gz
    ok "govc installed: $(govc version)"
  else
    warn "Skipping govc install."
  fi
else
  ok "govc already installed: $(govc version)"
fi

# ─── 4. SOPS ─────────────────────────────────────────────────────────────
if ! have sops; then
  if confirm "Install SOPS ${SOPS_VERSION}?"; then
    if [ "$USE_LATEST" = true ]; then
      _rel="$(github_latest getsops/sops || true)"; _rel="${_rel#v}"
      [ -n "$_rel" ] && SOPS_VERSION="$_rel"
    fi
    info "Downloading SOPS v${SOPS_VERSION}..."
    curl -fL -o /tmp/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.$(os_token).$(arch)"
    chmod +x /tmp/sops
    sudo mv /tmp/sops "${BIN_DIR}/sops"
    ok "SOPS installed: $(sops --version | head -n1)"
  else
    warn "Skipping SOPS install."
  fi
else
  ok "SOPS already installed: $(sops --version | head -n1)"
fi

# ─── 5. age key (SOPS backend) ───────────────────────────────────────────
if [ "$GEN_KEYS" = true ] && [ -z "${SOPS_AGE_KEY_FILE:-}" ]; then
  AGE_KEYS="${HOME}/.config/sops/age/keys.txt"
  if [ ! -f "$AGE_KEYS" ]; then
    if confirm "Generate an age key (SOPS encryption)?"; then
      mkdir -p "$(dirname "$AGE_KEYS")"
      age-keygen -o "$AGE_KEYS"
      chmod 600 "$AGE_KEYS"
      ok "age key created: ${AGE_KEYS}"
      warn "Public key (must match .sops.yaml):"
      echo "    $(age-keygen -y "$AGE_KEYS")"
    else
      warn "Skipping age key — SOPS decrypt will fail until one exists."
    fi
  else
    ok "age key already present: ${AGE_KEYS}"
  fi
fi

# ─── 6. SSH key ──────────────────────────────────────────────────────────
if [ "$GEN_KEYS" = true ]; then
  SSH_KEY="$([ -f "$HOME/.ssh/id_ed25519.pub" ] && echo "$HOME/.ssh/id_ed25519.pub" || true)"
  if [ -z "$SSH_KEY" ]; then
    if confirm "Generate an SSH key (login to deployed VMs)?"; then
      ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -q
      ok "SSH key created: ${HOME}/.ssh/id_ed25519"
      echo "    pub: $(cat "$HOME/.ssh/id_ed25519.pub")"
    else
      warn "Skipping SSH key."
    fi
  else
    ok "SSH key already present: ${SSH_KEY}"
  fi
fi

# ─── 7. terraform init ───────────────────────────────────────────────────
if [ "$RUN_INIT" = true ] && [ -d "terraform" ] && have terraform; then
  if confirm "Run 'terraform init' in ./terraform?"; then
    info "terraform init..."
    terraform -chdir=terraform init
    ok "terraform init done."
  else
    warn "Skipping terraform init."
  fi
fi

# ─── summary ─────────────────────────────────────────────────────────────
echo ""
info "Dependency check:"
for cmd in terraform govc sops age jq python3 git; do
  if have "$cmd"; then
    ok "$cmd → $($cmd --version 2>&1 | head -n1)"
  else
    warn "$cmd → MISSING"
  fi
done
echo ""
ok "Setup complete. Next step: bash scripts/vcenter-setup.sh"
