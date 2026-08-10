#!/usr/bin/env bash
###############################################################################
# install.sh — One-line VMPilot installer (works on Linux + macOS)
###############################################################################
# PURPOSE
#   Bootstrap the whole project from a fresh machine using a single URL:
#
#     curl -fsSL https://raw.githubusercontent.com/engr-rakib/VMPilot/main/install.sh | bash
#
#   It detects the OS, installs base tools (git/curl/unzip), clones the
#   repository, runs the project's own dependency installer (setup-deps.sh),
#   and prints the next steps to onboard your vCenter.
#
# ENV OVERRIDES
#   VMPILOT_REPO   git URL to clone (default: public GitHub repo)
#   VMPILOT_BRANCH branch to clone   (default: main)
#   VMPILOT_DIR    target directory  (default: ~/VMPilot)
#
# IDEMPOTENT — safe to re-run; existing clone is pulled, missing tools installed.
###############################################################################
set -euo pipefail

VMPILOT_REPO="${VMPILOT_REPO:-https://github.com/engr-rakib/VMPilot.git}"
VMPILOT_BRANCH="${VMPILOT_BRANCH:-main}"
VMPILOT_DIR="${VMPILOT_DIR:-${HOME}/VMPilot}"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'; c_bold=$'\e[1m'; c_rst=$'\e[0m'
info()  { printf '%s::%s %s\n' "$c_cyn" "$c_rst" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$c_yel" "$c_rst" "$*"; }
err()   { printf '%s✗%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()   { err "$1"; exit 1; }
ok()    { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
have()  { command -v "$1" >/dev/null 2>&1; }

echo ""
cat <<LOGO
${c_bold}══════════════════════════════════════════════════════${c_rst}
${c_bold}   VMPilot — one-line installer${c_rst}
${c_bold}══════════════════════════════════════════════════════${c_rst}
LOGO

# ─── 0. bash + OS detection ───────────────────────────────────────────────
[ "${BASH_VERSINFO:-0}" -ge 4 ] || die "bash 4+ is required."
OS="$(uname -s)"
case "$OS" in
  Linux)  PM=""; [ -x /usr/bin/apt-get ] && PM=apt; [ -x /usr/bin/dnf ] && PM=dnf; [ -x /usr/bin/yum ] && PM=yum ;;
  Darwin) PM=brew ;;
  *) die "Unsupported OS '$OS'. Use Linux or macOS (or Windows via WSL)." ;;
esac
info "OS: $OS  |  package manager: ${PM:-auto}"

# ─── 1. base tools ────────────────────────────────────────────────────────
BASE_TOOLS=""
for t in git curl unzip; do have "$t" || BASE_TOOLS+=" $t"; done
if [ -n "$BASE_TOOLS" ]; then
  info "Installing base tools:${BASE_TOOLS} ..."
  case "$PM" in
    apt) sudo apt-get update -y && sudo apt-get install -y git curl unzip ;;
    dnf) sudo dnf install -y git curl unzip ;;
    yum) sudo yum install -y git curl unzip ;;
    brew) have brew || die "Install Homebrew first: https://brew.sh"; brew install git curl unzip ;;
  esac
  ok "Base tools ready."
fi

# ─── 2. get the project ───────────────────────────────────────────────────
if [ -f "scripts/setup-deps.sh" ] && [ -d ".git" ]; then
  VMPILOT_DIR="$(pwd)"
  info "Already inside a VMPilot checkout — using: ${VMPILOT_DIR}"
elif [ -d "${VMPILOT_DIR}/.git" ] && [ -f "${VMPILOT_DIR}/scripts/setup-deps.sh" ]; then
  info "Existing VMPilot clone found — pulling latest..."
  git -C "${VMPILOT_DIR}" pull --ff-only origin "${VMPILOT_BRANCH}"
else
  info "Cloning ${VMPILOT_REPO} (branch ${VMPILOT_BRANCH}) → ${VMPILOT_DIR} ..."
  mkdir -p "$(dirname "${VMPILOT_DIR}")"
  git clone --depth 1 --branch "${VMPILOT_BRANCH}" "${VMPILOT_REPO}" "${VMPILOT_DIR}"
fi
cd "${VMPILOT_DIR}"
ok "Project at: ${VMPILOT_DIR}"

# ─── 3. dependencies (terraform, govc, sops, age, ssh key, terraform init) ─
info "Installing project dependencies (terraform / govc / sops / age) ..."
bash scripts/setup-deps.sh --yes

# ─── 4. next steps ────────────────────────────────────────────────────────
echo ""
cat <<EOF
${c_bold}══════════════════════════════════════════════════════${c_rst}
${c_bold}   VMPilot installed. Next steps${c_rst}
${c_bold}══════════════════════════════════════════════════════${c_rst}

  Your own age key was generated for SOPS encryption — no .sops.yaml edits
  needed (creation rules are path-based; encryption uses your key).

  1. Onboard YOUR vCenter (one interactive wizard — the only config you need):
     ${c_bold}cd ${VMPILOT_DIR}
     bash scripts/vcenter-setup.sh${c_rst}
       → "Create NEW vCenter" → server + inventory → press ${c_bold}y${c_rst}
       (the committed dc_example_192.0.2.10 is a dummy example — pick "Create NEW")

  2. Create a VM config (auto-stored in deploy/<vcenter>/<env>/):
     ${c_bold}bash scripts/create-vm-config.sh <vcenter> <env> <vm-name>${c_rst}

  3. Deploy it (decrypts creds, merges env override, applies):
     ${c_bold}bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>${c_rst}

  Help / docs: README.md · docs/multi-vcenter.md · secure/README.md
EOF
ok "Done."
