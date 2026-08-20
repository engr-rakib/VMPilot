"use strict";

const fs = require("fs");
const path = require("path");
const { DatabaseSync } = require("node:sqlite");

function openDb(dataDir) {
  fs.mkdirSync(dataDir, { recursive: true });
  const db = new DatabaseSync(path.join(dataDir, "webui.db"));
  db.exec(`
    CREATE TABLE IF NOT EXISTS jobs (
      id          TEXT PRIMARY KEY,
      action      TEXT NOT NULL,
      status      TEXT NOT NULL,
      params      TEXT NOT NULL,
      user        TEXT,
      exit_code   INTEGER,
      output_path TEXT,
      started_at  INTEGER,
      finished_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS events (
      id          TEXT PRIMARY KEY,
      kind        TEXT NOT NULL,        -- 'resource' | 'power' | 'job' | 'system'
      severity    TEXT NOT NULL,        -- 'info' | 'warn' | 'critical'
      vc          TEXT,
      env         TEXT,
      vm          TEXT,
      label       TEXT NOT NULL,
      value       TEXT,
      task_id     TEXT,
      at          INTEGER NOT NULL,     -- epoch ms
      seen        INTEGER DEFAULT 0,
      notified    INTEGER DEFAULT 0,
      notify_error TEXT
    );
    CREATE TABLE IF NOT EXISTS users (
      id          TEXT PRIMARY KEY,
      username    TEXT UNIQUE NOT NULL,
      pass_hash   TEXT NOT NULL,
      role        TEXT NOT NULL DEFAULT 'viewer',
      disabled    INTEGER DEFAULT 0,
      created_at  INTEGER,
      last_login  INTEGER
    );
    CREATE TABLE IF NOT EXISTS settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS roles (
      name       TEXT PRIMARY KEY,
      permissions TEXT NOT NULL,        -- JSON array of permission keys
      builtin    INTEGER DEFAULT 0,     -- 1 = viewer/operator/admin (cannot delete)
      description TEXT
    );
    CREATE TABLE IF NOT EXISTS samples (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      ts          INTEGER NOT NULL,     -- epoch ms (bucket start)
      vc          TEXT NOT NULL,
      kind        TEXT NOT NULL,        -- 'host_cpu'|'host_mem'|'host_net'|'host_disk'|'ds_used'
      entity      TEXT NOT NULL,        -- host name or datastore name / aggregate
      value       REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples (ts);
    CREATE INDEX IF NOT EXISTS idx_samples_entity ON samples (vc, kind, entity);
  `);
  // ensure jobs rows can reference targets even after creation
  const cols = db.prepare("PRAGMA table_info(jobs)").all().map((c) => c.name);
  if (!cols.includes("target_vc")) {
    db.exec("ALTER TABLE jobs ADD COLUMN target_vc TEXT;");
    db.exec("ALTER TABLE jobs ADD COLUMN target_env TEXT;");
    db.exec("ALTER TABLE jobs ADD COLUMN target_vm TEXT;");
  }
  // ensure events rows can carry the acting user for audit trail
  const ecols = db.prepare("PRAGMA table_info(events)").all().map((c) => c.name);
  if (!ecols.includes("user")) {
    db.exec("ALTER TABLE events ADD COLUMN user TEXT;");
  }
  return db;
}

const rowToJob = (r) => ({
  id: r.id,
  action: r.action,
  status: r.status,
  params: JSON.parse(r.params || "{}"),
  user: r.user,
  exit_code: r.exit_code,
  output_path: r.output_path,
  started_at: r.started_at,
  finished_at: r.finished_at,
  target_vc: r.target_vc,
  target_env: r.target_env,
  target_vm: r.target_vm
});

const rowToEvent = (r) => ({
  id: r.id,
  kind: r.kind,
  severity: r.severity,
  vc: r.vc,
  env: r.env,
  vm: r.vm,
  label: r.label,
  value: r.value,
  task_id: r.task_id,
  user: r.user,
  at: r.at,
  seen: !!r.seen,
  notified: !!r.notified,
  notify_error: r.notify_error
});

