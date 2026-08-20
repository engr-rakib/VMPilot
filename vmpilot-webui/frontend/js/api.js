// api.js — fetch helpers (works with the Express API).

// UI label for a job action. Backend action strings stay stable ("expand");
// only the human-readable name is remapped.
export const actionLabel = (a) => a === "expand" ? "Disk Resize" : (a || "");

export async function login(username, password) {
  const r = await fetch("/api/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password })
  });
  if (!r.ok) { const t = await r.json().catch(() => ({})); throw new Error(t.error || "login failed"); }
}

export async function me() {
  const r = await fetch("/api/auth/me");
  if (r.status === 401) return null;
  if (!r.ok) throw new Error("server error");
  return r.json();
}

export async function logout() {
  await fetch("/api/auth/logout", { method: "POST" });
}

async function j(r) {
  const res = await r;                       // r is the fetch() Promise — await to get the Response
  const t = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(t.error || "request failed");
  return t;
}

// ---- catalog / inventory ----
export const getInventory = () => j(fetch("/api/inventory"));
export const getVcenter = (vc) => j(fetch(`/api/vcenters/${encodeURIComponent(vc)}`));

export async function saveVcenter(data, existing) {
  const r = await fetch(existing ? `/api/vcenters/${encodeURIComponent(existing)}` : "/api/vcenters", {
    method: existing ? "PUT" : "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data)
  });
  return j(r);
}

export const deleteVcenter = (vc) => j(fetch(`/api/vcenters/${encodeURIComponent(vc)}`, { method: "DELETE" }));

export async function addEnv(vc, env) {
  const r = await fetch(`/api/vcenters/${encodeURIComponent(vc)}/envs`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ env })
  });
  return j(r);
}

export const deleteEnv = (vc, env) => j(fetch(`/api/vcenters/${encodeURIComponent(vc)}/envs/${encodeURIComponent(env)}`, { method: "DELETE" }));

export const getEnvOverride = (vc, env) => j(fetch(`/api/vcenters/${encodeURIComponent(vc)}/envs/${encodeURIComponent(env)}/override`));
export async function saveEnvOverride(vc, env, raw) {
  const r = await fetch(`/api/vcenters/${encodeURIComponent(vc)}/envs/${encodeURIComponent(env)}/override`, {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ raw })
  });
  return j(r);
}

// ---- VM configs ----
export const getVmConfig = (vc, env, file) => j(fetch(`/api/configs/${encodeURIComponent(vc)}/${encodeURIComponent(env)}/${encodeURIComponent(file)}`));

export async function createVmConfig(data) {
  const r = await fetch("/api/configs", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  return j(r);
}

export async function updateVmConfig(vc, env, file, data) {
  const r = await fetch(`/api/configs/${encodeURIComponent(vc)}/${encodeURIComponent(env)}/${encodeURIComponent(file)}`, {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  return j(r);
}

export const deleteVmConfig = (vc, env, file) => j(fetch(`/api/configs/${encodeURIComponent(vc)}/${encodeURIComponent(env)}/${encodeURIComponent(file)}`, { method: "DELETE" }));

export const findFreeIp = (baseIp, skipIp, rangeEnd) =>
  j(fetch(`/api/freeip?base_ip=${encodeURIComponent(baseIp)}${skipIp ? `&skip_ip=${encodeURIComponent(skipIp)}` : ""}${rangeEnd ? `&range_end=${encodeURIComponent(rangeEnd)}` : ""}`));

export const getVcenterOptions = (vc) => j(fetch(`/api/vcenters/${encodeURIComponent(vc)}/options`));

export const getProjectSshKey = () => j(fetch("/api/ssh-key"));

// ---- live VM / power ----
export const getLiveVms = (vc) => j(fetch(`/api/monitor/live?vc=${encodeURIComponent(vc)}`));

export async function setVmPower(vc, name, action) {
  const r = await fetch("/api/vms/power", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ vc, name, action })
  });
  return j(r);
}

// ---- monitoring ----
export const getMonitor = () => j(fetch("/api/monitor"));

// per-vCenter snapshot — each dashboard/monitor card fetches this independently
export const getMonitorVc = (vc) => j(fetch(`/api/monitor/${encodeURIComponent(vc)}`));
// time-series trend for a vc+kind+entity over the last `hours` (24 default)
export const getTrends = (vc, kind, entity, hours = 24) =>
  j(fetch(`/api/monitor/trends?vc=${encodeURIComponent(vc)}&kind=${encodeURIComponent(kind)}&entity=${encodeURIComponent(entity)}&hours=${hours}`));
// per-vCenter trend BUNDLE for the Inventory right-rail (host + datastore series)
export const getDcTrends = (vc, hours = 24) =>
  j(fetch(`/api/monitor/dc-trends?vc=${encodeURIComponent(vc)}&hours=${hours}`));
