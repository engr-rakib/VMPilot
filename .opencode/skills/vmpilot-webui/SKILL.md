---
name: vmpilot-webui
description: Use when editing the VMPilot WebUI (vmpilot-webui/frontend React views, server API/routes, or rebuilding Docker). Covers the no-build ESM + htm stack, the Vue-tree/Shell layout, view file-signatures, and the gotchas that keep coming back (React async useEffect, literal &lt;entity&gt; rendering, Target-fieldset design, job/socket contracts, nginx bake/verify loop).
---

# VMPilot WebUI — working notes

> **Communication rule:** User replies in Banglish (Bangla grammar/words written in Latin script, e.g. "kore", "bolo", "... thakbe"). ALWAYS reply in Banglish, NEVER in Bangla Unicode/Bengali font — user's terminal does not render Bangla characters. Keep it natural: e.g. "Ekhon server rebuild korechi, 429 ar asbe na — browser e hard refresh (Ctrl+Shift+R) diye dekho."

Everything lives in `/opt/terraform-lab/projects/VMPilot/vmpilot-webui`. No build
step: React + htm(html tag) are UMD/vender files; views are native ESM modules on
`/js/views/`. This note is the accumulated "recurring traps" list so they do not
get rediscovered every session.

## Stack & layout (never change these)

- `frontend/index.html` loads vendor UMD (react, react-dom, socket.io, xterm),
  then `<script type="module" src="/js/app.js">` (ESM entry).
- Views: `frontend/js/views/*.js`, each `export default function(...)` returning
  `html\`...\`` (htm tagged template). Import helpers from `/js/core.js`
  (`html, useState, useEffect, useRef, useCallback, useMemo, nextId`) and API
  wrappers from `/js/api.js`.
- `Shell.js` owns: left explorer tree (Config Inventory, VS Code selection
  context `sel`), `wizard` (vc/vm forms), `thread` (opened object cards), nav
  views, command bar.
- User's mental model: LEFT = `deploy/` VM-config tree (vCenter → env → VM);
  RIGHT = `secure/<vc>/` object views. vCenter add is a ONE-TIME setup job; the
  MAIN user task is deploy a VM.
- Monitor > everything. Fix/verify dashboard/monitor first.

## Recurring traps (READ BEFORE EDITING)

0. **Blank screen = null deref in a freshly-mounted view.** When a view starts
   with `useState(null)` (e.g. ConsoleView `live` stats, Monitor `trends`) and
   the JSX touches `live.cpuPct` / `pts("cpu")` BEFORE the async fetch resolves,
   React throws → whole card/page goes blank (user sees "nothing appears").
   ALWAYS guard with `${live ? html\`…\` : html\`…\`}` or `x?.y` in the template —
   never reference a nullable field directly inside `html\`…\``. CRITICAL
   SUB-RULE: when you ADD a new stat line (e.g. Net) to a guard-gated block,
   the new line MUST go INSIDE the same `${live ? html\`…\`}` — putting it after
   the closing backtick + `}` (as happened with `netKBps` in the console
   footer) silently re-introduces the null crash and the console goes blank.
   Every field touched in the template must live behind the guard that gates
   its parent block. This is the #1 "screen kicu asche na" cause; check it
   FIRST when a view renders blank.
1. **async fn in useEffect → Promise cleanup crash.** Passing `(async () => …)`
   directly as the effect callback makes React treat the returned Promise as a
   cleanup destroy → `TypeError: c is not a function` on unmount (seen in
   Dashboard). ALWAYS wrap: `useEffect(() => { load(); }, [load])`.
2. **htm text does NOT decode HTML entities.** `&lt;name&gt;` inside `html\`…\``
   renders as the literal text `&lt;name&gt;`. To show `<name>` in a template,
   build it as a JS string and interpolate (e.g. `${"vm-<name>_<ip>.tfvars"}`).
   `<`/`>` only works via interpolation or as real tags.
3. **Target (vCenter/environment) must be a proper card.** In `VmConfigForm.js`
   the target picker lives INSIDE the `<form className="wizard-form"><div className="wizard-grid">`
   as the first `<fieldset className="target-fieldset">` (styled in
   `css/views.css`: accent border + subtle gradient). It must sit in the same
   grid as Identity/Network/Compute — never its own standalone `.wizard-grid`,
   and never manual-only: tree selection in Shell pre-fills `initial={vc, env}`.
   - env folder selected → fieldset hidden, `target-hint` row shows
     `● target will be created as deploy/<vc>/<env>/vm-<name>_<ip>.tfvars`
     (hint = flex row with gap, real `<name>` interpolated).
   - only vCenter selected → show ONLY the Environment `<select>` (vc locked).
   - nothing selected → show vCenter + Environment selects (catalog prop).
4. **Current selection drives the wizard.** Tree-item clicks call `setSel({vc,env})`
   BEFORE `openVc/openEnv/openVm`. `+ New config` (tree-head, NOT top-right)
   passes `initial: { vc: sel.vc, env: sel.env }`. No "All VMs (N)" root node —
   tree is direct vCenter → env → VM like VS Code file explorer.
5. **`style` prop MUST be an object, NEVER a string.** `style="align-items:center"` in
   htm passes a string → React invariant error #62 ("style prop expects a mapping…
   not a string"), blank screen on that view render (seen in VmPanel deploy tab — TWO
   offenders: `<div className="row" style="...">` AND `<h3 style="margin:0">`). Always
   `style=${{ alignItems: "center", gap: 10 }}`. Before rebuild, grep for remaining
   string styles: `grep -rn 'style="' frontend/js/views/*.js` (must be empty).
6. **`getMonitor()` returns `{generated_at, vcenters}`, NOT a bare array.**
   `getMonitor().then(setMonitor)` then iterating `for (const vc of monitor || [])`
   throws "TypeError: (monitor || []) is not iterable". Must unwrap:
   `getMonitor().then((m) => setMonitor(Array.isArray(m?.vcenters) ? m.vcenters : []))`.
7. **`vm.summary.power` is NEVER populated** — `summarizeVmConfig()` in
   `server/src/catalog.js` has no power field, so the config tree always showed ⚪/none.
   For live/deployed tree marking fetch the **monitor snapshot** (`getMonitor()`) and
   build a `liveMap` keyed `${vc}/${env}/${file}` from `vcenter.envs[].vms[]` (each vm
   carries `{file, power, ip}`; power ∈ poweredOn/poweredOff/notDeployed). Header fleet
   pill count also from that map, not `vm.summary.power`.
8. **nginx denies `.tfvars` paths → API 403.** nginx.conf has
   `location ~* \.(env|htpasswd|pem|key|crt|tfvars|tf)$ { deny all; }` (regex beats
   non-`^~` prefix matches) → `GET /api/configs/…/vm-…_<ip>.tfvars` returned 403 even
   with auth. Fix (already applied): `/api/` proxy must be `location ^~ /api/ { … }`
   so the exact-prefix proxy wins over the file-denial regex. Keep it `^~` — changing
   it back re-breaks config loading.
