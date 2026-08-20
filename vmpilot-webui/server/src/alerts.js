"use strict";

// Alert/event log — backed by the SQLite events table (db.js makeEventStore).
// Sources:
//   1. RESOURCE: VM/host CPU or RAM utilization above threshold (evaluated on
//      the monitor snapshot).
//   2. EVENT:    VM power on/off, job (deploy/plan/sync) outcomes.
//
// Thresholds + delivery config come from the `alerting` settings row; see
// getConfig() below. SMTP delivery is opt-in (see mailer.js) — when no SMTP is
// configured the bell/log still works, delivery is just skipped.

const dbmod = require("./db");
const config = require("./config");

const DEFAULT_CONFIG = {
  resource_enabled: true,
  event_enabled: true,
  cpu_warn: 85,
  cpu_crit: 95,
  mem_warn: 85,
  mem_crit: 95,
  disk_warn: 85,
  disk_crit: 95,
  host_down_enabled: true,
  delivery: "bell",        // "bell" | "email" | "both"
  smtp: {
    host: "",
    port: 587,
    secure: false,
    user: "",
    password: "",
    from: "",
    to: ""
  }
};

const MAX_EVENTS = 500;

let settingsStore = null;

function init(database) {
  settingsStore = dbmod.makeSettingStore(database);
}

function getConfig() {
  const c = settingsStore ? settingsStore.get("alerting") : null;
  return { ...DEFAULT_CONFIG, ...(c || {}) };
}

function setConfig(next) {
  const cur = getConfig();
  const merged = { ...cur, ...(next || {}) };
  // Sanity-guard numeric thresholds: 0 / NaN / empty / > 100 would make the
  // evaluator alert on every entity (e.g. disk_crit=0 → "Datastore full" for
  // all). Treat them as "not set" and keep the configured default.
  for (const k of ["disk_warn", "disk_crit", "cpu_warn", "cpu_crit", "mem_warn", "mem_crit"]) {
    if (merged[k] !== undefined) {
      const n = Number(merged[k]);
      merged[k] = Number.isFinite(n) && n > 0 && n <= 100 ? n : cur[k];
    }
  }
  if (merged.smtp && cur.smtp) {
    // preserve existing password unless a new one is supplied
    merged.smtp = { ...cur.smtp, ...merged.smtp };
    if (!merged.smtp.password && cur.smtp.password) merged.smtp.password = cur.smtp.password;
  }
  settingsStore.set("alerting", merged);
  return merged;
}

function saveConfigDummy() { /* reserved for future per-channel config */ }

let seq = 0;
const newId = () => `${Date.now().toString(36)}-${(seq++).toString(36)}`;

// Unexpected VM power-off tracking. prevPower remembers the last seen power
// state per VM so a poweredOn → poweredOff transition can be alerted; the
// firedDown set stops re-alerting on every poll until the VM comes back on.
const prevPower = new Map();
const firedDown = new Set();

