#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════╗
# ║              GENERAL BACKUP & RESTORE SCRIPT                        ║
# ╠══════════════════════════════════════════════════════════════════════╣
# ║                                                                      ║
# ║  bash backup.sh                        → interactive (asks paths)   ║
# ║  bash backup.sh /project /backup       → direct (no prompts)        ║
# ║                                                                      ║
# ║  First run saves paths to ~/.backup-config; later runs reuse them.  ║
# ║                                                                      ║
# ║  Menu: 1=Backup  2=List  3=Restore  4=Exit                         ║
# ╚══════════════════════════════════════════════════════════════════════╝

BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}${BOLD}::${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

CONFIG="${HOME}/.backup-config"

PROJECT_DIR=""
BACKUP_DIR=""

# ─── Config ─────────────────────────────────────────────────────────────
save_config() {
  cat > "$CONFIG" <<-EOF
PROJECT_DIR="${PROJECT_DIR}"
BACKUP_DIR="${BACKUP_DIR}"
EOF
  ok "Saved config: ${CONFIG}"
}

load_config() {
  [ -f "$CONFIG" ] && { source "$CONFIG"; return 0; }
  return 1
}

# ─── Resolve paths ─────────────────────────────────────────────────────
[ $# -ge 2 ] && { PROJECT_DIR="$1"; BACKUP_DIR="$2"; shift 2; }

resolve_paths() {
  load_config && info "Loaded config: ${CONFIG}" && return
  while [ -z "$PROJECT_DIR" ]; do
    read -rp "$(echo -e "${CYAN}Project directory${NC}: ")" p
    [ -n "$p" ] && PROJECT_DIR="$(realpath "$p" 2>/dev/null || echo "$p")"
  done
  while [ -z "$BACKUP_DIR" ]; do
    read -rp "$(echo -e "${CYAN}Backup directory${NC}: ")" b
    [ -n "$b" ] && BACKUP_DIR="$b"
  done
  save_config
}

[ -z "$PROJECT_DIR" ] || [ -z "$BACKUP_DIR" ] && resolve_paths
[ ! -d "$PROJECT_DIR" ] && { err "Project not found: $PROJECT_DIR"; exit 1; }
mkdir -p "$BACKUP_DIR"

PROJECT_NAME="$(basename "$PROJECT_DIR")"

# ─── Backup ─────────────────────────────────────────────────────────────
do_backup() {
  local ts=$(date +"%Y%m%d-%H%M%S")
  local file="${BACKUP_DIR}/${PROJECT_NAME}-backup-${ts}.tar.gz"
  info "Backup: ${file}"
  tar -czf "$file" \
    --exclude=.git --exclude=.terraform --exclude=.terraform.lock.hcl \
    --exclude='*.tar.gz' --exclude='*.zip' --exclude=node_modules \
    --exclude=__pycache__ --exclude=.DS_Store \
    -C "$(dirname "$PROJECT_DIR")" "$(basename "$PROJECT_DIR")"
  ok "Done: $(basename "$file") ($(du -h "$file" | cut -f1))"
  # Rotation: keep max 5
  while [ $(ls -t "${BACKUP_DIR}/${PROJECT_NAME}-backup-"*.tar.gz 2>/dev/null | wc -l) -gt 5 ]; do
    local old=$(ls -t "${BACKUP_DIR}/${PROJECT_NAME}-backup-"*.tar.gz 2>/dev/null | tail -1)
    rm -f "$old"
    ok "Removed old: $(basename "$old")"
  done
}

# ─── List ────────────────────────────────────────────────────────────────
list_backups() {
  local backups=($(ls -t "${BACKUP_DIR}/${PROJECT_NAME}-backup-"*.tar.gz 2>/dev/null || true))
  [ ${#backups[@]} -eq 0 ] && { warn "No backups in ${BACKUP_DIR}"; return; }
  echo ""
  printf "  %-5s %-19s %-10s %s\n" "ID" "Date" "Size" "Filename"
  echo "  $(printf '%.0s-' {1..72})"
  for i in "${!backups[@]}"; do
    local f=$(basename "${backups[$i]}")
    local ts_raw="${f#${PROJECT_NAME}-backup-}"; ts_raw="${ts_raw%.tar.gz}"
    local date_str=$(date -d "${ts_raw:0:8} ${ts_raw:9:2}:${ts_raw:11:2}:${ts_raw:13:2}" "+%b %d %H:%M" 2>/dev/null || echo "$ts_raw")
    printf "  %-5s %-19s %-10s %s\n" "$((i+1))" "$date_str" "$(du -h "${backups[$i]}" | cut -f1)" "$f"
  done
}

# ─── Restore ─────────────────────────────────────────────────────────────
do_restore() {
  local rid="${1:-}"
  [ -z "$rid" ] && { list_backups; echo ""; read -rp "Backup ID/filename: " rid; }
  [ -z "$rid" ] && { info "Cancel."; return; }
  local file=""
  [ -f "$rid" ] && file="$rid"
  [[ "$rid" == *.tar.gz ]] && [ -f "${BACKUP_DIR}/${rid}" ] && file="${BACKUP_DIR}/${rid}"
  if [[ "$rid" =~ ^[0-9]+$ ]]; then
    local backups=($(ls -t "${BACKUP_DIR}/${PROJECT_NAME}-backup-"*.tar.gz 2>/dev/null || true))
    [ "$rid" -ge 1 ] && [ "$rid" -le "${#backups[@]}" ] && file="${backups[$((rid-1))]}"
  fi
  [ -z "$file" ] && { err "Not found."; return; }
  echo ""
  warn "RESTORE — files will be OVERWRITTEN!"
  echo "  File:   $(basename "$file") ($(du -h "$file" | cut -f1))"
  echo "  Target: ${PROJECT_DIR}"
  read -rp "  Continue? (y/N): " yn; [[ ! "$yn" =~ ^[Yy] ]] && { info "Cancel."; return; }
  [ -f "${PROJECT_DIR}/terraform/terraform.tfstate" ] && \
    cp "${PROJECT_DIR}/terraform/terraform.tfstate" "${BACKUP_DIR}/pre-restore-${PROJECT_NAME}-$(date +%Y%m%d-%H%M%S).tfstate"
  for sf in "${PROJECT_DIR}"/terraform/terraform.*.tfstate; do
    [ -f "$sf" ] || continue
    bn="$(basename "$sf")"
    cp "$sf" "${BACKUP_DIR}/pre-restore-${PROJECT_NAME}-$(date +%Y%m%d-%H%M%S).${bn}"
  done
  tar -xzf "$file" -C "$(dirname "$PROJECT_DIR")"
  ok "Restored: $(basename "$file")"
}

# ─── Interactive menu ───────────────────────────────────────────────────
interactive() {
  while true; do
    echo ""
    echo "╔═══════════════════════════════════════════════════╗"
    printf "║  Project: %-44s║\n" "$PROJECT_DIR"
    printf "║  Backup:  %-44s║\n" "$BACKUP_DIR/"
    echo "╠═══════════════════════════════════════════════════╣"
    echo "║  1) Create backup                                ║"
    echo "║  2) List backups                                 ║"
    echo "║  3) Restore from backup                          ║"
    echo "║  4) Exit                                         ║"
    echo "╚═══════════════════════════════════════════════════╝"
    read -rp "Select [1-4]: " c; c="${c:-4}"
    case "$c" in
      1) do_backup ;;
      2) list_backups ;;
      3) do_restore ;;
      4|q) info "Bye!"; exit 0 ;;
    esac
  done
}

# ─── Main ────────────────────────────────────────────────────────────────
case "${1:-menu}" in
  backup|b|-b)   do_backup ;;
  list|l|-l)     list_backups ;;
  restore|r|-r)  do_restore "${2:-}" ;;
  menu|m|*)      interactive ;;
esac