9. **Container needs `SOPS_AGE_KEY_FILE`.** `scripts/vcenter-inventory.sh` /
   deploy-sync call bare `sops --decrypt`, which looks for the age key at
   `$HOME/.config/sops/age/keys.txt` — that EXISTS on the host but NOT in the server
   container (only `/vmpilot/sops-age/keys.txt` is mounted). Result: `/api/monitor/live`
   → 502 "no usable credentials". `monitor.js liveVms()` now passes
   `env.SOPS_AGE_KEY_FILE = vmpilotDir/sops-age/keys.txt`. `executor.js` already did
   this; check any new code path that runs the CLI scripts via sudo.
10. **Single-file workspace rule:** `openVm()` in Shell REPLACES existing `vm` cards
    (`setThread(t => [...t.filter(c => c.kind !== "vm"), card])`) so clicking configs
    in the tree doesn't stack stale cards. vc/env/job/secure cards still stack.
11. **Redeploy guard + inline job console:** VmPanel deploy tab guards re-deploy of an
    already-deployed VM (typed-name to arm, `redeployName === key`); live job output
    renders inline via `<JobThread job={activeJob}/>` (socket stream, phase stepper
    Queued→Config→Plan→Apply→Done + animated % bar). Phase detection regexes live in
    `JobThread.js` PHASES. Don't regress the guard: `alreadyDeployed = power in
    (poweredOn, poweredOff)`.
12. **ANSI escape codes in job output.** Terraform/CLI emit `\x1b[1m`, `\x1b[33m`, … even
    with `TERM=dumb`. Strip in the FRONTEND before rendering (`clean()` helper in both
    `JobThread.js` and `Jobs.js`: `ANSI_RE = /[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g`
    + collapse `\n{3,}`), AND set `NO_COLOR=1` in `executor.js runScriptJob()` spawn env
    so the raw job log is clean too. Apply `clean()` on both the polled chunk AND the
    socket line.
13. **govc session cache permission denied.** govc writes a session cache under
    `$HOME/.govmomi/sessions`. The container user (uid 1000) may have a root-owned home
    (sudo-run jobs wrote there) → `govc: open /home/vmpilot/.govmomi/sessions/…:
    permission denied` on Power on/off. `GOVMOMI_HOME` is NOT a real govc env var —
    must set `HOME` to a fresh writable temp dir per run in `runGovc()` (executor.js).
    Verified: read-only `govc vm.info -json myvm` + session write succeeds with the
    override.
14. **Power is idempotent / stale live cache.** govc fails
    "The attempted operation cannot be performed in the current state (Powered off/on)"
    when the VM is already in the desired state — the inventory script's ~11s live
    cache can be stale vs. reality. `vmPower()` treats that message as success
    (`already:true`); VmPanel re-fetches live VMs ~12s after a power op so the button
    flips correctly.
15. **Monitor snapshot carries hosts + datastores (drill-down).** `monitorVc()`
    (server/src/monitor.js) now also returns `hosts[]` (live ESXi hosts from
    `vcenter-inventory.sh … live hosts`: `{name, ip, datastores[], cpuCores, cpuMhz,
    memoryMB, cpuUsageMHz, memUsageMB}`) and `datastores[]` (`{name, capacity, free}`,
    bytes). The full snapshot ALSO embeds live VM usage per config vm
    (`vm.live.{cpuUsageMHz,memUsageMB}` + `vm.power`) so Monitor.js renders host CPU/RAM
    bars, datastore %used bars and per-VM live CPU/RAM without extra calls. The
    fallback (`.catch`) shape in `monitorSnapshot` must stay key-compatible
    (`hosts: []`, `datastores: []`).
16. **govc host/datastore JSON gotchas (live hosts).** `govc host.info -json` returns
    key `hostSystems` (NOT `hosts`); `govc find . -type h -type s` under GOVC_DATACENTER
    returns RELATIVE paths (`./host/…`) that break `host.info` — the script normalizes
    to absolute (`H_BASE="/$GOVC_DATACENTER"` + sed) before batching. Host name parsed
    with `cut -d'|' -f1` (NOT `sed 's/.*|//'` — that grabs the last path field).
    Datastore free space: `govc datastore.info -json` → `capacity`/`free` bytes; sum for
    aggregate bars. Cache: `.cache/live-<vc>-hosts.json` is ROOT-OWNED after sudo runs
    → `docker exec … sudo -n rm -f` before re-testing, and the server must run the
    script via `sudo -n -E bash` with `SOPS_AGE_KEY_FILE` (trap 9).
17. **Alerts store = server data dir, NOT repo .cache.** `/vmpilot/.cache` is root-owned
    in the lab container → uid-1000 server can't write `webui-alerts.json` there
    (silent no-op via try/catch). `server/src/alerts.js` stores under `config.dataDir`
    (`/app/data/webui-alerts.json`, writable `vmpilot:node`). API: `GET /api/alerts`,
    `GET /api/alerts/unseen`, `POST /api/alerts/seen {ids}`, `DELETE /api/alerts`.
    Resource alerts are deduped per vc/env/vm+kind+severity (evaluated on `/api/monitor`
    poll); event alerts (power + job start) are NOT deduped. Frontend:
    `frontend/js/views/NotifyBell.js` (bell + dropdown, 12s unseen poll, marks-seen on
    open).
18. **Events & Tasks ledger is SQLite, not JSON.** db.js `events` table (`kind/severity/
    vc/env/vm/label/value/task_id/at/seen/notified/notify_error`), `users`, `settings`.
    API: `GET /api/events`, `/api/events/:id`, `/api/events/summary`, `GET /api/tasks`,
    `/api/tasks/:id`. Event `at` is EPOCH MS (JSON file used ISO strings) — `timeAgo`
    must use `new Date(number)` (works for both). `jobs` table gained `target_vc/env/vm`
    (set in the POST /api/jobs route from params.vcenter/env/vm_name, NOT inside
    createJob). Job-started/power alerts carry `task_id` for notification deep-links:
    NotifyBell click → Shell `openTask(id)` → opens a `task` thread card that fetches
    `/api/tasks/:id` and renders `<JobThread job={task}>`.
19. **RBAC: users table + role-gated routes.** `auth.js` got `useUserStore(makeUserStore(db))`
    (seeded in index.js only when `users.count()==0`: admin from WEBUI_USER/PASS_HASH +
    demo `viewer`/`viewer123`). `login()` checks the users table FIRST (config only as
    bootstrap fallback), token sub = username, role in token (role changes need
    re-login). `auth.requireRole("viewer"|"operator"|"admin")` middleware goes AFTER
    `requireAuth` on write routes: POST /api/jobs + /api/vms/power need "operator";
    /api/users + /api/settings/alerting need "admin"; GETs stay viewer. Last-admin
    guard: never demote/disable/delete the final `admin` (countRole("admin")<=1).
    Frontend: `SettingsView.js` (Users/Roles/Alerting tabs), Shell fetches `me()`
    (`/api/auth/me` → `{user, role}`) for the role pill + admin gating.
20. **Alerting settings + SMTP.** `alerts.getConfig()/setConfig()` read/write the
    `alerting` JSON in the `settings` table (thresholds cpu/mem warn 85 crit 95,
    resource_enabled/event_enabled, delivery bell|email|both, smtp{host,port,secure,
   user,password,from,to}). GET /api/settings/alerting MASKS the password (`__set__`);
    PUT preserves existing password when blank is sent. SMTP delivery via
    `server/src/mailer.js` (nodemailer — add to server/package.json + npm install +
    REBUILD server image; node_modules is root-owned, `npm ci` runs at build). Test
    email: POST /api/settings/alerting/test. Delivery status on `events.notified/
    notify_error`. No SMTP configured → sends are no-ops, bell still works.
21. **RBAC is permission-based now (not fixed roles).** `auth.js` defines the
    PERMISSION catalogue (`view, deploy, config.write, terminal, users.manage,
    settings.manage`) + BUILTIN_ROLES (viewer=[view], operator=[view,deploy,
    config.write,terminal], admin=[all]). db.js `roles` table + `makeRoleStore`
    (create/get/list/update/delete/permissionsOf) wired in index.js with idempotent
    `seedRoles()`. Gate writes with `auth.requirePerm("deploy")` (jobs + vms/power),
    `"users.manage"` (users + roles CRUD), `"settings.manage"` (alerting PUT/test);
    `auth.requireRole()` is only an ALIAS now. Roles CRUD: `POST /api/roles`,
    `PUT/DELETE /api/roles/:name` — built-in roles are undeletable; deleting a custom
    role reassigns its users → viewer (`reassigned` count in response). `/api/auth/me`
    → `{user, role, permissions[]}`; frontend gates UI on `me.permissions` (viewer sees
    read-only Settings, no edit controls). Custom roles in the Users tab's role
    `<select>` show as `name (custom)`. JWT role lives in the token → changing a user's
    role requires re-login to take effect.
22. **Settings/Logout live in a vCenter-style user menu (top-right), NOT the left
    nav — and it MUST use existing design tokens.** Shell.js `VIEWS` has NO settings
    entry; `runNav("settings")` still renders `<SettingsView>` via the `nav ===
    "settings"` branch. The trigger is a **`.ghost` button** (like the setup chip /
    notify bell), NOT a circular avatar: `👤 username · role ▾` (`.user-menu-trigger`
    + `.user-menu-name/.user-menu-caret` in shell.css). The dropdown is a
    `.notify-drop`-style panel (`.user-drop`: panel bg, 1px border, radius 10, shadow,
    padding 4) with a head (user + "signed in · role") and `.user-drop-item` rows
    (Settings ⚙, Logout ⏻ danger). Escape key + outside-click both close it. **Don't
    invent new UI primitives** — reuse `.card`, `.pill`, `.mini-table`,
    `button.ghost/primary/mini`, `.settings-grid`/`.settings-field`, `.checkline`,
    `.mini-select`/`.mini-input` (views.css) for any new admin UI. The Roles tab in
    SettingsView renders each role as a `.card.role-card` with `.checkline`
    permission checkboxes (grid via `.role-perms`), and the create-role form uses
    `.settings-grid` + `.settings-field` — NOT custom `.role-block`/`.perm-chip`
    styles (removed 2026-08-17). The Users tab keeps `.mini-table` + `.mini-select`
    role dropdowns + per-user "reset pw" inline input (`.mini-input`).
23. **Dashboard/Monitor auto-refresh MUST be stale-while-revalidate, never
    blank-to-"loading".** Both views poll `getMonitorVc(vc)` every 30s via
    `loadOne`/`loadAll`. The naive pattern (`setCards({[vc]: {state:"load"}})` at the
    start of every refresh) makes the page FLICKER: every 30s all cards reset to the
    loading skeleton, stats/charts/VM tables vanish, then data reappears. Correct
    pattern (Dashboard.js + Monitor.js): in `loadOne`, if `cards[vc]` already has
    `data`, set `refreshing: true` (keep the old card rendered) and only swap in the
    new payload on resolve; a fresh "loading" skeleton is seeded ONLY for vCenters
    never loaded yet (seed inside `load()` only when `!c[vc]`). On a background
    refresh failure, `patchErr` keeps the last good data with an error note instead
    of blanking.     Surface sync via a small "syncing…" spinner in the page-head next to
    Refresh (and a per-card inline spinner in Monitor's h3). `readyVcs` = cards with
    `state==="ok" && data` (not just `state==="ok"`). Header uniform-height rule
    (`.shell-top-right button.ghost`) also needs `margin-left:auto` on
    `.shell-top-right` so right-side controls hug the edge when `.shell-search` caps
    at `max-width:480px`. **Both views also remount on every nav switch** (Shell
    renders the active view via a `nav === "dashboard" ? <Dashboard/> : …` ternary —
    switching views UNMOUNTS them, wiping local state) AND lose state on browser
    reload. Fix: a **module-level `cardCache` + sessionStorage** (`vmp_dash_cache` /
    `vmp_mon_cache`): `useState` seed reads the cache so a remount/reload restores
    the last data instantly (never a full-page "collecting…"/"querying vCenters…"),
    and each successful `getMonitorVc` writes back to cache + sessionStorage. On
    first-ever load (no cache) the skeleton is seeded only after `listMonitorVcs`
    resolves.
24. **Wide `.mini-table`s MUST fit the card — fixed layout, NEVER `width: max-content`.** 
    The Monitor VM table has 13 columns (VM/IP/vCPU/RAM/OS disk/OS parts/Data disk/
    LVM vols/Users/node_exp/Live CPU/Live RAM/Power) with MiniBars. Originally we
    wrapped it in `.table-scroll { overflow-x: auto }` with `.mini-table { width:
    max-content }` so the table scrolled inside the card. BAD: with `max-content`
    the table is as wide as its WIDEST content, so prod (long VM names / long
    `extra_users` strings / many LVM vols) got wider than dev → a horizontal
    scrollbar appeared in prod but not dev (the "why does prod scroll?" bug,
    2026-08-17). Rule: every table in `.table-scroll` / `.mini-table-wrap` uses
    `width: 100%; table-layout: fixed` + an explicit `<colgroup>` whose `<col
    style={{width:"N%"}}/>` widths SUM TO 100, so the table is EXACTLY the card
    width regardless of content. Long text gets an ellipsis via
    `.table-scroll .mini-table th,td { overflow:hidden; text-overflow:ellipsis;
    white-space:nowrap }`. MiniBars inside fixed tables get compacted
    (`.table-scroll .minibar-label { display:none }`, track `flex:1 1 auto;
    min-width:18px`, value `flex:0 0 auto`) so they fit narrow cells. If you add
    a column, you MUST add/adjust a `<colgroup>` entry so the widths still sum to
    100 — otherwise `table-layout:fixed` distributes remaining space evenly and
    the layout looks wrong. Never re-introduce `max-content` for these tables.
25. **Monitor data shape + the ops endpoints added 2026-08-17.** Each host row now
    carries `powerState`, `connectionState`, `overallStatus`, `netKBps`, `diskKBps`
    (net/disk from a batched `govc metric.sample -n 1`), plus the existing
    `cpuCores/cpuMhz/memoryMB/cpuUsageMHz/memUsageMB/networks/datastores`. VM live
    rows carry `toolsStatus` (`$s.guest.toolsStatus`) and `os` (guestFullName).
    These come from `scripts/vcenter-inventory.sh live vms|hosts|datastores`
    (project root, NOT vmpilot-webui). Time-series: SQLite `samples` table
    (db.js `makeSampleStore`), appended on every `/api/monitor` poll via
    `monitor.collectSamples` (kinds `host_cpu|host_mem|host_net|host_disk|ds_used`,
    pruned to 24h). New endpoints: `GET /api/monitor/trends?vc&kind&entity&hours`
    (MUST be declared BEFORE `/api/monitor/:vc` or "trends" is captured as a
    vCenter name) and `GET /api/jobs/operators` (deploy count per operator + their
    VMs; falls back to `params` for pre-target-column jobs). alerts.js gained
    `disk_warn/disk_crit` (datastore % used) + `host_down_enabled` (power/conn
    state) checks. Dashboard panels: System health (alerts ledger + host-down
    pills), Datastore capacity (HBars by used%), Host utilization (table with
    MiniBars + Net/Disk IO + state), Network portgroups, Operator activity
    (clickable rows → VM list), Live vs configured (Sparkline), Latest VM table
    has a Guest OS column. SettingsView Alerting tab has the disk/host-down toggles.
26. **MANDATORY: behavior / use-case / lifecycle analysis BEFORE implementing a
    feature — never ship a half-feature.** The dashboard "compact MiniBar" change
    hid labels via `.table-scroll .minibar-label { display:none }` and only kept a
    hover `title` — the feature ("see what this bar measures") was DISABLED with no
    visible restore path (the 2026-08-18 "enable" gap). Before you write any code,
    trace the FULL behavior matrix and state it in your reply:
    - **On/Off both ways:** if you add a disable/hide/remove path, the ENABLE/show/
      restore path MUST exist in the same change. Every toggle is bidirectional.
    - **Lifecycle:** mount → data loaded → background refresh → refresh fails →
      nav-switch away/back → full page reload → component unmount. Data must not
      blank out at any point (stale-while-revalidate, cache in sessionStorage).
    - **Empty & error:** no-data placeholder, fetch failure keeps last-good data,
      Retry button, permission-denied ("unauthorized") handling.
    - **Responsive:** widest + narrowest content (dev vs prod!), smallest viewport,
      narrowest card. No horizontal scrollbar, no clipped text without ellipsis.
    - **Long text:** what happens to VM names / extra_users / LVM vols that are
      longer than their column — always ellipsis + `title` tooltip.
    - **Numeric edge:** 0 / undefined / null / NaN (e.g. `cpuUsageMHz` missing when
      powered off) must render "—" not "NaN" or a 0-width bar.
    Present this analysis in your reply BEFORE editing, then implement. If you
    realize mid-implementation that a branch (e.g. restore/enable) is missing, STOP
    and add it — do not merge a one-way feature. Also AUDIT pre-existing
    features for one-way paths before touching them (the 2026-08-18 session
    discovered the `minibar-label{display:none}` hide-without-restore AND the
    server-side alert threshold bug where `disk_warn:0`/NaN/`''` made EVERY
    datastore fire "Datastore full"). Rule: any numeric setting the user can
    blank must be sanitized server-side (alerts.setConfig guards 0/NaN/>100 → keep
    default), and any CSS `display:none` that drops a label must instead ellipsize
    (`.minibar-label{flex:0 1 auto;overflow:hidden;text-overflow:ellipsis}`) so the
    meaning stays visible when there is room.

27. **Persistent data layout + keep the project clean.** The app DB (users/jobs/
    events/samples/settings) lives in ONE place: SQLite at
    `vmpilot-webui/data/db/webui.db` (host) ⇄ `/app/data/db/webui.db` (container)
    via the `./data:/app/data` bind mount in docker-compose.yml. The server opens
    it with `openDb(path.join(config.dataDir,"db"))` where `WEBUI_DATA_DIR=/app/data`.
    This mount is what makes the DB SURVIVE `docker compose up -d --build` (a plain
    container rebuild would otherwise wipe it). Rules:
    - NEVER let the app write DB/job files anywhere outside `./data` — everything
      under `data/` (db, jobs logs, .cache) is host-persistent AND gitignored
      (project root `.gitignore:79` = `vmpilot-webui/data/`).
    - If you ever need a separate DB server / object storage / mount point, it must
      be configured through `WEBUI_DATA_DIR` (or a new env), never hard-coded —
      keep `openDb(dataDir)` the single dependency so storage can be swapped
      without touching code.
    - Remove leftover/duplicate files that nothing references. On 2026-08-18 the
      `data/` dir had THREE stale artifacts next to the live DB:
      `data/webui.db` (0-byte), `data/webui/webui.db` (old jobs-only schema) and
      `data/webui-alerts.json` (pre-SQLite JSON alerts dump). None was referenced
      by `server/src` (the only DB open is `path.join(dataDir,"webui.db")`) — they
      were deleted (backed up to /tmp first). Before deleting anything: grep the
      codebase for the filename, confirm it's not the live `data/db/webui.db`, then
      remove. Unreferenced stray files cause "which one is real?" confusion later.
    - **Git visibility (two-repo policy):** `vmpilot-webui/data/` is gitignored
      from the PUBLIC repo (project-root `.gitignore:79`), but the INTERNAL repo
      (`private`/VMPilot-internal) backs up the FULL project INCLUDING
      `vmpilot-webui/data/` via `github/vmpilot-sync.sh` (`git add -f ...
      vmpilot-webui/data`) and `github/backup-and-sync.md`. If you ever touch
      `.gitignore` or the sync script, keep BOTH sides in sync — public exclusion
      AND private `git add -f` list must include `vmpilot-webui/data/`.
28. **The "Jobs" sidebar view was REMOVED — jobs are unified into Events.**
    On 2026-08-18 the user asked to drop the Jobs button and have ALL activity
    (jobs, tasks, logs, events, notifications, alerts) tracked from the Events
    page. What changed: `Shell.js` `VIEWS` no longer has `jobs` (sidebar icons:
    dashboard/monitor/events/backups/terminal), the `nav === "jobs"` render
    branch and the "Open Jobs" fallback button are gone, and `frontend/js/views/
    Jobs.js` was DELETED (grep-verified unreferenced — `JobThread.js` still exists
    and is the per-job log card in the Shell thread). EventsView.js is now the
    unified "Events & Activity" page: top **overview card row** (`.ev-overview`/
    `.ev-card` in views.css) with critical/warn/unseen counts + task totals/
    success/failed/running — each card is FUNCTIONAL: click sets the tab+filter
    AND toggles an expandable preview panel (`.ev-preview`) of matching recent
    rows; clicking a preview/table row opens the detailed job log via `onOpen`
    (→ Shell `openTask` → `JobThread`). Live job socket streaming still works via
    JobThread's `/jobs` namespace. If you re-add a jobs view, remember the
    contract: tasks = jobs table, rows open JobThread by id.

29. **Events page = vCenter-style category tabs + cross-linked rows; VM monitor
    panels; SSH console button.** On 2026-08-18 the Events page was redesigned
    from an overview-card layout to **category tabs** (user disliked the cards):
    `Summary` (stat chips + merged latest-activity feed), `Notifications`
    (critical/warn, unseen-highlighted rows `.dot.danger` + "Mark all seen" →
    `POST /api/events/seen`), `Events`, `Tasks`, `Jobs` (listJobs), `System`
    (system+resource kinds). All newest-first. **Cross-linking:** every row has
    up to two action buttons — `→ cfg` opens that VM's CONFIG via
    `resolveVm(vc, vmName)` (Shell builds a `vc\u0000name → {vc,env,file}` map
    from `catalog`; event rows carry only the VM name, no file) + `onOpenVm`
    (openVm); `log` opens the job log via `onOpen`→openTask→JobThread. Event
    rows NO LONGER open a log on row-click — the buttons are explicit (both a
    cfg and a log link can coexist on one row).
    **Monitor VM rows:** now a `VmRow` component — ▸ chevron (stopPropagation!)
    expands an inline panel with 24h CPU/RAM Sparklines (`vm_cpu`/`vm_mem`
    trend kinds) + recent events for that VM; row click still opens VM config.
    New **Console** column after Power: `onConsole(ip)` → Shell `openConsole`
    → `openObject("console",{vm,user})` → `ConsoleView.js` (xterm over the
    `/console` socket). Server `terminal.js` `attachConsole` spawns
    `ssh -i <sshKeyPath> -o StrictHostKeyChecking=no <user>@<ip>`. SSH key:
    container reads `/app/data/ssh/id_ed25519` (= project key, host
    `~/.ssh/id_ed25519`, verified exact match to tfvars `ssh_public_key`;
    cloud-init puts it on the `ubuntu` user + default user with NOPASSWD sudo —
    so console user default is `ubuntu`, extra_users are password-only and CAN'T
    be used). Server trend kinds: `host_cpu|host_mem|host_net|host_disk|ds_used|
    vm_cpu|vm_mem` (no per-VM net — vCenter perf counters not enabled). If you
    change `openObject`'s identity `same()` check, keep `vm`/`user` in it so two
    consoles to different VMs don't collapse into one card.
- **Console typing GOTCHA (fixed):** server `attachConsole` MUST have
  `socket.on("input")` + `socket.on("resize")` handlers wiring into the SSH pty
  (mirror `attachTerminal`). Without them the xterm emits `input` but the pty
  never receives keys → "can't type anything". Console socket contract:
  `ready {vm,user}` / `data <bytes>` / `input <str>` / `resize {cols,rows}` /
  `exit {code}`.
- **Console = MobaXterm-style PiP card** (`ConsoleView.js`): header shows VM
  name + `user@ip` + status pill; ⛶ button pins it to a floating pill
  (bottom-right); **footer stats bar** (`console-stats`) polls `getLiveVms(vc)`
  every 10s → CPU% / RAM% (+ used/total G) / Disk (configured) / Net (always "—",
  no vCenter perf counters). `openConsole` passes FULL vm obj from Monitor
  (`{ip,name,vc}`) — Shell maps to `openObject("console",{vm:ip,name,vc,user})`.
  Keep `vc` in the card so ConsoleView can poll live stats.
- **Power menu = hover menu on the `on` pill, NOT a <select>:** custom
  `position:fixed` dropdown (`PowerMenu`) because absolute/relative menus get
  clipped by `.mon-sec`/`.table-scroll`/`td` overflow:hidden (a fixed menu is
  viewport-relative and only clipped if an ancestor has transform/filter — none
  do). `off` pill is a click → power on. Menu items are COLOR-CODED by action
  (small 11px font): Restart=accent2, Graceful shutdown=warn, Power off=#fb923c,
  Force power off=danger. Server `vmPower` actions: on/off/forceoff/reset/
  reboot/shutdown (govc `-off -force` / `-reset` / `-reboot` / `-shutdown`).
- **Monitor page = per-VC card with 2 collapsible sections** (`VcCard` hooks
  component — was plain `vcCard()`, MUST stay a component now that it owns
  `infraOpen`/`vmsOpen`/`powerBusy` state; render via `<${VcCard} …/>`). Section 1
  "Infrastructure" = Hosts + Datastores tables, collapsed summary shows
  `N hosts · M datastores · X% disk used`. Section 2 "VM Environments" = per-env
  VM tables, collapsed summary shows `on/off/pending` pills + env count; the
  **filter chips now live INSIDE this section** (passed `filter`/`setFilter` from
  Monitor) — `All VMs|Powered on|Powered off|Not deployed|Deployed` — and filter
  VM rows only (`power` values: `poweredOn|poweredOff|notDeployed|unknown|pending`).
   Each env is a **sub-header** (`.env-label`, left = env pill + count, right =
   `.env-summary` on/off/pending pills). VM table is a SLIM 7-column layout
   (`▸ VM IP vCPU RAM Disk Power`); live CPU/RAM utilization is shown INLINE in
   the vCPU/RAM cells (`2c (2%)`, red >85%) — there is NO separate Live CPU/Live
   RAM column. **Row click toggles the expanded detail** (24h trends + events);
   ONLY the 🖥 button opens the console. Disk cell = `used/cap GB (pct%)` +
   mini bar (used from inventory `diskUsedGB` = `summary.storage.committed`).
  data disks, LVM vols, users, node_exporter) moved into the expanded VmRow
  panel as a `.vm-meta` single-line ellipsis. Cropping rule still applies: keep
  colgroup widths summing to 100%, never add a 15th col back to the VM table.

30. **Events resource rows: the action cell must MATCH the target — a VM config
    file can't help a host alert.** The old `evActions` showed `→ cfg` whenever
    `e.vm && resolveVm && onOpenVm` — that checks the FUNCTION exists, not that
    it RESOLVES. For a `Host RAM 87%` alert, `vm` = the HOST name → `resolveVm`
    returned `null` → button rendered but click was a silent no-op (the 2026-08-20
    "cfg ki help korbe?" bug). Now target-matched (alerts.js labels classify by
    prefix: `Host ` / `Datastore` / `VM `|`Guest `):
    - job row (`task_id`) → `▸ log` inline expand (never navigate away).
    - `Host *` → `→ host` → `onHost(vc, vm)` → Shell `setNav("monitor")` +
      `setMonitorFocus({vc, host, ts})`.
    - `Datastore *` → `→ vCenter` → `onVc(vc)` → monitor focus `{vc, vm:"", host:""}`
      (scrolls to that vCenter card — datastore capacity bars live there).
    - VM row → `→ cfg` ONLY when `resolveVm(e.vc, e.vm)` is TRUTHY (result check,
      not function check).
    Suggestion + duration come from the SHARED module `frontend/js/alerts-util.js`
    (`highFor(e)` = "alerting for 25m" from event `at`; `alertSuggest(e)` = label +
    severity → actionable text; `suggestLine(e)` returns htm NODES so it imports
    `html`). EventsView renders it as `.ev-suggest` under the label; NotifyBell as
    `.notify-suggest`. Both surfaces import the same module — NEVER duplicate the
    map inline or the two diverge.
31. **Inventory deep-link focus covers hosts + vCenters (not just VMs), and must
    survive LATE-loaded cards.** Monitor `focus` = `{vc, vm?, host?, ts}`:
    - VM focus → VmRow effect: auto-expand + scroll `[data-vmrow="${CSS.escape(vm.file||vm.name)}"]`.
    - Host focus → VcCard effect (2026-08-20): `setInfraOpen(true)`, flash the row
      via `setHlHost(host)` (`.hl-host` class, 4s auto-clear via setTimeout, cleared
      in the effect cleanup), scroll `[data-hostrow="${CSS.escape(host)}"]`.
    - vCenter-only focus (datastore alerts) → Monitor top-level effect scrolls
      `[data-vccard="${CSS.escape(vc)}"]`.
    RULES: (a) selectors MUST use `CSS.escape` (host/VM names can contain dots/space);
    (b) effect deps = `focus.ts` AND the loaded-count (`hosts.length` / `vcs.length`)
    so a card that mounts AFTER the focus was set still scrolls (nav-switch while
    data loading); (c) openNotify routes by label prefix — Host→host, Datastore→vc,
    VM/Guest→vm — and sets the UNUSED focus fields to `""` so sibling effects don't
    fire; (d) `.hl-host td` flash uses a keyframe + persistent tint that the state
    clears (bidirectional: highlight appears AND disappears).
32. **Events page = ONE uniform table design across every tab + the `.ev-filters`
    flex trap.** All tabs (Summary/Notifications/Events/Tasks/System) share:
    flat `.ev-filters` + `.table-scroll` + `.mini-table` with shared `EVCOLS`
    colgroup (`8/11/30/27/13/11`). NO `.card` panels inside tables. Notifications =
    independent latest-200 list (Events pagination never hides warn/critical);
    unseen = red LEFT-EDGE accent `tr.unseen td:first-child { box-shadow: inset
    3px 0 0 var(--danger) }` — a dot COLUMN created phantom left/right whitespace
    (2026-08-20 fix). `.ev-filters` MUST have `display:flex; align-items:center`
    — `gap:8px` + `margin-left:auto` only work under flex; standalone `.ev-filters`
    (Notifications/System) silently broke without it. Events tab paginates 50/page
    via `offset` in `/api/events` (eventStore.list) + `.ev-pager` Prev/Next; the
    30s poll reads `filterRef` (stale-closure fix) so it never resets page/filter.
    Inline expand = `JobExpand` → `getJob(id)` → `<JobThread>` accordion (no thread
    navigation; workflow stays on the page); bell deep-link `taskDeep` effect dep =
    PRIMITIVE `initial.openTaskId` (an object dep re-fires every render). Root-cause
    trap: `rowToJob` MUST return `output_path` or `/api/jobs/:id/output` 404s → the
    expand shows a stepper but "no output" (2026-08-20 fix).

## PAGE MAP (page-wise blueprint — read before editing any page)

| Page | View file | Backend / API | Feature docs |
|------|-----------|---------------|--------------|
| Shell / Workspace (layout + thread) | `Shell.js` (owns nav, tree, `sel`, `thread`, `monitorFocus`, `taskDeep`, pips) + `app.js` | — | — |
| Dashboard | `Dashboard.js` | `/api/monitor`, `/api/monitor/trends`, `/api/alerts` | events-activity |
| Inventory (Monitor) | `Monitor.js` (VcCard/VmRow/MiniBar) | `/api/monitor/:vc`, `/api/monitor/trends`, `/api/discover`, power via govc | disk-expand (Grow), guest-troubleshoot |
| Events & Activity | `EventsView.js` (+ JobThread, NotifyBell) | `/api/events`, `/api/events/summary`, `/api/tasks`, `/api/jobs` | events-activity, events-workflow |
| Backups | `BackupPanel.js` | `POST /api/jobs` (backup/restore) | events-workflow |
| Terminal / Console | `Terminal.js`, `ConsoleView.js`, `ConsolePip.js`, `PipWindow.js`, `ExpandConsole.js` | socket `/terminal`, `/console` | console-pip |
| Settings | `SettingsView.js` (Users/Roles/Alerting) | `/api/users`, `/api/roles`, `/api/settings/*` | — |
| VM Config Form / vCenter Wizard | `VmConfigForm.js`, `VCenterWizard.js` | `/api/configs`, `/api/vcenters/:vc/options`, `/api/discover`, `findFreeIp` | disk-expand |
| Job log card | `JobThread.js` (embedded in VmPanel + Events inline + thread) | socket `/jobs`, `GET /api/jobs/:id/output` | events-workflow |

Every page keeps a doc under `docs/pages/<page>.md`; every feature under
`docs/features/<feature>.md`; architecture under `docs/technical/`. See
`vmpilot-webui/docs/README.md` for the full index.

## FEATURE DOCS (MANDATORY — before/with ANY feature code)

- **Three doc layers, all kept in sync with the code in the SAME change:**
  1. **Feature docs** — every WebUI feature has **one doc file** at
     `vmpilot-webui/docs/features/<feature>.md` following the template
     `vmpilot-webui/docs/_template-feature.md` (index + rules:
     `vmpilot-webui/docs/README.md`). Sections are fixed: Overview, Features
     (what exists), Case analysis (edge cases), User flow (UI step-by-step),
     Lifecycle, Backend technology & workflow, Verification, Files, Gotchas.
  2. **Page-wise docs** — every UI PAGE keeps a doc at
     `vmpilot-webui/docs/pages/<page>.md` (Shell/Workspace, Dashboard, Inventory,
     Events, Backups, Terminal/Console, Settings, VM Form). One doc per page,
     listing its view file(s), the backend endpoints it calls, its lifecycle
     (SWR cache, 30s polls, deep-links), and the page-specific traps.
  3. **Technical background** — `vmpilot-webui/docs/technical/architecture.md`
     (stack, request lifecycle, realtime, storage), `database.md` (schema +
     API), `build-verify.md` (the bake/verify protocol). Update when the stack /
     DB schema / build flow changes.
- A feature change is NOT done until its doc is updated in the SAME change —
  code + doc land together; stale doc = regression.
- New feature → create `docs/features/<name>.md` from the template AND add an
  index row in `docs/README.md`. Migrate an existing `docs/*-plan.md` into the
  template when you touch that feature (old loose plan files get deleted, back
  up first, grep for references).
- New PAGE or new tech layer → create the doc + add an index row in
  `docs/README.md` (and a PAGE MAP row here in SKILL.md).
- Docs written in Banglish (never Bangla Unicode/Bengali font — see trap 0).

## STALE-CACHE / blank-screen debug protocol (user says "old UI still shows" or "nothing appears")

- **First suspect: nginx `Cache-Control` is `max-age=0, must-revalidate`** (nginx.conf)
  with no-build ESM modules that keep identical filenames. Browsers usually
  revalidate via ETag, but a user who opens a NEW console card / sees a duplicate
  header or old layout is seeing a STALE cached module. Do NOT just tell them to
  hard-refresh — VERIFY the baked file first:
  `docker exec vmpilot-webui-nginx sh -c 'grep -c "your-marker" /usr/share/nginx/html/js/views/X.js'`.
  If the baked file is already correct, the stale UI is a client cache problem →
  tell them to force reload once (Ctrl+Shift+R). If a user reports a UI element
  you believe you deleted (e.g. a duplicate console header), 9/10 it is stale
  cache, but ALSO re-read your own latest edit — a leftover duplicate block is
  just as common (see trap below).
- **Second suspect: leftover duplicate JSX block.** When editing a view, a
  replaced `<tr>`/block can leave an orphan copy behind (seen in Monitor.js
  VmRow — the old console cell stayed after the new one was added). After every
  `edit`, re-read the region and grep the baked file for the marker count; if
  count > expected, there is an orphan block.
- **`docker compose up -d --build` does NOT always recreate the container.**
  If the image hash didn't change (or compose decides nothing to do), nginx keeps
  serving the OLD baked HTML even though the image was rebuilt. ALWAYS verify the
  baked file AFTER every rebuild (`docker exec vmpilot-webui-nginx grep …`); if
  stale, force: `docker compose --profile nginx up -d --force-recreate web`. Do
  not trust "Started" output.
- **Third suspect: server rebuild killed live sockets.** `docker compose up -d
  --build server` RESTARTS the container → all active socket.io sessions drop →
  an open terminal/console shows "disconnected". Expected after rebuilds; not a
  bug. Reconnect by reopening.
- **CSS specificity beats intent.** A later rule with the SAME specificity wins
  (`.console-term { height:460px }` lost to the later `.term-host { height:100% }`
  — both 0,1,0 → console collapsed to parent's auto height, terminal shrank in a
  fit()/ResizeObserver loop). When overriding a shared base class, RAISE
  specificity (`.console-card .console-term { height:460px }`), never rely on
  order or `!important`.
- **fit() + ResizeObserver = infinite resize loop.** `fit.fit()` mutates the
  terminal size → observer fires again → re-fit → flood of `resize` events to the
  server + collapsing view. Guard: only `sock.emit("resize")` when
  `cols/rows` ACTUALLY changed (keep lastCols/lastRows). Apply to ANY xterm host.
- **`vc` is never on the vm object.** Monitor's per-VM objects carry
  `name/ip/cpu/memory_mb/power/live` but NOT `vc` — `onConsole(vm)` leaves the
  console card's `vc` undefined, so ConsoleView's `getLiveVms(vc)` poll 404s and
  the footer stats stay "…"/empty ("server load hoy nai"). Always spread it:
  `onConsole({ ...vm, vc })` at the call site.
- **Check the ACTUAL server response shape, not the assumed one.**
  `/api/monitor/live` returns a PLAIN ARRAY (`live.vms`), not `{vms: []}` —
  ConsoleView's `r.vms || []` silently emptied it → footer stuck on "stats…"
  forever. When consuming an endpoint, read its handler's `res.json(...)` line;
  if you ever normalize, use `Array.isArray(r) ? r : (r && r.vms) || []` so both
  shapes work. This is the #2 silent-blank-footer cause.
- **VM "pending"/"—" live columns = name-key mismatch.** Live vCenter VM names
  can differ from config hostnames (`accesspilot_prod` vs `accesspilot-prod`,
  trailing `_110` suffixes, spaces). `liveByName.get(c.name)` alone returns
  `{}` → power falls to "notDeployed" (UI shows "pending") and CPU/RAM stay "—"
  even though the VM is live. ALWAYS fall back to an IP index:
  `liveByName.get(c.name) || liveByIp.get(s.ip) || {}` (build `liveByIp` from
  live VMs that have `.ip`). Screenshot-check the live payload names BEFORE
  blaming the frontend.
- **vSphere RAM usage ≠ guest usage.** `guestMemoryUsage + hostMemoryUsage` in
  `vcenter-inventory.sh` adds hypervisor overhead → utilization exceeds 100%
  (e.g. 8652MB on an 8192MB VM → 105%, users report "110%"). For VM RAM
  utilization use **guestMemoryUsage only**; hostMemoryUsage is overhead, not
  guest load. Also CAP every % at 100 (`Math.min(100, …)`) in alerts/trends —
  an uncapped memPct in alerts.js is how "110%" leaks into UI badges.
- **The real fix gate:** ALWAYS run the syntax check + bake + verify-baked grep
  before telling the user to look. If you skipped verify-baked, you don't know
  what the user sees.

## View signatures (do not break these)

- `VCenterWizard({ initial, onDone, onCancel })` — `initial={vc, edit:true}` for edit.
- `VmConfigForm({ initial, catalog, refresh, onDone, onCancel })` —
  `initial={vc, env, file?}` (file ⇒ edit); `onDone({vc, env, file})`; uses
  `getVmConfig/createVmConfig/updateVmConfig/findFreeIp/getEnvOverride`.
- `Deploy({ catalog, refresh, onJobCreated })` — job via `createJob`.
- `Jobs` — socket `/jobs`, events `job:output {jobId,line,stream}` +
  `job:status {jobId,status,exit_code}`; `loadList` handles array-or-`{jobs}`.
- `JobThread({ job })` — live console + workflow stepper (PHASES) + animated % bar;
  embedded inline in VmPanel deploy tab AND as thread job cards. Keep `JobThread`
  importable by both; phase regexes are output-driven, do not hardcode script names.
- `VmPanel({ vc, env, file, refresh, onVmForm })` — has redeploy guard (typed-name
  arm) + inline `<JobThread>` when a job is active; "Deploy / Ops" tab renders
  PowerBadge for current live power.
- Shell passes `onOpen`/`onWizard` to Dashboard/Monitor/Inventory/Deploy.

## Contracts

- Job DB fields: `id, action, status, params, user, exit_code, started_at,
  finished_at, output_path`. No `job_id/done/vcenter`.
- Actions: deploy/deploy-plan need `{vcenter, env, vm_name}`; sync/sync-plan
  `{vcenter, env}`; backup none. No destroy (scripts have no destroy.sh; safe
  destroy guarded only).
- `connectJobs` uses `window.io("/jobs", { transports:["websocket","polling"]})`.

## Docker rebuild + verify (run after ANY frontend/server change)

```bash
cd /opt/terraform-lab/projects/VMPilot/vmpilot-webui
node --input-type=module --check < frontend/js/views/<view>.js   # ESM syntax gate
docker compose --profile nginx up -d --build web                # server or web (bake new files)
# verify baked asset:
curl -sk https://127.0.0.1/js/views/Shell.js | grep -n "<your marker>"
# browser checks: hard refresh (Ctrl+Shift+R); confirm tree head = "Config Inventory",
# Monitor click doesn't crash, `+ New config` Target behavior, /_debug/monitor unreachable
# via nginx except `docker exec vmpilot-webui-nginx sh -c 'curl -s http://server:3000/_debug/monitor'`.
# after monitor/live or config-tree work: curl /api/monitor through nginx with a fresh
# JWT (config.secret, iss/aud "vmpilot-webui") and confirm /api/configs/*.tfvars returns
# 200 (NOT 403 — that means the nginx ^~ /api/ location was regressed).
```

Server = container 3000 (no host map), nginx on 80/443 proxies `/api/`,
`/api/auth/login`, `/socket.io/`. Secrets: WEBUI_PASS_HASH in
`config/secrets.env` → `/run/secrets/webui.env`. Test login generated via
`node scripts/gen-pass.js <pw>`; real admin password unknown — do not overwrite.

## Data layout map

- `deploy/<vc>/<env>/vm-<name>_<ip>.tfvars` → LEFT tree / VM configs (fullCatalog).
- `secure/<vc>/vcenter.tfvars` (inventory) + `credentials.tfvars` (SOPS) +
  `<env>/vcenter.tfvars` overrides → RIGHT object views.
- `catalog.js`: fullCatalog = deploy/; readVcenterInventory = secure/<vc>/
  vcenter.tfvars; readEnvOverride = secure/<vc>/<env>/vcenter.tfvars.

## govc auto-discovery (VM form)

- Backend: `executor.govcDiscover(vmpilotDir, vcenter, datacenter)` reuses
  `decryptCreds` + `runCmd("govc", …)` with GOVC_* env. Route: `GET /api/discover?vc=&datacenter=`
  (auth-protected like `/api/vms`, govcLimiter). Returns
  `{ ok, datacenters[], datacenter, items:{clusters[],datastores[],networks[],templates[],resource_pools[]} }`.
- **govc path gotcha:** `govc find . -type <t>` needs `GOVC_DATACENTER` env set
  to the scoped datacenter — passing the dc as a path arg returns empty lists.
  First discover lists datacenters only; pick dc → re-discover scoped items.
- **Templates gotcha:** `govc find . -type m` returns EVERY VM. Must filter real
  templates with `-config.template true` or the Template dropdown floods with
  powered-on VMs. Resource pools use `-type p`.
- **vcenter.tfvars schema (list form):** `datacenter = "..."`, `clusters = [... ]`,
  `templates = [ ... ]` are the persisted (curated) lists. datastores/networks/
  resource_pools are AUTO-DISCOVERED by govc at VM-create time and must NOT be
  stored as single "chosen" values (comment `datastores/networks/resource_pools`
  lists to curate dropdown options). Legacy single keys (`cluster/template/
  datastore/network/resource_pool`) still work — `catalog.inventoryOptions()`
  merges single→list.
- **Per-env override file (`secure/<vc>/<env>/vcenter.tfvars`):** child-wins merge for
  ANY key — vCenter resource pinning (`datacenter/clusters/templates/datastores/
  networks/resource_pools`) is OPTIONAL per-env (commented in template by default;
  uncomment to FORCE for that env; otherwise govc auto-discovers). Network/IPAM
  defaults (`domain/gateway/netmask/dns_servers/ipam_base_ip`) also overridable.
  Merge is `{ ...readVcenterInventory(), ...readEnvOverride().parsed }`
  (top → child wins). CLI loaders (`load_vcenter_defaults`) re-apply the override
  file AFTER top-level. UI applies per-env overrides to form defaults
  (VmConfigForm `getEnvOverride`). Secrets NEVER per-env.
- `catalog.inventoryOptions(vmpilotDir, vc)` → `{datacenter, clusters, templates,
  datastores, networks, resource_pools, domain, gateway, netmask, dns_servers,
  ipam_base_ip}`; route `GET /api/vcenters/:vc/options`.
- Frontend: `getDiscover(vc, dc)` + `getVcenterOptions(vc)` in api.js. VmConfigForm
  auto-loads on `chosenVc` (create mode only); dropdown options = union(curated
  file lists, discovery); when a list has EXACTLY ONE item it is auto-filled,
  multiple items → dropdown. Inventory defaults (gateway/dns/netmask from
  getEnvOverride) merge in.
- VM form field set (mirrors create-vm-config.sh): Target (vc/env picker),
  vCenter resources (datacenter/cluster/datastore/network/template/resource_pool/
  ipam_base_ip — auto-discovered dropdowns), Identity (name/hostname/domain/
  annotation), Network (ip+Pick free IP/netmask/gateway/dns), Compute
  (memory/vcpu/disk/firmware/disk-type incl eager/thin/hot-adds/boot size/
  OS partitions "mount:size" CSV/data disk GB+type), Customization (ssh key,
  extra users CSV, disable auto-updates). Submit maps to backend keys:
  os_partitions → `{mount_point,size,lv_name}`, data_disks →
  `{label,size,unit_number,thin_provisioned,eagerly_scrub}`.
- CLI mirrors UI: vcenter-setup.sh writes list-form vcenter.tfvars + govc
  auto-discovery multi-select (clusters/templates curated); create-vm-config.sh
  `govc_pick` merges curated file lists (VC_CLUSTERS/VC_TEMPLATES/…) with
  discovery. No UI dependency — both scripts discover via govc directly.
  `bash -n scripts/*.sh` after editing.

## create-vm-config.sh gotchas (set -euo pipefail)

- **`set -u` unbound traps (fixed 2026):** top-level shell vars `VCENTER`/`ENV`/
  `ENV_DIR` must be `=""` pre-initialized near the preset block — they are only
  assigned inside interactive branches and otherwise trigger "unbound variable"
  at first use (`[ -z "$VCENTER" ]` after env select). Same for the vCenter
  inventory defaults `DEFAULT_DATACENTER/CLUSTER/RESOURCE_POOL/DATASTORE/NETWORK/
  TEMPLATE/DOMAIN/GATEWAY/NETMASK/BASE_IP/DNS` — the `${x:-$DEFAULT_*}` nested
  fallbacks blow up under `set -u` when a tfvars key is absent; pre-initialize
  with `: "${DEFAULT_X:=}"` near the other `DEFAULT_*`.
- **grep no-match kills the script:** `x=$(grep ... | head -1 | sed ...)` fails
  (exit 1) when grep finds nothing → `set -o pipefail` + `set -e` ⇒ silent exit
  mid-parse. `load_vcenter_defaults()` wraps its whole body in
  `set +e +o pipefail` … `set -e -o pipefail` so parsing is never fatal.
- **assoc arrays declared inside functions are LOCAL:** `declare -A` (without
  `-g`) inside `load_vcenter_defaults()` vanishes when the function returns, so
  later `${NET_HOSTS[$key]:-}` reads trip "unbound variable". Use
  `declare -gA NET_SUBNETS=()` / `NET_HOSTS` / `HOST_INFO`. Symptom: config
  dies right after env select, no error you can see.
- **per-env override call must NOT wipe top-level maps:** `load_vcenter_defaults`
  runs TWICE (top-level `secure/<vc>/vcenter.tfvars`, then per-env
  `secure/<vc>/<env>/vcenter.tfvars`). The `unset X; declare -gA X=()`
  initializers must live INSIDE the `if grep -qE '^X='` guard — if the override
  file lacks a block (e.g. `network_subnets`), a guard-outside unset silently
  wipes the top-level map → later `${NET_SUBNETS[$NET_PORT_GROUP]}` misses →
  "no network_subnets entry — default range" + wrong gateway/range for a
  perfectly-mapped port group (seen: VM Network → used 192.168.100.x instead of
  192.168.101.106). DPortGroup/VM Network entries then never apply.