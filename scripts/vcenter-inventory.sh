#!/usr/bin/env bash
# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
set -euo pipefail

# ===========================================================================
# Script   : vcenter-inventory.sh
# Path     : scripts/vcenter-inventory.sh   (relative to project root)
# ---------------------------------------------------------------------------
# Purpose  : The SINGLE dedicated vCenter inventory loader for VMPilot.
#            Cache-first + live govc gap-fill, shared by BOTH the CLI and the
#            Web UI so every consumer sees exactly the same data.
#
#            * CLI (create-vm-config.sh)   → `list` mode feeds the pick menus.
#            * Web UI (catalog/executor)   → `options` mode feeds dropdowns;
#              `live` mode feeds dashboard / monitoring / charts.
#
#            Source of truth: secure/<vcenter>/vcenter.tfvars (cached at
#            vcenter-setup.sh time). govc is used ONLY to fill options the file
#            does not know yet (brand-new node/network/datastore) and for live
#            monitoring data — never as the primary source.
#
# Usage
# ───────────────────────────────────────────────────────────────────────────
#   scripts/vcenter-inventory.sh <vcenter> list <key> [--datacenter=DC] [--json]
#   scripts/vcenter-inventory.sh <vcenter> options [--json]
#   scripts/vcenter-inventory.sh <vcenter> live vms|hosts|datastores|alarms [--json]
#
#   <key> for `list`: dc|cluster|template|datastore|network|resource_pool|host
#
#   Output (stdout): newline-separated names by default; --json emits an array
#   (options/live always emit JSON).
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  sed -n '/^# Usage$/,/^# ===/p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//' | sed '/^$/d' | head -20
  exit "${1:-0}"
}

[ $# -ge 2 ] || { usage 1; }
VCENTER="$1"
MODE="$2"
shift 2

LIST_KEY=""
LIVE_WHAT=""
DC_SCOPE=""
JSON_OUT=false
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUT=true ;;
    --datacenter=*) DC_SCOPE="${1#*=}" ;;
    -h|--help) usage 0 ;;
    *) POS+=("$1") ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# 0. paths + credential env (govc ready only when creds decrypt cleanly)
# ---------------------------------------------------------------------------
INV_FILE="${ROOT_DIR}/secure/${VCENTER}/vcenter.tfvars"
CRED_FILE="${ROOT_DIR}/secure/${VCENTER}/credentials.tfvars"

GOVC_READY=false
if [ -f "$CRED_FILE" ] && command -v govc &>/dev/null; then
  VCREAD="cat"
  command -v sops &>/dev/null && VCREAD="sops --decrypt"
  CRED_CONTENT=$($VCREAD "$CRED_FILE" 2>/dev/null) || CRED_CONTENT=""
  VC_SERVER=$(grep -oP 'vsphere_server\s*=\s*"\K[^"]+' <<<"$CRED_CONTENT" || true)
  VC_USER=$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' <<<"$CRED_CONTENT" || true)
  VC_PASS=$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' <<<"$CRED_CONTENT" || true)
  if [ -n "$VC_SERVER" ] && [ -n "$VC_USER" ] && [ -n "$VC_PASS" ]; then
    export GOVC_URL="$VC_SERVER"
    export GOVC_USERNAME="$VC_USER"
    export GOVC_PASSWORD="$VC_PASS"
    export GOVC_INSECURE=true
    # Never persist govc sessions to disk: the container's ~/.govmomi session
    # cache hits a permission-denied on shared mounts and breaks every govc
    # call. A fresh login per invocation is negligible (results are batched +
    # cached ~11s in .cache/).
    export GOVC_PERSIST_SESSION=false
    export TERM=dumb
    GOVC_READY=true
  fi
fi

# ---------------------------------------------------------------------------
# 1. cache readers — parse secure/<vc>/vcenter.tfvars (same format the CLI and
#    vcenter-setup.sh write). All values land in *_CACHE arrays / maps.
# ---------------------------------------------------------------------------
DC=""; DOMAIN=""; GATEWAY=""; NETMASK=24; BASE_IP=""
declare -a CLUSTERS_CACHE TEMPLATES_CACHE DATASTORES_CACHE NETWORKS_CACHE POOLS_CACHE DNS_CACHE HOSTS_CACHE
declare -A HOST_INFO_CACHE NET_SUBNETS_CACHE NET_HOSTS_CACHE

read_list() { # $1 = array name (indirect), $2 = grep key (plural list form)
  local -n _arr="$1"; _arr=()
  local key="$2" line vals
  line=$(grep -E "^${key}[[:space:]]*=" "$INV_FILE" 2>/dev/null | head -1 || true)
  [ -n "$line" ] || return 0
  # quoted items, one per line, preserving spaces inside a name
  vals=$(grep -oE '"[^"]+"' <<<"$line" | tr -d '"' || true)
  while IFS= read -r v; do [ -n "$v" ] && _arr+=("$v"); done <<<"$vals"
}

