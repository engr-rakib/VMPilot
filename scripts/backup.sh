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

# ╔══════════════════════════════════════════════════════════════════════╗
# ║              GENERAL BACKUP & RESTORE SCRIPT                        ║
# ╠══════════════════════════════════════════════════════════════════════╣
# ║                                                                      ║
# ║  bash backup.sh                        → interactive (asks paths)   ║
# ║  bash backup.sh /project /backup       → direct (no prompts)        ║
# ║  bash backup.sh paths                  → clear & re-ask paths       ║
# ║                                                                      ║
# ║  First run asks for the project + backup paths and saves them to    ║
# ║  ~/.backup-config; later runs reuse them (no hardcoded paths).      ║
# ║                                                                      ║
# ║  Menu: 1=Backup 2=List 3=Restore 4=Change paths 5=Exit             ║
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

# ─── Auto-detect project root ────────────────────────────────────────────
# Used when the saved PROJECT_DIR is stale (e.g. the directory was renamed or
# moved). Detects the repo root from the current directory — but only accepts
# it if it really looks like this project.
detect_project_root() {
  local git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$git_root" ] && [ -f "$git_root/scripts/backup.sh" ] && [ -d "$git_root/terraform" ]; then
    echo "$git_root"
    return 0
  fi
  echo ""
  return 1
}

