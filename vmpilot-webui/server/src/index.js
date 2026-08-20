"use strict";

const http = require("http");
const { randomUUID } = require("crypto");
const express = require("express");
const helmet = require("helmet");
const cookieParser = require("cookie-parser");
const rateLimit = require("express-rate-limit");
const { Server } = require("socket.io");

const fs = require("fs");
const path = require("path");
const config = require("./config");
const auth = require("./auth");
const { attachTerminal, attachConsole, activeConsoleSessions } = require("./terminal");
const guest = require("./guest");
const dbmod = require("./db");
const executor = require("./executor");
const catalog = require("./catalog");
const vcenterOps = require("./vcenterOps");
const vmConfigs = require("./vmConfigs");
const monitor = require("./monitor");
const opsStatus = require("./opsStatus");
const alerts = require("./alerts");

const db = dbmod.openDb(path.join(config.dataDir, "db"));
const jobs = dbmod.makeJobStore(db);
jobs.dataDir = config.dataDir;
alerts.init(db);
const events = dbmod.makeEventStore(db);
const users = dbmod.makeUserStore(db);
const roles = dbmod.makeRoleStore(db);
const samples = dbmod.makeSampleStore(db);
auth.useUserStore(users);
auth.useRoleStore(roles);

// Seed built-in roles (idempotent): only creates the ones missing.
(function seedRoles() {
  const builtin = [
    { name: "viewer", permissions: ["view"], description: "Read-only access to inventory, monitoring and events." },
    { name: "operator", permissions: ["view", "deploy", "config.write", "terminal"], description: "Day-to-day operations: deploy, power, edit configs, terminal." },
    { name: "admin", permissions: ["view", "deploy", "config.write", "terminal", "users.manage", "settings.manage"], description: "Full control including user and role management." }
  ];
  for (const r of builtin) {
    if (!roles.get(r.name)) roles.create({ ...r, builtin: 1 });
  }
})();

// Bootstrap user seed (idempotent): only when the users table is empty.
//  - admin  → from WEBUI_USER / WEBUI_PASS_HASH (never re-seeded over existing)
//  - viewer → demo read-only account for testing RBAC
(function seedUsers() {
  if (users.count() > 0) return;
  const bcrypt = require("bcryptjs");
  try {
    if (config.user && config.passHash) {
      users.create({ id: "u-admin", username: config.user, pass_hash: config.passHash, role: "admin" });
    }
    const demoHash = bcrypt.hashSync("viewer123", 10);
    users.create({ id: "u-viewer", username: "viewer", pass_hash: demoHash, role: "viewer" });
    console.log("[vmpilot-webui] seeded default users: admin + viewer (demo password: viewer123)");
  } catch (e) {
    console.error("[vmpilot-webui] user seed failed:", String(e.message || e));
  }
})();

const app = express();

// We are behind nginx (TLS termination).
app.set("trust proxy", 1);
app.disable("x-powered-by");

// Security headers at the app layer too (defense in depth; CSP is set at nginx).
// Disable COOP / Origin-Agent-Cluster for non-HTTPS local origins to avoid
// browser console warnings when serving from an IP or HTTP during local dev.
app.use(helmet({
  contentSecurityPolicy: false,
  crossOriginEmbedderPolicy: false,
  crossOriginOpenerPolicy: false,
  originAgentCluster: false
}));
// Some proxies or older Helmet versions may still add COOP / OAC headers.
// Strip them explicitly to avoid browser console warnings when serving
// the app over plain HTTP during local development.
app.use((req, res, next) => {
  res.removeHeader && res.removeHeader("Cross-Origin-Opener-Policy");
  res.removeHeader && res.removeHeader("Origin-Agent-Cluster");
  next();
});
app.use(cookieParser());
app.use(express.json({ limit: "64kb" }));

// unauthenticated debug endpoint (outside /api) — protected by X-Debug-Token
app.get("/_debug/monitor", async (req, res) => {
  const token = String(req.headers["x-debug-token"] || "");
  if (!token || token !== config.secret) return res.status(403).json({ error: "forbidden" });
  try {
    const snap = await monitor.monitorSnapshot(config.vmpilotDir);
    return res.json({ generated_at: Date.now(), vcenters: snap });
  } catch (e) { console.error("[vmpilot-webui] debug monitor failed:", e && e.stack || e); return res.status(500).json({ error: String(e && e.message || e) }); }
});


