"use strict";

// vCenter CRUD — mirrors scripts/vcenter-setup.sh so the Web UI can onboard /
// update / remove a vCenter exactly the way the CLI does:
//   * plaintext staging in .tmp-sops-plain/<vc>/ then sops --encrypt --age
//   * secure/<vc>/credentials.tfvars   (encrypted — secrets)
//   * secure/<vc>/vcenter.tfvars       (plaintext — inventory)
//   * deploy/<vc>/{dev,prod,staging}/  + per-env override templates

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFile } = require("child_process");
const catalog = require("./catalog");
const { readFileOrSudo, writeFileOrSudo, mkdirOrSudo, rmOrSudo } = catalog;

const DEFAULT_ENVS = ["dev", "prod", "staging"];

async function run(cmd, args, cwd, timeoutMs = 30000, env = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { cwd, timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, env: { ...process.env, ...env } },
      (err, stdout, stderr) => {
        if (err) return reject(new Error((stderr || err.message || "").toString().slice(0, 500)));
        resolve(stdout.toString("utf8"));
      });
  });
}

function readAgePublicKey(vmpilotDir) {
  // .sops.yaml already pins the recipient; but vcenter-setup.sh resolves the
  // key from the keys file to pass --age. We reuse the pinned file too.
  const keyFile = path.join(vmpilotDir, "sops-age", "keys.txt");
  if (!fs.existsSync(keyFile)) {
    throw new Error("sops-age/keys.txt not found — cannot encrypt credentials");
  }
  const text = readFileOrSudo(keyFile);
  const m = text.match(/public key: (age1[0-9a-z]+)/);
  if (!m) throw new Error("could not read age public key from sops-age/keys.txt");
  return m[1];
}