// Evaluate the full monitor snapshot and append any NEW resource alerts.
// Each alert is deduped so it appears once until the condition clears.
function evaluate(db, snapshots, vmpilotDir = "") {
  const events = dbmod.makeEventStore(db);
  const cfg = getConfig();
  const add = (e) => {
    if (events.dedupeExists(e)) return;
    const id = newId();
    const full = { id, ...e, at: Date.now(), seen: 0, notified: 0 };
    events.create(full);
    deliver(db, events, full, cfg);
  };
  // Like add() but ignores the dedupe — used for state-transition alerts that
  // must re-fire each time (VM down) even if an old one is still in the log.
  const addRaw = (e) => {
    const id = newId();
    const full = { id, ...e, at: Date.now(), seen: 0, notified: 0 };
    events.create(full);
    deliver(db, events, full, cfg);
  };

  if (!cfg.resource_enabled) return events.list({ limit: MAX_EVENTS });

  for (const vcSnap of snapshots || []) {
    const vc = vcSnap.vcenter;
    for (const h of vcSnap.hosts || []) {
      // Host down / disconnected — only fire when live data is available (the
      // script reports power/connection state only when govc answered).
      if (cfg.host_down_enabled !== false && (h.powerState || h.connectionState)) {
        const down = (h.powerState && h.powerState !== "poweredOn") || (h.connectionState && h.connectionState !== "connected");
        if (down) {
          const why = `${h.powerState || "?"} / ${h.connectionState || "?"}`;
          add({ kind: "resource", severity: "critical", vc, env: "", vm: h.name, label: "Host DOWN", value: why });
        }
      }
      const cpu = (h.cpuCores || 0) * (h.cpuMhz || 0);
      if (cpu > 0) {
        const cpuPct = Math.round((h.cpuUsageMHz || 0) / cpu * 100);
        if (cpuPct >= cfg.cpu_crit) add({ kind: "resource", severity: "critical", vc, env: "", vm: h.name, label: "Host CPU", value: cpuPct + "%" });
        else if (cpuPct >= cfg.cpu_warn) add({ kind: "resource", severity: "warn", vc, env: "", vm: h.name, label: "Host CPU", value: cpuPct + "%" });
      }
      if (h.memoryMB > 0) {
        const memPct = Math.round((h.memUsageMB || 0) / h.memoryMB * 100);
        if (memPct >= cfg.mem_crit) add({ kind: "resource", severity: "critical", vc, env: "", vm: h.name, label: "Host RAM", value: memPct + "%" });
        else if (memPct >= cfg.mem_warn) add({ kind: "resource", severity: "warn", vc, env: "", vm: h.name, label: "Host RAM", value: memPct + "%" });
      }
    }
    for (const d of vcSnap.datastores || []) {
      const cap = d.capacity || 0;
      if (cap > 0) {
        const usedPct = Math.round((cap - (d.free || 0)) / cap * 100);
        if (usedPct >= cfg.disk_crit) add({ kind: "resource", severity: "critical", vc, env: "", vm: d.name, label: "Datastore full", value: usedPct + "%" });
        else if (usedPct >= cfg.disk_warn) add({ kind: "resource", severity: "warn", vc, env: "", vm: d.name, label: "Datastore", value: usedPct + "%" });
      }
    }
    for (const env of vcSnap.envs || []) {
      for (const vm of env.vms || []) {
        const live = vm.live || {};

        // Unexpected VM power-off: poweredOn in the previous poll, now off.
        // Suppressed when the operator intentionally powered it off (the power
        // action pushes an "event" alert within the last 5 min).
        const key = `${vc}/${env.env}/${vm.name}`;
        const prev = prevPower.get(key);
        prevPower.set(key, vm.power);
        if (vm.power && vm.power !== "notDeployed" && prev === "poweredOn" && vm.power !== "poweredOn") {
          if (!firedDown.has(key)) {
            const intentional = events.recentEvent(env.env, vm.name, 5 * 60 * 1000);
            if (!intentional) {
              firedDown.add(key);
              addRaw({ kind: "resource", severity: "critical", vc, env: env.env, vm: vm.name, label: "VM DOWN", value: `${prev} → ${vm.power}` });
            }
          }
        } else if (vm.power === "poweredOn") {
          firedDown.delete(key);
        }

        const cpuPct = vm.power === "poweredOn" && (vm.cpu || 1) ? Math.round((live.cpuUsageMHz || 0) / ((vm.cpu || 1) * 2000) * 100) : 0;
        if (cpuPct >= cfg.cpu_crit) add({ kind: "resource", severity: "critical", vc, env: env.env, vm: vm.name, label: "VM CPU", value: cpuPct + "%" });
        else if (cpuPct >= cfg.cpu_warn) add({ kind: "resource", severity: "warn", vc, env: env.env, vm: vm.name, label: "VM CPU", value: cpuPct + "%" });
        const memPct = vm.power === "poweredOn" && (vm.memory_mb || 1) ? Math.min(100, Math.round((live.memUsageMB || 0) / (vm.memory_mb || 1) * 100)) : 0;
        if (memPct >= cfg.mem_crit) add({ kind: "resource", severity: "critical", vc, env: env.env, vm: vm.name, label: "VM RAM", value: memPct + "%" });
        else if (memPct >= cfg.mem_warn) add({ kind: "resource", severity: "warn", vc, env: env.env, vm: vm.name, label: "VM RAM", value: memPct + "%" });

        // Guest-OS criticals from the guest probe cache (best-effort): failed
        // systemd services, root disk filling, stale probe on a powered-on VM.
        if (vm.power === "poweredOn" && vm.ip && vmpilotDir) {
          try {
            const fs = require("fs");
            const path = require("path");
            const cacheFile = path.join(vmpilotDir, ".cache", `guest-${vm.ip}.json`);
            if (fs.existsSync(cacheFile)) {
              const c = JSON.parse(fs.readFileSync(cacheFile, "utf8"));
              if (c && c.ok && c.data) {
                const d = c.data;
                const svcs = (d.services_failed || []).filter((s) => s.name);
                if (svcs.length) {
                  add({ kind: "resource", severity: "warn", vc, env: env.env, vm: vm.name, label: "VM failed services", value: svcs.map((s) => s.name).join(", ").slice(0, 80) });
                }
                const root = (d.disk || []).find((x) => x.mount === "/");
                if (root && root.pct) {
                  const p = Number(root.pct);
                  if (p >= cfg.disk_crit) add({ kind: "resource", severity: "critical", vc, env: env.env, vm: vm.name, label: "Guest / full", value: p + "%" });
                  else if (p >= cfg.disk_warn) add({ kind: "resource", severity: "warn", vc, env: env.env, vm: vm.name, label: "Guest / disk", value: p + "%" });
                }
              }
            }
          } catch { /* guest-cache alert best-effort */ }
        }
      }
    }
    // vCenter native alarms (AlarmManager triggered alarms) — the SAME alarms
    // the vSphere UI shows (host health, memory/CPU exhaustion, HA failover…).
    // Surfaced as resource alerts so they land in Notifications + Events.
    //   • deduped per src (alarm identity + entity) — one event per alarm
    //   • yellow → warn, red → critical (green rows are already filtered by
    //     the inventory script)
    //   • alarms vCenter has since cleared are marked resolved: they stay in
    //     the ledger as history but stop counting toward the unseen bell.
    //     Guarded by !alarms_error so a transient govc failure never
    //     false-resolves every alarm.
    if (Array.isArray(vcSnap.alarms) && !vcSnap.alarms_error) {
      const alarmSrcs = [];
      for (const a of vcSnap.alarms) {
        const sev = a.status === "red" ? "critical" : a.status === "yellow" ? "warn" : "info";
        if (sev === "info") continue;
        const src = `alarm:${a.alarmId || "?"}:${a.entityMoid || ""}`;
        alarmSrcs.push(src);
        const vm = (a.entityType === "HostSystem" || a.entityType === "VirtualMachine") ? (a.entityName || a.entityPath || "") : "";
        add({
          kind: "resource", severity: sev, vc, env: "", vm,
          label: a.name || "vCenter alarm",
          value: (a.message || "").slice(0, 160),
          src
        });
      }
      events.resolveBySrc(vc, alarmSrcs);
    }
  }
  return events.list({ limit: MAX_EVENTS });
}

