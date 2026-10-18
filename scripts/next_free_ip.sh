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
vmpilot_banner >&2

set -euo pipefail

# ===========================================================================
# Script   : next_free_ip.sh
# Path     : scripts/next_free_ip.sh   (relative to project root)
# ---------------------------------------------------------------------------
# Purpose  : IPAM helper — pings sequential IPs from a base address upward
#            until it finds one that does NOT respond.  Called by Terraform
#            (external data source) to auto-assign free IPs.
#
# Input    : JSON via stdin  { "base_ip": "198.51.100.10", "skip_ip": "..." }
# Output   : JSON via stdout { "free_ip": "198.51.100.10", "attempted": "0" }
#            or               { "error": "No free IP found after N attempts" }
#
# How it works
# ───────────────────────────────────────────────────────────────────────────
#   1. Reads base_ip from stdin (JSON).
#   2. Pings candidate = base_ip, then base_ip+1, base_ip+2, …
#   3. First IP that does NOT respond is returned as free_ip.
#   4. If skip_ip is set, that IP is immediately accepted (no ping needed)
#      — used to honour the pre-assigned IP stored in the .<vm>_ip file.
#
# How to run (standalone test)
# ───────────────────────────────────────────────────────────────────────────
#   echo '{"base_ip": "198.51.100.10"}' | ./scripts/next_free_ip.sh
#   echo '{"base_ip": "198.51.100.10", "skip_ip": "198.51.100.15"}' \
#     | MAX_ATTEMPTS=5 ./scripts/next_free_ip.sh
#
# Env vars
# ───────────────────────────────────────────────────────────────────────────
#   MAX_ATTEMPTS  — max IPs to try  (default: 20)
#   RESERVE       — reserved low host-count (gateway + RESERVE IPs below this
#                   are never handed out; special uses). Default 30.
#
# Notes
# ───────────────────────────────────────────────────────────────────────────
#   stdin is read ONCE into $INPUT and reused for both jq calls — otherwise
#   the first jq consumes the whole pipe and skip_ip is always empty.
#
# Dependencies
# ───────────────────────────────────────────────────────────────────────────
#   - jq       (JSON parsing)
#   - ping     (ICMP reachability check)
# ===========================================================================

# Fail loudly: stdout keeps the JSON contract terraform expects, and the SAME
# reason is echoed to stderr. Terraform's external data source shows ONLY stderr
# in its "Error Message:" block and silently discards stdout — without this the
# operator sees the banner plus "terraform exited 1" and no reason at all.
fail() {
  # The message can embed operator config (BASE_IP) — a raw `"` would break
  # the stdout JSON contract terraform parses, so sanitize quotes first.
  local _m
  _m=$(printf '%s' "$1" | tr '"' "'")
  echo "{\"error\": \"$_m\"}"
  echo ":: IPAM ERROR: $1" >&2
  exit 1
}

if ! command -v jq &>/dev/null; then
  fail "jq not installed"
fi

INPUT=$(cat)
BASE_IP=$(jq -r '.base_ip' <<< "$INPUT")
SKIP_IP=$(jq -r '.skip_ip // ""' <<< "$INPUT")
RANGE_END=$(jq -r '.range_end // ""' <<< "$INPUT")
MAX_ATTEMPTS=${MAX_ATTEMPTS:-20}
RESERVE=${RESERVE:-30}
[ "$RESERVE" -ge 0 ] 2>/dev/null || RESERVE=30

