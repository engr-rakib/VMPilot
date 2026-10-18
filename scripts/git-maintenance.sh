#!/usr/bin/env bash
# git-maintenance.sh — keep the repository (and the DISK) at a fixed size.
#
# WHY (2026-10-18): every sync used to push a ~320 MB `webui.db` LFS object, and
# `private-backup` accumulated 577 commits / 642 LFS objects / 99 GB. The disk
# hit 100 %. Prevention has two halves:
#   1. the sync writes a small gzipped artifact (github/vmpilot-sync.sh);
#   2. THIS script caps how much history and how many LFS objects we keep —
#      so even if (1) is bypassed, the repo cannot grow without bound.
#
# SAFE BY CONSTRUCTION
#   • history is rebuilt with `git commit-tree` plumbing: nothing is ever
#     checked out, so the production worktree and uncommitted work are NEVER
#     touched (this is the whole difference from rebase / filter-branch, which
#     rewrite the worktree and can delete production files);
#   • the oldest kept commit is created WITHOUT a parent, so the chain really
#     is KEEP commits and not "KEEP commits + all their ancestors";
#   • the rebuilt tip is verified to have the SAME tree hash as the old tip —
#     if any file content would change, the trim is aborted;
#   • the branch is moved with compare-and-swap, so a concurrent commit
#     (the sync running at the same time) cannot be clobbered;
#   • `git lfs prune` only removes objects no ref can reach.
#
# Usage:  bash scripts/git-maintenance.sh [--keep N] [--apply] [--push]
#         default is a dry run that only reports.
#
# Env:    KEEP_COMMITS=10   LFS_STORE=/opt/terraform-lab/git-lfs-store

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KEEP="${KEEP_COMMITS:-10}"
APPLY=0
PUSH=0
BRANCH="private-backup"

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)  KEEP="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --push)  PUSH=1; APPLY=1; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
warn() { printf '  WARN: %s\n' "$*" >&2; }

echo "== git maintenance (branch=$BRANCH keep=$KEEP apply=$APPLY) =="

TOTAL=$(git rev-list --count "$BRANCH")
say "commits on $BRANCH: $TOTAL"

# ── 1. trim the history ────────────────────────────────────────────────────
if [ "$TOTAL" -gt "$KEEP" ]; then
  OLD_TIP=$(git rev-parse "$BRANCH")
  OLD_TREE=$(git rev-parse "$BRANCH^{tree}")
  KEEP_LIST=$(git rev-list --max-count="$KEEP" "$BRANCH" | tac)
  if [ "$APPLY" -eq 0 ]; then
    say "would trim $TOTAL -> $KEEP (drop $(( TOTAL - KEEP )) commits)"
  else
    PARENT=""
    for c in $KEEP_LIST; do
      TREE=$(git rev-parse "$c^{tree}")
      MSG=$(git log -1 --format=%B "$c")
      AN=$(git log -1 --format=%an "$c"); AE=$(git log -1 --format=%ae "$c"); AD=$(git log -1 --format=%aI "$c")
      CN=$(git log -1 --format=%cn "$c"); CE=$(git log -1 --format=%ce "$c"); CD=$(git log -1 --format=%cI "$c")
      NEW=$(GIT_AUTHOR_NAME="$AN" GIT_AUTHOR_EMAIL="$AE" GIT_AUTHOR_DATE="$AD" \
            GIT_COMMITTER_NAME="$CN" GIT_COMMITTER_EMAIL="$CE" GIT_COMMITTER_DATE="$CD" \
            git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} <<<"$MSG")
      PARENT="$NEW"
    done
    NEW_TREE=$(git rev-parse "$PARENT^{tree}")
    if [ "$NEW_TREE" != "$OLD_TREE" ]; then
      warn "ABORT: rebuilt tree differs from the current tip — refusing to move history"
      exit 1
    fi
    git update-ref "refs/heads/$BRANCH" "$PARENT" "$OLD_TIP"
    say "trimmed $TOTAL -> $(git rev-list --count "$BRANCH") (tree identical, worktree untouched)"
    if [ "$PUSH" -eq 1 ]; then
      say "pushing trimmed branch to private …"
      git push private "$BRANCH:refs/heads/$BRANCH" --force >/dev/null 2>&1 \
        && git push private "$BRANCH:refs/heads/main" --force >/dev/null 2>&1 \
        && say "pushed (both refs/heads/$BRANCH and refs/heads/main)" \
        || warn "push failed — run again, or check credentials"
    fi
  fi
else
  say "history already within the cap"
fi

# ── 2. drop unreachable objects + prune LFS ────────────────────────────────
LFS_DIR=$(git config --get lfs.storage 2>/dev/null || echo "$ROOT/.git/lfs")
say "lfs store: $LFS_DIR"
BEFORE_LFS=$(du -sm "$LFS_DIR" 2>/dev/null | cut -f1 || echo 0)

if [ "$APPLY" -eq 1 ]; then
  git reflog expire --expire=now --expire-unreachable=now --all
  git gc --prune=now --quiet
  git lfs prune --force >/dev/null 2>&1 || warn "lfs prune returned non-zero"
else
  say "would expire reflogs, gc --prune=now and git lfs prune"
fi

AFTER_LFS=$(du -sm "$LFS_DIR" 2>/dev/null | cut -f1 || echo 0)
say "lfs store: ${BEFORE_LFS}MB -> ${AFTER_LFS}MB"
say ".git total : $(du -sh .git 2>/dev/null | cut -f1)"
say "disk       : $(df -h . | tail -1 | awk '{print $3" used, "$4" free ("$5")"}')"
[ "$APPLY" -eq 0 ] && echo "(dry run — re-run with --apply to change anything)"
echo "== done =="