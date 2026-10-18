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

# ─── Pipeline markers (MACHINE contract — WebUI parses these) ────────────
# Format:  :: STEP <script>:<phase> <start|done|fail|skip> [detail] ts=<epoch>
# Rules: keep the literal ":: STEP " prefix + single spaces; <phase> kebab-case;
# detail has no newlines; ts= is ALWAYS last (epoch seconds → per-step durations).
# JobThread.stepsFromOutput() + Dashboard strip parse the SUBSTRING (ANSI-safe,
# no ^ anchor). Human-readable AND machine-readable.
pstep() { # $1=script $2=phase $3=status [$4=detail]
  local _ts
  _ts=$(date +%s)
  echo -e "${CYAN}${BOLD}::${NC} STEP $1:$2 $3${4:+ $4} ts=${_ts}"
  # Per-VM pipeline log (set PIPELINE_LOG=<file> by the caller): every marker
  # of every run APPENDS here — full lifecycle history per VM, CLI-readable.
  # Plain format (no ANSI), same contract otherwise.
  # When the whole run is being teed into this same file (pipeline_tee_on), the
  # line above already lands there — appending again would double every marker.
  if [ -n "${PIPELINE_LOG:-}" ] && [ "${PIPELINE_TEE:-false}" != true ]; then
    echo ":: STEP $1:$2 $3${4:+ $4} ts=${_ts}" >> "$PIPELINE_LOG" 2>/dev/null || true
  fi
}
# Send the ENTIRE run output (not just markers) into the pipeline log.
# The WebUI imports a CLI run's log slice as its job output, so with markers
# only the Execution-logs tab of a terminal-la run was empty. Teeing makes the
# shared log the full picture; pstep then skips its own append (see above).
pipeline_tee_on() {
  [ -n "${PIPELINE_LOG:-}" ] || return 0
  [ "${PIPELINE_TEE:-false}" = true ] && return 0
  PIPELINE_TEE=true
  export PIPELINE_TEE
  exec > >(tee -a "$PIPELINE_LOG") 2>&1
}
# Per-VM pipeline log LOCATION (2026-10-14, single source — all callers use
# this): runtime history lives under .cache/pipelines/<vc>/<env>/, NOT next to
# the tfvars (config dirs stay clean + git-quiet; .cache/ is gitignored).
# One-time migration: an old ENV_DIR file moves over on first use (history kept).
# Sets PIPELINE_LOG. Call AFTER ROOT_DIR + VC/ENV/VM are final.
pipeline_log_for() { # $1=vc $2=env $3=vm-name [$4=old-env-dir]
  local _dir="${ROOT_DIR:-.}/.cache/pipelines/$1/$2" _old="${4:-}/.pipeline-$3.log"
  mkdir -p "$_dir" 2>/dev/null || true
  chmod 777 "$_dir" 2>/dev/null || true
  PIPELINE_LOG="${_dir}/.pipeline-$3.log"
  if [ -n "$_old" ] && [ ! -f "$PIPELINE_LOG" ] && [ -f "$_old" ]; then
    mv -f "$_old" "$PIPELINE_LOG" 2>/dev/null || true
  fi
  chmod 666 "$PIPELINE_LOG" 2>/dev/null || true
}
# Per-env runtime STATE dir (2026-10-14, single source): markers, IP memory
# and locks live under .cache/state/<vc>/<env>/ — NOT next to the tfvars
# (config dirs hold inventory only; .cache/ is gitignored). Sets STATE_DIR.
# One-time migration: legacy ENV_DIR dotfiles move over on first use.
# Call AFTER ROOT_DIR + VC/ENV are final, BEFORE any marker/lock/IP access.
state_dir_for() { # $1=vc $2=env [$3=old-env-dir]
  local _f
  STATE_DIR="${ROOT_DIR:-.}/.cache/state/$1/$2"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  chmod 777 "$STATE_DIR" 2>/dev/null || true
  if [ -n "${3:-}" ] && [ -d "$3" ]; then
    for _f in "$3"/.hardening-*.failed "$3"/.last-ip-*; do
      [ -f "$_f" ] || continue
      [ -f "${STATE_DIR}/$(basename "$_f")" ] || mv -f "$_f" "$STATE_DIR/" 2>/dev/null || true
    done
    rm -f "$3/.ipam.lock" 2>/dev/null || true   # lock state never migrates
  fi
}
# Start (or continue) the per-VM pipeline log: run header line. Call once per
# invocation AFTER pipeline_log_for().
pipeline_log_header() { # $1=script-name (rest of $0/$* auto)
  [ -n "${PIPELINE_LOG:-}" ] || return 0
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) $1 ===" >> "$PIPELINE_LOG" 2>/dev/null || true
  # Shared-runner writable: CLI (root) and server jobs (uid 1000) append alike.
  chmod 666 "$PIPELINE_LOG" 2>/dev/null || true
}

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
  local input="${1^^}" num mult=1024
  case "$input" in *MB|*M) mult=1 ;; esac
  num="$(grep -oE '^[0-9]+' <<< "$input" || true)"
  [ -n "$num" ] || num=0
  echo "$(( num * mult ))"
}

to_gb() {
  local input="${1^^}" num
  case "$input" in
    *GB|*G) num="$(grep -oE '^[0-9]+' <<< "$input" || true)" ;;
    *MB|*M) num="$(grep -oE '^[0-9]+' <<< "$input" || true)"; [ -n "$num" ] || num=0; echo "$(( (num + 512) / 1024 ))"; return ;;
    *) num="$(grep -oE '^[0-9]+' <<< "$input" || true)" ;;
  esac
  [ -n "$num" ] || num=0
  echo "$num"
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

# ─── IP validation ───────────────────────────────────────────────────────
valid_ipv4() { # $1 → exit 0 iff strict dotted-quad, every octet 0–255
  local a b c d
  [[ "${1:-}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
  [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}
