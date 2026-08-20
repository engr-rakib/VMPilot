# VMPilot Console — Events & Tasks + Settings (RBAC / Users / Alerting) Implementation Plan
> Status: **PLAN / proposal** (2026-08-17) · Owner: Engr. Rakib
> Extends the v3 console with two new operator surfaces:
>   1. **Events & Tasks** — a vCenter-style drill-down for every project
>      initiated task (deploy/plan/sync/destroy/power/backup/restore) and the
>      resource alerts that today only surface in the bell dropdown. Clicking a
>      notification navigates to the targeted event log + full history.
>   2. **Settings** — user management, RBAC / role control, and the
>      notification/alerting system (email/SMTP delivery) managed from the UI.

---

## 1. Goals

1. **Events & Tasks view** (`/events`): one page with **Events** (resource
   alerts + power/deploy events) and **Tasks** (every job/task the console has
   ever started, with full lifecycle state + output log). Mirrors the Monitor
   page's per-vCenter card layout.
2. **Notification → event drill-down**: clicking a bell notification jumps to
   the matching event in the Events view (deep link), which links to its full
   history/details.
3. **Task list = source of truth for "what happened"**: everything already in
   the jobs table (deploy, plan, sync, destroy, backup, restore) plus new
   power events become Tasks with a state machine.
4. **Settings panel** (`/settings`):
   - **Users**: list / create / disable / reset-password / assign-role.
   - **RBAC roles**: `admin`, `operator`, `viewer` with an explicit permission
     matrix enforced on the API (not just hidden buttons).
   - **Alerting**: enable/disable alert types, thresholds (CPU/RAM %), SMTP
     (server/port/from/to/TLS) + test email, and per-severity delivery policy.
5. **Email/SMTP delivery** behind a feature flag; UI-first (panel works without
   SMTP configured — alerts still log + bell), SMTP is the opt-in delivery
   channel.

---

## 2. Current state (what exists today)

| Capability | Where | Notes |
|---|---|---|
| Job/task store | `server/src/db.js` SQLite `jobs` table | `id, action, status, params, user, exit_code, output_path, started_at, finished_at`. Status: `queued/running/success/failed`. |
| Job execution | `executor.js` (`startJob`, `runScriptJob`, `runBackupJob`, `runRestoreJob`) | Spawns scripts via sudo; emits socket `job:status` + `job:output`; `NO_COLOR=1`. |
| Jobs page | `frontend/js/views/Jobs.js` | Live table + socket stream; ANSI-stripped. |
| JobThread card | `frontend/js/views/JobThread.js` | Inline console + PHASES stepper, used in thread + VmPanel deploy tab. |
| Alerts | `server/src/alerts.js` | `{id, kind: resource\|event, severity, vc, env, vm, label, value, at, seen}` in `/app/data/webui-alerts.json`. |
| Alerts API | `GET /api/alerts`, `/unseen`, `POST /seen`, `DELETE` | Frontend `NotifyBell.js` polls unseen every 12s. |
| Auth | `server/src/auth.js` + `config.js` | Single admin (`WEBUI_USER`/`WEBUI_PASS_HASH`), JWT HS256 cookie `vmpilot_sid`, iss/aud `vmpilot-webui`. No user table, no roles. |
| Monitor | `monitor.js` + `views/Monitor.js` | Per-vCenter → host → datastore → VM drill-down; hosts/datastores from inventory script. |
| Backups | `executor.listBackups` + `BackupPanel.js` | Backup/restore as jobs. |
| Terminal | `terminal.js` + `Terminal.js` | xterm.js over socket.io. |
| Env status | `EnvStatus.js` / `opsStatus.js` | Setup state backend. |

**Gaps identified:**
- No dedicated Events/Tasks **page** — alerts only live in the bell; jobs only
  in the Jobs page (no state-machine history, no drill-to-details, no
  notification→event deep link).
- Tasks lack a lifecycle model beyond `queued/running/success/failed` and are
  not linkable to the object (vc/env/vm) that triggered them for targeted log
  navigation.
- No **users** table, no **roles**, no API-level authorization (every route is
  admin-only via `requireAuth`).
