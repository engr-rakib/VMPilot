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
- **Docs index:** `docs/README.md` — three doc layers that MUST stay in sync
  with code:
  1. `docs/features/<feature>.md` — one doc per FEATURE (template-driven).
  2. `docs/pages/<page>.md` — one doc per UI PAGE (Shell, Dashboard, Inventory,
     Events, Backups, Terminal/Console, Settings, VM Form).
  3. `docs/technical/` — architecture, database, build-verify.
- **A feature change is NOT done until its doc (feature + page + technical where
  touched) is updated in the SAME change** — stale doc = regression.

## Feature documentation (MANDATORY — every feature needs a doc)

- **Three doc layers, all updated in the SAME change as the code:**
  1. **Feature docs** — every WebUI feature has **one doc file** at
     `docs/features/<feature>.md` following the template `docs/_template-feature.md`
     (index + rules: `docs/README.md`). Sections are fixed: Overview, Features,
     Case analysis, User flow, Lifecycle, Backend technology & workflow,
     Verification, Files, Gotchas.
  2. **Page-wise docs** — every UI PAGE has a doc at `docs/pages/<page>.md`
     (Shell/Workspace, Dashboard, Inventory, Events & Activity, Backups,
     Terminal/Console, Settings, VM Form/Wizard). One doc per page: view file(s),
     backend endpoints, lifecycle (SWR cache, 30s polls, deep-links),
     page-specific traps. New page → new doc + index row.
  3. **Technical background** — `docs/technical/architecture.md` (stack, request
     lifecycle, realtime, storage), `database.md` (schema + API map),
     `build-verify.md` (bake/verify protocol). Update when stack/DB/build changes.
- A feature change is NOT complete until its doc is updated in the SAME change
  (code + doc land together; stale doc = regression).
- New features: create `docs/features/<name>.md` from the template AND add an
  index row in `docs/README.md`.
- All docs written in Banglish (same rule as communication), never Bangla
  Unicode/Bengali font.