const rowToUser = (r) => ({
  id: r.id,
  username: r.username,
  role: r.role,
  disabled: !!r.disabled,
  created_at: r.created_at,
  last_login: r.last_login
});

const rowToRole = (r) => ({
  name: r.name,
  permissions: JSON.parse(r.permissions || "[]"),
  builtin: !!r.builtin,
  description: r.description
});

function makeJobStore(db) {
  return {
    create(job) {
      db.prepare(
        `INSERT INTO jobs (id, action, status, params, user, exit_code, output_path, started_at, finished_at, target_vc, target_env, target_vm)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).run(job.id, job.action, job.status, JSON.stringify(job.params), job.user,
            job.exit_code ?? null, job.output_path ?? null, job.started_at ?? null, job.finished_at ?? null,
            job.target_vc ?? null, job.target_env ?? null, job.target_vm ?? null);
    },
    get(id) {
      const r = db.prepare("SELECT * FROM jobs WHERE id = ?").get(id);
      return r ? rowToJob(r) : null;
    },
    update(id, fields) {
      const keys = Object.keys(fields);
      if (!keys.length) return;
      const set = keys.map((k) => `${k} = ?`).join(", ");
      db.prepare(`UPDATE jobs SET ${set} WHERE id = ?`).run(...keys.map((k) => fields[k]), id);
    },
    list(limit = 50) {
      return db
        .prepare("SELECT * FROM jobs ORDER BY started_at DESC LIMIT ?")
        .all(limit)
        .map(rowToJob);
    },
    // task list with optional filters (vcenter/env/vm/action/status)
    listTasks({ vc, env, vm, action, status, limit = 200 } = {}) {
      const where = [];
      const args = [];
      if (vc) { where.push("target_vc = ?"); args.push(vc); }
      if (env) { where.push("target_env = ?"); args.push(env); }
      if (vm) { where.push("target_vm = ?"); args.push(vm); }
      if (action) { where.push("action = ?"); args.push(action); }
      if (status) { where.push("status = ?"); args.push(status); }
      const sql = `SELECT * FROM jobs ${where.length ? "WHERE " + where.join(" AND ") : ""}
                   ORDER BY started_at DESC LIMIT ?`;
      args.push(limit);
      return db.prepare(sql).all(...args).map(rowToJob);
    },
    listTasksByVm(vc, env, vm) {
      return db.prepare(
        `SELECT * FROM jobs WHERE target_vc = ? AND target_env = ? AND target_vm = ? ORDER BY started_at DESC LIMIT 50`
      ).all(vc, env, vm).map(rowToJob);
    }
  };
}

function makeEventStore(db) {
  return {
    create(e) {
      db.prepare(
        `INSERT INTO events (id, kind, severity, vc, env, vm, label, value, task_id, user, at, seen, notified, notify_error)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      ).run(e.id, e.kind, e.severity, e.vc ?? null, e.env ?? null, e.vm ?? null,
            e.label, e.value ?? null, e.task_id ?? null, e.user ?? null, e.at ?? Date.now(),
            e.seen ? 1 : 0, e.notified ? 1 : 0, e.notify_error ?? null);
    },
    list({ vc, env, vm, kind, severity, limit = 200, offset = 0 } = {}) {
      const where = [];
      const args = [];
      if (vc) { where.push("vc = ?"); args.push(vc); }
      if (env) { where.push("env = ?"); args.push(env); }
      if (vm) { where.push("vm = ?"); args.push(vm); }
      if (kind) { where.push("kind = ?"); args.push(kind); }
      if (severity) { where.push("severity = ?"); args.push(severity); }
      const sql = `SELECT * FROM events ${where.length ? "WHERE " + where.join(" AND ") : ""}
                   ORDER BY at DESC LIMIT ? OFFSET ?`;
      args.push(limit, offset);
      return db.prepare(sql).all(...args).map(rowToEvent);
    },
    listUnseen(limit = 100) {
      return db.prepare("SELECT * FROM events WHERE seen = 0 ORDER BY at DESC LIMIT ?")
        .all(limit).map(rowToEvent);
    },
    markSeen(ids) {
      for (const id of ids || []) {
        db.prepare("UPDATE events SET seen = 1 WHERE id = ?").run(id);
      }
      return db.prepare("SELECT COUNT(*) AS c FROM events WHERE seen = 0").get().c;
    },
    markNotified(id, error) {
      if (error) db.prepare("UPDATE events SET notified = 1, notify_error = ? WHERE id = ?").run(String(error), id);
      else db.prepare("UPDATE events SET notified = 1, notify_error = NULL WHERE id = ?").run(id);
    },
    get(id) {
      const r = db.prepare("SELECT * FROM events WHERE id = ?").get(id);
      return r ? rowToEvent(r) : null;
    },
    clear() {
      db.exec("DELETE FROM events;");
    },
    dedupeExists(e) {
      const r = db.prepare(
        `SELECT id FROM events WHERE vc = ? AND COALESCE(env,'') = ? AND COALESCE(vm,'') = ?
         AND kind = ? AND severity = ? LIMIT 1`
      ).get(e.vc ?? null, e.env ?? "", e.vm ?? "", e.kind, e.severity);
      return !!r;
    },
    // Any event for this VM within the last windowMs — used to suppress the
    // "VM DOWN" alert when the operator powered it off intentionally (the power
    // action pushes a "VM powered off" event alert first).
    recentEvent(env, vm, windowMs) {
      const r = db.prepare(
        `SELECT id FROM events WHERE COALESCE(env,'') = ? AND COALESCE(vm,'') = ?
         AND at >= ? ORDER BY at DESC LIMIT 1`
      ).get(env ?? "", vm ?? "", Date.now() - windowMs);
      return !!r;
    },
    summary() {
      const sev = db.prepare("SELECT severity, COUNT(*) AS c FROM events GROUP BY severity").all();
      const kind = db.prepare("SELECT kind, COUNT(*) AS c FROM events GROUP BY kind").all();
      const unseen = db.prepare("SELECT COUNT(*) AS c FROM events WHERE seen = 0").get().c;
      return {
        by_severity: Object.fromEntries(sev.map((r) => [r.severity, r.c])),
        by_kind: Object.fromEntries(kind.map((r) => [r.kind, r.c])),
        unseen
      };
    }
  };
}

