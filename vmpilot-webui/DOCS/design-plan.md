# VMPilot Web UI — Design Plan (v2)

> Status: **active (v2)** · Replaces the v1 draft. Target: a **vCenter-style,
> graphical management console** — easy to operate, chart-driven dashboard,
> per-VM lifecycle + monitoring, everything operated from the browser.
>
> Hard rule set by the owner:
> - **All UI code lives in `vmpilot-webui/` only** — zero new files outside it.
> - **No code dependency on the VMPilot repo.** The UI talks to VMPilot **only via
>   the API + subprocess** at runtime. VMPilot → UI dependency does not exist.
> - **Zero changes to the main project.** The Terraform project already works as
>   expected; the web app must not require any edit there.
> - The UI may run on its **own server / own Docker** — a separate deployable
>   unit is fine, as long as it can reach a VMPilot deploy directory.

---

## 1. What is already real (as of 2026-08-12)

The console is **working today** — verified containers + HTTP checks:

| Slice | Status | Where |
|---|---|---|
| Login (bcrypt + JWT httpOnly cookie) | ✅ | `server/src/auth.js` |
| Web terminal (xterm.js + node-pty) | ✅ | `server/src/terminal.js`, `frontend/js/views/Terminal.js` |
| Dashboard (KPI cards, power meter, tables) | ✅ | `frontend/js/views/Dashboard.js`, `server/src/monitor.js` |
| VM inventory tree (vCenter→env→VM) | ✅ | `frontend/js/views/Inventory.js`, `server/src/catalog.js` |
| vCenter wizard (add/edit/remove) | ✅ | `frontend/js/views/VCenterWizard.js`, `server/src/vcenterOps.js` |
| VM config form (per-VM tfvars) | ✅ | `frontend/js/views/VmConfigForm.js`, `server/src/vmConfigs.js` |
| Deploy / plan / sync / backup jobs | ✅ | `frontend/js/views/Deploy.js`, `frontend/js/views/Jobs.js`, `server/src/executor.js` |
| Live job output over socket.io | ✅ | `frontend/js/views/Jobs.js`, `server/src/index.js` |
| Monitoring snapshot (capacity + live govc) | ✅ | `server/src/monitor.js`, `frontend/js/views/Monitor.js` |
| **Chart layer (Phase 2.5)** | ✅ | `frontend/js/charts.js` (SVG): power donut, capacity bars, env distribution, job-outcome donut, per-VM usage bars |
| No-build frontend (external js/css/vendor) | ✅ | `frontend/{index.html,css,js,vendor}` |
| Standalone (no nginx) or nginx edge (profile) | ✅ | `docker-compose.yml`, `nginx/` |

**Why the demo previously looked "stale":** the old UI was a Vite/React build
(`frontend/src/*.jsx` → `dist/`) while the new no-build UI (`frontend/js/`,
`frontend/css/`) was not being served, and `css/` was empty. That has been fixed:
the frontend is now pure static files (no build step) and `dist/`, `src/`,
`node_modules/`, Vite config were removed from `frontend/`.

### Architecture (v2, current)

```
Browser ──► [nginx:443] ──► [server:3000]  Node.js (Express + socket.io)
              │  OR optionally omit nginx ─►  standalone :3000 serves UI+API
                                              │
                                              ├── static: frontend/{css,js,vendor}
                                              ├── API:   /api/* (JSON, JWT cookie)
                                              ├── WS:    /socket.io (terminal, /jobs)
                                              └── exec ─► VMPilot scripts (subprocess only)
                                                           │ mount /vmpilot (runtime only)
                                                           ▼
                                       VMPilot repo (deploy/, secure/, terraform/)
```

- **The only coupling to VMPilot is a runtime bind-mount** (`VMPILOT_DIR`) + calling
  its scripts/CLI via `child_process.execFile`. No imports, no shared code.
- **nginx is optional** (`docker compose --profile nginx up -d`). LAN/desktop use
  the Node server directly; exposed deployments add TLS + rate-limit + WAF headers.
- **Data the UI persists lives in `vmpilot-webui/data/`** (SQLite + job logs) —
  nothing written into the VMPilot tree except what the CLI itself writes.

