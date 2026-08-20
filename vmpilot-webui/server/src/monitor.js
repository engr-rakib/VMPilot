"use strict";

// Monitoring module — aggregates cloud-init status + VM resource usage.
// Uses govc (live power/CPU/RAM) and parses the per-VM config files for
// configured capacity. cloud-init status is read from the terraform state
// (the null_resource wait_for_cloud_init messages) when available.

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");
const catalog = require("./catalog");

function run(cmd, args, cwd, timeoutMs = 30000, env = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { cwd, timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, env: { ...process.env, ...env } },
      (err, stdout) => (err ? reject(err) : resolve(stdout.toString("utf8"))));
  });
}

// Generic runner for the inventory script's `live` subcommands (vms|hosts|datastores).
// Shares the script's ~11s file cache; SOPS_AGE_KEY_FILE is required in the
// container (host path /vmpilot/sops-age/keys.txt, mounted).
async function runLive(vmpilotDir, vc, what) {
  const script = path.join(vmpilotDir, "scripts", "vcenter-inventory.sh");
  if (!fs.existsSync(script)) return { ok: false, error: "missing scripts/vcenter-inventory.sh" };
  let readable = true;
  try { fs.accessSync(script, fs.constants.R_OK | fs.constants.X_OK); } catch { readable = false; }
  const cmdArgs = readable ? [script, vc, "live", what] : ["-n", "-E", "bash", script, vc, "live", what];
  const ageKey = path.join(vmpilotDir, "sops-age", "keys.txt");
  const env = { TERM: "dumb" };
  if (fs.existsSync(ageKey)) env.SOPS_AGE_KEY_FILE = ageKey;
  try {
    const raw = await run(readable ? "bash" : "sudo", cmdArgs, vmpilotDir, 60000, env);
    const arr = JSON.parse(raw.trim().split("\n").filter(Boolean).pop() || "[]");
    return { ok: true, items: Array.isArray(arr) ? arr : [] };
  } catch (e) {
    return { ok: false, error: (e.message || "").slice(0, 300) };
  }
}

// Live VM list for one vCenter (power + configured/utilized CPU/RAM) — comes
// from the dedicated scripts/vcenter-inventory.sh provider (same data the CLI
// and dashboard read), not a parallel govc implementation here. The script
// itself keeps a short ~11s file cache, so repeat calls are near-instant while
// operator-triggered refreshes stay fresh.
async function liveVms(vmpilotDir, vc) {
  const r = await runLive(vmpilotDir, vc, "vms");
  return { ok: r.ok, vms: r.ok ? r.items : [], error: r.error };
}

// Live host resource usage (CPU/RAM capacity + usage) for the datacenter/host
// drill-down on the Monitoring page.
async function liveHosts(vmpilotDir, vc) {
  return runLive(vmpilotDir, vc, "hosts");
}

// Live datastore capacity/free for storage bars on the Monitoring page.
async function liveDatastores(vmpilotDir, vc) {
  return runLive(vmpilotDir, vc, "datastores");
}

// Read cloud-init status from terraform state (the null_resource provisioner
// records "VM: cloud-init completed" in state). Falls back to per-env output.
function cloudInitStatusFromState(vmpilotDir, vc, env) {
  const stateFile = path.join(vmpilotDir, "terraform", `terraform.${vc}.${env}.tfstate`);
  if (!fs.existsSync(stateFile)) return null;
  try {
    const st = JSON.parse(fs.readFileSync(stateFile, "utf8"));
    const out = {};
    const rec = (res) => {
      if (!res || !res.instances) return;
      for (const inst of res.instances) {
        const attrs = inst.attributes || {};
        if (attrs.hostname) {
          const key = attrs.hostname;
          out[key] = {
            ip: attrs.ip_address || attrs.primary_ip_address || "",
            cloud_init: attrs.cloud_init_status || (attrs.hostname && !attrs.ip_address ? "pending" : "unknown"),
            provisioned: true
          };
        }
      }
    };
    const rs = st.resources || [];
    // module.vm["<name>"] resources carry hostname + default_ip_address
    for (const r of rs) {
      if (r.type === "vsphere_virtual_machine" && r.module) {
        const m = r.module.match(/module\.vm\["(.+)"\]/);
        if (m) rec(r);
      }
    }
    return out;
  } catch {
    return null;
  }
}