// operator deploy statistics (from the jobs ledger)
export const getOperatorStats = () => j(fetch("/api/jobs/operators"));
// names of configured vCenters (/api/vcenters returns [{vcenter, envs[]}])
export const listMonitorVcs = () =>
  fetch("/api/vcenters")
    .then((r) => r.json())
    .then((arr) => (Array.isArray(arr) ? arr.map((x) => x.vcenter || "") : []));

// ---- backups ----
export const getBackups = () => j(fetch("/api/backups"));
export async function restoreBackup(backup_file) {
  const r = await fetch("/api/jobs", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "restore", backup_file })
  });
  return j(r);
}

// ---- IPAM snapshot (free IP + used list) ----
export const getIpam = (vc, env) => j(fetch(`/api/ipam?vc=${encodeURIComponent(vc)}&env=${encodeURIComponent(env)}`));

// ---- environment / setup status ----
export const getEnvStatus = () => j(fetch("/api/env/status"));

// ---- secure explorer (vCenter inventory + per-env policy files) ----
export const getSecureTree = () => j(fetch("/api/secure/tree"));
export const getSecureFile = (vc, rel) => j(fetch(`/api/secure/file?vc=${encodeURIComponent(vc)}&rel=${encodeURIComponent(rel)}`));

export async function saveSecureFile(vc, rel, raw) {
  const r = await fetch("/api/secure/file", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ vcenter: vc, rel, raw })
  });
  return j(r);
}

export async function createSecurePolicy(vc, env) {
  const r = await fetch("/api/secure/policy", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ vcenter: vc, env })
  });
  return j(r);
}

// ---- jobs ----
export const listJobs = () => j(fetch("/api/jobs"));
export const getJob = (id) => j(fetch(`/api/jobs/${id}`));
export const getJobOutput = (id, offset = 0) => j(fetch(`/api/jobs/${id}/output?offset=${offset}`));

export async function createJob(params) {
  const r = await fetch("/api/jobs", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(params)
  });
  return j(r);
}

// socket.io (live job output)
export function connectJobs(cb) {
  const socket = window.io("/jobs", { transports: ["websocket", "polling"] });
  socket.on("job:output", ({ jobId, line }) => cb && cb("output", { jobId, line }));
  socket.on("job:status", ({ jobId, status, exit_code }) => cb && cb("status", { jobId, status, exit_code }));
  return socket;
}

// ---- notifications / alerts ----
export const getAlerts = () => j(fetch("/api/alerts"));
export const getAlertsUnseen = () => j(fetch("/api/alerts/unseen"));
export async function markAlertsSeen(ids) {
  const r = await fetch("/api/alerts/seen", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ids })
  });
  return j(r);
}
export const clearAlerts = () => j(fetch("/api/alerts", { method: "DELETE" }));

// ---- events & tasks ledger ----
const qs = (obj) => {
  const p = Object.entries(obj).filter(([, v]) => v).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
  return p ? `?${p}` : "";
};
export const getEvents = (f) => j(fetch(`/api/events${qs(f || {})}`));
export const getConsoleSessions = () => j(fetch("/api/console/sessions"));
export const getGuestData = (f) => j(fetch(`/api/monitor/guest${qs(f || {})}`));
export const getEventsSummary = () => j(fetch("/api/events/summary"));
export const getEvent = (id) => j(fetch(`/api/events/${encodeURIComponent(id)}`));
export const getTasks = (f) => j(fetch(`/api/tasks${qs(f || {})}`));
export const getTask = (id) => j(fetch(`/api/tasks/${encodeURIComponent(id)}`));
export const markEventsSeen = (ids) => j(fetch("/api/events/seen", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ ids: ids || [] })
}));

// ---- users & settings ----
export const getUsers = () => j(fetch("/api/users"));
export async function createUser(data) {
  const r = await fetch("/api/users", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  return j(r);
}
export async function updateUser(id, data) {
  const r = await fetch(`/api/users/${encodeURIComponent(id)}`, {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  return j(r);
}
export async function deleteUser(id) {
  const r = await fetch(`/api/users/${encodeURIComponent(id)}`, { method: "DELETE" });
  return j(r);
}
export const getRoles = () => j(fetch("/api/roles"));
export async function createRole(data) {
  const r = await fetch("/api/roles", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  return j(r);
}
export async function updateRole(name, data) {
  const r = await fetch(`/api/roles/${encodeURIComponent(name)}`, {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  return j(r);
}
export async function deleteRole(name) {
  const r = await fetch(`/api/roles/${encodeURIComponent(name)}`, { method: "DELETE" });
  return j(r);
}
export const getAlerting = () => j(fetch("/api/settings/alerting"));
export async function saveAlerting(data) {
  const r = await fetch("/api/settings/alerting", {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
  });
  return j(r);
}
export async function testAlerting() {
  const r = await fetch("/api/settings/alerting/test", { method: "POST" });
  return j(r);
}