function makeUserStore(db) {
  return {
    create(u) {
      db.prepare(
        `INSERT INTO users (id, username, pass_hash, role, disabled, created_at, last_login)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).run(u.id, u.username, u.pass_hash, u.role || "viewer", u.disabled ? 1 : 0,
            u.created_at ?? Date.now(), u.last_login ?? null);
    },
    getByUsername(username) {
      const r = db.prepare("SELECT * FROM users WHERE username = ?").get(username);
      return r ? { ...rowToUser(r), pass_hash: r.pass_hash } : null;
    },
    get(id) {
      const r = db.prepare("SELECT * FROM users WHERE id = ?").get(id);
      return r ? { ...rowToUser(r), pass_hash: r.pass_hash } : null;
    },
    list() {
      return db.prepare("SELECT * FROM users ORDER BY created_at ASC").all().map(rowToUser);
    },
    update(id, fields) {
      const keys = Object.keys(fields);
      if (!keys.length) return;
      const set = keys.map((k) => `${k} = ?`).join(", ");
      const vals = keys.map((k) => (typeof fields[k] === "boolean" ? (fields[k] ? 1 : 0) : fields[k]));
      db.prepare(`UPDATE users SET ${set} WHERE id = ?`).run(...vals, id);
    },
    delete(id) {
      db.prepare("DELETE FROM users WHERE id = ?").run(id);
    },
    countRole(role) {
      return db.prepare("SELECT COUNT(*) AS c FROM users WHERE role = ? AND disabled = 0").get(role).c;
    },
    count() {
      return db.prepare("SELECT COUNT(*) AS c FROM users").get().c;
    }
  };
}

function makeSettingStore(db) {
  return {
    get(key) {
      const r = db.prepare("SELECT value FROM settings WHERE key = ?").get(key);
      if (!r) return null;
      try { return JSON.parse(r.value); } catch { return r.value; }
    },
    set(key, value) {
      const v = typeof value === "string" ? value : JSON.stringify(value);
      db.prepare(
        `INSERT INTO settings (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value`
      ).run(key, v);
    }
  };
}

function makeSampleStore(db) {
  return {
    // append one sample row (value aggregated to the bucket)
    add(ts, vc, kind, entity, value) {
      db.prepare("INSERT INTO samples (ts, vc, kind, entity, value) VALUES (?, ?, ?, ?, ?)")
        .run(ts, vc, kind, entity, value);
    },
    addMany(rows) {
      const st = db.prepare("INSERT INTO samples (ts, vc, kind, entity, value) VALUES (?, ?, ?, ?, ?)");
      for (const r of rows || []) st.run(r.ts, r.vc, r.kind, r.entity, r.value);
    },
    // series for one vc+kind+entity over [fromTs, toTs], oldest first
    series({ vc, kind, entity, fromTs, toTs, limit = 5000 }) {
      return db.prepare(
        `SELECT ts, value FROM samples
         WHERE vc = ? AND kind = ? AND entity = ?
           AND ts >= ? AND ts <= ?
         ORDER BY ts ASC LIMIT ?`
      ).all(vc, kind, entity, fromTs, toTs, limit).map((r) => ({ ts: r.ts, value: r.value }));
    },
    // latest value for each entity of a kind (vc-agnostic, for quick checks)
    latest(kind, vc) {
      const rows = db.prepare(
        `SELECT entity, value FROM samples
         WHERE kind = ? AND vc = ? AND ts = (SELECT MAX(ts) FROM samples WHERE kind = ? AND vc = ?)`
      ).all(kind, vc, kind, vc);
      return Object.fromEntries(rows.map((r) => [r.entity, r.value]));
    },
    prune(keepMs) {
      db.prepare("DELETE FROM samples WHERE ts < ?").run(Date.now() - keepMs);
    }
  };
}

function makeRoleStore(db) {
  return {
    create(role) {
      db.prepare(
        `INSERT INTO roles (name, permissions, builtin, description) VALUES (?, ?, ?, ?)`
      ).run(role.name, JSON.stringify(role.permissions || []), role.builtin ? 1 : 0, role.description || "");
    },
    get(name) {
      const r = db.prepare("SELECT * FROM roles WHERE name = ?").get(name);
      return r ? rowToRole(r) : null;
    },
    list() {
      return db.prepare("SELECT * FROM roles ORDER BY builtin DESC, name ASC").all().map(rowToRole);
    },
    update(name, fields) {
      const keys = Object.keys(fields);
      if (!keys.length) return;
      const set = keys.map((k) => `${k} = ?`).join(", ");
      const vals = keys.map((k) => (Array.isArray(fields[k]) ? JSON.stringify(fields[k]) : fields[k]));
      db.prepare(`UPDATE roles SET ${set} WHERE name = ?`).run(...vals, name);
    },
    delete(name) {
      db.prepare("DELETE FROM roles WHERE name = ?").run(name);
    },
    permissionsOf(roleName) {
      const r = db.prepare("SELECT permissions FROM roles WHERE name = ?").get(roleName);
      if (!r) return [];
      try { return JSON.parse(r.permissions || "[]"); } catch { return []; }
    }
  };
}

module.exports = { openDb, makeJobStore, makeEventStore, makeUserStore, makeSettingStore, makeRoleStore, makeSampleStore };