function sanitizeComponent(name) {
  return String(name || "").replace(/^[a-zA-Z]+:\/\//, "").replace(/[/:]+$/, "")
    .replace(/[^a-zA-Z0-9._-]/g, "_");
}

// Build the plaintext contents both vcenter-setup.sh and this module share.
function buildCredsFile(v) {
  return `vsphere_server       = "${v.server}"
vsphere_user         = "${v.user}"
vsphere_password     = "${v.password}"
allow_unverified_ssl = true
`;
}

// Build the inventory file (list-form / discovery-friendly). Everything is
// AUTO-discovered by vcenter-setup.sh into secure/<vc>/vcenter.tfvars and that
// file is the SINGLE source of truth for both CLI and Web UI. On GUI edit we
// preserve whatever the operator keeps (lists, network_subnets, network_hosts,
// hosts) and only overwrite fields the form actually changed.
function buildInventoryFile(v, existingInventory) {
  const dns = (v.dns_servers || []).map((d) => `"${d}"`).join(", ");
  const list = (k, fallback) => {
    const arr = Array.isArray(v[k]) && v[k].length ? v[k]
      : (v[k] ? [v[k]] : (fallback && fallback.length ? fallback : []));
    return arr.map((x) => `"${x}"`).join(", ");
  };
  const ex = existingInventory || {};
  const clusters = list("clusters", Array.isArray(ex.clusters) ? ex.clusters : []);
  const templates = list("templates", Array.isArray(ex.templates) ? ex.templates : []);
  const datastores = list("datastores", Array.isArray(ex.datastores) ? ex.datastores : []);
  const networks = list("networks", Array.isArray(ex.networks) ? ex.networks : []);
  const pools = list("resource_pools", Array.isArray(ex.resource_pools) ? ex.resource_pools : []);

  // Preserve the operator's per-network IPAM map on edit (GUI textarea → HCL).
  let subnetsBlock = "";
  if (v.network_subnets_raw) {
    subnetsBlock = v.network_subnets_raw.replace(/\s+$/, "");
  } else if (ex.network_subnets) {
    subnetsBlock = "  # network_subnets preserved from the current file (edit in the GUI)";
  }

  // Per-network host/node pinning — network → ESXi node. Curated fact; an empty
  // network falls back to DRS auto-placement.
  let hostsBlock = "";
  if (v.network_hosts_raw) {
    hostsBlock = v.network_hosts_raw.replace(/\s+$/, "");
  } else if (ex.network_hosts) {
    hostsBlock = "  # network_hosts preserved from the current file (edit in the GUI)";
  }

  // Node-wise inventory (AUTO-discovered) — carried forward untouched on edit.
  let nodeInventory = "";
  if (ex.hosts && typeof ex.hosts === "object") {
    const render = (name, cfg) => `  "${name}" = { ip = "${cfg.ip || ""}", datastores = [${(cfg.datastores || []).map((x) => `"${x}"`).join(", ")}], networks = [${(cfg.networks || []).map((x) => `"${x}"`).join(", ")}] }`;
    nodeInventory = Object.entries(ex.hosts)
      .filter(([, c]) => c && typeof c === "object")
      .map(([n, c]) => render(n, c)).join("\n") + "\n";
  }

  return `# ═══════════════════════════════════════════════════════════════════
# ✓ IDENTITY (operator-set at onboarding)
# ═══════════════════════════════════════════════════════════════════
datacenter = "${v.datacenter}"

# ═══════════════════════════════════════════════════════════════════
# ✓ vCenter-WIDE INVENTORY (AUTO-discovered by vcenter-setup.sh) — single
#   source of truth shared by CLI + Web UI (no live discovery at VM-create)
# ═══════════════════════════════════════════════════════════════════
${clusters ? `clusters        = [${clusters}]` : "# clusters        = []"}
${templates ? `templates       = [${templates}]` : "# templates       = []"}
${datastores ? `datastores      = [${datastores}]` : "# datastores      = []"}
${networks ? `networks        = [${networks}]` : "# networks        = []"}
${pools ? `resource_pools  = [${pools}]` : "# resource_pools  = []"}

# Per-vCenter network defaults (used by create-vm-config.sh + terraform)
domain      = "${v.domain}"
gateway     = "${v.gateway}"
netmask     = ${v.netmask || 24}
dns_servers = [${dns}]

# ═══════════════════════════════════════════════════════════════════
# ✓ NODE-WISE INVENTORY (AUTO-discovered) — key = ESXi node
#   Each node: management IPs + datastores mounted + networks attached
# ═══════════════════════════════════════════════════════════════════
hosts = {
${nodeInventory || "  # \"node-01\" = { ip = \"192.168.1.11\", datastores = [\"datastore01\"], networks = [\"VM Network\"] }"}
}

# ═══════════════════════════════════════════════════════════════════
# ✓ PER-NETWORK CONFIG (operator-editable in GUI) — each network has its OWN
#   gateway/netmask/IPAM block. ipam_base = FIRST deployable IP of THIS network
# ═══════════════════════════════════════════════════════════════════
network_subnets = {
${subnetsBlock || "  # \"VM Network\"  = { gateway = \"192.0.2.1\", netmask = 24, ipam_base = \"198.51.100.106\", range_end = \"198.51.100.200\", dns_servers = [" + dns + "] }"}
}

# per-network host/node pinning — selecting a mapped network auto-fills the
# Host (node) in CLI/UI; blank = DRS auto-placement.
network_hosts = {
${hostsBlock || "  # \"VM Network\" = \"esxi-node-01\""}
}

# IPAM — legacy fallback base IP (per-network ipam_base WINS when the network
# has a network_subnets entry)
ipam_base_ip = "${v.ipam_base_ip || ""}"
`;
}

function buildOverrideTemplate(vcenter, env) {
  return `# Per-env override — secure/${vcenter}/${env}/vcenter.tfvars
# Uncomment + set any key to OVERRIDE the top-level secure/${vcenter}/vcenter.tfvars
# for this environment only. Keys left commented fall back to the top-level value.
# (credentials are NEVER per-env — secrets stay in secure/${vcenter}/credentials.tfvars)
#
# datacenter   = "${vcenter}"
# domain       = "example.local"
# gateway      = "192.0.2.1"
# netmask      = 24
# dns_servers  = ["203.0.113.53", "203.0.113.54"]
# ipam_base_ip = "198.51.100.106"
# clusters     = ["primary_cluster"]   # curated lists (auto-discovered if unset)
# templates    = ["ubuntu-24-template"]
# datastores   = ["datastore01"]
# networks     = ["VM Network"]
# resource_pools = ["Resources"]
# network_subnets = { "VM Network" = { gateway = "192.0.2.1", netmask = 24, ipam_base = "198.51.100.106", range_end = "198.51.100.200", dns_servers = ["203.0.113.53"] } }
`;
}

function requireFields(v, fields, label) {
  const missing = fields.filter((f) => !v[f]);
  if (missing.length) throw new Error(`${label}: missing required field(s): ${missing.join(", ")}`);
}

function normalizeVcenter(v) {
  // Editing an existing vCenter with a blank password → keep the current one.
  const isEdit = Boolean(v.existing);
  if (isEdit && !v.password) v.password = null; // resolved below
  // cluster/datastore/network/template/resource_pool are OPTIONAL — govc
  // auto-discovers them at VM-create time. Only connection + network defaults
  // are required at onboarding.
  const required = ["server", "user", "datacenter", "domain", "gateway", "netmask", "ipam_base_ip", "dns_servers"];
  if (!isEdit) required.push("password");
  requireFields(v, required, "vCenter");
  if (!Array.isArray(v.dns_servers) || v.dns_servers.length === 0) {
    throw new Error("vCenter: at least one DNS server required");
  }
  const dcSan = sanitizeComponent(v.datacenter) || v.datacenter;
  const srvSan = sanitizeComponent(v.server);
  const dir = `${dcSan}_${srvSan}`;
  return { ...v, dir };
}

// Create or update a vCenter. When `existing` non-empty it updates in place.
async function saveVcenter(vmpilotDir, input) {
  let v = normalizeVcenter(input);
  const vc = v.existing || v.dir;

  // Edit with blank password → reuse the currently stored (encrypted) one.
  if (v.password === null && v.existing) {
    const cur = await readDecryptedCreds(vmpilotDir, v.existing);
    if (!cur || !cur.pass) throw new Error("could not read existing password — supply one");
    v = { ...v, password: cur.pass };
  }

  const pubKey = readAgePublicKey(vmpilotDir);

  // Validate operator-edited network_subnets HCL before it hits disk.
  if (v.network_subnets_raw && v.network_subnets_raw.trim()) {
    try {
      const parsed = catalog.parseHclText(`network_subnets = {\n${v.network_subnets_raw}\n}`);
      const ns = parsed.network_subnets;
      if (!ns || typeof ns !== "object") throw new Error("must be an object of { \"<network>\" = { ... } }");
      for (const [name, cfg] of Object.entries(ns)) {
        if (!cfg || typeof cfg !== "object") throw new Error(`'${name}' must be an object`);
        if (!cfg.gateway) throw new Error(`'${name}': gateway is required`);
        if (cfg.netmask == null) throw new Error(`'${name}': netmask is required`);
      }
    } catch (e) {
      throw new Error(`network_subnets: ${e.message}`);
    }
  }

  // Validate operator-edited network_hosts HCL (a map of string → string).
  if (v.network_hosts_raw && v.network_hosts_raw.trim()) {
    try {
      const parsed = catalog.parseHclText(`network_hosts = {\n${v.network_hosts_raw}\n}`);
      const nh = parsed.network_hosts;
      if (!nh || typeof nh !== "object") throw new Error("must be an object of { \"<network>\" = \"<node>\" }");
      for (const [name, node] of Object.entries(nh)) {
        if (typeof node !== "string" || !node) throw new Error(`'${name}' must map to a non-empty host name`);
      }
    } catch (e) {
      throw new Error(`network_hosts: ${e.message}`);
    }
  }

  // Existing inventory (to preserve network_subnets the operator already set).
  let existingInv = {};
  const invPath = path.join(vmpilotDir, "secure", vc, "vcenter.tfvars");
  if (fs.existsSync(invPath)) {
    try { existingInv = catalog.parseHclText(readFileOrSudo(invPath) || ""); } catch { existingInv = {}; }
  }

  // Staging dir — same rule as the CLI (must live inside the repo so
  // .sops.yaml creation_rules apply via path_regex).
  const stage = path.join(vmpilotDir, ".tmp-sops-plain", vc);
  await mkdirOrSudo(stage);

  const credsPlain = path.join(stage, "credentials.tfvars");
  const invPlain = path.join(stage, "vcenter.tfvars");
  await writeFileOrSudo(credsPlain, buildCredsFile(v));
  await writeFileOrSudo(invPlain, buildInventoryFile(v, existingInv));

  // Encrypt credentials → secure/<vc>/credentials.tfvars
  const dest = path.join(vmpilotDir, "secure", vc);
  await mkdirOrSudo(dest);
  const enc = await new Promise((resolve, reject) => {
    execFile("sops", ["--encrypt", "--age", pubKey, credsPlain], { cwd: vmpilotDir, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) return reject(new Error((stderr || err.message || "").toString().slice(0, 500)));
        resolve(stdout.toString("utf8"));
      });
  });
  await writeFileOrSudo(path.join(dest, "credentials.tfvars"), enc);

  // Inventory (plaintext, readable)
  await writeFileOrSudo(path.join(dest, "vcenter.tfvars"), buildInventoryFile(v, existingInv));

  // Env dirs under deploy/ + override templates under secure/
  for (const env of (v.envs && v.envs.length ? v.envs : DEFAULT_ENVS)) {
    await mkdirOrSudo(path.join(vmpilotDir, "deploy", vc, env));
    const ov = path.join(vmpilotDir, "secure", vc, env, "vcenter.tfvars");
    if (!fs.existsSync(ov)) {
      await writeFileOrSudo(ov, buildOverrideTemplate(vc, env));
    }
  }

  await rmOrSudo(stage);
  return { vcenter: vc, ...v };
}