- No SMTP/email delivery and no alert **configuration** (thresholds, enable
  flags are hardcoded constants in `alerts.js`).

---

## 3. Feature A — Events & Tasks view

### 3.1 Data model (unified ledger)

Introduce a **ledger** concept backed by SQLite (`webui.db`). It is the join of
"events" and "tasks" behind a single read API, and the target of notification
deep links.

- **Tasks** = existing `jobs` rows, extended:
  - `target_vc`, `target_env`, `target_vm` (denormalized from `params` at job
    creation) so drill-down can filter/link.
  - `state` derived from `status` (see lifecycle), kept in sync.
  - `logs` stay in `output_path` (already streamed + polled).
- **Events** = an `events` table:
  ```
  CREATE TABLE IF NOT EXISTS events (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,        -- 'resource' | 'power' | 'job' | 'system'
    severity    TEXT NOT NULL,        -- 'info' | 'warn' | 'critical'
    vc          TEXT, env TEXT, vm TEXT,
    label       TEXT NOT NULL,
    value       TEXT,                  -- e.g. "94%"
    task_id     TEXT,                  -- FK-ish to jobs.id for power/deploy events
    at          INTEGER NOT NULL,      -- epoch ms
    seen        INTEGER DEFAULT 0
  );
  ```
  `alerts.js` migrates from the JSON file to this table (file fallback for
  backward-compat during rollout, then removed).

### 3.2 Events page layout (mirrors Monitor.js)

```
/events
├─ Toolbar: [Events] [Tasks] tabs · filter chips (severity, vc) · search
├─ EVENTS tab
│   └─ per-vCenter cards (like Monitor)
│      ├─ Host / VM CPU·RAM alerts   (severity pill, value, time-ago)
│      └─ power on/off + job events  (→ "open task" link)
├─ TASKS tab
│   └─ task list table
│      id · action · target (vc/env/vm chips) · user · status pill
│      · started/finished · duration · [open log] [history]
└─ Task details (right pane or thread card)
     state machine timeline + JobThread output + related events
```

Navigation:
- VIEWS array in `Shell.js` gains `{ id: "events", label: "Events", icon: "◈" }`.
- Clicking a **bell notification** → `runNav("events")` + open the matching
  event/task detail (thread card) via a query param / callback into
  `NotifyBell.onOpen`.
- Task rows deep-link to a `JobThread` card so logs + PHASES stepper are reused.

### 3.3 Task lifecycle

```
                  ┌────────────┐
        create ──▶│   QUEUED   │
                  └────────────┘
                        │ startJob
                        ▼
                  ┌────────────┐    ┌────────────┐
                  │  RUNNING   │──▶│   FAILED   │
                  └────────────┘    └────────────┘
                        │ 0
                        ▼
                  ┌────────────┐
                  │  SUCCESS   │
                  └────────────┘
```
- Persisted columns unchanged (`status`), `state` derived. Add `finished_at`
  already exists. Duration = `finished_at - started_at`.
- A task's related events (its power/deploy notifications) are queryable via
  `events.task_id`, giving the "history" view.

### 3.4 API

```
GET  /api/events?vc=&env=&vm=&kind=&severity=&limit=      → events[] (desc)
GET  /api/events/:id                                      → event + linked task
GET  /api/tasks?vc=&env=&vm=&action=&status=&limit=       → tasks[] (jobs, desc)
GET  /api/tasks/:id                                       → task (job) + output head
GET  /api/tasks/:id/log?offset=                           → reuse /api/jobs/:id/output
GET  /api/events/summary                                  → { by_severity, by_kind, unseen }
```
All behind `requireAuth`; role-gated (viewer can read, operator/admin can act).

---

## 4. Feature B — Settings panel

### 4.1 Users + RBAC

New SQLite tables:

```
CREATE TABLE IF NOT EXISTS users (
  id        TEXT PRIMARY KEY,          -- uuid
  username  TEXT UNIQUE NOT NULL,
  pass_hash TEXT NOT NULL,             -- bcrypt
  role      TEXT NOT NULL DEFAULT 'viewer',  -- admin|operator|viewer
  disabled  INTEGER DEFAULT 0,
  created_at INTEGER, last_login INTEGER
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL                  -- JSON
);
```

