"use strict";

// VMPilot catalog module — reads/writes the on-disk tfvars inventory the same
// way the CLI scripts do, so the web UI can offer interactive vCenter-setup,
// VM-config create/edit and monitoring without duplicating Terraform logic.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFile, execFileSync } = require("child_process");

// ---------------------------------------------------------------------------
// HCL (tfvars subset) parser + writer
// ---------------------------------------------------------------------------
// Handles the exact structure the VMPilot scripts generate:
//   key = "string" | 24 | true | false | [ ... ] | { ... }
//   vm_configs = { name = { ... } }
//   os_partitions = [ { mount_point = "/", size = "10G", ... }, ... ]
// Comments (lines starting with # or //) are preserved only as raw text.

function parseHclText(text) {
  const src = String(text || "");
  let i = 0;
  const n = src.length;

  function skipWs() {
    while (i < n) {
      const c = src[i];
      if (c === "#") {
        while (i < n && src[i] !== "\n") i++;
      } else if (c === " " || c === "\t" || c === "\n" || c === "\r") {
        i++;
      } else {
        break;
      }
    }
  }

  function parseString() {
    // at opening quote
    i++; // consume "
    let out = "";
    while (i < n) {
      const c = src[i];
      if (c === "\\") {
        i++;
        const e = src[i];
        if (e === "n") out += "\n";
        else if (e === "t") out += "\t";
        else if (e === "r") out += "\r";
        else if (e === '"') out += '"';
        else if (e === "\\") out += "\\";
        else out += e;
        i++;
      } else if (c === '"') {
        i++;
        return out;
      } else {
        out += c;
        i++;
      }
    }
    return out;
  }

  function parseValue() {
    skipWs();
    const c = src[i];
    if (c === "{") {
      i++;
      const obj = {};
      for (;;) {
        skipWs();
        if (src[i] === "}") { i++; break; }
        // key — either a bare identifier or a quoted string ("network name")
        let key = "";
        if (src[i] === '"') { key = parseString(); }
        else { while (i < n && !/[=\s}]/.test(src[i])) { key += src[i]; i++; } }
        skipWs();
        if (src[i] === "=") i++;
        skipWs();
        const v = parseValue();
        // if key ends with '=' already consumed, use it
        obj[key.trim()] = v;
        skipWs();
        if (src[i] === ",") i++;
      }
      return obj;
    }
    if (c === "[") {
      i++;
      const arr = [];
      for (;;) {
        skipWs();
        if (src[i] === "]") { i++; break; }
        if (src[i] === ",") { i++; continue; }
        arr.push(parseValue());
      }
      return arr;
    }
    if (c === '"') return parseString();
    // bare token: number / bool / null
    let tok = "";
    while (i < n && !/[\s,}\]\]]/.test(src[i])) { tok += src[i]; i++; }
    const t = tok.trim();
    if (t === "true") return true;
    if (t === "false") return false;
    if (t === "null") return null;
    if (/^-?\d+(\.\d+)?$/.test(t)) return Number(t);
    return t; // unknown identifier kept as string
  }

  const root = {};
  for (;;) {
    skipWs();
    if (i >= n) break;
    let key = "";
    while (i < n && src[i] !== "=" && src[i] !== "\n") { key += src[i]; i++; }
    skipWs();
    if (src[i] === "=") i++;
    const v = parseValue();
    root[key.trim()] = v;
  }
  return root;
}

// Deterministic HCL writer matching VMPilot's generated style.
function hclValue(v, indent) {
  const pad = " ".repeat(indent || 0);
  if (v === null || v === undefined) return "null";
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) {
    if (v.length === 0) return "[]";
    const items = v.map((x) => hclValue(x, indent + 2)).join(", ");
    return `[\n${v.map((x) => " ".repeat(indent + 2) + hclValue(x, indent + 4)).join(",\n")}\n${pad}]`;
  }
  if (typeof v === "object") {
    const keys = Object.keys(v);
    if (keys.length === 0) return "{}";
    const body = keys
      .map((k) => `${" ".repeat(indent + 2)}${k} = ${hclValue(v[k], indent + 2)}`)
      .join(",\n");
    return `{\n${body}\n${pad}}`;
  }
  return String(v);
}

