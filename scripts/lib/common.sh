#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
# lib/common.sh — shared functions for scripts in this project
# Source with: source "$(dirname "$0")/lib/common.sh"

# ─── Colors ──────────────────────────────────────────────────────────────
BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()     { echo -e "${CYAN}${BOLD}::${NC} $*"; }
ok()       { echo -e "${GREEN}✓${NC} $*"; }
ok_inline(){ echo -e "\033[1A\033[2K${GREEN}✓${NC} $*"; }
warn()     { echo -e "${YELLOW}⚠${NC} $*"; }
err()      { echo -e "${RED}✗${NC} $*" >&2; }
die()      { err "$1"; exit 1; }
error()    { err "$@"; }   # alias for err() — used by deploy scripts

# ─── Author banner ────────────────────────────────────────────────────────
# Printed on every script run so the project's origin is always visible.
vmpilot_banner() {
  echo -e "${CYAN}================================================================================${NC}"
  echo -e "${CYAN}${BOLD}  VMPilot${NC}  -  VMware vSphere Automation"
  echo -e "${GREEN}${BOLD}  (c) 2026 Rakibuzzaman (Engr. Rakib)${NC}  -  Original author"
  echo -e "  GitHub: https://github.com/engr-rakib   |   Web: https://engr-rakib.github.io/web"
  echo -e "${CYAN}================================================================================${NC}"
}

# ─── Prompt helpers ──────────────────────────────────────────────────────
prompt_required() {
  local var="$1" label="$2" def="$3"
  local val
  while true; do
    read -rp "$(echo -e "${CYAN}${label}${NC} [${def}]: ")" val
    val="${val:-$def}"
    [ -n "$val" ] && break
    warn "Cannot be empty."
  done
  printf -v "$var" '%s' "$val"
}

prompt_optional() {
  local var="$1" label="$2" def="$3"
  read -rp "$(echo -e "${CYAN}${label}${NC} [${def}]: ")" val
  val="${val:-$def}"
  printf -v "$var" '%s' "$val"
}

confirm() {
  local msg="$1" def="${2:-N}"
  read -rp "$(echo -e "${YELLOW}${msg}${NC} (y/N): ")" yn
  yn="${yn:-$def}"; [[ "$yn" =~ ^[Yy] ]]
}

# Filesystem selection
prompt_fs() {
  local def="${1:-xfs}"
  read -rp "  Filesystem (1-ext4, 2-xfs, 3-btrfs, b=back) [2]: " fs_sel
  fs_sel="${fs_sel:-2}"
  case "${fs_sel,,}" in
    b|back) echo "b" ;;
    1|ext4)   echo "ext4" ;;
    2|xfs)    echo "xfs"  ;;
    3|btrfs)  echo "btrfs" ;;
    *)        echo "$def" ;;
  esac
}

# ─── Size helpers ────────────────────────────────────────────────────────
normalize_size() {
  local input="$1"
  input="${input^^}"
  case "$input" in
    *GB) echo "${input%GB}G" ;;
    *G)  echo "$input" ;;
    *MB) local val="${input%MB}"; echo "$(( (val + 1023) / 1024 ))G" ;;
    *M)  local val="${input%M}";  echo "$(( (val + 1023) / 1024 ))G" ;;
    *)   echo "${input}G" ;;
  esac
}

to_mb() {
  local input="$1"
  input="${input^^}"
  case "$input" in
    *GB) local val="${input%GB}"; echo "$(( val * 1024 ))" ;;
    *G)  local val="${input%G}"; echo "$(( val * 1024 ))" ;;
    *MB) echo "${input%MB}" ;;
    *M)  echo "${input%M}" ;;
    *)   echo "$(( input * 1024 ))" ;;  # bare number = GB
  esac
}

to_gb() {
  local input="$1"
  input="${input^^}"
  case "$input" in
    *GB) echo "${input%GB}" ;;
    *G)  echo "${input%G}" ;;
    *MB) local val="${input%MB}"; echo "$(( (val + 512) / 1024 ))" ;;
    *M)  local val="${input%M}";  echo "$(( (val + 512) / 1024 ))" ;;
    *)   echo "$input" ;;
  esac
}

human_size() {
  local input="$1"
  input="${input^^}"
  local mb
  case "$input" in
    *GB) local val="${input%GB}"; mb=$(( val * 1024 )) ;;
    *G)  local val="${input%G}";  mb=$(( val * 1024 )) ;;
    *MB) mb="${input%MB}" ;;
    *M)  mb="${input%M}" ;;
    *)   mb="$input" ;;  # assume raw MB
  esac
  if [ "$mb" -ge 1024 ]; then
    echo "$(( mb / 1024 ))G"
  else
    echo "${mb}M"
  fi
}
