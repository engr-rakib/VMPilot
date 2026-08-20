# VMPilot Console v3 — WhatsApp-Shell Workspace + vCenter-Style Operator Menu
> Status: **PLAN / proposal** (2026-08-12) · Owner: Engr. Rakib
> Replaces the current tab-bar layout with an **operator console**: a
> WhatsApp-desktop inspired shell workspace + a vCenter-like logical navigator.
> Every capability in the repo `README.md` must be reachable from this UI.

---

## 0. Why v3 (the problem with "just tabs")

The current layout is a classic multi-tab web app (Dashboard · Monitor ·
Inventory · Deploy · Jobs · Terminal). An operator asked:

> "page UI er design as like console — but if it's just a console, I can already
> do everything with shell scripts in my Linux environment."

So a raw terminal is not the goal. The goal is a **graphical operator cockpit**
that keeps two familiar mental models:

1. **WhatsApp desktop shell** — a conversation-style workspace: everything you're
   working on feels like one connected session, with an always-present
   command bar at the bottom (type or tap), and a live object *thread* above.
2. **vCenter logical menu** — a real inventory tree (vCenter → env → VM), object
   tabs (Summary / Monitor / Deploy / Raw), and **guided step workflows** that
   follow the exact CLI pipeline the scripts already implement.

The UI must **cover 100% of README.md features** (zero-touch deploy, auto-deploy
loop R1–R6, config guard, backup/restore, safe destroy, monitoring, multi-vCenter,
per-env overrides, encryption status, audit trail, S3 backend status).

---

## 1. Layout — WhatsApp shell + vCenter navigator

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  HEADER  ● VMPilot Console              [search vm/ip]   [● sync] [user ▾]  │
├──┬──────────────────────────┬──────────────────────────────────────────────┤
│  │  NAVIGATOR (left)        │  WORKSPACE (main thread)                     │
│  │  ▸ vCenter tree          │                                              │
│  │    └─ data_103 (3/3) on  │   ┌─────────────────────────────────────┐    │
│  │       ├─ dev  (3 VMs)    │   │  object thread (selected obj)       │    │
│  │       │  ├─ rakib-lab01  │   │  · header: name + status badges      │    │
│  │       │  ├─ rakib-lab02  │   │  · tabs: Summary/Monitor/Deploy/Raw  │    │
│  │       │  └─ rakib-lab03  │   │  · quick chips row (contextual)      │    │
│  │       └─ prod (1 VM)     │   │  · live job/provision stream inline  │    │
│  │  ▸ dc_example (demo)     │   └─────────────────────────────────────┘    │
│  │  ▸ testv_169             │                                              │
│  │                          │                                              │
│  │  [FLEET HEALTH]          │                                              │
│  │  ● 5 on · 2 off · 3 none │                                              │
│  ├──────────────────────────┤                                              │
│  │  JOBS STREAM (bottom)    │                                              │
│  │  last job: deploy …ok    │                                              │
├──┴──────────────────────────┴──────────────────────────────────────────────┤
│  THREAD (work-space)   newest objects stack like WhatsApp messages;        │
│  each card: breadcrumb chips + tabs + quick chips + inline job stream;     │
│  scroll up to any previously opened vCenter/env/VM, newest at the bottom   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  [object: rakib-lab01] ▸ immediate ops  [deploy] [plan] [power]     │   │
│  │  · Summary/Monitor/Deploy/Raw tabs · live job bubbles inside card    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│  COMMAND BAR  vmpilot>  [deploy rakib-lab01 ▸] [plan] [backup] [status]    │
│  (WhatsApp-style input: type a command OR tap a quick chips → runs a job)  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Left navigator (vCenter logical menu)
- **Tree:** vCenter → environment → VM, exactly like the object-navigator in the
  vSphere client (already exists today — kept, but restyled + enriched).
- Each vCenter row shows a live power summary badge: `● 3 on / 1 off`.
- Each VM row shows its power dot (🟢/🔴/⚪) + IP + cloud-init status.
- Bottom block: **fleet health** mini-summary + jump buttons.
- **Search box** filters VMs by name/IP across all vCenters.

