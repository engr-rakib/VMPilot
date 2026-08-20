"use strict";

// opsStatus.js — read-only environment status (Phase D: setup-status chip) and
// IPAM snapshot endpoint (ipam command). Mirrors what install.sh / the CLI
// check so the header chip can show install readiness without running the
// installer. Never writes anything.

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const catalog = require("./catalog");

function run(cmd, args, cwd, timeoutMs = 10000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { cwd, timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout) => {
        if (err) return resolve({ ok: false });
        resolve({ ok: true, out: stdout.toString("utf8").trim() });
      });
  });
}

async function toolStatus() {
  const tools = ["terraform", "govc", "sops", "age", "jq", "git", "docker"];
  const out = {};
  for (const t of tools) {
    const r = await run(t, ["--version"], "/");
    out[t] = r.ok ? (r.out.split("\n")[0] || "present") : "missing";
  }
  return out;
}

function envStatus(vmpilotDir) {
  const tfDir = path.join(vmpilotDir, "terraform");
  const keysDir = path.join(vmpilotDir, "sops-age");
  const secureDir = path.join(vmpilotDir, "secure");

  const stateFiles = [];
  try {
    for (const f of fs.readdirSync(tfDir)) {
      if (/^terraform\..+\.tfstate$/.test(f)) stateFiles.push(f);
    }
  } catch { /* not yet initialized */ }

  const backendMode = (() => {
    const initDir = path.join(tfDir, ".terraform");
    if (fs.existsSync(path.join(tfDir, "backend.tf")) ||
        fs.existsSync(path.join(tfDir, "backend.hcl"))) return "s3";
    if (fs.existsSync(path.join(initDir, "terraform.tfstate"))) return "remote";
    return stateFiles.length ? "local" : "none";
  })();

  const vcenters = catalog.listVcenters(vmpilotDir);
  let vmConfigs = 0;
  for (const vc of vcenters) {
    for (const env of catalog.listEnvs(vmpilotDir, vc)) {
      vmConfigs += catalog.listVmConfigs(vmpilotDir, vc, env).length;
    }
  }

  return {
    tools_present: Boolean(fs.existsSync(path.join(tfDir, ".terraform"))),
    state_backend: backendMode,
    state_files: stateFiles.length,
    vcenters: vcenters.length,
    vm_configs: vmConfigs,
    age_key: fs.existsSync(path.join(keysDir, "keys.txt")),
    sops_config: fs.existsSync(path.join(vmpilotDir, ".sops.yaml")),
    has_credentials: (() => {
      let n = 0;
      try {
        for (const vc of fs.readdirSync(secureDir)) {
          const dir = path.join(secureDir, vc);
          if (fs.statSync(dir).isDirectory() && fs.existsSync(path.join(dir, "credentials.tfvars"))) n++;
        }
      } catch { /* ignore */ }
      return n;
    })(),
    repo_root: vmpilotDir,
    deploy_path: path.join(vmpilotDir, "deploy"),
    scripts_path: path.join(vmpilotDir, "scripts"),
    tool_binaries: {
      terraform: fs.existsSync("/usr/local/bin/terraform") || fs.existsSync("/usr/bin/terraform"),
      govc: fs.existsSync("/usr/local/bin/govc") || fs.existsSync("/usr/bin/govc") || fs.existsSync("/opt/govc/govc")
    }
  };
}

// IPAM snapshot for one vCenter+env: base IP, currently-reserved IPs (from the
// per-VM config files, the source of truth) and the next free IP.
async function ipamSnapshot(vmpilotDir, vc, env) {
  const inv = catalog.readEffectiveInventory(vmpilotDir, vc, env);
  const baseIp = inv.ipam_base_ip || "";
  const used = [];
  for (const c of catalog.listVmConfigs(vmpilotDir, vc, env)) {
    const ip = catalog.parseVmFile(c.file).ip || c.summary?.ip;
    if (ip && ip !== "0.0.0.0" && !used.includes(ip)) used.push(ip);
  }
  let freeIp = "";
  let error = "";
  if (baseIp) {
    try {
      // next_free_ip.sh reads the reserved IPs straight from the per-VM config
      // files (source of truth) — no skip list required here.
      freeIp = await catalog.findFreeIp(vmpilotDir, baseIp, "", inv.ipam_range_end || "");
    } catch (e) {
      error = String(e.message || e);
    }
  }
  return {
    vcenter: vc, env, base_ip: baseIp, range_end: inv.ipam_range_end || "",
    used, free_ip: freeIp, error
  };
}

module.exports = { toolStatus, envStatus, ipamSnapshot };