// Delete a vCenter — removes deploy/<vc> and secure/<vc> (credentials too).
async function deleteVcenter(vmpilotDir, vc) {
  const safe = String(vc).replace(/[^a-zA-Z0-9._-]/g, "");
  if (!safe || safe === "." || safe === "..") throw new Error("bad vCenter name");
  const dirs = [path.join(vmpilotDir, "deploy", safe), path.join(vmpilotDir, "secure", safe)];
  for (const d of dirs) if (fs.existsSync(d)) await rmOrSudo(d);
  return { vcenter: safe, deleted: true };
}

// Add a new environment to an existing vCenter (deploy/<vc>/<env> + override).
async function addEnv(vmpilotDir, vc, env) {
  if (!env || !/^[a-z0-9_-]+$/.test(env)) throw new Error("env must match [a-z0-9_-]+");
  const vcenterPath = path.join(vmpilotDir, "deploy", vc);
  if (!fs.existsSync(vcenterPath)) throw new Error(`vCenter '${vc}' not found`);
  await mkdirOrSudo(path.join(vcenterPath, env));
  const ov = path.join(vmpilotDir, "secure", vc, env, "vcenter.tfvars");
  if (!fs.existsSync(ov)) {
    await mkdirOrSudo(path.join(vmpilotDir, "secure", vc, env));
    await writeFileOrSudo(ov, buildOverrideTemplate(vc, env));
  }
  return { vcenter: vc, env, created: true };
}

