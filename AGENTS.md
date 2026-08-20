# VMPilot — Agent Instructions

## Communication (MANDATORY)

- **NEVER** output Bangla/Bengali Unicode characters (Bangla font) in ANY
  response, tool output, or file you write. The user's terminal cannot render
  Bangla script — it shows as garbled text.
- Reply in **English** (or Banglish = Bangla words written in Latin script,
  e.g. "kore", "thakbe", "bolo"), NEVER Bangla Unicode/Bengali font.
- This applies to every conversation, regardless of how the user types.

## Project context

- VMPilot automates VM deployment on VMware vSphere via Terraform + cloud-init.
- Deploy flow: `scripts/create-vm-config.sh` generates a per-VM tfvars file,
  `scripts/deploy-vm.sh` deploys one VM, `scripts/deploy-sync.sh` reconciles all.
- Per-VM configs live in `deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars` and are
  gitignored (contain inventory/SSH/IP secrets).

## WebUI knowledge (READ FIRST before any WebUI work)

- **Load the skill:** `.opencode/skills/vmpilot-webui/SKILL.md` — the accumulated
  "recurring traps" list (no-build ESM+htm stack, null-guard rule, htm entity
  gotcha, style-object rule, SWR/never-blank, fixed-layout tables + colgroup
  100%, unified Events design, target-matched actions, deep-link focus, nginx
  bake/verify loop). It also has a **PAGE MAP** (page → view file → API → doc).
- **Docs index:** `vmpilot-webui/docs/README.md` — three doc layers that MUST
  stay in sync with code:
  1. `docs/features/<feature>.md` — one doc per FEATURE (template-driven).
  2. `docs/pages/<page>.md` — one doc per UI PAGE (Shell, Dashboard, Inventory,
     Events, Backups, Terminal/Console, Settings, VM Form).
  3. `docs/technical/` — architecture, database, build-verify.
- **A feature change is NOT done until its doc (feature + page + technical where
  touched) is updated in the SAME change** — stale doc = regression.

## Persistent data & cleanup (MANDATORY)

- The webui DB is SQLite at `vmpilot-webui/data/db/webui.db` (host) ⇄
  `/app/data/db/webui.db` (container), bound via `./data:/app/data` so it survives
  `docker compose up -d --build`. Storage is swapped via the `WEBUI_DATA_DIR` env +
  `openDb(dataDir)` — never hard-code a DB path; keep storage swappable to a
  separate DB server / mount point / object store.
- **ALL persistent webui data lives under `vmpilot-webui/data/`** (db, jobs logs,
  .cache). Nothing else may hold runtime state.
- **Git visibility (two-repo policy):**
  - **Public repo (`origin`/VMPilot):** `vmpilot-webui/data/` is gitignored
    (project-root `.gitignore:79`) — DB/jobs/secrets NEVER go public.
  - **Internal repo (`private`/VMPilot-internal):** the FULL project incl.
    `vmpilot-webui/data/` IS backed up there via `github/vmpilot-sync.sh`
    (its `git add -f ... vmpilot-webui/data` line) and `github/backup-and-sync.md`.
  - Keep this split intact: if you touch `.gitignore`, re-verify both the public
    exclusion AND the private `git add -f` list include `vmpilot-webui/data/`.
- Keep the repo clean: delete leftover/duplicate files that nothing references
  (verify with grep first, back up, then remove). Never leave stray DBs or config
  dumps next to the live one — they cause conflicts.

## Feature implementation (MANDATORY — before ANY feature)

**Do a behavior / use-case / lifecycle analysis BEFORE writing code, and never
ship a half-feature.** Every feature change must cover ALL of these:

- **Bidirectional on/off:** if you add a hide/disable/remove path, the
  show/enable/restore path MUST land in the SAME change. Never leave a one-way
  feature (e.g. hiding a label but only keeping an invisible hover tooltip).
  If space forces content out, use ellipsis + `title` (progressive
  disclosure), not silent removal.
- **Lifecycle:** mount → data loaded → background refresh → refresh failure →
  nav-switch away/back → full page reload → unmount. Data must never blank out
  at any point (stale-while-revalidate + sessionStorage cache).
- **Empty / error states:** no-data placeholder, fetch failure keeps last-good
  data, Retry button, permission-denied ("unauthorized") handling.
- **Edge values:** `0 / undefined / null / NaN` (e.g. `cpuUsageMHz` missing
  when VM is powered off) must render "—", never "NaN" or a 0-width bar.
- **Responsive:** widest AND narrowest content (dev vs prod VMs!), smallest
  viewport, narrowest card. No horizontal scrollbar, no clipped text without
  ellipsis. Long values (VM names, extra_users, LVM vols) get ellipsis +
  tooltip.
- Present the analysis in your reply BEFORE editing, then implement. If you
  find mid-change that a branch (restore/enable/empty) is missing, STOP and add
  it — do not merge a one-way feature.

## Feature documentation (MANDATORY — every feature needs a doc)

- **Three doc layers, all updated in the SAME change as the code:**
  1. **Feature docs** — every WebUI feature has **one doc file** at
     `vmpilot-webui/docs/features/<feature>.md` following the template
     `vmpilot-webui/docs/_template-feature.md` (index + rules:
     `vmpilot-webui/docs/README.md`). Sections are fixed: Overview, Features
     (what exists), Case analysis (edge cases), User flow (UI step-by-step),
     Lifecycle, Backend technology & workflow, Verification, Files, Gotchas.
  2. **Page-wise docs** — every UI PAGE has a doc at
     `vmpilot-webui/docs/pages/<page>.md` (Shell/Workspace, Dashboard, Inventory,
     Events & Activity, Backups, Terminal/Console, Settings, VM Form/Wizard).
     One doc per page: view file(s), backend endpoints, lifecycle (SWR cache,
     30s polls, deep-links), page-specific traps. New page → new doc + index row.
  3. **Technical background** — `vmpilot-webui/docs/technical/architecture.md`
     (stack, request lifecycle, realtime, storage), `database.md` (schema + API
     map), `build-verify.md` (bake/verify protocol). Update when stack/DB/build
     changes.
- A feature change is NOT complete until its doc is updated in the SAME change
  (code + doc land together; stale doc = regression).
- New features: create `docs/features/<name>.md` from the template AND add an
  index row in `vmpilot-webui/docs/README.md`.
- All docs written in Banglish (same rule as communication), never Bangla
  Unicode/Bengali font.