read_scalar() { # $1 = var name (indirect), $2 = key
  local -n _v="$1"
  _v=$(grep -E "^${2}[[:space:]]*=" "$INV_FILE" 2>/dev/null | head -1 \
    | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)
}

read_hosts_block() {
  HOSTS_CACHE=(); HOST_INFO_CACHE=()
  [ -f "$INV_FILE" ] || return 0
  grep -qE '^hosts[[:space:]]*=' "$INV_FILE" || return 0
  local line hname hip hds hnet
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    hname=$(grep -oE '^[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/' || true)
    [ -n "$hname" ] || continue
    hip=$(grep -oE 'ip[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
    hds=$(grep -oE 'datastores[[:space:]]*=[[:space:]]*\[[^]]*\]' <<<"$line" | head -1 \
      | sed -E 's/datastores[[:space:]]*=[[:space:]]*//' | tr -d '[]"' || true)
    hnet=$(grep -oE 'networks[[:space:]]*=[[:space:]]*\[[^]]*\]' <<<"$line" | head -1 \
      | sed -E 's/networks[[:space:]]*=[[:space:]]*//' | tr -d '[]"' || true)
    HOSTS_CACHE+=("$hname")
    HOST_INFO_CACHE["$hname"]="ip=$hip;ds=$hds;net=$hnet"
  done < <(sed -n '/^hosts[[:space:]]*=/,/^}/p' "$INV_FILE")
}

read_network_subnets() {
  NET_SUBNETS_CACHE=()
  [ -f "$INV_FILE" ] || return 0
  grep -qE '^network_subnets[[:space:]]*=' "$INV_FILE" || return 0
  local line name gw nm base start end dns
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    name=$(grep -oE '"[^"]+"[[:space:]]*=' <<<"$line" | head -1 | sed -E 's/^"([^"]+)".*/\1/' || true)
    [ -n "$name" ] || continue
    gw=$(grep -oE 'gateway[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
    nm=$(grep -oE 'netmask[[:space:]]*=[[:space:]]*[0-9]+' <<<"$line" | head -1 | grep -oE '[0-9]+' || true)
    base=$(grep -oE 'ipam_base[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
    start=$(grep -oE 'range_start[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
    end=$(grep -oE 'range_end[[:space:]]*=[[:space:]]*"[^"]+"' <<<"$line" | head -1 | sed -E 's/.*"([^"]+)"/\1/' || true)
    dns=$(grep -oE 'dns_servers[[:space:]]*=[[:space:]]*\[[^]]*\]' <<<"$line" | head -1 \
      | sed -E 's/dns_servers[[:space:]]*=//; s/\[([^]]*)\]/\1/; s/[[:space:]]//g; s/","/,/g; s/^"//; s/"$//' || true)
    [ -n "$base" ] || base="$start"
    NET_SUBNETS_CACHE["$name"]="gw=$gw;nm=${nm:-24};base=$base;end=$end;dns=$dns"
  done < <(sed -n '/^network_subnets[[:space:]]*=/,/^}/p' "$INV_FILE")
}

read_network_hosts() {
  NET_HOSTS_CACHE=()
  [ -f "$INV_FILE" ] || return 0
  grep -qE '^network_hosts[[:space:]]*=' "$INV_FILE" || return 0
  local line name node
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    name=$(grep -oE '"[^"]+"[[:space:]]*=' <<<"$line" | head -1 | sed -E 's/^"([^"]+)".*/\1/' || true)
    [ -n "$name" ] || continue
    node=$(grep -oE '=\s*"[^"]+"' <<<"$line" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)
    [ -n "$node" ] && NET_HOSTS_CACHE["$name"]="$node"
  done < <(sed -n '/^network_hosts[[:space:]]*=/,/^}/p' "$INV_FILE")
}

if [ -f "$INV_FILE" ]; then
  read_scalar DC datacenter
  read_scalar DOMAIN domain
  read_scalar GATEWAY gateway
  read_scalar BASE_IP ipam_base_ip
  local_nm=$(grep -E '^netmask[[:space:]]*=' "$INV_FILE" | head -1 | grep -oE '[0-9]+' || true)
  [ -n "$local_nm" ] && NETMASK="$local_nm"
  read_list CLUSTERS_CACHE clusters
  read_list TEMPLATES_CACHE templates
  read_list DATASTORES_CACHE datastores
  read_list NETWORKS_CACHE networks
  read_list POOLS_CACHE resource_pools
  read_list DNS_CACHE dns_servers
  read_hosts_block
  read_network_subnets
  read_network_hosts
fi

# ---------------------------------------------------------------------------
# 2. govc discovery — union with cache. Cached (curated) names come FIRST
#    (single source of truth); live govc only adds what the file lacks.
# ---------------------------------------------------------------------------
# scoped_dc: prefer explicit --datacenter=, else cached datacenter
scoped_dc() { echo "${DC_SCOPE:-$DC}"; }

discover_list() { # $1 = govc find type flag: c|s|n|m|p|h|d
  local t="$1" extra="" out dc
  $GOVC_READY || return 0
  # datacenters live at the root — never scope a `-type d` discovery
  if [ "$t" = "d" ]; then
    unset GOVC_DATACENTER
  else
    dc=$(scoped_dc)
    if [ -n "$dc" ]; then export GOVC_DATACENTER="$dc"; else unset GOVC_DATACENTER; fi
  fi
  [ "$t" = "m" ] && extra="-config.template true"
  out=$(govc find . -type "$t" $extra 2>/dev/null | sed 's|.*/||' || true)
  if [ "$t" = "n" ]; then
    # Distributed-switch uplink bundles are not VM port groups — never offer.
    out=$(printf '%s\n' "$out" | grep -vE 'DVUplinks' || true)
  fi
  if [ "$t" = "d" ]; then
    # govc find . -type d reports the root itself "." — drop it
    out=$(printf '%s\n' "$out" | grep -vE '^\.$' || true)
  fi
  printf '%s\n' "$out" | sort -u | grep -v '^$' || true
}

# union_array <result-name> <array-name> [ <array-name> ... ]
union_array() {
  local -n _res="$1"; _res=()
  local -a _seen=() _all=()
  local i j skip
  shift
  for arr in "$@"; do
    local -n _a="$arr"
    for i in "${_a[@]}"; do
      [ -n "$i" ] || continue
      skip=0
      for j in "${_seen[@]}"; do [ "$j" = "$i" ] && skip=1 && break; done
      [ "$skip" = 1 ] && continue
      _seen+=("$i"); _all+=("$i")
    done
  done
  _res=("${_all[@]}")
}

case "$MODE" in
# ───────────────────────────────────────────────────────────────────────────
# list <key> — one inventory list (CLI pick menus)
# ───────────────────────────────────────────────────────────────────────────
list)
  case "${POS[0]:-}" in
    dc|datacenter) LIST_KEY=dc ;;
    cluster|clusters) LIST_KEY=cluster ;;
    template|templates) LIST_KEY=template ;;
    datastore|datastores) LIST_KEY=datastore ;;
    network|networks) LIST_KEY=network ;;
    resource_pool|resource_pools) LIST_KEY=resource_pool ;;
    host|hosts) LIST_KEY=host ;;
    *) echo "Error: unknown list key '${POS[0]:-}'" >&2; exit 1 ;;
  esac

  declare -a CACHE_ARRAY DISCOVER_ARRAY RESULT
  # datacenter: cached scalar first (if any), then discovered
  if [ "$LIST_KEY" = "dc" ]; then
    CACHE_ARRAY=()
    [ -n "$DC" ] && CACHE_ARRAY=("$DC")
  else
    case "$LIST_KEY" in
      cluster)       CACHE_ARRAY=("${CLUSTERS_CACHE[@]}") ;;
      template)      CACHE_ARRAY=("${TEMPLATES_CACHE[@]}") ;;
      datastore)     CACHE_ARRAY=("${DATASTORES_CACHE[@]}") ;;
      network)       CACHE_ARRAY=("${NETWORKS_CACHE[@]}") ;;
      resource_pool) CACHE_ARRAY=("${POOLS_CACHE[@]}") ;;
      host)          CACHE_ARRAY=("${HOSTS_CACHE[@]}") ;;
    esac
  fi
  case "$LIST_KEY" in
    dc)            DISCOVER_ARRAY=("$(discover_list d)") ;;
    cluster)       mapfile -t DISCOVER_ARRAY < <(discover_list c) ;;
    template)      mapfile -t DISCOVER_ARRAY < <(discover_list m) ;;
    datastore)     mapfile -t DISCOVER_ARRAY < <(discover_list s) ;;
    network)       mapfile -t DISCOVER_ARRAY < <(discover_list n) ;;
    resource_pool) mapfile -t DISCOVER_ARRAY < <(discover_list p) ;;
    host)          mapfile -t DISCOVER_ARRAY < <(discover_list h) ;;
  esac
  union_array RESULT CACHE_ARRAY DISCOVER_ARRAY
  if $JSON_OUT; then
    jq -cn --argjson a "$(printf '%s\n' "${RESULT[@]:-}" | jq -R . | jq -s .)" '$a'
  else
    printf '%s\n' "${RESULT[@]:-}"
  fi
  ;;

