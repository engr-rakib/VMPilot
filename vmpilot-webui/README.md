# VMPilot WebUI

Browser-based console for [VMPilot](../README.md) — **secure web terminal,
vCenter-style dashboard, job runner with live logs**, with RBAC and a
WhatsApp/shell chat UI later.

Full architecture, phases and decisions: [`DOCS/design-plan.md`](DOCS/design-plan.md)

## Product guideline (owner-mandated)

- **The CLI is the product; the Web UI is an optional add-on.** Everything you can
  do in the browser must be doable from the CLI (`scripts/*.sh`) with no UI
  involved. The Web UI only *wraps* those CLI actions — it never invents
  parallel logic of its own.
- **No dependency on the Web UI — ever.** If `vmpilot-webui/` is deleted, the
  whole project (setup, VM config, deploy, destroy, backups, monitoring) must
  keep working exactly the same. The UI is not allowed to become a required
  component of any workflow.
- **One source of truth.** Both the CLI and the Web UI read the same data
  (`secure/<vc>/vcenter.tfvars` inventory + `deploy/*` VM configs). They share
  state through files, never through each other. Changes made in the UI must be
  indistinguishable from changes made in the CLI (same output files, same
  behaviour).
- **The UI never runs discovery or state it owns.** Any fact the UI needs
  (inventory, IPAM, VM list, status) comes from the cached files or from running
  the real CLI script as a subprocess — not from the UI keeping its own copy.

## Rules (owner-mandated)

- Lives **inside the VMPilot repo** (`vmpilot-webui/`) — single `.git`, one clone,
  one `install.sh` for the whole project.
- **No code dependency on VMPilot**: this Node.js backend never imports VMPilot
  scripts. It talks to the CLI **only via subprocess** (`execFile`) at runtime.
- **All web UI dependencies live only inside this directory** (`node_modules`,
  vendored frontend libs, DB, job logs). Nothing is pulled from the VMPilot repo.
- The frontend has **no dependency on VMPilot either** — it is a static no-build
  app (external ES modules + css + vendored UMD libs) that only calls the API.

## Features

- **Terminal** — full interactive shell (node-pty + xterm.js) inside the container,
  where terraform/govc/sops/age are installed.
- **Dashboard** — pick a vCenter, list VMs live (power, CPU, RAM, OS, IP),
  power on/off/reset straight from the browser.
- **Deploy & Operations** — start a deploy/plan/sync/backup job with vCenter,
  environment and VM name; the server runs the exact VMPilot CLI script.
- **Destroy (guarded)** — type the VM name to arm, then confirm; runs the real
  `destroy.sh --yes` CLI as a job with live output.
- **Backups & restore** — `GET /api/backups` lists the `backups/` rotation
  (max 5); one-click **restore** runs the real `backup.sh --restore` CLI as a job.
- **IPAM viewer** — `GET /api/ipam?vc&env` returns base IP, reserved IPs (from
  per-VM config files) and the next free IP (via `next_free_ip.sh`).
- **Env status** — `GET /api/env/status` reports tool versions
  (terraform/sops/age/jq/git), state backend mode and repo/deploy paths;
  shown as a header chip in the Console v3 shell.
- **Jobs** — history + live-streamed output over socket.io; persisted in SQLite
  (`data/webui.db`), logs in `data/jobs/`.
- **Charts (Phase 2.5)** — dependency-free SVG visualization: power donut
  (dashboard), capacity bars per vCenter, VMs-by-env distribution, job-outcome
  donut, and live per-VM CPU/RAM utilization bars (govc quickStats).

## Stack

| Layer | Tech |
|---|---|
| Backend | Node.js (Express) + socket.io + node-pty |
| Frontend | No-build ES modules + React UMD + xterm.js (external js/css, vendored) |
| Proxy | nginx (**optional** — TLS, security headers, rate limiting, WS) |
| Auth | bcrypt + JWT in httpOnly `SameSite=Strict` cookie |
| Jobs | SQLite (`node:sqlite`) + subprocess runner |