# Strict base validation — never scan from garbage (octet >255, bad prefix
# math and .256 candidates all start here). Standalone contract: JSON error.
if ! [[ "$BASE_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
  || [ "${BASH_REMATCH[1]}" -gt 255 ] || [ "${BASH_REMATCH[2]}" -gt 255 ] \
  || [ "${BASH_REMATCH[3]}" -gt 255 ] || [ "${BASH_REMATCH[4]}" -gt 255 ]; then
  fail "invalid base_ip: $BASE_IP (need dotted-quad, octets 0-255)"
fi

# If range_end given, scan no further than the last IP of the block and never
# cross the block boundary (e.g. .200 for a /24 deploy range).
BLOCK_LAST=""
if [ -n "$RANGE_END" ] && [[ "$RANGE_END" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  BLOCK_LAST="$RANGE_END"
fi
MAX_ATTEMPTS=$(if [ -n "$BLOCK_LAST" ]; then
  IFS='.' read -r _a _b _c _d <<< "$BASE_IP"
  IFS='.' read -r _e _f _g _h <<< "$BLOCK_LAST"
  n=$(( (_h - _d) + 1 )); [ "$n" -gt 0 ] && echo "$n" || echo "$MAX_ATTEMPTS"
else echo "$MAX_ATTEMPTS"; fi)

# ── Reserved IPs = the ip_address values declared in the per-VM config
# files (deploy/<server>/<vcenter>/<env>/vm-*.tfvars, plus legacy deploy/<env>/vm-*.tfvars).
# These are the source of truth (config file = desired/assigned IP). Reading them
# here means we no longer need <persist> .<vm>_ip tracking. A powered-off VM is
# still "reserved" because its IP is in its config file, so ping alone can never
# hand a used IP to a new VM.
RESERVED_FILE_IPS=""
ROOT="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_GLOBS=( "${ROOT}/deploy/*/vm-*.tfvars" "${ROOT}/deploy/*/*/vm-*.tfvars" "${ROOT}/deploy/*/*/*/vm-*.tfvars" )
shopt -s nullglob
for CONFIG_GLOB in "${CONFIG_GLOBS[@]}"; do
  for f in $CONFIG_GLOB; do
    [ -f "$f" ] || continue
    # every ip_address inside vm_configs (2-space-indented entry keys)
    for ip in $(grep -oE 'ip_address[[:space:]]*=[[:space:]]*"[0-9.]+"' "$f" | grep -oE '[0-9.]+'); do
      [ -n "$ip" ] && RESERVED_FILE_IPS+="$ip
"
    done
  done
done
shopt -u nullglob
RESERVED_FILE_IPS="$(printf '%s' "$RESERVED_FILE_IPS" | sort -u)"

IFS='.' read -r o1 o2 o3 o4 <<< "$BASE_IP"

# Candidate list first (fast local checks), then ping ALL of them in PARALLEL
# and take the lowest non-responder — 20 sequential pings (~20s worst case)
# become one ~1s wave. Order preserved: lowest free IP still wins.
_CANDS=""
for i in $(seq 0 "$MAX_ATTEMPTS"); do
  # No cross-octet carry — .255 is the last handout in this /24; going past
  # it would emit .256 (invalid) or leak into the next subnet. Stop loudly.
  if [ $((o4 + i)) -gt 255 ]; then
    fail "range exhausted at $o1.$o2.$o3.255 (no cross-subnet carry)"
  fi
  candidate="$o1.$o2.$o3.$((o4 + i))"
  # never hand out an IP in the reserved low range (gateway + RESERVE hosts) —
  # those are for routers/switches/DNS/vCenter/special uses, not VMs. Assumes
  # gateway = subnet.1 (the standard layout).
  cand_last=$((o4 + i))
  if [ "$cand_last" -le "$RESERVE" ]; then
    continue
  fi
  # never hand out an IP past the block's last address (range_end boundary)
  if [ -n "$BLOCK_LAST" ]; then
    IFS='.' read -r _l1 _l2 _l3 _l4 <<< "$BLOCK_LAST"
    if [ "$o1.$o2.$o3" = "$_l1.$_l2.$_l3" ] && [ $((o4 + i)) -gt "$_l4" ]; then
      fail "No free IP found in range $BASE_IP..$BLOCK_LAST"
    fi
  fi
  # Honor a pre-assigned IP (skip_ip / or the VM's own base) — never move a
  # running VM off its configured IP just because it answers ping.
  if [ -n "$SKIP_IP" ] && [ "$candidate" = "$SKIP_IP" ]; then
    echo ":: STEP ipam:scan done ${candidate} ts=$(date +%s)" >&2
    echo "{\"free_ip\": \"$candidate\", \"attempted\": \"$i\"}"
    exit 0
  fi
  if echo "$RESERVED_FILE_IPS" | grep -qx "$candidate"; then
    continue
  fi
  _CANDS="${_CANDS} ${candidate}"
done
_PINGDIR="$(mktemp -d /tmp/vmpilot-ipam-XXXXXX)"
_CAND_COUNT=0
for _c in $_CANDS; do
  _CAND_COUNT=$(( _CAND_COUNT + 1 ))
  # one file PER candidate (deterministic) — $RANDOM-$$ collides between
  # background subshells and can drop a result, which then reads as "all used"
  ( ping -c1 -W2 "$_c" >/dev/null 2>&1 && echo "USED $_c" || echo "FREE $_c" ) > "$_PINGDIR/$_c" 2>/dev/null &
done
wait
if [ "$_CAND_COUNT" -eq 0 ]; then
  rm -rf "$_PINGDIR"
  fail "no candidate IPs to scan from $BASE_IP (all <= RESERVE=$RESERVE or already reserved in config files)"
fi
for _c in $_CANDS; do
  if grep -qxF "FREE $_c" "$_PINGDIR"/* 2>/dev/null; then
    rm -rf "$_PINGDIR"
    # STEP marker goes to STDERR: stdout is the JSON contract (terraform
    # external data source parses it) — stderr is safe for humans + job logs.
    echo ":: STEP ipam:scan done ${_c} ts=$(date +%s)" >&2
    echo "{\"free_ip\": \"$_c\", \"attempted\": \"0\"}"
    exit 0
  fi
done
rm -rf "$_PINGDIR"

echo ":: STEP ipam:scan fail \"none-free\" ts=$(date +%s)" >&2
fail "No free IP found after $MAX_ATTEMPTS attempts from $BASE_IP (${_CAND_COUNT:-0} candidates pinged, all answered)"
