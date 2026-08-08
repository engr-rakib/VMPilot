#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# Script   : next_free_ip.sh
# Path     : /opt/terraform-lab/projects/project01/scripts/next_free_ip.sh
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

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq not installed"}'
  exit 1
fi

INPUT=$(cat < /dev/stdin)
BASE_IP=$(jq -r '.base_ip' <<< "$INPUT")
SKIP_IP=$(jq -r '.skip_ip // ""' <<< "$INPUT")
MAX_ATTEMPTS=${MAX_ATTEMPTS:-20}

# ── Reserved IPs = the ip_address values declared in the per-VM config
# files (deploy/<vcenter>/<env>/vm-*.tfvars, plus legacy deploy/<env>/vm-*.tfvars).
# These are the source of truth (config file = desired/assigned IP). Reading them
# here means we no longer need <persist> .<vm>_ip tracking. A powered-off VM is
# still "reserved" because its IP is in its config file, so ping alone can never
# hand a used IP to a new VM.
RESERVED_FILE_IPS=""
ROOT="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_GLOBS=( "${ROOT}/deploy/*/vm-*.tfvars" "${ROOT}/deploy/*/*/vm-*.tfvars" )
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

for i in $(seq 0 "$MAX_ATTEMPTS"); do
  candidate="$o1.$o2.$o3.$((o4 + i))"
  # Honor a pre-assigned IP (skip_ip / or the VM's own base) — never move a
  # running VM off its configured IP just because it answers ping.
  if [ -n "$SKIP_IP" ] && [ "$candidate" = "$SKIP_IP" ]; then
    echo "{\"free_ip\": \"$candidate\", \"attempted\": \"$i\"}"
    exit 0
  fi
  if echo "$RESERVED_FILE_IPS" | grep -qx "$candidate"; then
    continue
  fi
  if ! ping -c1 -W1 "$candidate" &>/dev/null; then
    echo "{\"free_ip\": \"$candidate\", \"attempted\": \"$i\"}"
    exit 0
  fi
done

echo "{\"error\": \"No free IP found after $MAX_ATTEMPTS attempts from $BASE_IP\"}"
exit 1