// Static frontend (no-build ES modules). Same origin as the API, so the
// session cookie works without CORS. nginx can proxy /api + /socket.io and
// serve these files itself; this also lets Node run standalone (no nginx).
const frontendDir = config.frontendDir || path.join(__dirname, "..", "..", "frontend");
app.use(express.static(frontendDir, { index: "index.html" }));

app.get("/api/health", (req, res) => res.json({ status: "ok" }));

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 5,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "too many attempts, try later" }
});

app.post("/api/auth/login", loginLimiter, async (req, res) => {
  try {
    const { username, password } = req.body || {};
    const token = await auth.login(String(username || ""), String(password || ""));
    if (!token) return res.status(401).json({ error: "invalid credentials" });
    auth.setSessionCookie(req, res, token);
    return res.json({ ok: true });
  } catch {
    return res.status(500).json({ error: "internal error" });
  }
});

app.post("/api/auth/logout", (req, res) => {
  auth.clearSessionCookie(req, res);
  res.json({ ok: true });
});

app.get("/api/auth/me", (req, res) => {
  const p = auth.payloadFromRequest(req);
  if (!p) return res.status(401).json({ error: "unauthorized" });
  res.json({ user: p.sub, role: p.role, permissions: auth.effectivePermissions(p.role) });
});

// Protect every other API route.
app.use("/api", auth.requireAuth, (req, res, next) => next());

// Error logging middleware: ensures unexpected errors are logged with stack traces.
app.use((err, req, res, next) => {
  try {
    console.error("[vmpilot-webui] Express error:", (err && err.stack) || err);
  } catch (e) {
    console.error("[vmpilot-webui] Error while logging error:", e);
  }
  return next(err);
});

// Express 4 does not catch async handler rejections — wrap them.
const ah = (fn) => (req, res, next) => fn(req, res, next).catch((e) => {
  res.status(500).json({ error: String(e.message || e) });
});

// Temporary debug endpoint: return monitor snapshot when caller supplies
// a valid X-Debug-Token header equal to the server secret. This helps
// reproduce monitor errors without authenticating via the UI during debug.
app.get("/api/_debug/monitor", ah(async (req, res) => {
  const token = String(req.headers["x-debug-token"] || "");
  if (!token || token !== config.secret) return res.status(403).json({ error: "forbidden" });
  const snap = await monitor.monitorSnapshot(config.vmpilotDir);
  res.json({ generated_at: Date.now(), vcenters: snap });
}));

// ---- vCenters / VM inventory ----
app.get("/api/vcenters", (req, res) => res.json(executor.listVcenters(config.vmpilotDir)));

app.get("/api/configs", (req, res) => res.json(executor.listConfigs(config.vmpilotDir)));

// ---- Catalog (vCenter-style inventory tree + object CRUD) ----
const vcLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: true, legacyHeaders: false });

app.get("/api/inventory", (req, res) => res.json(catalog.fullCatalog(config.vmpilotDir)));

app.get("/api/vcenters/:vc", (req, res) => {
  const vc = req.params.vc;
  if (!catalog.listVcenters(config.vmpilotDir).includes(vc)) {
    return res.status(404).json({ error: "vCenter not found" });
  }
  const detail = catalog.vcenterDetail(config.vmpilotDir, vc);
  detail.envs = detail.envs.map((env) => ({
    env,
    override: catalog.readEnvOverride(config.vmpilotDir, vc, env),
    effective: catalog.readEffectiveInventory(config.vmpilotDir, vc, env),
    vm_configs: catalog.listVmConfigs(config.vmpilotDir, vc, env)
  }));
  res.json(detail);
});

app.get("/api/vcenters/:vc/options", (req, res) => {
  const vc = req.params.vc;
  if (!catalog.listVcenters(config.vmpilotDir).includes(vc)) {
    return res.status(404).json({ error: "vCenter not found" });
  }
  res.json(catalog.inventoryOptions(config.vmpilotDir, vc));
});

// Project's shared SSH public key (most common across deploy/*/*/vm-*.tfvars)
app.get("/api/ssh-key", (req, res) => {
  res.json({ ssh_public_key: catalog.findProjectSshKey(config.vmpilotDir) });
});

app.post("/api/vcenters", vcLimiter, ah(async (req, res) => {
  const result = await vcenterOps.saveVcenter(config.vmpilotDir, req.body || {});
  res.status(201).json({ ok: true, vcenter: result.vcenter });
}));