### 1.2 Workspace = "conversation" with the selected object
Selecting an object **pushes its card onto the thread** (chat-style, newest at
the bottom — scrollable like a WhatsApp conversation):
- **Object cards** (vCenter / env / VM conversation) keep the familiar tabs and
  actions, now stacked so the operator can scroll back to anything they opened.
- **vCenter conversation**: inventory key-values, environments, VM list, live
  power toggles, edit / add-vCenter actions, per-env overrides.
- **Env conversation**: VM table + per-env override editor.
- **VM conversation**: summary tabs (Summary / Config / Deploy-Ops / Raw),
  exactly as today, **plus an inline provision stream** for the current deploy.
- Each card carries **breadcrumb chips** at its top (vCenter → env → VM) so any
  card can be re-selected without re-searching.

### 1.3 Command bar (WhatsApp input = the shell)
- Persistent footer input styled like a message box:
  `vmpilot>` + text field + send button + **quick chip** row above it.
- Typing a command runs the **real CLI script via the job API** (same code path
  as today's executor — no new backend). Command grammar:

  ```
  deploy  <vc> <env> <vm>        → scripts/deploy-vm.sh (apply, one VM)
  plan    <vc> <env> <vm>        → deploy-vm.sh --plan
  sync    <vc> <env>             → deploy-sync.sh (auto-deploy scan)
  syncp   <vc> <env>             → deploy-sync.sh plan
  backup                         → scripts/backup.sh
  backups                        → list last N backup archives
  status  [vm|venv|all]          → fleet / object health snapshot
  ipam    <vc> <env>             → next free IP + used list
  create  <vc> <env>             → VM config wizard (guided)
  vcenter                        → vCenter wizard (guided)
  help                           → command reference
  ```
- **Redundant safety:** commands that mutate (deploy/sync/backup) always show a
  **confirm chip/modal** first with the exact operation string.
- Chips are **context aware**: selecting a VM shows `deploy`, `plan`, `power
  on/off`, `reset`, `backup`; selecting a vCenter shows `sync`, `create VM`,
  `edit`, `overrides`.

### 1.4 Live job stream
- Jobs show **inline in the workspace thread** (not only the Jobs tab): when a
  command runs, its output bubbles into the conversation with a status pill
  (running / success / failed) and a link to the full log.
- Reuses `/api/jobs` + socket.io; the Jobs tab becomes "history" of the thread.

---

## 2. vCenter-style guided workflows (operator journeys)

Each workflow mirrors the README's "From Zero to a Production-Grade VM" pipeline,
with an explicit step tracker. The UI drives the same scripts; it never reimplements
Terraform logic.

### W1 — Onboard a vCenter  (`vcenter-setup.sh`)
1. Connection (server / datacenter / inventory) 2. Networks+IPAM 3. Envs
4. Credentials → **encrypt (SOPS+Age), show only a 🔑 encrypted badge**
5. Summary → done → tree refreshes. *(exists as VCenterWizard — restyle + step bar)*

### W2 — Create a VM config  (`create-vm-config.sh`)
1. vCenter+env 2. identity (name/domain/desc) 3. compute 4. network+free-IP
5. partitions/LVM/data disks 6. SSH/users 7. compliance check → writes per-VM tfvars.
*(exists as VmConfigForm — restyle + step bar + free-IP preview)*

### W3 — Deploy lifecycle  (`deploy-vm.sh` / `deploy-sync.sh`)
- Single VM: `plan` (review diff) → `deploy` (live stream) → `verify` (IP +
  cloud-init status) → offer `backup`.
- Env sync: runs deploy-sync; shows the R1–R6 table outcome inline.

### W4 — Destroy (safe)  — **NEW, README §9**
- Read README: safe destroy = `state rm` + explicit `govc vm.destroy`.
- In the VM conversation add a **`Destroy`** action behind a two-step confirm
  (`type DESTROY to confirm` equivalent — checkbox + typed name) that runs a
  new `scripts/destroy.sh --vm <vc> <env> <vm>` (extends the roadmap item).
- UI **never** offers bare auto-destroy.

### W5 — Backup & Restore  — **NEW links from README §5**
- `backup` command → creates archive (rotation 5). `backups` lists them with
  size/date + **Restore** button for a chosen archive (restore guarded).

---

## 3. README feature → UI coverage matrix

| # | README feature | Where in the UI |
|---|----------------|-----------------|
| 0 | Install / env bootstrap | Header **Setup status** (deps age ssh-key terraform-init) + `install.sh --yes` hint |
| 1 | Zero-touch VM deploy | VM conversation → **Deploy** chip; Command bar `deploy` |
| 2 | Stack ready (LVM, data, DNS) | VM **Configuration** tab shows partitions/disks/LVM; wizard W2 |
| 3 | Auto-deploy loop R1–R6 | **Sync** chip (vCenter), Command bar `sync`; result table inline |
| 4 | Config guard / key auto-fix | Plan output shows auto-normalization R4; editor validates on save |
| 5 | IP auto-sync (R3) | After deploy, VM summary shows the **rewritten IP** + renamed file |
| 6 | Backup & restore | Command bar `backup` / `backups`; W5 |
| 7 | SOPS+Age security, auto-cleanup | vCenter **🔑 encrypted** badge; deploy stream shows decrypt→cleanup |
| 8 | prevent_destroy / safe destroy | VM **Destroy** guarded workflow W4; vCenter never offers destroy |
| 9 | Monitoring readiness (node_exporter, cloud-init) | VM Summary indicator + Monitor tab chart |
| 10 | Duplicate-IP guard | Apply output surfaces the check error inline |
| 11 | Pre-deploy validation | `plan` before `deploy`, results presented as pass/fail chips |
| 12 | Audit trail | Commands auto-log to the Jobs/thread history + SQLite |
| 13 | Multi-VM & scaling | Tree + per-VM deploy; infinite VMs via `for_each` |
| 14 | Multi-vCenter + per-env overrides | Tree per vCenter; env conversation has **Overrides** tab |
| 15 | Customization options | W2 parts (partition/LVM/fs/users/updates flags) |
| 16 | S3 remote-state backend | Header status chip "state: local / S3" + docs link |

---

## 4. Interaction & operator-friendliness rules

- **Everything is 2-key reachable:** breadcrumb list in the thread header lets an
  operator jump vCenter → env → VM instantly (deep-link chips).
- **Confirm before mutate:** deploy/plan/backup/destroy require an explicit
  confirm chip (destructives require typed confirmation).
- **Live, not polling:** socket.io streams job output into the thread; power
  state refreshes after every action; optional auto-refresh toggle.
- **Keyboard-first:** `/` focuses the command bar, `Esc` closes it, arrow-up
  recalls history, `Enter` sends. Tab completes `deploy <vc>` etc.
- **Fail fast, readable:** every error is a colored chip in the thread with a
  one-line fix hint (reuse CLI validation messages).
- Empty/demo states are obvious: "no vCenter yet → Add one" CTA reflects the
  README fresh-setup path.

---

## 5. Implementation plan (files, phases)

All changes stay inside `vmpilot-webui/` (owner rule — zero edits to the main
project). The backend **only** gains non-breaking routes; the CLI is never
touched.

### Phase A — Shell frame (layout)
- NEW `frontend/js/views/Shell.js` — WhatsApp-style app shell replacing the
  current `app.js` body: left navigator (kept/enriched), workspace thread,
  command bar with chips.
- NEW `frontend/js/views/Workspace.js`, `frontend/js/views/CommandBar.js`,
  `frontend/css/shell.css`.
- `app.js` becomes a thin mount that keeps auth + nav state.

### Phase B — Command engine
- NEW `frontend/js/commands.js` — parser + confirm flow + chip factory mapping
  commands to `createJob` payloads.
- Command history + autocomplete; `help` renders the reference card.
- Server: no change needed (`POST /api/jobs` already covers all actions).

### Phase C — Object thread + inline job stream
- Refactor `Inventory.js` panels (VcenterPanel/EnvPanel/VmPanel) into thread
  renderers with breadcrumb chips + embedded job view.
- NEW `frontend/js/views/JobThread.js` — one job's live output inside a
  conversation bubble (reuse socket.io connect).
- Jobs tab becomes thread-history / archive.

### Phase D — Missing workflows ✅ DONE
- W4 safe-destroy: NEW `scripts/destroy.sh` (main repo, per updated README roadmap)
  + UI `Destroy` flow. *(this one file is the ONLY main-repo touch, and it is an
  additive standalone CLI per README roadmap)* — delivered: `scripts/destroy.sh`,
  `destroy` action in `executor.js` + guarded two-step typed-confirm `VmPanel` flow.
- W5 backup list/restore: server endpoint `GET /api/backups` (list archives)
  + restore job action `restore` in `executor.js` — delivered: `listBackups()`,
  `backup`/`restore` actions + rotation cap 5, `BackupPanel.js` with restore button.
- Setup-status chip: `GET /api/env/status` (deps/keys/init flags) — read-only.
  Delivered: `envStatus()` in `opsStatus.js` + header chip in `Shell.js`.
- Plus `GET /api/ipam` (`ipamSnapshot()`) + `IpamPanel.js` (reserved/free IPs).

### Phase E — Polish + doc
- Theming pass (shell.css), keyboard shortcuts, empty-demo states.
- Update `vmpilot-webui/README.md`, `DOCS/design-plan.md` (mark v3), and
  `PROJECT_STATUS.md`.
- E2E smoke: login → W1 … W3 → command bar → job stream → destroy guard.

### Estimated scope
| Phase | Effort | Depends on |
|-------|--------|-----------|
| A shell | S | — |
| B commands | S | A |
| C thread | M | A, B |
| D workflows | M (S for UI, S for destroy.sh/executor) | C |
| E polish/docs | S | A–D |

> Board: A → B (canned) → C → D → E. Each phase lands **working** (rebuilt
> container + smoke test) before the next starts.

---

## 6. Open decisions (owner picks)

1. **Shell look** — **LOCKED: dark navy cockpit (keep).** Same vCenter-style navy
   theme + status colors; only the organization changes into the shell frame.
2. **Conversation stack** — **LOCKED: full chat-style history.** Every opened
   object stays stacked in the workspace thread like a chat conversation —
   scroll back to a previous vCenter/env/VM at any time; the newest object is at
   the bottom, breadcrumb chips at the top of each object card.
3. **Destroy UI** — **LOCKED: build the two-step typed-confirm Destroy** in v3
   (add `scripts/destroy.sh` to the main repo per the README roadmap + guarded UI
   flow). UI never offers bare auto-destroy.
4. **Command set** — start with the listed commands (deploy/plan/sync/syncp/
   backup/backups/status/ipam/create/vcenter/help); `ssh`/`govc repl` passthrough
   is deliberately excluded for security — the Terminal tab covers interactive
   shells.

### Locked roadmap (v3)

| Ship | Deliverable |
|------|-------------|
| v3.0 | Shell frame (A) + command bar (B) — dark navy cockpit, chat-style thread, command engine with chips |
| v3.1 | Object thread + inline job stream (C) — panels become stacked conversations with live output |
| v3.2 | Workflows W4/W5 + env-status chip (D) — guarded destroy, backup list/restore | ✅ shipped |
| v3.3 | Polish + docs (E) — keyboard first, empty states, README/design-plan/PROJECT_STATUS updates | ✅ docs updated |

---

## 7. Non-negotiables (carried from v2)

- All UI code stays in `vmpilot-webui/`; no CDN; no build step.
- Frontend talks only to the API; backend talks to CLI only via subprocess.
- No auto-destroy; destructive actions always guarded.
- The CLI scripts remain canonical — the UI only orchestrates them.