---

## 2. Non-Negotiables (owner-locked)

1. **UI isolate korte hobe.** All UI source stays under `vmpilot-webui/`. A future
   move to its own Git repo / its own server is supported (see decision table).
2. **API is the contract.** Every VMPilot capability the UI needs flows through
   the Node API. The frontend never walks the filesystem and never shells out.
3. **Main project is untouched.** No new hooks, no plugins, no config injected
   into `terraform/` or `scripts/` by the UI. Scripts are already deployable as-is.
4. **Graphical, vCenter-like, easy.** Dashboards not dumps: charts, status colors,
   click-to-act, wizards, confirmations on destructive actions.

---

## 3. Target UI — How it looks & behaves (vCenter style)

### 3.1 Visual language
- Dark VMware-style cockpit: deep navy panels, cyan accent, status traffic-lights
  (🟢 on / 🔴 off / 🟡 pending / ⚪ undeployed).
- **Left sidebar object navigator** (vCenter → environments → VMs), main content
  panel on the right. Header with global actions.
- System font + emoji glyphs (no icon CDN); all assets are local files.

### 3.2 Pages (target)

| # | Page | Contents | Built? |
|---|------|----------|--------|
| 1 | **Login** | username/password, error, redirect | ✅ |
| 2 | **Dashboard** | KPI stat cards, **power donut**, **CPU/RAM/disk bars per vCenter**, VM status table, recent jobs | ✅⁎ (add charts) |
| 3 | **Monitor** | per-vCenter capacity table, per-VM **resource sparklines/usage %**, cloud-init status, live power | ✅⁎ (add charts) |
| 4 | **Inventory** | tree navigator + object panels (vCenter / env / VM) | ✅ |
| 5 | **VM detail** | summary kv, partitions, disks/LVM, raw tfvars, power + deploy actions | ✅ |
| 6 | **Deploy** | action picker (deploy/plan/sync/backup) → runs real CLI job | ✅ |
| 7 | **Jobs** | history list + **live streaming output**, status/exit badge | ✅ |
| 8 | **Terminal** | full interactive shell | ✅ |
| 9 | **vCenter wizard** | add/edit vCenter (connection + inventory + network + IPAM) | ✅ |
| 10 | **VM config form** | full per-VM wizard (identity/compute/network/ssh/disks/LVM/users) | ✅ |

### 3.3 Charting (the main *new* visual layer)
- **Goal:** replace bare stat numbers/tables with proper charts so capacity and
  health are readable at a glance.
- **Engine:** a tiny vendored chart library (no CDN, no build step) driving an
  SVG/Canvas component — e.g. **Chart.js (vendored UMD)** or, if we want to stay
  dependency-free, a small hand-rolled SVG chart util in `frontend/js/charts.js`.
- **Charts planned:**
  - **Power donut** — on / off / pending / undeployed per fleet (Dashboard).
  - **Capacity bars** — configured vCPU / RAM / disk vs. what's powered on, per vCenter.
  - **Per-VM utilization** — CPU %, RAM %, disk % (govc real-time where available).
  - **Env distribution** — VMs per environment as a horizontal bar.
  - **Job outcome history** — success/failed count over last N jobs (from SQLite).
  - **IPAM usage** — used vs. free in the configured subnet (from `next_free_ip` data).

### 3.4 Interaction model
- Click tree node → object panel; tabs inside panels (Summary / Config / Deploy / Raw).
- Destructive/power actions → **confirm modal** + result toast + job badge.
- Long operations → job starts, Jobs tab opens, output streams live; sidebar badge.
- Everypage has Refresh; Dashboard + Monitor get an optional 5 s auto-refresh toggle.

---

## 4. API Surface (contract that keeps UI decoupled)

Implemented today:

```
POST /api/auth/login | logout  ·  GET /api/auth/me          # JWT cookie
GET  /api/health
GET  /api/inventory                     # tree: vCenter → env → VM configs (+summary)
GET  /api/vcenters | /api/vcenters/:vc  # list / detail (inventory + envs + configs)
POST /api/vcenters · PUT/DELETE /api/vcenters/:vc          # wizard CRUD
POST /api/vcenters/:vc/envs · DELETE /api/vcenters/:vc/envs/:env
GET/PUT /api/vcenters/:vc/envs/:env/override              # per-env tfvars
GET  /api/freeip?base_ip&skip_ip                          # IPAM probe
GET  /api/configs/:vc/:env · /api/configs/:vc/:env/:file   # read VM config
POST /api/configs · PUT/DELETE /api/configs/:vc/:env/:file  # write VM config
GET  /api/monitor · /api/monitor/live?vc=                  # capacity + live govc
GET  /api/vms?vc= · POST /api/vms/power                   # govc list / on|off|reset
GET  /api/jobs · /api/jobs/:id · /api/jobs/:id/output      # history + log chunks
POST /api/jobs                          # {action: deploy|sync|backup, params}
WS   /socket.io/jobs (job:output, job:status) · /socket.io/terminal
```

**Every endpoint enforces the JWT session cookie** (`requireAuth`). Actions are
structured JSON only — no free-form shell from the UI.

---

## 5. Security model

| Layer | Mechanism |
|---|---|
| Auth | bcrypt login → JWT in httpOnly `SameSite=Strict` cookie; app refuses to boot without `WEBUI_SECRET` + `WEBUI_PASS_HASH` |
| Edge | Optional nginx: TLS, Strict-Transport-Security, CSP (`script-src 'self'`), X-Frame DENY, Referrer-Policy, Permissions-Policy; rate-limit on login (5/min) + API limits |
| Runtime | Container drops to uid 1000; terminal spawns a real shell as that user; VMPilot repo bind-mounted read-write only for the CLI's own writes (identical trust to a local shell) |
| Secrets | vCenter creds stay in `secure/<vc>/` (sops/age); the UI never receives them — decrypt happens server-side per call |
| Audit | Job history + exit codes already persisted in SQLite; full RBAC/audit trail is a Phase 3 item |

---

## 6. Data model (all inside `vmpilot-webui/data/`)

```
jobs(id, action, status, params_json, user, exit_code,
     output_path, started_at, finished_at)          # SQLite (node:sqlite)
job logs -> data/jobs/<id>.log                       # rotated, metadata only in DB
```

Future (Phase 3+): `users`, `audit_log`. The UI never mirrors VMPilot configs into
this DB — it reads the live tree via the API on demand.

---

## 7. Roadmap (v2)

### Phase 2.5 — Chart & visualization layer ✅ DONE (2026-08-12)
- Implemented **`frontend/js/charts.js`** — a tiny hand-rolled **SVG** util (no CDN,
  no build): `Donut`, `HBars`, `MiniBar`, `PowerDonut`.
- Dashboard rebuilt: **power donut**, **capacity bars by vCenter** (CPU/RAM/disk),
  **VMs-by-environment** bars, **job-outcome donut** (from SQLite), per-VM bars.
- Monitor enhanced: per-vCenter **capacity bars** + **live per-VM utilization**
  (CPU % / RAM %) from govc `quickStats`.
- **Server:** `/api/monitor` snapshot now includes `cpuUsageMHz` + `memUsageMB`
  per VM (govc `quickStats`); jobs outcome reuses `/api/jobs` (no new endpoint).
- **Fix (pre-existing):** `catalog.readFileOrSudo` fell back asynchronously to
  sudo while all readers are sync → root-owned 0600 files (demo/secure/) produced
  `[object Promise]`. Now uses `execFileSync` + passed sudo, private the async
  helper. Demo vCenter parses cleanly, charts show real names/values.
- Files: `frontend/js/charts.js` (NEW), `frontend/js/views/Dashboard.js`,
  `frontend/js/views/Monitor.js`, `frontend/css/views.css`,
  `server/src/monitor.js`, `server/src/catalog.js`.

### Phase 3 — RBAC + Audit + 2FA
- Users table, roles (viewer/operator/admin), per-endpoint enforcement,
  audit_log, optional TOTP.