app.put("/api/vcenters/:vc", vcLimiter, ah(async (req, res) => {
  const result = await vcenterOps.saveVcenter(config.vmpilotDir, { ...(req.body || {}), existing: req.params.vc });
  res.json({ ok: true, vcenter: result.vcenter });
}));

app.delete("/api/vcenters/:vc", vcLimiter, ah(async (req, res) => {
  const result = await vcenterOps.deleteVcenter(config.vmpilotDir, req.params.vc);
  res.json(result);
}));

app.post("/api/vcenters/:vc/envs", vcLimiter, ah(async (req, res) => {
  const result = await vcenterOps.addEnv(config.vmpilotDir, req.params.vc, String((req.body || {}).env || ""));
  res.status(201).json(result);
}));

app.delete("/api/vcenters/:vc/envs/:env", vcLimiter, ah(async (req, res) => {
  const result = await vcenterOps.deleteEnv(config.vmpilotDir, req.params.vc, req.params.env);
  res.json(result);
}));

// Per-env override read/write (secure/<vc>/<env>/vcenter.tfvars)
app.get("/api/vcenters/:vc/envs/:env/override", (req, res) => {
  const { vc, env } = req.params;
  res.json({
    ...catalog.readEnvOverride(config.vmpilotDir, vc, env),
    effective: catalog.readEffectiveInventory(config.vmpilotDir, vc, env)
  });
});

app.put("/api/vcenters/:vc/envs/:env/override", vcLimiter, ah(async (req, res) => {
  const { vcenter, env } = req.params;
  const raw = String((req.body || {}).raw || "");
  await catalog.writeFileOrSudo(
    require("path").join(config.vmpilotDir, "secure", vcenter, env, "vcenter.tfvars"),
    raw
  );
  res.json({ ok: true });
}));

// Free-IP scan (IPAM)
app.get("/api/freeip", vcLimiter, ah(async (req, res) => {
  const base = String(req.query.base_ip || "");
  const skip = String(req.query.skip_ip || "");
  const rangeEnd = String(req.query.range_end || "");
  if (!base) return res.status(400).json({ error: "base_ip required" });
  const ip = await catalog.findFreeIp(config.vmpilotDir, base, skip, rangeEnd);
  res.json({ free_ip: ip });
}));

// ---- Secure explorer (vCenter inventory + per-env policy files) ----
// The left-panel "Secure" root browses secure/<vc>/ (vcenter.tfvars,
// vm-defaults.conf, per-env overrides + user-groups policy). Read + write raw
// text; credentials.tfvars stays encrypted and read-only.
app.get("/api/secure/tree", (req, res) => {
  res.json(catalog.secureTree(config.vmpilotDir));
});

app.get("/api/secure/file", (req, res) => {
  const vc = String(req.query.vc || "");
  const rel = String(req.query.rel || "");
  if (!vc || !rel) return res.status(400).json({ error: "vc and rel required" });
  if (!catalog.listVcenters(config.vmpilotDir).includes(vc)) {
    return res.status(404).json({ error: "vCenter not found" });
  }
  try {
    const raw = catalog.readSecureFile(config.vmpilotDir, vc, rel);
    res.json({ vcenter: vc, rel, raw });
  } catch (e) {
    res.status(404).json({ error: String(e.message || e) });
  }
});