// Append an event alert (power on/off, job outcome). Events are not deduped —
// every deploy / power action is a distinct notification.
function pushEvent(db, a) {
  const events = dbmod.makeEventStore(db);
  const cfg = getConfig();
  if (cfg.event_enabled === false) return events.list({ limit: MAX_EVENTS });
  const id = newId();
  events.create({ id, kind: "event", severity: a.severity || "info", ...a, at: Date.now(), seen: 0, notified: 0 });
  deliver(db, events, { id, kind: "event", severity: a.severity || "info", ...a, at: Date.now() }, cfg);
  return events.list({ limit: MAX_EVENTS });
}

// Best-effort SMTP delivery when configured + delivery mode includes email.
function deliver(db, events, alert, cfg) {
  if (cfg.delivery !== "email" && cfg.delivery !== "both") return;
  const mailer = require("./mailer");
  mailer.sendAlert(cfg, alert, config.baseUrl).then((r) => {
    events.markNotified(alert.id, r.ok ? undefined : r.error);
  }).catch(() => {});
}

function list(db, { vc, env, vm, kind, severity, limit = MAX_EVENTS } = {}) {
  return dbmod.makeEventStore(db).list({ vc, env, vm, kind, severity, limit });
}

function get(db, id) {
  return dbmod.makeEventStore(db).get(id);
}

function markSeen(db, ids) {
  const events = dbmod.makeEventStore(db);
  events.markSeen(ids || []);
  return { count: events.summary().unseen };
}

function clear(db) {
  const events = dbmod.makeEventStore(db);
  events.clear();
  return [];
}

function countUnseen(db) {
  return dbmod.makeEventStore(db).summary().unseen;
}

function summary(db) {
  return dbmod.makeEventStore(db).summary();
}

module.exports = {
  init, getConfig, setConfig,
  evaluate, pushEvent, list, get, markSeen, clear, countUnseen, summary,
  DEFAULT_CONFIG, saveConfigDummy
};