> **Why is nginx optional?** Node.js can serve the static frontend and the API by
> itself (same origin → no CORS, socket.io over the same port), so the UI works
> with a single container. nginx only adds value when the console is exposed
> over the network: TLS termination, login rate-limiting at the edge, immutable
> asset caching and defence-in-depth security headers. LAN/desktop → plain Node;
> exposed deployment → `--profile nginx`.

## Quickstart

```bash
cd vmpilot-webui

# 1. configure (never commit .env / config/secrets.env)
cp .env.example .env
WEBUI_SECRET="$(openssl rand -hex 32)"      # put into .env

cp config/secrets.env.example config/secrets.env
npm --prefix server run gen-pass            # paste bcrypt hash into config/secrets.env

# 2. run — standalone (Node serves the UI itself, no nginx needed)
docker compose up -d --build

#    → open http://<host>:3000 and sign in
#    (all deps live inside this directory; nothing else required)

# optional hardened edge (TLS + rate limiting + WAF headers):
# docker compose --profile nginx up -d --build
#    → https://<host>:443 (self-signed cert auto-generated;
#      replace nginx/certs/server.crt + server.key for a real one)
```

> **Why two files?** Docker Compose interpolates `$VAR` inside `.env` values,
> which corrupts bcrypt hashes (they contain `$`). The password hash therefore
> lives in `config/secrets.env`, which the Node app parses literally. Everything
> without `$` (secret is hex, ports, user) stays in `.env`.

## Security posture (Phase 1)

- Only **nginx:443** is exposed; the Node server binds the internal Docker network.
- **TLS always on** (self-signed auto-generated, replaceable); HTTP→HTTPS redirect.
- **Login rate-limited** (5/min/IP at nginx **and** app layer); bcrypt password hashing.
- **httpOnly + SameSite=Strict** session cookie; JWT signed with `WEBUI_SECRET`.
- Security headers + CSP at nginx; the app refuses to boot without
  `WEBUI_SECRET`/`WEBUI_PASS_HASH`.
- Terminal runs as a **non-root user** (`TERMINAL_UID/GID`, default 1000).
- The VMPilot repo is mounted **read-write** because the CLI must write
  `.terraform/` state and generated tfvars — this container is *the* trusted
  operator, equivalent to a local shell.

## Development (no Docker)

```bash
# server (needs system node >= 20) — serves the UI too
cd server && npm install && npm run dev     # → http://localhost:3000

# frontend is plain static files — just reload your browser after an edit.
# (no vite build step, no HMR server needed)
```

## Layout

```
vmpilot-webui/
├── docker-compose.yml
├── .env.example
├── nginx/          nginx.conf + TLS entrypoint (OPTIONAL profile)
├── server/         Node backend (auth, terminal, executor API)
│   ├── Dockerfile  installs terraform/govc/sops/age for the terminal
│   └── src/        config, auth, terminal, executor, govc, db, index
├── frontend/       static no-build UI (external js/css, vendored UMD libs)
│   ├── index.html
│   ├── css/        themes.css · layout.css · views.css · shell.css
│   ├── js/         core.js · api.js · charts.js · app.js + views/
│   └── vendor/     react, react-dom, socket.io, xterm, htm (committed, no CDN)
├── data/           SQLite DB + job logs (persistent, gitignored)
└── scripts/        helper scripts
```

The frontend depends on **nothing else in the repo** — it is fully self-contained
under `frontend/` and talks only to the API. All runtime/code dependencies of the
whole UI live inside `vmpilot-webui/`.

## Roadmap (from design-plan.md)

1. **Phase 1 — web terminal** ✅ working
2. **Phase 2 — dashboard + job API + live logs** ✅ working
3. **Phase 2.5 — charts / visualization layer** ✅ done (SVG: power donut, capacity bars, per-VM utilization)
4. Phase 3 — RBAC + audit + 2FA
5. Phase 4 — operator chat / quick-command bar
6. Phase 5 — deeper monitoring (Prometheus/alerts)