// ---------------------------------------------------------------------------
// filesystem helpers (read + sudo fallback for root-owned secrets)
// ---------------------------------------------------------------------------
function readFileOrSudo(p) {
  try {
    return fs.readFileSync(p, "utf8");
  } catch (e) {
    if (e.code !== "EACCES" && e.code !== "EPERM") throw e;
    // Files (esp. the demo dir + secure/*) are often root-owned 0600 while the
    // container runs as uid 1000 with passwordless sudo — read them synchronously
    // so the sync catalog readers (readVmConfig & co.) keep working.
    return execFileSync("sudo", ["-n", "cat", p], { maxBuffer: 4 * 1024 * 1024, encoding: "utf8" });
  }
}

async function writeFileOrSudo(p, content) {
  const tmp = path.join(os.tmpdir(), `catalog-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  fs.writeFileSync(tmp, content, { mode: 0o600 });
  try {
    fs.writeFileSync(p, content, { mode: 0o600 });
    fs.rmSync(tmp, { force: true });
    return;
  } catch (e) {
    if (e.code !== "EACCES" && e.code !== "EPERM") throw e;
  }
  await new Promise((resolve, reject) => {
    execFile("sudo", ["-n", "install", "-m", "600", tmp, p], (err) => {
      fs.rmSync(tmp, { force: true });
      if (err) return reject(new Error(`cannot write ${p}: ${err.message}`));
      resolve();
    });
  });
}

async function mkdirOrSudo(p) {
  try { fs.mkdirSync(p, { recursive: true }); return; }
  catch (e) { if (e.code !== "EACCES" && e.code !== "EPERM") throw e; }
  await new Promise((resolve, reject) => {
    execFile("sudo", ["-n", "mkdir", "-p", p], (err) => err ? reject(err) : resolve());
  });
}

async function rmOrSudo(p) {
  try { fs.rmSync(p, { recursive: true, force: true }); return; }
  catch (e) { if (e.code !== "EACCES" && e.code !== "EPERM") throw e; }
  await new Promise((resolve, reject) => {
    execFile("sudo", ["-n", "rm", "-rf", p], (err) => err ? reject(err) : resolve());
  });
}

// Whether a repo script is directly readable/executable by the container uid.
// Root-owned lab repos need passwordless-sudo bash (same as executor.js).
function repoScriptReadable(vmpilotDir, rel) {
  try {
    fs.accessSync(path.join(vmpilotDir, rel), fs.constants.R_OK | fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// inventory discovery (mirrors scripts/create-vm-config.sh / vcenter-setup.sh)
// ---------------------------------------------------------------------------
function listVcenters(vmpilotDir) {
  const dir = path.join(vmpilotDir, "secure");
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((p) => fs.statSync(path.join(dir, p)).isDirectory() &&
      (fs.existsSync(path.join(dir, p, "credentials.tfvars")) || fs.existsSync(path.join(dir, p, "vcenter.tfvars"))))
    .sort();
}

function listEnvs(vmpilotDir, vc) {
  const dir = path.join(vmpilotDir, "deploy", vc);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((p) => fs.statSync(path.join(dir, p)).isDirectory())
    .sort();
}

function parseVmFile(filename) {
  // vm-<name>_<ip>.tfvars
  const m = filename.match(/^vm-(.+)_(\d+\.\d+\.\d+\.\d+)\.tfvars$/);
  return m ? { name: m[1], ip: m[2], file: filename } : { name: filename, ip: "", file: filename };
}

function listVmConfigs(vmpilotDir, vc, env) {
  const dir = path.join(vmpilotDir, "deploy", vc, env);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => f.startsWith("vm-") && f.endsWith(".tfvars"))
    .map(parseVmFile)
    .sort((a, b) => a.name.localeCompare(b.name));
}

// Read + parse a per-VM tfvars file → { top: {...}, vm_configs: {...} }
function readVmConfig(vmpilotDir, vc, env, file) {
  const full = path.join(vmpilotDir, "deploy", vc, env, file);
  const raw = readFileOrSudo(full);
  const parsed = parseHclText(raw);
  const vms = parsed.vm_configs && typeof parsed.vm_configs === "object" ? parsed.vm_configs : {};
  delete parsed.vm_configs;
  return { raw, top: parsed, vm_configs: vms };
}

// Read vCenter inventory from secure/<vc>/vcenter.tfvars (plaintext, readable)
function readVcenterInventory(vmpilotDir, vc) {
  const f = path.join(vmpilotDir, "secure", vc, "vcenter.tfvars");
  if (!fs.existsSync(f)) return {};
  return parseHclText(readFileOrSudo(f));
}

// Candidate lists for VM creation — the CLI + UI share ONE provider
// (scripts/vcenter-inventory.sh) so both see identical data: cache-first from
// secure/<vc>/vcenter.tfvars + live govc gap-fill for options the file lacks.
// This is the same union the CLI pick menus use.
function inventoryOptions(vmpilotDir, vc) {
  const script = path.join(vmpilotDir, "scripts", "vcenter-inventory.sh");
  const printable = repoScriptReadable(vmpilotDir, "scripts/vcenter-inventory.sh");
  const args = printable ? [script, vc, "options"] : ["-n", "-E", "bash", script, vc, "options"];
  const raw = execFileSync(printable ? "bash" : "sudo", args, {
    cwd: vmpilotDir,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    env: { ...process.env, TERM: "dumb" }
  });
  try {
    const j = JSON.parse(raw.trim().split("\n").pop());
    if (j && typeof j === "object") return j;
  } catch { /* fall through to the file-only reader */ }
  return inventoryOptionsFromFile(vmpilotDir, vc);
}

// File-only fallback (script missing / JSON malformed) — legacy shape.
function inventoryOptionsFromFile(vmpilotDir, vc) {
  const inv = readVcenterInventory(vmpilotDir, vc);
  const one = (k, listK) => {
    const vals = [];
    const a = inv[listK];
    if (Array.isArray(a)) vals.push(...a.map((x) => (typeof x === "string" ? x : String(x))));
    if (inv[k]) vals.push(inv[k]);
    return [...new Set(vals.filter(Boolean))];
  };
  // Per-network IPAM defaults — { "<network>" = { gateway, netmask, ipam_base_ip, dns_servers } }
  let network_subnets = {};
  if (inv.network_subnets && typeof inv.network_subnets === "object") {
    for (const [name, cfg] of Object.entries(inv.network_subnets)) {
      if (cfg && typeof cfg === "object") network_subnets[name] = { ...cfg };
    }
  }
  // Per-network host/node pinning — { "<network>" = "<esxi-node>" }
  let network_hosts = {};
  if (inv.network_hosts && typeof inv.network_hosts === "object") {
    for (const [name, node] of Object.entries(inv.network_hosts)) {
      if (typeof node === "string" && node) network_hosts[name] = node;
    }
  }
  // Discovered host inventory — { "<node>" = { ip, networks[] } } (reference)
  let hosts = [];
  if (inv.hosts && typeof inv.hosts === "object") {
    for (const [name, cfg] of Object.entries(inv.hosts)) {
      if (cfg && typeof cfg === "object") {
        hosts.push({
          name,
          ip: typeof cfg.ip === "string" ? cfg.ip : "",
          networks: Array.isArray(cfg.networks) ? cfg.networks.map(String) : []
        });
      }
    }
    hosts.sort((a, b) => a.name.localeCompare(b.name));
  }
  return {
    datacenter: inv.datacenter || "",
    datacenters: inv.datacenter ? [inv.datacenter] : [],
    clusters: one("cluster", "clusters"),
    templates: one("template", "templates"),
    datastores: one("datastore", "datastores"),
    networks: one("network", "networks"),
    resource_pools: one("resource_pool", "resource_pools"),
    network_subnets,
    network_hosts,
    hosts,
    items: {
      clusters: one("cluster", "clusters"),
      templates: one("template", "templates"),
      datastores: one("datastore", "datastores"),
      networks: one("network", "networks"),
      resource_pools: one("resource_pool", "resource_pools"),
      hosts: hosts.map((h) => h.name)
    },
    domain: inv.domain || "",
    gateway: inv.gateway || "",
    netmask: inv.netmask ?? 24,
    dns_servers: Array.isArray(inv.dns_servers) ? inv.dns_servers : [],
    ipam_base_ip: inv.ipam_base_ip || ""
  };
}

// Per-env override file (secure/<vc>/<env>/vcenter.tfvars) — commented template.
function readEnvOverride(vmpilotDir, vc, env) {
  const f = path.join(vmpilotDir, "secure", vc, env, "vcenter.tfvars");
  if (!fs.existsSync(f)) return { raw: "", parsed: {} };
  const raw = readFileOrSudo(f);
  return { raw, parsed: parseHclText(raw) };
}

// Effective inventory = top-level, merged with uncommented per-env overrides.
function readEffectiveInventory(vmpilotDir, vc, env) {
  const top = readVcenterInventory(vmpilotDir, vc);
  const ov = readEnvOverride(vmpilotDir, vc, env).parsed;
  return { ...top, ...ov };
}

// Credentials presence (without exposing the secret)
function vcenterHasCredentials(vmpilotDir, vc) {
  return fs.existsSync(path.join(vmpilotDir, "secure", vc, "credentials.tfvars"));
}

// Most common ssh_public_key across ALL deploy/*/*/vm-*.tfvars — lets the UI
// auto-fill the SSH key field with the project's shared public key.
function findProjectSshKey(vmpilotDir) {
  const deployDir = path.join(vmpilotDir, "deploy");
  if (!fs.existsSync(deployDir)) return "";
  const counts = new Map();
  for (const vc of fs.readdirSync(deployDir)) {
    const vcDir = path.join(deployDir, vc);
    if (!fs.statSync(vcDir).isDirectory() || vc === "examples") continue;
    for (const env of fs.readdirSync(vcDir)) {
      const envDir = path.join(vcDir, env);
      if (!fs.statSync(envDir).isDirectory()) continue;
      for (const file of fs.readdirSync(envDir)) {
        if (!file.startsWith("vm-") || !file.endsWith(".tfvars")) continue;
        const m = readFileOrSudo(path.join(envDir, file)).match(/ssh_public_key\s*=\s*"([^"]+)"/);
        if (m && m[1].trim()) counts.set(m[1], (counts.get(m[1]) || 0) + 1);
      }
    }
  }
  let best = "";
  let bestN = 0;
  for (const [key, n] of counts) {
    if (n > bestN) { best = key; bestN = n; }
  }
  return best;
}

function vcenterDetail(vmpilotDir, vc) {
  return {
    vcenter: vc,
    inventory: readVcenterInventory(vmpilotDir, vc),
    has_credentials: vcenterHasCredentials(vmpilotDir, vc),
    envs: listEnvs(vmpilotDir, vc)
  };
}

function fullCatalog(vmpilotDir) {
  const vcs = listVcenters(vmpilotDir);
  const data = [];
  for (const vc of vcs) {
    const envs = listEnvs(vmpilotDir, vc);
    const envData = envs.map((env) => ({
      env,
      vm_configs: listVmConfigs(vmpilotDir, vc, env).map((c) => {
        const inv = readEffectiveInventory(vmpilotDir, vc, env);
        return {
          ...c,
          summary: summarizeVmConfig(readVmConfig(vmpilotDir, vc, env, c.file), inv)
        };
      })
    }));
    data.push({ vcenter: vc, inventory: readVcenterInventory(vmpilotDir, vc), envs: envData });
  }
  return data;
}

function summarizeVmConfig({ top, vm_configs }, inv) {
  const vms = vm_configs;
  const keys = Object.keys(vms);
  if (keys.length === 0) return { keys: [] };
  const k = keys[0];
  const v = vms[k];
  return {
    keys,
    name: v.hostname || k,
    ip: v.ip_address || "",
    cpu: v.cpu,
    memory_mb: v.memory,
    disk_gb: v.disk_size,
    data_disk_gb: Array.isArray(v.data_disks) ? v.data_disks.map((d) => Number(d && d.size) || 0) : [],
    total_disk_gb: (Number(v.disk_size) || 0) + (Array.isArray(v.data_disks) ? v.data_disks.reduce((a, d) => a + (Number(d && d.size) || 0), 0) : 0),
    os_partitions: Array.isArray(v.os_partitions) ? v.os_partitions.length : 0,
    data_disks: Array.isArray(v.data_disks) ? v.data_disks.length : 0,
    lvm_volumes: Array.isArray(v.lvm_config) ? v.lvm_config.length : 0,
    lvm_detail: Array.isArray(v.lvm_config) ? v.lvm_config.map((l) => ({
      vg: l.vg_name || "", lv: l.lv_name || "", size: l.lv_size || "", mount: l.mount_point || ""
    })) : [],
    extra_users: Array.isArray(v.extra_users) ? v.extra_users.map((u) => u.username).join(", ") : "",
    default_user: v.default_user || "ubuntu",
    user_detail: [{
      username: v.default_user || "ubuntu", groups: "sudo", shell: "/bin/bash", role: "default"
    }].concat(Array.isArray(v.extra_users) ? v.extra_users.map((u) => ({
      username: u.username || "", groups: Array.isArray(u.groups) ? u.groups.join(",") : "", shell: u.shell || "", role: "extra"
    })) : []),
    disable_auto_updates: v.disable_auto_updates === true,
    enable_node_exporter: v.enable_node_exporter === true,
    domain: v.domain,
    gateway: v.gateway,
    netmask: v.netmask,
    dns_servers: Array.isArray(v.dns_servers) ? v.dns_servers : [],
    datacenter: top.datacenter,
    cluster: top.cluster,
    datastore: top.datastore,
    network: top.network,
    template: top.template
  };
}

// ---------------------------------------------------------------------------
// secure/ explorer — list + read + write the vCenter inventory / policy files
// (secure/<vc>/vcenter.tfvars, vm-defaults.conf, per-env override + policy).
// ---------------------------------------------------------------------------
const SECURE_EDITABLE_RE = /\.(tfvars|conf)$/;
const SECURE_ENCRYPTED_RE = /^credentials\.tfvars$/;
const SECURE_POLICY_RE = /^user-groups\.tfvars$/;

// rel path like "vcenter.tfvars", "dev/user-groups.tfvars", "vm-defaults.conf".
// Must stay inside secure/<vc>/ and be a known editable file type.
function secureRelToPath(vmpilotDir, vc, rel) {
  const relStr = String(rel || "");
  if (!relStr || relStr.includes("..") || relStr.startsWith("/")) {
    throw new Error("invalid secure path");
  }
  const base = path.join(vmpilotDir, "secure", vc);
  const full = path.normalize(path.join(base, relStr));
  if (full !== base && !full.startsWith(base + path.sep)) {
    throw new Error("secure path escapes vCenter dir");
  }
  return full;
}

// Build the secure/ tree — the LEFT-panel "Secure" root mirrors the CLI's
// secure/<vc>/ layout: top-level files + per-env dirs with their files.
function secureTree(vmpilotDir) {
  const vcs = listVcenters(vmpilotDir);
  const out = [];
  for (const vc of vcs) {
    const base = path.join(vmpilotDir, "secure", vc);
    const files = [];
    const envs = [];
    try {
      for (const entry of fs.readdirSync(base)) {
        const p = path.join(base, entry);
        const st = fs.statSync(p);
        if (st.isFile()) {
          files.push({
            name: entry,
            editable: SECURE_EDITABLE_RE.test(entry) && !SECURE_ENCRYPTED_RE.test(entry),
            encrypted: SECURE_ENCRYPTED_RE.test(entry),
            policy: SECURE_POLICY_RE.test(entry)
          });
        } else if (st.isDirectory() && /^[a-z0-9_-]+$/.test(entry)) {
          const envFiles = [];
          try {
            for (const f of fs.readdirSync(p)) {
              const fp = path.join(p, f);
              if (!fs.statSync(fp).isFile()) continue;
              envFiles.push({
                name: f,
                editable: SECURE_EDITABLE_RE.test(f) && !SECURE_ENCRYPTED_RE.test(f),
                encrypted: SECURE_ENCRYPTED_RE.test(f),
                policy: SECURE_POLICY_RE.test(f)
              });
            }
          } catch { /* skip unreadable env dir */ }
          envFiles.sort((a, b) => a.name.localeCompare(b.name));
          envs.push({ env: entry, files: envFiles });
        }
      }
    } catch { /* skip unreadable vCenter dir */ }
    files.sort((a, b) => a.name.localeCompare(b.name));
    envs.sort((a, b) => a.env.localeCompare(b.env));
    out.push({ vcenter: vc, files, envs });
  }
  return out;
}

// Read a secure file's raw text (never decrypts credentials.tfvars).
function readSecureFile(vmpilotDir, vc, rel) {
  const full = secureRelToPath(vmpilotDir, vc, rel);
  if (!fs.existsSync(full)) throw new Error("secure file not found");
  return readFileOrSudo(full);
}

// Write a secure file. Credentials are encrypted → read-only; never editable.
async function writeSecureFile(vmpilotDir, vc, rel, raw) {
  if (SECURE_ENCRYPTED_RE.test(String(rel).split("/").pop() || "")) {
    throw new Error("credentials.tfvars is encrypted — not editable in the UI");
  }
  const full = secureRelToPath(vmpilotDir, vc, rel);
  const name = String(rel).split("/").pop() || "";
  if (!SECURE_EDITABLE_RE.test(name)) {
    throw new Error(`unsupported file type for secure editing: ${name}`);
  }
  await mkdirOrSudo(path.dirname(full));
  await writeFileOrSudo(full, String(raw ?? ""));
  return { vcenter: vc, rel, ok: true };
}

// Create a new user-group policy file (per-env) from a template when absent.
async function createSecurePolicy(vmpilotDir, vc, env) {
  if (!/^[a-z0-9_-]+$/.test(String(env || ""))) throw new Error("bad environment name");
  const dir = path.join(vmpilotDir, "secure", vc, env);
  const full = path.join(dir, "user-groups.tfvars");
  if (fs.existsSync(full)) throw new Error(`policy already exists: secure/${vc}/${env}/user-groups.tfvars`);
  await mkdirOrSudo(dir);
  const template = `# ============================================================
# User group policy — secure/${vc}/${env}/user-groups.tfvars
# ============================================================
# Defines what OS-level access each GROUP grants to VM extra_users in THIS env.
# Users are members of GROUPS (a user can be in MANY groups); permission lives
# on the group, not the user.
#
# Per-VM config: extra_users[].groups = list of group names (from this file)
#   { username = "devops", groups = ["admin"], password = "" }
#
# Applied to every VM in this env at deploy time (deploy-vm.sh loads this file).
#
# Group fields:
#   os_groups   = OS groups the user joins (created automatically).
#   sudo        = sudoers rule string; "NONE" = no sudo at all.
#   shell       = login shell (default /bin/bash)
#   description = human-readable purpose of this group — REQUIRED.
#
# CUSTOMIZATION (add your own groups):
#     mygroup = {
#       os_groups   = ["mygroup"]
#       sudo        = "ALL=(ALL) NOPASSWD:/path/to/binary"   # "NONE" = no sudo
#       shell       = "/bin/bash"
#       description = "What this group is for / who it is for"
#     }
#
# IMPORTANT: after changing a group, redeploy VMs that use it:
#   bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>
#
# A user with NO groups = no sudo, default shell, no extra OS groups.

user_groups = {
  # ─── admin ─────────────────────────────────────────────────────────────
  admin = {
    os_groups   = ["sudo", "adm"]
    sudo        = "ALL=(ALL) NOPASSWD:ALL"
    shell       = "/bin/bash"
    description = "Infra admin — full sudo + sudo/adm groups (trusted operators only)"
  }
}
`;
  await writeFileOrSudo(full, template);
  return { vcenter: vc, env, rel: `${env}/user-groups.tfvars`, created: true };
}

// ---------------------------------------------------------------------------
// free IP (IPAM) — calls scripts/next_free_ip.sh with a JSON stdin payload
// ---------------------------------------------------------------------------
function findFreeIp(vmpilotDir, baseIp, skipIp, rangeEnd) {
  return new Promise((resolve, reject) => {
    const input = JSON.stringify({ base_ip: baseIp, ...(skipIp ? { skip_ip: skipIp } : {}), ...(rangeEnd ? { range_end: rangeEnd } : {}) });
    const script = path.join(vmpilotDir, "scripts", "next_free_ip.sh");
    // Repo may be root-owned (locked-down lab hosts) — container uid 1000 must
    // run the script through passwordless sudo, mirroring executor.js.
    let readable = true;
    try { fs.accessSync(script, fs.constants.R_OK); } catch { readable = false; }
    const args = readable ? [script] : ["-n", "-E", "bash", script];
    const child = require("child_process").spawn(readable ? "bash" : "sudo", args, {
      cwd: vmpilotDir
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.stdin.end(input);
    child.on("error", reject);
    child.on("close", (code) => {
      const last = out.trim().split("\n").pop();
      try {
        const j = JSON.parse(last || "{}");
        if (j.free_ip) return resolve(j.free_ip);
        return reject(new Error(j.error || "free IP scan failed"));
      } catch {
        return reject(new Error(`free IP scan failed${err ? ": " + err.slice(0, 200) : ""}`));
      }
    });
  });
}

// ---------------------------------------------------------------------------
// write helpers — build + write the exact tfvars the CLI expects
// ---------------------------------------------------------------------------
function buildVmConfigFile({ header, top, vm_key, vm }) {
  const lines = [];
  if (header) lines.push(header);
  for (const [k, v] of Object.entries(top)) {
    if (k === "vm_configs") continue;
    lines.push(`${k} = ${hclValue(v, 0)}`);
  }
  lines.push("");
  lines.push("vm_configs = {");
  lines.push(`  ${vm_key} = ${hclValue(vm, 2)}`);
  lines.push("}");
  return lines.join("\n") + "\n";
}

module.exports = {
  parseHclText,
  parseVmFile,
  hclValue,
  readFileOrSudo,
  repoScriptReadable,
  listVcenters,
  listEnvs,
  listVmConfigs,
  readVmConfig,
  readVcenterInventory,
  inventoryOptions,
  readEnvOverride,
  readEffectiveInventory,
  findProjectSshKey,
  vcenterDetail,
  fullCatalog,
  summarizeVmConfig,
  findFreeIp,
  writeFileOrSudo,
  mkdirOrSudo,
  rmOrSudo,
  buildVmConfigFile,
  secureTree,
  readSecureFile,
  writeSecureFile,
  createSecurePolicy
};