app.put("/api/secure/file", vcLimiter, ah(async (req, res) => {
  const vc = String((req.body || {}).vcenter || "");
  const rel = String((req.body || {}).rel || "");
  const raw = String((req.body || {}).raw ?? "");
  if (!vc || !rel) return res.status(400).json({ error: "vcenter and rel required" });
  try {
    const result = await catalog.writeSecureFile(config.vmpilotDir, vc, rel, raw);
    res.json(result);
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
}));

// Create a new per-env user-group policy file from a template.
app.post("/api/secure/policy", vcLimiter, ah(async (req, res) => {
  const vc = String((req.body || {}).vcenter || "");
  const env = String((req.body || {}).env || "");
  if (!vc || !env) return res.status(400).json({ error: "vcenter and env required" });
  try {
    const result = await catalog.createSecurePolicy(config.vmpilotDir, vc, env);
    res.status(201).json(result);
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
}));

// ---- VM configs CRUD ----
app.get("/api/configs/:vc/:env", (req, res) => {
  const { vc, env } = req.params;
  const envs = catalog.listEnvs(config.vmpilotDir, vc);
  if (!envs.includes(env)) return res.status(404).json({ error: "environment not found" });
  const list = catalog.listVmConfigs(config.vmpilotDir, vc, env);
  res.json(list.map((c) => {
    const cfg = catalog.readVmConfig(config.vmpilotDir, vc, env, c.file);
    return { ...c, summary: catalog.summarizeVmConfig(cfg, catalog.readEffectiveInventory(config.vmpilotDir, vc, env)) };
  }));
});

app.get("/api/configs/:vc/:env/:file", (req, res) => {
  const { vc, env, file } = req.params;
  if (!catalog.listVmConfigs(config.vmpilotDir, vc, env).some((c) => c.file === file)) {
    return res.status(404).json({ error: "config not found" });
  }
  const cfg = catalog.readVmConfig(config.vmpilotDir, vc, env, file);
  res.json({
    ...cfg,
    file,
    effective: catalog.readEffectiveInventory(config.vmpilotDir, vc, env),
    summary: catalog.summarizeVmConfig(cfg, catalog.readEffectiveInventory(config.vmpilotDir, vc, env))
  });
});

app.post("/api/configs", vcLimiter, ah(async (req, res) => {
  const result = await vmConfigs.createVmConfig(config.vmpilotDir, req.body || {});
  res.status(201).json({ ok: true, ...result });
}));

app.put("/api/configs/:vc/:env/:file", vcLimiter, ah(async (req, res) => {
  const { vc, env, file } = req.params;
  const result = await vmConfigs.updateVmConfig(config.vmpilotDir, vc, env, file, req.body || {});
  res.json({ ok: true, ...result });
}));

app.delete("/api/configs/:vc/:env/:file", vcLimiter, ah(async (req, res) => {
  const result = await vmConfigs.deleteVmConfig(config.vmpilotDir, req.params.vc, req.params.env, req.params.file);
  res.json(result);
}));

// ---- Monitoring ----
// Dedicated, generous limiter: each Dashboard/Monitor card fires one request per
// vCenter (3+ parallel), plus a 30s auto-refresh and manual reloads. The old
// vcLimiter (30/min) exhausted after a few reloads → 429 spam. Calls are cheap
// (disk cache ~0.16s), so a higher ceiling is safe here.
const monLimiter = rateLimit({ windowMs: 60 * 1000, limit: 120, standardHeaders: true, legacyHeaders: false });

app.get("/api/monitor", ah(async (req, res) => {
  const snap = await monitor.monitorSnapshot(config.vmpilotDir);
  // Evaluate resource-utilization alerts on every full snapshot poll.
  try { alerts.evaluate(db, snap, config.vmpilotDir); } catch { /* never block the snapshot */ }
  // Persist per-entity metric samples (host cpu/mem/net/disk, datastore used%)
  // for the trend charts; keep only the last 72h (feeds 6h/24h/72h windows).
  try {
    samples.addMany(monitor.collectSamples(snap, Date.now(), config.vmpilotDir));
    samples.prune(72 * 60 * 60 * 1000);
  } catch { /* trend persistence is best-effort */ }
  res.json({ generated_at: Date.now(), vcenters: snap, alerts: alerts.countUnseen(db) });
}));

app.get("/api/monitor/live", monLimiter, ah(async (req, res) => {
  const vc = String(req.query.vc || "");
  if (!vc) return res.status(400).json({ error: "vc required" });
  const live = await monitor.liveVms(config.vmpilotDir, vc);
  return live.ok ? res.json(live.vms) : res.status(502).json({ error: live.error });
}));

// Live guest-OS probe (users, who, df/LVM utilization, failed services) via SSH.
// Best-effort: returns last-good cache on transient failure.
app.get("/api/monitor/guest", monLimiter, ah(async (req, res) => {
  const ip = String(req.query.ip || "");
  const user = String(req.query.user || config.sshUser);
  if (!ip) return res.status(400).json({ error: "ip required" });
  const r = await guest.probeGuest(config.vmpilotDir, ip, config.sshKeyPath, user);
  return r.ok ? res.json(r) : res.status(502).json(r);
}));

// Per-vCenter monitoring snapshot — each card fetches independently so a slow
// vCenter never blocks the rest of the dashboard/monitor page.
app.get("/api/monitor/trends", monLimiter, ah(async (req, res) => {
  const vc = String(req.query.vc || "");
  const kind = String(req.query.kind || "");
  const entity = String(req.query.entity || "");
  const hours = Math.min(72, Math.max(1, parseInt(req.query.hours || "24", 10) || 24));
  if (!vc || !kind || !entity) return res.status(400).json({ error: "vc, kind, entity required" });
  const to = Date.now();
  const from = to - hours * 60 * 60 * 1000;
  const series = samples.series({ vc, kind, entity, fromTs: from, toTs: to });
  res.json({ vc, kind, entity, from, to, points: series });
}));

// Per-vCenter trend BUNDLE for the Inventory right-rail (Grafana-style panels):
// one request returns per-entity series for every host/datastore kind
// (host_cpu|host_mem|host_net|host_disk|ds_used) over the last `hours`.
// MUST be declared BEFORE /api/monitor/:vc (same route-order trap as /trends).
app.get("/api/monitor/dc-trends", monLimiter, ah(async (req, res) => {
  const vc = String(req.query.vc || "");
  const hours = Math.min(72, Math.max(1, parseInt(req.query.hours || "24", 10) || 24));
  if (!vc) return res.status(400).json({ error: "vc required" });
  const to = Date.now();
  const from = to - hours * 60 * 60 * 1000;
  const series = samples.grouped({
    vc, fromTs: from, toTs: to,
    kinds: ["host_cpu", "host_mem", "host_net", "host_disk", "ds_used"]
  });
  res.json({ vc, hours, from, to, series });
}));

app.get("/api/monitor/:vc", monLimiter, ah(async (req, res) => {
  const vc = String(req.params.vc || "");
  if (!vc) return res.status(400).json({ error: "vc required" });
  const snap = await monitor.monitorVc(config.vmpilotDir, vc);
  res.json({ generated_at: Date.now(), vcenter: snap });
}));

// Time-series trend for one vc+kind+entity over the last `hours` (default 24).
// kinds: host_cpu | host_mem | host_net | host_disk | ds_used
// MUST be declared BEFORE /api/monitor/:vc or "trends" is captured as a vCenter.

// Operator deploy stats — how many VM deploys each operator ran, plus the VMs
// they created (for the dashboard's "operator activity" panel).
app.get("/api/jobs/operators", (req, res) => {
  const all = jobs.list(2000);
  const byUser = {};
  for (const j of all) {
    const u = j.user || "unknown";
    byUser[u] = byUser[u] || { user: u, deploy_count: 0, vms: [] };
    if (j.action === "deploy" || j.action === "deploy-plan" || j.action === "create-vm-config") {
      byUser[u].deploy_count++;
      // older jobs may lack the target_* columns — fall back to params
      const p = j.params || {};
      const vmName = j.target_vm || p.vm_name || "";
      if (vmName) byUser[u].vms.push({ vc: j.target_vc || p.vcenter || "", env: j.target_env || p.env || "", vm: vmName, status: j.status, at: j.started_at });
    }
  }
  const ops = Object.values(byUser)
    .map((o) => ({ ...o, vms: o.vms.slice(-50) }))
    .sort((a, b) => b.deploy_count - a.deploy_count);
  res.json(ops);
});

const govcLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: true, legacyHeaders: false });