# ─── Resolve paths ─────────────────────────────────────────────────────
# No hardcoded paths: first run prompts, then remembers. CLI args or the
# "Change paths" menu option update the saved values any time.
[ $# -ge 2 ] && { PROJECT_DIR="$1"; BACKUP_DIR="$2"; shift 2; }

prompt_project_dir() {
  local detected="$(detect_project_root)"
  local p=""
  if [ -n "$detected" ]; then
    read -rp "$(echo -e "${CYAN}Project directory${NC} [${detected}]: ")" p
    p="${p:-$detected}"
  else
    read -rp "$(echo -e "${CYAN}Project directory${NC}: ")" p
  fi
  realpath "$p" 2>/dev/null || echo "$p"
}

resolve_paths() {
  # Both known (from CLI args or current values) → remember and return.
  if [ -n "$PROJECT_DIR" ] && [ -n "$BACKUP_DIR" ]; then
    save_config
    return
  fi
  # Nothing provided → use the saved config if it exists.
  if [ -z "$PROJECT_DIR" ] && [ -z "$BACKUP_DIR" ] && load_config; then
    info "Loaded config: ${CONFIG}"
    return
  fi
  # Still missing → ask.
  [ -z "$PROJECT_DIR" ] && PROJECT_DIR="$(prompt_project_dir)"
  if [ -z "$BACKUP_DIR" ]; then
    read -rp "$(echo -e "${CYAN}Backup directory${NC}: ")" b
    BACKUP_DIR="$b"
  fi
  save_config
}

resolve_paths

# Self-heal: saved PROJECT_DIR no longer exists (dir renamed/moved) →
# fall back to the detected repo root and update the saved config.
if [ ! -d "$PROJECT_DIR" ]; then
  ROOT_DETECTED="$(detect_project_root)"
  if [ -n "$ROOT_DETECTED" ]; then
    warn "Project not found: ${PROJECT_DIR}"
    info "Auto-detected project root: ${ROOT_DETECTED} — updating config"
    PROJECT_DIR="$ROOT_DETECTED"
    save_config
  else
    err "Project not found: ${PROJECT_DIR}"
    exit 1
  fi
fi
mkdir -p "$BACKUP_DIR"

PROJECT_NAME="$(basename "$PROJECT_DIR")"

# ─── Backup ─────────────────────────────────────────────────────────────
do_backup() {
  local ts=$(date +"%Y%m%d-%H%M%S")
  local file="${BACKUP_DIR}/${PROJECT_NAME}-backup-${ts}.tar.gz"
  local tmp_tar="${BACKUP_DIR}/.${PROJECT_NAME}-backup-${ts}.tar"
  local stage=""
  # Temp files never linger, even if tar fails mid-way.
  trap 't=${tmp_tar:-}; [ -n "$t" ] && rm -f "$t"; s=${stage:-}; [ -n "$s" ] && rm -rf "$s"' EXIT
  info "Backup: ${file}"
  # ── Consistent SQLite snapshot ──────────────────────────────────────────
  # The WebUI server writes webui.db continuously (samples/jobs). Tarring the
  # live file prints "file changed as we read it" and can store a TORN
  # (corrupt) database — and with `set -e` the warning's exit code aborts the
  # whole backup. So: VACUUM INTO a snapshot inside the server container
  # (transactionally consistent while the server keeps running), verify it
  # with integrity_check, archive the snapshot AT the live DB's path, and
  # exclude the live db/wal/shm/journal files from the tree walk.
  local db_rel="vmpilot-webui/data/db/webui.db"
  local db_exclude=""
  if [ -f "${PROJECT_DIR}/${db_rel}" ]; then
    stage="$(mktemp -d "${BACKUP_DIR}/.vmpilot-stage-XXXXXX")"
    local dest="${stage}/${PROJECT_NAME}/vmpilot-webui/data/db/webui.db"
    mkdir -p "$(dirname "$dest")"
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "vmpilot-webui-server"; then
      if docker exec vmpilot-webui-server node -e 'const db=new (require("node:sqlite").DatabaseSync)("/app/data/db/webui.db");db.exec(`VACUUM INTO '"'"'/tmp/vmpilot-backup-webui.db'"'"'`);const r=db.prepare("PRAGMA integrity_check").get();db.close();if(r.integrity_check!=="ok"){throw new Error("snapshot corrupt: "+r.integrity_check)}' >/dev/null 2>&1 \
        && docker cp vmpilot-webui-server:/tmp/vmpilot-backup-webui.db "$dest" >/dev/null 2>&1; then
        ok "SQLite snapshot: consistent DB copy taken (server kept running)"
      else
        warn "DB snapshot via container failed — falling back to live file copy"
      fi
      docker exec vmpilot-webui-server rm -f /tmp/vmpilot-backup-webui.db >/dev/null 2>&1 || true
    else
      warn "Server container not running — archiving a live DB copy (stop the server for guaranteed consistency)"
      cp "${PROJECT_DIR}/${db_rel}" "$dest" 2>/dev/null || true
    fi
    if [ -f "$dest" ]; then
      chmod 644 "$dest"
      db_exclude="--exclude=${PROJECT_NAME}/vmpilot-webui/data/db/webui.db*"
    else
      warn "DB snapshot missing — live DB files will be archived as-is"
    fi
  fi
  # ── Archive (uncompressed first so the snapshot can be appended) ─────────
  # --warning=no-file-changed: append-only job/log files may grow mid-read;
  # that must not abort the backup (the DB itself is already snapshotted).
  # shellcheck disable=SC2086
  tar -cf "$tmp_tar" \
    --exclude=.git --exclude=.terraform --exclude=.terraform.lock.hcl \
    --exclude='*.tar.gz' --exclude='*.zip' --exclude=node_modules \
    --exclude=__pycache__ --exclude=.DS_Store \
    ${db_exclude:-} \
    --warning=no-file-changed \
    -C "$(dirname "$PROJECT_DIR")" "$(basename "$PROJECT_DIR")"
  if [ -n "$db_exclude" ]; then
    tar -rf "$tmp_tar" -C "$stage" "${PROJECT_NAME}"
  fi
  gzip -c "$tmp_tar" > "$file"
  rm -f "$tmp_tar"
  [ -n "$stage" ] && rm -rf "$stage"
  trap - EXIT
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
  # ── Container lifecycle + ownership ─────────────────────────────────────
  # The tarball stores root-owned files. The WebUI server runs as uid 1000 —
  # extracting over a live tree leaves a root-owned webui.db it cannot open
  # (crash-loop: "unable to open database file") and replaces the DB under a
  # running process. So: stop the server first, extract, fix ownership, start.
  local was_running=0
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "vmpilot-webui-server"; then
    was_running=1
    info "Stopping WebUI server for restore..."
    docker stop vmpilot-webui-server >/dev/null 2>&1 || true
  fi
  tar -xzf "$file" -C "$(dirname "$PROJECT_DIR")"
  if [ -d "${PROJECT_DIR}/vmpilot-webui/data" ]; then
    chown -R 1000:1000 "${PROJECT_DIR}/vmpilot-webui/data"
    [ -f "${PROJECT_DIR}/vmpilot-webui/data/ssh/id_ed25519" ] && chmod 600 "${PROJECT_DIR}/vmpilot-webui/data/ssh/id_ed25519"
    ok "Ownership fixed: vmpilot-webui/data → uid 1000"
  fi
  if [ "$was_running" -eq 1 ]; then
    docker start vmpilot-webui-server >/dev/null 2>&1 || true
    sleep 6
    if docker logs vmpilot-webui-server --tail 5 2>&1 | grep -q "listening on"; then
      ok "Server restarted and listening"
    else
      err "Server may not be healthy — check: docker logs vmpilot-webui-server"
    fi
  fi
  ok "Restored: $(basename "$file")"
}

# ─── Change paths ───────────────────────────────────────────────────────
# Clear saved paths and ask for new ones (or auto-detect) at any time.
change_paths() {
  warn "Clearing saved paths..."
  PROJECT_DIR=""
  BACKUP_DIR=""
  rm -f "$CONFIG"
  resolve_paths
  ok "Paths updated — project: ${PROJECT_DIR}, backup: ${BACKUP_DIR}/"
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
    echo "║  4) Change paths                                 ║"
    echo "║  5) Exit                                         ║"
    echo "╚═══════════════════════════════════════════════════╝"
    read -rp "Select [1-5]: " c; c="${c:-5}"
    case "$c" in
      1) do_backup ;;
      2) list_backups ;;
      3) do_restore ;;
      4) change_paths ;;
      5|q) info "Bye!"; exit 0 ;;
    esac
  done
}

# ─── Main ────────────────────────────────────────────────────────────────
case "${1:-menu}" in
  backup|b|-b)   do_backup ;;
  list|l|-l)     list_backups ;;
  restore|r|-r)  do_restore "${2:-}" ;;
  paths|set-path|change-path) change_paths ;;
  menu|m|*)      interactive ;;
esac