- **Bootstrap:** first run seeds `users` with the existing `WEBUI_USER` /
  `WEBUI_PASS_HASH` as an `admin` (config fallback). `auth.login` switches from
  config-only to users-table lookup (config stays as seed/bootstrap).
- **Roles / permission matrix** (enforced in `requireAuth` via a small RBAC
  helper, `auth.can(role, perm)`):

  | Permission | admin | operator | viewer |
  |---|---|---|---|
  | view inventory / monitor / events / settings (read) | ✓ | ✓ | ✓ |
  | deploy / plan / sync / destroy / power / backup | ✓ | ✓ | — |
  | create/edit/delete VM configs, secure files, vCenters | ✓ | ✓ | — |
  | manage users / roles | ✓ | — | — |
  | change alerting settings / SMTP | ✓ | — | — |
  | terminal | ✓ | ✓ | — |

- API protection pattern:
  ```
  app.get("/api/settings", auth.requireRole("viewer"), ...);
  app.put("/api/settings/alerting", auth.requireRole("admin"), ...);
  ```
  Existing routes get role annotations from the matrix above; default stays
  admin (conservative) until each is explicitly relaxed.

### 4.2 Settings page layout

```
/settings
├─ Tabs:  [Users] [Roles] [Alerting]
├─ Users: table (username · role · status · last login) · [+ Add user]
│         edit role · disable/enable · reset password
├─ Roles: matrix viewer (read-only explainer of the matrix above)
└─ Alerting:
     ├─ Resource alerts  [on/off]  CPU warn/crit % · RAM warn/crit %
     ├─ Event alerts     [on/off]  power · jobs
     ├─ Delivery         [bell only] · [email] · [both]
     ├─ SMTP: host · port · secure/TLS · from · to (comma) · username · password
     ├─ [Send test email]
     └─ Last delivery status (per alert id, e.g. "sent/failed@15:04")
```

### 4.3 Alerting engine (with SMTP)

- `settings.alerting` JSON in the `settings` table drives `alerts.js` instead of
  hardcoded `CPU_WARN/CRIT` etc. `evaluate()` reads config each run.
- **SMTP delivery** via `nodemailer` (add dependency) in a new
  `server/src/mailer.js`:
  - `sendAlert(alert, config)` builds subject
    `[VMPilot {severity}] {label} · {vm}` + body (vc/env/vm/value/at) + link to
    `/events`.
  - Queued async (fire-and-forget with a delivery-status column on `events`:
    `notified INTEGER DEFAULT 0`, `notify_error TEXT`). No SMTP configured →
    skipped, bell only.
  - Test email route `POST /api/settings/alerting/test`.

### 4.4 API

```
GET    /api/users                     (admin)
POST   /api/users                     (admin)  {username, password, role}
PUT    /api/users/:id                 (admin)  {role?, disabled?, password?}
DELETE /api/users/:id                 (admin)  (never delete the last admin)
GET    /api/settings/alerting         (viewer)
PUT    /api/settings/alerting         (admin)  {enabled*, thresholds, delivery, smtp}
POST   /api/settings/alerting/test    (admin)
```

---

## 5. Implementation lifecycle (phases)