// Per-vCenter snapshot: catalog capacity + live govc state. Isolated so one
// vCenter (slow/unreachable) can never block or fail the whole dashboard.
async function monitorVc(vmpilotDir, vc) {
  let detail;
  try { detail = catalog.vcenterDetail(vmpilotDir, vc); }
  catch { detail = { envs: [], inventory: {}, has_credentials: false }; }
  let live = { ok: false, vms: [] };
  try { live = await liveVms(vmpilotDir, vc); } catch { live = { ok: false, vms: [] }; }
  // host + datastore live data (datacenter → host → resource drill-down).
  // Best-effort: failures degrade to empty arrays, never fail the vCenter.
  let hosts = { ok: false, items: [] };
  let datastores = { ok: false, items: [] };
  try { hosts = await liveHosts(vmpilotDir, vc); } catch { hosts = { ok: false, items: [] }; }
  try { datastores = await liveDatastores(vmpilotDir, vc); } catch { datastores = { ok: false, items: [] }; }
  const liveByName = new Map((live.ok ? live.vms : []).map((v) => [v.name, v]));
  const liveByIp = new Map((live.ok ? live.vms : []).filter((v) => v.ip).map((v) => [v.ip, v]));
  const envs = [];
  let totalCpu = 0, totalMemMB = 0, totalDiskGb = 0, poweredOn = 0, poweredOff = 0;
  for (const env of detail.envs) {
    let configs = [];
    try { configs = catalog.listVmConfigs(vmpilotDir, vc, env); } catch { configs = []; }
    const vms = configs.map((c) => {
      let cfg = {}, s = { cpu: null, memory_mb: null, disk_gb: null, ip: "" };
      try { cfg = catalog.readVmConfig(vmpilotDir, vc, env, c.file); } catch { cfg = {}; }
      try {
        s = catalog.summarizeVmConfig(cfg, catalog.readEffectiveInventory(vmpilotDir, vc, env));
      } catch { s = { cpu: null, memory_mb: null, disk_gb: null, ip: "" }; }
      const liveInfo = liveByName.get(c.name) || liveByIp.get(s.ip) || {};
      const power = liveInfo.power || "notDeployed";
      totalCpu += Number(s.cpu || 0);
      totalMemMB += Number(s.memory_mb || 0);
      totalDiskGb += Number(s.disk_gb || 0);
      if (power === "poweredOn") poweredOn++;
      if (power === "poweredOff") poweredOff++;
      return {
        ...s, file: c.file, power,
        ip: liveInfo.ip || s.ip,
        live: liveInfo,
        cpuUsageMHz: liveInfo.cpuUsageMHz,
        memUsageMB: liveInfo.memUsageMB
      };
    });
    envs.push({ env, vms, count: vms.length });
  }
  return {
    vcenter: vc,
    inventory: detail.inventory,
    has_credentials: detail.has_credentials,
    live_ok: live.ok,
    live_error: live.ok ? undefined : live.error,
    hosts: hosts.ok ? hosts.items : [],
    hosts_error: hosts.ok ? undefined : hosts.error,
    datastores: datastores.ok ? datastores.items : [],
    datastores_error: datastores.ok ? undefined : datastores.error,
    envs,
    summary: {
      vm_count: envs.reduce((a, e) => a + e.count, 0),
      powered_on: poweredOn,
      powered_off: poweredOff,
      total_cpu: totalCpu,
      total_mem_gb: Math.round(totalMemMB / 1024),
      total_disk_gb: totalDiskGb
    }
  };
}

// Full monitoring snapshot — vCenters fetched IN PARALLEL so a single slow one
// does not add to the others' latency (sum → max).
async function monitorSnapshot(vmpilotDir) {
  const vcs = catalog.listVcenters(vmpilotDir);
  const snaps = await Promise.all(vcs.map((vc) =>
    monitorVc(vmpilotDir, vc).catch((e) => ({
      vcenter: vc, envs: [], inventory: {}, has_credentials: false,
      live_ok: false, live_error: String((e && e.message) || e),
      hosts: [], datastores: [], summary: {
        vm_count: 0, powered_on: 0, powered_off: 0, total_cpu: 0, total_mem_gb: 0, total_disk_gb: 0
      }
    }))
  ));
  return snaps;
}