app.post("/api/vms/power", govcLimiter, auth.requirePerm("deploy"), ah(async (req, res) => {
  const { vc, name, action } = req.body || {};
  if (!vc || !name || !action) return res.status(400).json({ error: "vc, name, action required" });
  const result = await executor.vmPower(config.vmpilotDir, vc, name, action);
  if (result.ok) {
    alerts.pushEvent(db, {
      vc, env: String(req.body.env || ""), vm: name,
      label: action === "on" ? "VM powered on" : action === "off" ? "VM powered off"
        : action === "forceoff" ? "VM force powered off" : action === "reset" ? "VM reset"
        : action === "reboot" ? "VM rebooted" : action === "shutdown" ? "VM graceful shutdown" : "VM power action",
      severity: "info",
      user: req.auth ? req.auth.sub : "admin"
    });
  }
  return result.ok ? res.json({ ok: true }) : res.status(502).json({ error: result.error });
}));

// ---- Alerts / events ledger ----
app.get("/api/alerts", (req, res) => res.json(alerts.list(db)));
app.get("/api/alerts/unseen", (req, res) => res.json({ count: alerts.countUnseen(db) }));
app.post("/api/alerts/seen", (req, res) => {
  const { ids } = req.body || {};
  res.json(alerts.markSeen(db, ids));
});
app.delete("/api/alerts", (req, res) => res.json(alerts.clear(db)));