// Delete an environment (deploy/<vc>/<env> + secure/<vc>/<env>).
async function deleteEnv(vmpilotDir, vc, env) {
  if (!env || !/^[a-z0-9_-]+$/.test(env) || env === "..") throw new Error("bad env name");
  const vcPath = path.join(vmpilotDir, "deploy", vc);
  if (!fs.existsSync(vcPath)) throw new Error(`vCenter '${vc}' not found`);
  const dirs = [path.join(vcPath, env), path.join(vmpilotDir, "secure", vc, env)];
  for (const d of dirs) if (fs.existsSync(d)) await rmOrSudo(d);
  return { vcenter: vc, env, deleted: true };
}

// Read the decrypted (SOPS) credentials — used by govc helpers; never returned.
async function readDecryptedCreds(vmpilotDir, vc) {
  const f = path.join(vmpilotDir, "secure", vc, "credentials.tfvars");
  if (!fs.existsSync(f)) return null;
  let text = await readFileOrSudo(f);
  const grab = (k) => {
    const m = text.match(new RegExp(`${k}\\s*=\\s*"([^"]*)"`));
    return m ? m[1] : "";
  };
  if (grab("vsphere_server") && grab("vsphere_user") && grab("vsphere_password")) {
    return { url: grab("vsphere_server"), user: grab("vsphere_user"), pass: grab("vsphere_password") };
  }
  // SOPS-encrypted → stage then decrypt
  const tmp = path.join(os.tmpdir(), `creds-${Date.now()}.tfvars`);
  fs.writeFileSync(tmp, text, { mode: 0o600 });
  try {
    const out = await run("sops", ["--decrypt", tmp], vmpilotDir, 20000);
    text = out;
    return { url: grab("vsphere_server"), user: grab("vsphere_user"), pass: grab("vsphere_password") };
  } catch {
    return null;
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

module.exports = {
  saveVcenter,
  deleteVcenter,
  addEnv,
  deleteEnv,
  readDecryptedCreds,
  buildInventoryFile
};