// Extract per-entity metric samples from a snapshot for time-series storage.
// The caller buckets by ts and persists via db.makeSampleStore. Each snapshot
// is a POINT-IN-TIME reading, so a new sample row is appended per poll.
function collectSamples(snapshots, ts = Date.now(), vmpilotDir = "") {
  const rows = [];
  for (const vcSnap of snapshots || []) {
    const vc = vcSnap.vcenter;
    for (const h of vcSnap.hosts || []) {
      const cpuTot = (h.cpuCores || 0) * (h.cpuMhz || 0);
      if (cpuTot > 0) rows.push({ ts, vc, kind: "host_cpu", entity: h.name, value: Math.round((h.cpuUsageMHz || 0) / cpuTot * 100) });
      if (h.memoryMB > 0) rows.push({ ts, vc, kind: "host_mem", entity: h.name, value: Math.round((h.memUsageMB || 0) / h.memoryMB * 100) });
      if (h.netKBps) rows.push({ ts, vc, kind: "host_net", entity: h.name, value: h.netKBps });
      if (h.diskKBps) rows.push({ ts, vc, kind: "host_disk", entity: h.name, value: h.diskKBps });
    }
    for (const d of vcSnap.datastores || []) {
      const cap = d.capacity || 0;
      if (cap > 0) rows.push({ ts, vc, kind: "ds_used", entity: d.name, value: Math.round((cap - (d.free || 0)) / cap * 100) });
    }
    // Per-VM utilization trends (cpu/mem %) — feeds the vCenter-style VM panel.
    for (const env of vcSnap.envs || []) {
      for (const vm of env.vms || []) {
        if (vm.power !== "poweredOn" || vm.cpuUsageMHz == null) continue;
        const cpuTot = (vm.cpu || 0) * 2000;
        if (cpuTot > 0) rows.push({ ts, vc, kind: "vm_cpu", entity: vm.name, value: Math.min(100, Math.round((vm.cpuUsageMHz || 0) / cpuTot * 100)) });
        const memTot = vm.memory_mb || 0;
        if (memTot > 0) rows.push({ ts, vc, kind: "vm_mem", entity: vm.name, value: Math.min(100, Math.round((vm.memUsageMB || 0) / memTot * 100)) });
        const diskTot = vm.total_disk_gb ? vm.total_disk_gb * 1024 : (vm.live && vm.live.diskUsedGB ? 0 : 0);
        if (diskTot > 0 && vm.live && vm.live.diskUsedGB != null) {
          rows.push({ ts, vc, kind: "vm_disk", entity: vm.name, value: Math.min(100, Math.round((vm.live.diskUsedGB * 1024) / diskTot * 100)) });
        }
        if (vm.live && vm.live.netKBps != null) {
          rows.push({ ts, vc, kind: "vm_net", entity: vm.name, value: vm.live.netKBps });
        }
        if (vm.live && vm.live.diskKBps != null) {
          rows.push({ ts, vc, kind: "vm_diskio", entity: vm.name, value: vm.live.diskKBps });
        }
        // Per-physical-disk usage sampled from the guest probe cache (lsblk tree).
        // Entity is `${vm.name}::${disk}` (sda/sdb/sdc…) so the trend chart can
        // auto-add one line per disk. Value = aggregate used/size of the disk's
        // filesystem leaves (nodes that carry fssize).
        if (vm.ip) {
          try {
            const cache = path.join(vmpilotDir, ".cache", `guest-${vm.ip}.json`);
            if (fs.existsSync(cache)) {
              const c = JSON.parse(fs.readFileSync(cache, "utf8"));
              if (c && c.ok && c.data && Array.isArray(c.data.disks)) {
                const fsLeaves = (node) => {
                  let size = 0, used = 0;
                  const kids = node.children || [];
                  if (node.fssize > 0) { size += node.fssize; used += node.fsused || 0; }
                  for (const k of kids) { const s = fsLeaves(k); size += s.size; used += s.used; }
                  return { size, used };
                };
                for (const dsk of c.data.disks) {
                  const { size, used } = fsLeaves(dsk);
                  if (!size) continue;
                  rows.push({ ts, vc, kind: "vm_diskmount", entity: `${vm.name}::${dsk.name}`, value: Math.min(100, Math.max(0, Math.round((used / size) * 100))) });
                }
              }
            }
          } catch { /* guest cache best-effort */ }
        }
      }
    }
  }
  return rows;
}

module.exports = { monitorSnapshot, monitorVc, liveVms, liveHosts, liveDatastores, cloudInitStatusFromState, collectSamples };