- **Files:** `server/src/db.js` (tables), `server/src/auth.js`, NEW `server/src/rbac.js`, routes in `server/src/index.js`; `frontend/js/views/*` role gating + `frontend/js/views/Admin.js`.

### Phase 4 — Operator chat / quick-command bar
- A `vmpilot>` command bar + quick-reply chips (`Deploy`, `Create Config`,
  `Backup`, `Status`) that drive the same jobs API.
- **Files:** NEW `frontend/js/views/Chat.js`, `frontend/js/app.js` (nav), `frontend/css/views.css`.

### Phase 5 — Deeper monitoring
- Structured logs, optional Prometheus collector for node_exporter VMs, alerts
  (job failure / VM down). Mostly new service + `server/src/monitor.js` extension.

---

## 8. Change log vs old plan (what had to change, and why)

| Topic | v1 plan | v2 (this) | Why |
|---|---|---|---|
| Frontend stack | React + Vite + Tailwind | **No-build ES modules + vendored UMD** | zero build step, static files only, runs anywhere incl. standalone |
| Containers | always nginx + api | **api standalone; nginx optional profile** | Node can serve UI+API; nginx only for exposed deployments |
| nginx role | required proxy | **optional edge** (TLS/rate-limit/headers) | simpler LAN/dev; answer to "node can host, why nginx" |
| Location of UI deps | mostly implicit | **everything under `vmpilot-webui/`** | owner rule: no UI dependency anywhere in the repo |
| Main-project coupling | mount repo, no imports | **unchanged + explicitly zero touch** | Terraform works — never require edits there |
| Monitoring UI | plain tables | **chart-driven dashboard/monitor** | "graphical, vCenter-like, easy" requirement |
| Review screens | console-first | **dashboard-first, wizard-driven** | ease of operation |

---

## 9. Repository layout (final)

```
vmpilot-webui/                       # THE ONLY UI codebase
├── docker-compose.yml               # server (default) + web/nginx (profile)
├── .env.example                     # non-secret settings
├── DOCS/design-plan.md              # this document
├── README.md
├── server/                          # Node backend = the ONLY VMPilot-aware part
│   ├── Dockerfile                   # + terraform/govc/sops/age for terminal & exec
│   ├── scripts/gen-pass.js
│   └── src/
│       ├── config.js · auth.js · db.js · terminal.js
│       ├── executor.js · monitor.js · catalog.js
│       ├── vcenterOps.js · vmConfigs.js
│       └── index.js                 # Express + socket.io wiring
├── frontend/                        # static, no-build (no npm at runtime)
│   ├── index.html
│   ├── css/{themes,layout,views}.css
│   ├── js/{core,api,components,app}.js
│   ├── js/views/{Login,Dashboard,Monitor,Inventory,VCenterWizard,
│   │            VmConfigForm,Deploy,Jobs,Terminal}.js
│   └── vendor/{react,react-dom,socket.io,xterm,htm}   # charts are hand-rolled SVG (js/charts.js)
├── nginx/                           # OPTIONAL edge (profile)
├── config/secrets.env.example       # bcrypt hash (never via compose .env)
├── data/                            # webui.db + jobs/ (gitignored, persists)
└── scripts/setup.sh                 # idempotent .env + secrets bootstrap
```

---

## 10. Decisions (locked)

| # | Decision | Chosen |
|---|---|---|
| 1 | UI location | **Inside VMPilot repo** (`vmpilot-webui/`), self-contained; movable to its own server/repo without touching VMPilot |
| 2 | Coupling | **API + subprocess only**; no imports; zero changes to main project |
| 3 | Frontend | **No-build static ES modules + vendored UMD** (no CDN, no bundler) |
| 4 | Backend | **Node.js** (Express + socket.io + node-pty + SQLite) |
| 5 | nginx | **Optional** — Node standalone for LAN/dev; nginx profile for exposure |
| 6 | Visual | **vCenter-style**, chart-driven dashboard, confirmation modals, wizards |
| 7 | Charts | **Internal hand-rolled SVG util** (`frontend/js/charts.js`) — no external CDN, no dependency |
| 8 | Deployment | `docker compose up -d` (server) or `--profile nginx`; `scripts/setup.sh` bootstraps |