// ---- Events & Tasks (ledger) ----
app.get("/api/events", (req, res) => {
  const q = req.query;
  res.json(events.list({
    vc: q.vc || "", env: q.env || "", vm: q.vm || "",
    kind: q.kind || "", severity: q.severity || "",
    limit: Math.min(500, parseInt(q.limit || "200", 10) || 200),
    offset: Math.max(0, parseInt(q.offset || "0", 10) || 0)
  }));
});
app.get("/api/console/sessions", (req, res) => {
  res.json({ sessions: activeConsoleSessions() });
});
app.post("/api/events/seen", (req, res) => {
  const body = req.body || {};
  const ids = Array.isArray(body.ids) ? body.ids.filter((i) => typeof i === "string") : [];
  res.json({ unseen: events.markSeen(ids) });
});
app.get("/api/events/summary", (req, res) => res.json(events.summary()));
app.get("/api/events/:id", (req, res) => {
  const e = events.get(req.params.id);
  if (!e) return res.status(404).json({ error: "event not found" });
  const linked = e.task_id ? jobs.get(e.task_id) : null;
  res.json({ event: e, task: linked });
});

app.get("/api/tasks", (req, res) => {
  const q = req.query;
  res.json(jobs.listTasks({
    vc: q.vc || "", env: q.env || "", vm: q.vm || "",
    action: q.action || "", status: q.status || "",
    limit: Math.min(500, parseInt(q.limit || "200", 10) || 200)
  }));
});
app.get("/api/tasks/:id", (req, res) => {
  const task = jobs.get(req.params.id);
  if (!task) return res.status(404).json({ error: "task not found" });
  const related = events.list({ limit: 50 }).filter((e) => e.task_id === task.id);
  res.json({ task, related });
});

// ---- Users & RBAC ----
const settingsLimiter = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: true, legacyHeaders: false });

app.get("/api/users", auth.requirePerm("users.manage"), (req, res) => res.json(users.list()));

app.post("/api/users", settingsLimiter, auth.requirePerm("users.manage"), async (req, res) => {
  const { username, password, role } = req.body || {};
  const uname = String(username || "").trim();
  if (!uname || !String(password || "")) return res.status(400).json({ error: "username and password required" });
  if (!roles.get(role)) return res.status(400).json({ error: "invalid role" });
  if (users.getByUsername(uname)) return res.status(409).json({ error: "username already exists" });
  const bcrypt = require("bcryptjs");
  const hash = bcrypt.hashSync(String(password), 10);
  users.create({ id: "u-" + Math.random().toString(36).slice(2, 10), username: uname, pass_hash: hash, role });
  res.status(201).json({ ok: true });
});

app.put("/api/users/:id", settingsLimiter, auth.requirePerm("users.manage"), async (req, res) => {
  const { role, disabled, password } = req.body || {};
  const target = users.get(req.params.id);
  if (!target) return res.status(404).json({ error: "user not found" });
  // never demote/disable the last active admin
  if (target.role === "admin" && users.countRole("admin") <= 1) {
    if ((role && role !== "admin") || disabled) return res.status(400).json({ error: "cannot remove the last admin" });
  }
  const fields = {};
  if (role && roles.get(role)) fields.role = role;
  if (typeof disabled === "boolean") fields.disabled = disabled;
  if (password) {
    const bcrypt = require("bcryptjs");
    fields.pass_hash = bcrypt.hashSync(String(password), 10);
  }
  users.update(target.id, fields);
  res.json({ ok: true });
});

app.delete("/api/users/:id", settingsLimiter, auth.requirePerm("users.manage"), (req, res) => {
  const target = users.get(req.params.id);
  if (!target) return res.status(404).json({ error: "user not found" });
  if (target.role === "admin" && users.countRole("admin") <= 1) {
    return res.status(400).json({ error: "cannot delete the last admin" });
  }
  users.delete(target.id);
  res.json({ ok: true });
});

// ---- Roles (RBAC) ----
app.get("/api/roles", (req, res) => {
  const all = roles.list();
  res.json({ roles: all, permissions: auth.PERMISSIONS });
});