# ───────────────────────────────────────────────────────────────────────────
# options — full inventory bundle (Web UI dropdowns, same shape as the old
# catalog.inventoryOptions) — cache-first with gap-fill on empty lists
# ───────────────────────────────────────────────────────────────────────────
options)
  declare -a ITEMS_CLUSTERS ITEMS_TEMPLATES ITEMS_DATASTORES ITEMS_NETWORKS ITEMS_POOLS ITEMS_HOSTS
  declare -a DC_LIST_RAW DC_LIST
  declare -a HOSTS_OBJS NS_OBJS NH_OBJS
  ITEMS_CLUSTERS=("${CLUSTERS_CACHE[@]}")
  ITEMS_TEMPLATES=("${TEMPLATES_CACHE[@]}")
  ITEMS_DATASTORES=("${DATASTORES_CACHE[@]}")
  ITEMS_NETWORKS=("${NETWORKS_CACHE[@]}")
  ITEMS_POOLS=("${POOLS_CACHE[@]}")
  ITEMS_HOSTS=("${HOSTS_CACHE[@]}")
  # gap-fill empty lists from live discovery (never overwrite curated values)
  if $GOVC_READY; then
    [ "${#ITEMS_CLUSTERS[@]}"  -gt 0 ] || mapfile -t ITEMS_CLUSTERS < <(discover_list c)
    [ "${#ITEMS_TEMPLATES[@]}"  -gt 0 ] || mapfile -t ITEMS_TEMPLATES < <(discover_list m)
    [ "${#ITEMS_DATASTORES[@]}" -gt 0 ] || mapfile -t ITEMS_DATASTORES < <(discover_list s)
    [ "${#ITEMS_NETWORKS[@]}"   -gt 0 ] || mapfile -t ITEMS_NETWORKS < <(discover_list n)
    [ "${#ITEMS_POOLS[@]}"      -gt 0 ] || mapfile -t ITEMS_POOLS < <(discover_list p)
    [ "${#ITEMS_HOSTS[@]}"      -gt 0 ] || mapfile -t ITEMS_HOSTS < <(discover_list h)
    [ -n "$DC" ] || mapfile -t DC_LIST_RAW < <(discover_list d)
  fi
  DC_LIST=("${DC:-}")
  if [ -n "${DC_LIST_RAW[0]:-}" ]; then
    DC="${DC_LIST_RAW[0]}"
    DC_LIST=("${DC_LIST_RAW[@]}")
  fi
  # hosts detail (ip/networks/datastores) — cache only (file is the source of
  # truth for node-wise facts; live monitoring has its own `live` mode)
  HOSTS_OBJS=()
  for h in "${ITEMS_HOSTS[@]:-}"; do
    hip="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^ip=/) {sub("^ip=","",$i); print $i}}' <<<"${HOST_INFO_CACHE[$h]:-}")"
    hds="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^ds=/) {sub("^ds=","",$i); print $i}}' <<<"${HOST_INFO_CACHE[$h]:-}")"
    hnet="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^net=/) {sub("^net=","",$i); print $i}}' <<<"${HOST_INFO_CACHE[$h]:-}")"
    # comma-separated lists (multi-word names preserved), split + trim
    _ds_arr=(); IFS=',' read -r -a _ds_arr <<<"$hds"
    _net_arr=(); IFS=',' read -r -a _net_arr <<<"$hnet"
    HOSTS_OBJS+=("$(jq -cn --arg name "$h" --arg ip "$hip" \
      --argjson ds "$(printf '%s\n' "${_ds_arr[@]:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | jq -R . | jq -s .)" \
      --argjson ns "$(printf '%s\n' "${_net_arr[@]:-}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | jq -R . | jq -s .)" \
      '{name:$name, ip:$ip, networks:$ns, datastores:$ds}')")
  done
  # network_subnets → { "<network>": { gateway, netmask, ipam_base, range_end, dns_servers } }
  NS_OBJS=()
  for k in "${!NET_SUBNETS_CACHE[@]}"; do
    v="${NET_SUBNETS_CACHE[$k]}"
    _gw="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^gw=/) {sub("^gw=","",$i); print $i}}' <<<"$v")"
    _nm_raw="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^nm=/) {sub("^nm=","",$i); print $i}}' <<<"$v")"
    _nm="${_nm_raw:-24}"
    _base="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^base=/) {sub("^base=","",$i); print $i}}' <<<"$v")"
    _end="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^end=/) {sub("^end=","",$i); print $i}}' <<<"$v")"
    _dns_raw="$(awk -F';' '{for(i=1;i<=NF;i++) if($i~/^dns=/) {sub("^dns=","",$i); print $i}}' <<<"$v" | tr ',' $'\n' || true)"
    _dns_json="$([ -z "$_dns_raw" ] && echo '[]' || printf '%s\n' "${_dns_raw// /$'\n'}" | grep -v '^$' | jq -R . | jq -s .)"
    NS_OBJS+=("$(jq -cn --arg name "$k" --arg gw "$_gw" --argjson nm "$_nm" --arg base "$_base" \
      --arg rngend "$_end" --argjson dns "$_dns_json" \
      '{name:$name, v:{gateway:$gw, netmask:$nm, ipam_base:$base, range_start:$base, range_end:$rngend, dns_servers:$dns}}')")
  done
  NH_OBJS=()
  for k in "${!NET_HOSTS_CACHE[@]}"; do
    NH_OBJS+=("$(jq -cn --arg name "$k" --arg node "${NET_HOSTS_CACHE[$k]}" '{name:$name, node:$node}')")
  done

  jq -cn \
    --arg datacenter "$DC" \
    --argjson datacenters "$(printf '%s\n' "${DC_LIST[@]:-}" | jq -R . | jq -s .)" \
    --argjson clusters   "$(printf '%s\n' "${ITEMS_CLUSTERS[@]:-}"  | jq -R . | jq -s .)" \
    --argjson templates  "$(printf '%s\n' "${ITEMS_TEMPLATES[@]:-}" | jq -R . | jq -s .)" \
    --argjson datastores "$(printf '%s\n' "${ITEMS_DATASTORES[@]:-}" | jq -R . | jq -s .)" \
    --argjson networks   "$(printf '%s\n' "${ITEMS_NETWORKS[@]:-}" | jq -R . | jq -s .)" \
    --argjson pools      "$(printf '%s\n' "${ITEMS_POOLS[@]:-}" | jq -R . | jq -s .)" \
    --argjson hosts      "$(printf '%s\n' "${HOSTS_OBJS[@]:-}" | jq -R . | jq -s . | jq -c 'map(fromjson?)')" \
    --argjson net_subs   "$(printf '%s\n' "${NS_OBJS[@]:-}" | jq -R . | jq -s . | jq -c 'map(fromjson?)')" \
    --argjson net_hosts  "$(printf '%s\n' "${NH_OBJS[@]:-}" | jq -R . | jq -s . | jq -c 'map(fromjson?)')" \
    --arg domain "$DOMAIN" --arg gateway "$GATEWAY" \
    --argjson netmask "$NETMASK" --argjson dns "$(printf '%s\n' "${DNS_CACHE[@]:-}" | jq -R . | jq -s .)" \
    --arg ipam_base_ip "$BASE_IP" \
    '{datacenter:$datacenter, datacenters:$datacenters,
      clusters:$clusters, templates:$templates, datastores:$datastores,
      networks:$networks, resource_pools:$pools,
      network_subnets:($net_subs | map({(.name): .v}) | add // {}),
      network_hosts:($net_hosts | map({(.name): .node}) | add // {}),
      hosts:$hosts,
      items:{clusters:$clusters, templates:$templates, datastores:$datastores,
             networks:$networks, resource_pools:$pools, hosts:($hosts|map(.name))},
      domain:$domain, gateway:$gateway, netmask:$netmask,
      dns_servers:$dns, ipam_base_ip:$ipam_base_ip}'
  ;;

# ───────────────────────────────────────────────────────────────────────────
# live vms|hosts|datastores — real-time dashboard / monitoring data
# ───────────────────────────────────────────────────────────────────────────
live)
  LIVE_WHAT="${POS[0]:-vms}"
  # Short file cache: all consumers (CLI, executor, monitor) share one fresh
  # dataset ~60s; live queries stay fresh (dashboard 30s poll re-caches) while
  # first page loads hit the boot-warmed cache instead of a ~7s cold govc run.
  LIVE_CACHE="${ROOT_DIR}/.cache/live-${VCENTER}-${LIVE_WHAT}.json"
  if [ -f "$LIVE_CACHE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$LIVE_CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 60 ]; then cat "$LIVE_CACHE"; exit 0; fi
  fi
  if ! $GOVC_READY; then
    echo "{\"ok\":false,\"error\":\"no usable credentials for ${VCENTER}\"}" >&2
    exit 1
  fi
  dc=$(scoped_dc)
  [ -n "$dc" ] && export GOVC_DATACENTER="$dc" || unset GOVC_DATACENTER

  case "$LIVE_WHAT" in
    vms)
      # Single batched govc call (all VM paths at once) — one vCenter RTT
      # instead of one `govc vm.info` round-trip per VM. 16 VMs: ~2.3s → ~0.3s.
      declare -a NAMES VMS_PATHS
      mapfile -t VMS_PATHS < <(govc find . -type m 2>/dev/null | grep -v '^vm$' | sort -u || true)
      if [ "${#VMS_PATHS[@]}" -eq 0 ]; then echo "[]"; break; fi
      NAMES=()
      for _p in "${VMS_PATHS[@]}"; do NAMES+=("$(basename "$_p")"); done
      info=$(govc vm.info -json "${NAMES[@]}" 2>/dev/null || true)
      [ -n "$info" ] && [ "$info" != "{}" ] || { echo "[]"; break; }
      # VM network + disk I/O throughput — one batched metric.sample call (all
      # VMs at once), aggregate (empty-instance) net.usage / disk.usage in KB/s,
      # keyed by MOID. Best-effort: on any failure the map stays empty → 0.
      NETMAP_JSON="{}"
      DISKMAP_JSON="{}"
      SAMPLE_JSON=$(govc metric.sample -json -n 1 "${VMS_PATHS[@]}" net.usage.average disk.usage.average 2>/dev/null || true)
      if [ -n "$SAMPLE_JSON" ] && [ "$SAMPLE_JSON" != "{}" ]; then
        NETMAP_JSON=$(printf '%s' "$SAMPLE_JSON" | jq -c '(.sample | if type == "array" then . else [.] end) | map(. as $e | {moid: ($e.entity.value // ""), v: (((($e.value // []) | map(select(.name == "net.usage.average" and (.instance // "") == ""))) | .[0].value[0]) // 0)}) | map({key: .moid, value: .v}) | from_entries' 2>/dev/null || true)
        DISKMAP_JSON=$(printf '%s' "$SAMPLE_JSON" | jq -c '(.sample | if type == "array" then . else [.] end) | map(. as $e | {moid: ($e.entity.value // ""), v: (((($e.value // []) | map(select(.name == "disk.usage.average" and (.instance // "") == ""))) | .[0].value[0]) // 0)}) | map({key: .moid, value: .v}) | from_entries' 2>/dev/null || true)
      fi
      [ -z "$NETMAP_JSON" ] || [ "$NETMAP_JSON" = "null" ] && NETMAP_JSON="{}"
      [ -z "$DISKMAP_JSON" ] || [ "$DISKMAP_JSON" = "null" ] && DISKMAP_JSON="{}"
      out=$(jq -c --argjson netmap "$NETMAP_JSON" --argjson diskmapper "$DISKMAP_JSON" '[ (.virtualMachines // .VirtualMachines // [])[]? |
        ( ( .name != null ) and ( .name != "" ) ) as $keep |
        .summary as $s |
        ($s.quickStats // {}) as $q |
        select($keep) |
        {name:.name,
         power:(.runtime.powerState // "unknown"),
         cpu:($s.config.numCpu // null),
         memoryMB:($s.config.memorySizeMB // null),
         os:($s.config.guestFullName // null),
         toolsStatus:($s.guest.toolsStatus // null),
         ip:($s.guest.ipAddress // null),
         host:($s.runtime.host // null),
         cpuUsageMHz:($q.overallCpuUsage // 0),
         memUsageMB:($q.guestMemoryUsage // 0),
         memUsedGB:($q.guestMemoryUsage // 0),
         memTotalGB:(($s.config.memorySizeMB // 0)/1024),
         diskUsedGB:((.summary.storage.committed // 0)/1024/1024/1024),
         diskUnsharedGB:((.summary.storage.unshared // 0)/1024/1024/1024),
         netKBps:($netmap[(.self.value // "")] // 0),
         diskKBps:($diskmapper[(.self.value // "")] // 0),
         hostMoid:(.runtime.host.value // null)}
      ]' <<<"$info")
      printf '%s\n' "$out"
      mkdir -p "${ROOT_DIR}/.cache"
      printf '%s\n' "$out" >"$LIVE_CACHE" || true
      ;;
    hosts)
      declare -a H_ROWS H_PATHS hnets
      # govc host.info needs absolute inventory paths, but govc find under a
      # scoped datacenter returns relative ones (./host/cluster/node). Normalize
      # to absolute: when GOVC_DATACENTER is set, prefix with its path.
      H_BASE=""
      if [ -n "${GOVC_DATACENTER:-}" ]; then
        H_BASE="/${GOVC_DATACENTER}"
      fi
      mapfile -t H_PATHS < <(govc find . -type h 2>/dev/null | sed "s|^\.|${H_BASE}|" || true)
      # Host CPU/RAM capacity + usage — ONE batched govc call (all hosts) so the
      # per-host resource monitoring data stays cheap: numCpuCores, cpuMhz,
      # memorySize (bytes), overallCpuUsage (MHz), overallMemoryUsage (MB).
      # Also power/connection state + overall status for host-health monitoring.
      declare -A H_HW=() H_QS=() H_MOID=()
      if [ "${#H_PATHS[@]}" -gt 0 ]; then
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          hname=$(printf '%s' "$line" | cut -d'|' -f1)
          props=$(printf '%s' "$line" | cut -d'|' -f2-)
          H_HW["$hname"]="$props"
          H_MOID["$hname"]="$(printf '%s' "$line" | cut -d'|' -f2)"
        done < <(govc host.info -json "${H_PATHS[@]}" 2>/dev/null \
          | jq -r '(.hostSystems // .HostSystems // .hosts // .Hosts // [])[]? | .name as $n |
            (.self.value // .Self.Value // "") as $moid |
            ([.summary.hardware.numCpuCores, .summary.hardware.cpuMhz,
              .summary.hardware.memorySize] | join("|")) as $hw |
            ([.summary.quickStats.overallCpuUsage,
              .summary.quickStats.overallMemoryUsage] | join("|")) as $qs |
            ([.summary.runtime.powerState, .summary.runtime.connectionState,
              .summary.overallStatus, .summary.runtime.bootTime] | join("|")) as $rt |
            "\($n)|\($moid)|\($hw)|\($qs)|\($rt)"' 2>/dev/null || true)
      fi
      declare -A _dpg_dvs=()
      while IFS= read -r _dpg; do
        [ -n "$_dpg" ] || continue
        _dname=$(basename "$_dpg")
        _dvs=$(govc object.collect -s "$_dpg" config.distributedVirtualSwitch 2>/dev/null || true)
        [ -n "$_dvs" ] || continue
        _dvsname=$(govc object.collect -s "$_dvs" name 2>/dev/null || true)
        _dpg_dvs["$_dname"]="${_dvsname:-$_dvs}"
      done < <(govc find . -type g 2>/dev/null || true)
      # Host IO/network throughput — ONE batched govc metric.sample call (all
      # hosts at once). Aggregate (empty-instance) counters only: net.usage and
      # disk.usage in KB/s. Best-effort — on any failure the values stay 0.
      declare -A H_IO=()
      if [ "${#H_PATHS[@]}" -gt 0 ]; then
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          hname=$(printf '%s' "$line" | cut -d'|' -f1)
          H_IO["$hname"]="$line"
        done < <(govc metric.sample -json -n 1 "${H_PATHS[@]}" net.usage.average disk.usage.average 2>/dev/null \
          | jq -r '.sample[]? | (.entity.value // .Entity.Value // "") as $e |
            ([.value[]? | select((.instance // "") == "") | .name as $n | select($n == "net.usage.average" or $n == "disk.usage.average") | (.value[0] // 0)] | join("|")) as $io |
            select($e != "" and $io != "") | "\($e)|\($io)"' 2>/dev/null || true)
      fi
      # H_IO is keyed by host MOID; the jq stored "moid|net|disk" so strip the
      # leading moid here so the loop can read net/disk directly.
      for _h in "${!H_IO[@]}"; do
        H_IO["$_h"]="$(printf '%s' "${H_IO[$_h]}" | cut -d'|' -f2- )"
      done
      for hp in "${H_PATHS[@]:-}"; do
        hname=$(govc object.collect -s "$hp" name 2>/dev/null || true); [ -n "$hname" ] || hname=$(basename "$hp")
        hips=$(govc object.collect -json -s "$hp" config.network.vnic 2>/dev/null \
          | jq -r '[.[] | select((.spec.ip.ipAddress // "") != "") | .spec.ip.ipAddress] | unique | join(",")' 2>/dev/null || true)
        pgnames=$(govc object.collect -json -s "$hp" config.network.portgroup 2>/dev/null \
          | jq -r '[.[].spec.name] | unique | join(",")' 2>/dev/null || true)
        hostdvs=$(govc object.collect -json -s "$hp" config.network.proxySwitch 2>/dev/null \
          | jq -r '[.[].dvsName] | join(",")' 2>/dev/null || true)
        dpg_list=()
        for _n in "${!_dpg_dvs[@]}"; do
          [[ "$_n" == *"-DVUplinks-"* ]] && continue
          [[ ",$hostdvs," == *",${_dpg_dvs[$_n]},"* ]] && dpg_list+=("$_n")
        done
        hnets=()
        IFS=',' read -r -a hnets <<<"$pgnames"
        for _n in "${dpg_list[@]:-}"; do
          [[ " ${hnets[*]} " == *" $_n "* ]] || hnets+=("$_n")
        done
        # datastores this host can actually reach (live govc — refs → names)
        hds_names=()
        dsrefs=$(govc object.collect -json -s "$hp" datastore 2>/dev/null \
          | jq -r 'if .[0].val._value then .[0].val._value[]? else .[]? end | (.type+":"+.value)' 2>/dev/null || true)
        while IFS= read -r _ref; do
          [ -n "$_ref" ] || continue
          _nm=$(govc object.collect -s "$_ref" name 2>/dev/null || true)
          [ -n "$_nm" ] && hds_names+=("$_nm")
        done <<<"$dsrefs"
        # host CPU/RAM from the batched info (hname → "moid|cores|cpuMhz|memBytes|cpuUsg|memUsg|power|conn|status")
        _hw_qs="${H_HW[$hname]:-}"
        _moid=$(awk -F'|' '{print $1}' <<<"$_hw_qs")
        _cores=$(awk -F'|' '{print $2}' <<<"$_hw_qs")
        _mhz=$(awk -F'|' '{print $3}' <<<"$_hw_qs")
        _memb=$(awk -F'|' '{print $4}' <<<"$_hw_qs")
        _cpusg=$(awk -F'|' '{print $5}' <<<"$_hw_qs")
        _memsg=$(awk -F'|' '{print $6}' <<<"$_hw_qs")
        _pw=$(awk -F'|' '{print $7}' <<<"$_hw_qs")
        _conn=$(awk -F'|' '{print $8}' <<<"$_hw_qs")
        _status=$(awk -F'|' '{print $9}' <<<"$_hw_qs")
        _boot=$(awk -F'|' '{print $10}' <<<"$_hw_qs")
        [ -n "$_cores" ] || _cores=0
        [ -n "$_mhz" ] || _mhz=0
        [ -n "$_memb" ] || _memb=0
        [ -n "$_cpusg" ] || _cpusg=0
        [ -n "$_memsg" ] || _memsg=0
        [ -n "$_pw" ] || _pw="unknown"
        [ -n "$_conn" ] || _conn="unknown"
        [ -n "$_status" ] || _status="unknown"
        # IO throughput (net/disk KB/s) — batched metric.sample, matched via MOID
        _io="${H_IO[$_moid]:-}"
        _netKB=$(awk -F'|' '{print $1}' <<<"$_io")
        _diskKB=$(awk -F'|' '{print $2}' <<<"$_io")
        [ -n "$_netKB" ] || _netKB=0
        [ -n "$_diskKB" ] || _diskKB=0
        H_ROWS+=("$(jq -cn --arg name "$hname" --arg ip "$hips" --arg id "$_moid" \
          --argjson cores "$_cores" --argjson mhz "$_mhz" \
          --argjson memBytes "$_memb" --argjson cpuUsageMHz "$_cpusg" --argjson memUsageMB "$_memsg" \
          --arg powerState "$_pw" --arg connectionState "$_conn" --arg overallStatus "$_status" \
          --arg bootTime "$_boot" \
          --argjson netKBps "$_netKB" --argjson diskKBps "$_diskKB" \
          --argjson ns "$(printf '%s\n' "${hnets[@]:-}" | jq -R . | jq -s .)" \
          --argjson ds "$(printf '%s\n' "${hds_names[@]:-}" | jq -R . | jq -s .)" \
          '{name:$name, ip:$ip, id:$id, networks:$ns, datastores:$ds,
            cpuCores:$cores, cpuMhz:$mhz, memoryMB:($memBytes/1024/1024),
            cpuUsageMHz:$cpuUsageMHz, memUsageMB:$memUsageMB,
            powerState:$powerState, connectionState:$connectionState, overallStatus:$overallStatus,
            bootTime:$bootTime,
            netKBps:$netKBps, diskKBps:$diskKBps}')")
      done
      out=$(printf '[%s]' "$(IFS=,; printf '%s' "${H_ROWS[*]:-}")")
      out="$(printf '%s\n' "$out" | jq -c '.')"
      printf '%s\n' "$out"
      mkdir -p "${ROOT_DIR}/.cache"
      printf '%s\n' "$out" >"$LIVE_CACHE" || true
      ;;
    datastores)
      ds_info=$(govc datastore.info -json 2>/dev/null || true)
      if [ -z "$ds_info" ]; then out="[]"; else
      out=$(jq -c '[ (.datastores // .Datastores // [])[]? | {name:.name,
        capacity:(.summary.capacity // .Summary.Capacity // 0),
        free:(.summary.freeSpace // .Summary.FreeSpace // 0)} ]' <<<"$ds_info")
      fi
      printf '%s\n' "$out"
      mkdir -p "${ROOT_DIR}/.cache"
      printf '%s\n' "$out" >"$LIVE_CACHE" || true
      ;;
    alarms)
      # vCenter-triggered alarms (AlarmManager.triggeredAlarms) — the SAME
      # alarms the vSphere UI shows (host hardware health, memory/CPU
      # exhaustion, datastore usage, ...). Compact each to name/status/time/
      # entity so the WebUI can surface them without re-querying vCenter.
      # For host-scoped alarms the entity MOID is resolved to a name (the
      # deep-link target in Inventory).
      alarm_info=$(govc alarms -json 2>/dev/null || true)
      if [ -z "$alarm_info" ]; then
        out="[]"
      else
        A_ROWS=()
        while IFS= read -r _entry; do
          [ -n "$_entry" ] || continue
          _name=$(jq -r '(.name.name // .name.systemName // .name // "Unknown alarm")' <<<"$_entry")
          _status=$(jq -r '(.overallStatus // "unknown")' <<<"$_entry")
          _time=$(jq -r '(.time // "")' <<<"$_entry")
          _am=$(jq -r '(.alarm.value // "")' <<<"$_entry")
          _em=$(jq -r '(.entity.value // "")' <<<"$_entry")
          _et=$(jq -r '(.entity.type // "")' <<<"$_entry")
          _ep=$(jq -r '(.path // "")' <<<"$_entry")
          _msg=$(jq -r '(.event.fullFormattedMessage // "")' <<<"$_entry")
          [ "$_status" = "green" ] && continue
          _ename=""
          [ "$_et" = "HostSystem" ] || [ "$_et" = "VirtualMachine" ] && _ename=$(govc object.collect -s "${_et}:${_em}" name 2>/dev/null || true)
          A_ROWS+=("$(jq -cn --arg name "$_name" --arg status "$_status" --arg time "$_time" \
            --arg alarmId "$_am" --arg entityMoid "$_em" --arg entityType "$_et" --arg entityPath "$_ep" \
            --arg entityName "$_ename" --arg message "$_msg" \
            '{name:$name, status:$status, time:$time, alarmId:$alarmId, entityMoid:$entityMoid, entityType:$entityType, entityPath:$entityPath, entityName:$entityName, message:$message}')")
        done < <(jq -c '.[]?' <<<"$alarm_info")
        out=$(printf '[%s]' "$(IFS=,; printf '%s' "${A_ROWS[*]:-}")")
        out="$(printf '%s\n' "$out" | jq -c '.')"
      fi
      printf '%s\n' "$out"
      mkdir -p "${ROOT_DIR}/.cache"
      printf '%s\n' "$out" >"$LIVE_CACHE" || true
      ;;
    *)
      echo "{\"ok\":false,\"error\":\"unknown live type '${LIVE_WHAT}'\"}" >&2
      exit 1
      ;;
  esac
  ;;

*)
  echo "Error: unknown mode '${MODE}'" >&2
  usage 1
  ;;
esac