> Each phase ends in a **rebuild + verify** (see
> [Docker rebuild + verify](#8-docker-rebuild--verify)). Phases are additive;
> nothing in phases 1–2 blocks phase 3.

| Phase | Scope | Exit criteria |
|---|---|---|
| **P0 — Ledger backend** | `events` table + migration from alerts JSON; `alerts.js` writes to SQLite; `jobs` gets `target_vc/env/vm` + `state`; new `/api/events` + `/api/tasks` read routes. | `curl /api/events` + `/api/tasks` return data through nginx; alerts persist across restart. |
| **P1 — Events & Tasks UI** | New `EventsView.js` (Events/Tasks tabs, vCenter-card layout, filters, search); task detail reuse `JobThread`; `Shell` VIEWS entry; `NotifyBell` click → deep-link to event/task. | Clicking a bell notification opens the matching event + its task log. |
| **P2 — Users + RBAC** | `users` table + seed; `auth.login` reads table; `auth.requireRole`/`can` helper; role annotations on routes; `/api/users` CRUD. | Viewer can read, operator can deploy, admin-only user/settings management enforced server-side. |
| **P3 — Settings UI** | `SettingsView.js` (Users/Roles/Alerting tabs); `api.js` helpers; Shell VIEWS entry + gear icon in top bar. | Users manageable from UI; role changes take effect on next login. |
| **P4 — Alerting engine + SMTP** | `settings.alerting` read by `alerts.js`; `mailer.js` (nodemailer); delivery status columns; test-email route; Alerting tab wired. | Configured SMTP delivers; bell still works with SMTP off. |
| **P5 — Hardening + docs** | last-admin guard, rate limits on users/settings, secret handling for SMTP password (write via secrets pattern, never echo), SKILL.md traps update. | Full regression pass; doc updated. |

Dependencies: P2 (users table) is a prerequisite for role-gating P3/P4 routes;
P0/P1 are independent of P2–P4.

---

## 6. Risks & gotchas (from accumulated SKILL notes)

1. **style prop object only** — new views: never `style="..."`.
2. **`getMonitor()` unwrap** — Events cards fetch per-vCenter like Monitor.js
   (independent load/error per card, 30s interval).
3. **`.cache` root-owned** — do NOT store ledger/alerts in repo `.cache`; use
   SQLite in `config.dataDir` (`/app/data/webui.db`), already the jobs home.
4. **nginx `/api/` must stay `^~`** — new routes are under `/api/`; never
   regress the nginx location (403 on `.tfvars` again otherwise).
5. **govc/sudo + SOPS_AGE_KEY_FILE** — events/tasks that trigger live power
   queries must pass `HOME` tempdir + `SOPS_AGE_KEY_FILE` (already in
   `runGovc`/`liveVms`).
6. **ANSI strip + NO_COLOR** — task log rendering must reuse `clean()` +
   `NO_COLOR=1` pattern from JobThread/Jobs.
7. **Single-file workspace rule** — opening a task/event detail in the thread
   must dedupe (reuse `openObject` same-identity replace).
8. **Do not overwrite admin password** — user seed reads `WEBUI_PASS_HASH`
   only at bootstrap; never re-seed over existing `users` rows.
9. **SMTP secrets** — never log password; store in `settings` value but mask in
   GET responses (return `smtp_password_set: true`).
10. **Last-admin guard** — refuse delete/disable of the final `admin`.

---

## 7. Files touched

```
server/src/db.js        events + users + settings tables; jobs target cols
server/src/alerts.js    → SQLite ledger; config-driven thresholds; delivery status
server/src/auth.js      users lookup + requireRole/can helpers
server/src/mailer.js    NEW — nodemailer send + delivery status
server/src/index.js     /api/events /api/tasks /api/users /api/settings routes + RBAC
frontend/js/views/EventsView.js   NEW — Events/Tasks drill-down
frontend/js/views/SettingsView.js NEW — Users/Roles/Alerting
frontend/js/views/Shell.js        VIEWS entry (events, settings) + deep-link wiring
frontend/js/views/NotifyBell.js   click → runNav("events") + open target
frontend/js/api.js                getEvents/getTasks/getUsers/settings helpers
frontend/css/views.css, shell.css new panel styles
docs/ this file
```

## 8. Docker rebuild + verify

```bash
cd /opt/terraform-lab/projects/VMPilot/vmpilot-webui
node --input-type=module --check < frontend/js/views/<view>.js
docker compose --profile nginx up -d --build        # server + web
curl -sk https://127.0.0.1/js/views/EventsView.js | grep "<marker>"
# API smoke through nginx with a fresh JWT (config.secret, iss/aud vmpilot-webui):
#   /api/events /api/tasks /api/users /api/settings/alerting
# regression: /api/configs/*.tfvars must stay 200 (nginx ^~ intact)
```