app.post("/api/roles", settingsLimiter, auth.requirePerm("users.manage"), (req, res) => {
  const { name, permissions, description } = req.body || {};
  const rname = String(name || "").trim();
  if (!rname) return res.status(400).json({ error: "role name required" });
  if (roles.get(rname)) return res.status(409).json({ error: "role already exists" });
  const perms = (Array.isArray(permissions) ? permissions : []).filter((p) => auth.PERMISSIONS.includes(p));
  roles.create({ name: rname, permissions: perms, builtin: 0, description: String(description || "") });
  res.status(201).json({ ok: true });
});

app.put("/api/roles/:name", settingsLimiter, auth.requirePerm("users.manage"), (req, res) => {
  const target = roles.get(req.params.name);
  if (!target) return res.status(404).json({ error: "role not found" });
  const { permissions, description } = req.body || {};
  const fields = {};
  if (Array.isArray(permissions)) {
    fields.permissions = permissions.filter((p) => auth.PERMISSIONS.includes(p));
  }
  if (typeof description === "string") fields.description = description;
  roles.update(target.name, fields);
  res.json({ ok: true });
});

app.delete("/api/roles/:name", settingsLimiter, auth.requirePerm("users.manage"), (req, res) => {
  const target = roles.get(req.params.name);
  if (!target) return res.status(404).json({ error: "role not found" });
  if (target.builtin) return res.status(400).json({ error: "cannot delete a built-in role" });
  // users assigned to this role fall back to viewer
  const assigned = users.list().filter((u) => u.role === target.name);
  for (const u of assigned) users.update(u.id, { role: "viewer" });
  roles.delete(target.name);
  res.json({ ok: true, reassigned: assigned.length });
});

// ---- Settings / alerting config ----
app.get("/api/settings/alerting", (req, res) => {
  const cfg = alerts.getConfig();
  const smtp = cfg.smtp || {};
  // never leak the SMTP password — expose only whether one is set
  res.json({ ...cfg, smtp: { ...smtp, password: smtp.password ? "__set__" : "" } });
});

app.put("/api/settings/alerting", settingsLimiter, auth.requirePerm("settings.manage"), (req, res) => {
  const body = req.body || {};
  const cfg = alerts.setConfig(body);
  const smtp = cfg.smtp || {};
  res.json({ ...cfg, smtp: { ...smtp, password: smtp.password ? "__set__" : "" } });
});

app.post("/api/settings/alerting/test", settingsLimiter, auth.requirePerm("settings.manage"), ah(async (req, res) => {
  const mailer = require("./mailer");
  const cfg = alerts.getConfig();
  const result = await mailer.sendTest(cfg);
  res.json(result);
}));

// ---- Jobs ----
app.get("/api/jobs", (req, res) => res.json(jobs.list(50)));

app.get("/api/jobs/:id", (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) return res.status(404).json({ error: "job not found" });
  res.json(job);
});

app.get("/api/jobs/:id/output", (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job || !job.output_path) return res.status(404).json({ error: "no output" });
  const offset = Math.max(0, parseInt(req.query.offset || "0", 10) || 0);
  const max = 256 * 1024;
  try {
    const stat = fs.statSync(job.output_path);
    const size = stat.size;
    let chunk = "";
    if (size > offset) chunk = fs.readFileSync(job.output_path, "utf8").slice(offset, offset + max);
    res.json({ output: chunk, size, offset: offset + chunk.length });
  } catch (e) {
    res.status(500).json({ error: String(e.message) });
  }
});

app.post("/api/jobs", auth.requirePerm("deploy"), (req, res) => {
  const body = req.body || {};
  const action = executor.validateAction(String(body.action || ""));
  if (!action) return res.status(400).json({ error: "invalid action" });
  const params = { ...body, action };
  const missing = checkMissing(action, params);
  if (missing) return res.status(400).json({ error: missing });
  const job = executor.createJob(jobs, params, req.auth ? req.auth.sub : "admin");
  job.target_vc = String(params.vcenter || "");
  job.target_env = String(params.env || "");
  job.target_vm = String(params.vm_name || "");
  if (job.target_vc || job.target_env || job.target_vm) {
    jobs.update(job.id, { target_vc: job.target_vc, target_env: job.target_env, target_vm: job.target_vm });
  }
  executor.startJob(io, jobs, job, config.vmpilotDir, {
    sshKey: config.sshKeyPath,
    sshUser: config.sshUser,
    onJobEvent: (finished, code) => alerts.pushEvent(db, {
      vc: finished.target_vc, env: finished.target_env, vm: finished.target_vm,
      label: `${finished.action} job ${code === 0 ? "succeeded" : "failed"}`,
      value: code === 0 ? undefined : `exit ${code}`,
      severity: code === 0 ? "info" : "warn",
      task_id: finished.id,
      user: finished.user || (req.auth ? req.auth.sub : "admin")
    })
  });
  alerts.pushEvent(db, {
    vc: job.target_vc, env: job.target_env, vm: job.target_vm,
    label: `${action} job started`, severity: "info", task_id: job.id,
    user: job.user
  });
  res.status(202).json(job);
});

function checkMissing(action, params) {
  const spec = {
    deploy: ["vcenter", "env", "vm_name"],
    "deploy-plan": ["vcenter", "env", "vm_name"],
    sync: ["vcenter", "env"],
    "sync-plan": ["vcenter", "env"],
    destroy: ["vcenter", "env", "vm_name"],
    restore: ["backup_file"],
    expand: ["vcenter", "env", "vm_name", "ip", "new_size_gb"]
  }[action] || [];
  const missing = spec.filter((k) => !params[k]);
  return missing.length ? `missing: ${missing.join(", ")}` : null;
}

// ---- Backups (list + restore) ----
app.get("/api/backups", (req, res) => res.json(executor.listBackups(config.vmpilotDir)));

// ---- IPAM snapshot (free IP + used list for a vCenter+env) ----
app.get("/api/ipam", vcLimiter, ah(async (req, res) => {
  const vc = String(req.query.vc || "");
  const env = String(req.query.env || "");
  if (!vc || !env) return res.status(400).json({ error: "vc and env required" });
  const snap = await opsStatus.ipamSnapshot(config.vmpilotDir, vc, env);
  res.json(snap);
}));

// ---- Environment / setup status (read-only install-readiness) ----
app.get("/api/env/status", ah(async (req, res) => {
  const tools = await opsStatus.toolStatus();
  res.json({ generated_at: Date.now(), tools, ...opsStatus.envStatus(config.vmpilotDir) });
}));

// ---- Socket.io ----
// Terminal + live jobs namespace. Both authenticate via the session cookie.

// SPA fallback for client-side routes (everything that isn't /api/* or a
// real file) → index.html.
app.get(/^\/(?!api|socket\.io).*/, (req, res) => {
  res.sendFile(path.join(frontendDir, "index.html"));
});

const server = http.createServer(app);
const io = new Server(server, {
  path: "/socket.io",
  transports: ["websocket", "polling"],
  maxHttpBufferSize: 64 * 1024,
  cookie: false // terminal uses the session cookie, not an io cookie
});

attachTerminal(io, config);
attachConsole(io, {
  ...config,
  onEvent: (e) => {
    try { events.create({ ...e, id: randomUUID() }); } catch { /* best-effort */ }
  }
});

const jobsNs = io.of("/jobs");
jobsNs.use((socket, next) => {
  const payload = auth.payloadFromRequest({ headers: socket.handshake.headers });
  if (!payload) return next(new Error("unauthorized"));
  socket.payload = payload;
  next();
});
jobsNs.on("connection", () => {
  // job progress is broadcast to all authenticated listeners via namespace-wide events
});

if (!config.secret) {
  // In production we refuse to boot with a weak default secret.
  throw new Error("WEBUI_SECRET is not set — refusing to start");
}
if (!config.passHash) {
  throw new Error("WEBUI_PASS_HASH is not set — refusing to start");
}

server.listen(config.port, config.host, () => {
  console.log(`[vmpilot-webui] server listening on ${config.host}:${config.port}`);
});

// Global handlers to capture uncaught exceptions and unhandled rejections
process.on("uncaughtException", (err) => {
  try { console.error("[vmpilot-webui] UncaughtException:", err && err.stack || err); }
  catch (e) { console.error("[vmpilot-webui] Error logging uncaughtException", e); }
  // Do not exit the process to keep the web UI available; operator can restart if needed.
});
process.on("unhandledRejection", (reason, p) => {
  try { console.error("[vmpilot-webui] UnhandledRejection:", reason, p); }
  catch (e) { console.error("[vmpilot-webui] Error logging unhandledRejection", e); }
});
