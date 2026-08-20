"use strict";

// VM config CRUD — mirrors scripts/create-vm-config.sh so the Web UI can
// scaffold / edit / delete per-VM tfvars exactly like the CLI:
//   deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars
// Auto-assigns a free IP (IPAM) and writes the exact HCL the CLI generates.

const path = require("path");
const fs = require("fs");
const catalog = require("./catalog");
const { writeFileOrSudo, mkdirOrSudo, rmOrSudo } = catalog;

const DEFAULTS = {
  cpu: 2,
  ram_gb: 4,
  firmware: "efi",
  cpu_hot: true,
  mem_hot: true,
  os_disk_gb: 40,
  boot_size: "512M",
  provisioning: "thin",
  domain: "",
  netmask: 24,
  ipam_enabled: true,
  disable_auto_updates: true,
  enable_node_exporter: false
};

function normalizeSize(v) {
  const s = String(v || "").trim().toUpperCase();
  const m = s.match(/^([\d.]+)\s*(GB|G|MB|M)?$/);
  if (!m) return v;
  const num = parseFloat(m[1]);
  const unit = m[2];
  if (unit === "GB" || unit === "G") return `${num}G`;
  if (unit === "MB" || unit === "M") return `${num}M`;
  return `${num}G`;
}

function toMb(v) {
  const s = String(v || "").trim().toUpperCase();
  const m = s.match(/^([\d.]+)\s*(GB|G|MB|M)?$/);
  if (!m) return Number(v) * 1024;
  const num = parseFloat(m[1]);
  if (m[2] === "MB" || m[2] === "M") return num;
  return num * 1024;
}

function toGb(v) {
  return Math.round(toMb(v) / 1024);
}

function normalizeMount(mp) {
  let m = String(mp || "").trim();
  if (m && m !== "/" && !m.startsWith("/")) m = "/" + m;
  return m;
}

function lvNameFor(mp) {
  if (mp === "/") return "lv_root";
  const lv = "lv_" + mp.replace(/^\//, "").replace(/\//g, "_");
  return lv;
}

// Build the full tfvars file content for a VM config (mirrors the CLI output).
function buildVmTfvars(vc, env, vm) {
  const key = vm.name;
  const header = `#############################################################
# VM config — ${key} (${vm.ip_address || "AUTO"})
# vCenter: ${vc}   Env: ${env}
# Generated: ${new Date().toISOString().slice(0, 19).replace("T", " ")}
#
# HOW TO USE
# ───────────────────────────────────────────────────────────
# Deploy this VM only (other VMs untouched):
#   bash scripts/deploy-vm.sh ${vc} ${env} ${key}
#
# Git note: this file is gitignored (deploy/*/*/vm-*.tfvars).
# Its values (inventory, SSH key, IPs) are NOT pushed to GitHub.
#############################################################
`;

  const osParts = (vm.os_partitions || []).map((p) => {
    const o = { mount_point: p.mount_point, size: normalizeSize(p.size) };
    if (p.lv_name) o.lv_name = p.lv_name;
    if (p.filesystem && p.filesystem !== "xfs") o.filesystem = p.filesystem;
    return o;
  });

  const vmConfig = {
    hostname: vm.hostname || key,
    domain: vm.domain,
    annotation: vm.annotation || `${key} Server`,
    cpu: Number(vm.cpu),
    memory: toMb(vm.memory_mb || vm.ram_gb || DEFAULTS.ram_gb),
    disk_size: toGb(vm.os_disk_gb || vm.disk_gb || DEFAULTS.os_disk_gb),
    firmware: vm.firmware || DEFAULTS.firmware,
    enable_cpu_hot_add: vm.cpu_hot !== false,
    enable_memory_hot_add: vm.mem_hot !== false,
    thin_provisioned: (vm.provisioning || "thin") !== "eager" && (vm.provisioning || "thin") !== "thick",
    eagerly_scrub: vm.provisioning === "eager",
    ip_address: vm.ip_address || "",
    netmask: Number(vm.netmask ?? DEFAULTS.netmask),
    gateway: vm.gateway,
    dns_servers: vm.dns_servers || [],
    ipam_enabled: vm.ipam_enabled !== false,
    host: vm.host || "",
    os_partitions: osParts,
    data_disks: vm.data_disks || [],
    lvm_config: vm.lvm_config || [],
    mount_points: vm.mount_points || [],
    extra_users: vm.extra_users || [],
    disable_auto_updates: vm.disable_auto_updates !== false,
    enable_node_exporter: vm.enable_node_exporter === true
  };

  const top = {
    datacenter: vm.datacenter,
    cluster: vm.cluster,
    datastore: vm.datastore,
    network: vm.network,
    template: vm.template,
    resource_pool: vm.resource_pool || "Resources",
    ipam_base_ip: vm.ipam_base_ip || "",
    ssh_public_key: vm.ssh_public_key || ""
  };

  return catalog.buildVmConfigFile({ header, top, vm_key: key, vm: vmConfig });
}

function sanitizeVmName(name) {
  let n = String(name || "").trim();
  n = n.replace(/\s+/g, "-").replace(/_/g, "-");
  n = n.replace(/[^a-zA-Z0-9-]/g, "");
  return n.replace(/^[^a-zA-Z0-9]+/, "").replace(/[^a-zA-Z0-9]+$/, "");
}

async function createVmConfig(vmpilotDir, input) {
  const { vcenter: vc, env, vm_name } = input;
  if (!vc || !env || !vm_name) throw new Error("vcenter, env and vm_name are required");
  const name = sanitizeVmName(vm_name);
  if (!name) throw new Error("invalid VM name");
  if (name !== String(vm_name).trim().replace(/\s+/g, "-")) {
    // allow but note the normalized name
  }

  const envDir = path.join(vmpilotDir, "deploy", vc, env);
  await mkdirOrSudo(envDir);

  // resolve IPAM base from effective inventory unless overridden
  const eff = catalog.readEffectiveInventory(vmpilotDir, vc, env);
  const baseIp = input.ipam_base_ip || eff.ipam_base_ip;
  const rangeEnd = input.ipam_range_end || eff.ipam_range_end || "";
  let ip = "";
  if (baseIp) {
    try {
      ip = await catalog.findFreeIp(vmpilotDir, baseIp, input.skip_ip || "", rangeEnd);
    } catch (e) {
      ip = input.ip_address || "";
    }
  }
  if (!ip && input.ip_address) ip = input.ip_address;

  // default values from inventory (per-vCenter defaults win over static)
  const inv = catalog.readVcenterInventory(vmpilotDir, vc);
  const merged = {
    datacenter: input.datacenter || inv.datacenter || eff.datacenter || "",
    cluster: input.cluster || inv.cluster || eff.cluster || "",
    datastore: input.datastore || inv.datastore || eff.datastore || "",
    network: input.network || inv.network || eff.network || "",
    template: input.template || inv.template || eff.template || "",
    resource_pool: input.resource_pool || inv.resource_pool || eff.resource_pool || "Resources",
    domain: input.domain || inv.domain || eff.domain || "",
    gateway: input.gateway || inv.gateway || eff.gateway || "",
    netmask: input.netmask ?? inv.netmask ?? eff.netmask ?? DEFAULTS.netmask,
    dns_servers: input.dns_servers && input.dns_servers.length ? input.dns_servers : (inv.dns_servers || eff.dns_servers || []),
    ipam_base_ip: input.ipam_base_ip || inv.ipam_base_ip || eff.ipam_base_ip || "",
    ip_address: ip,
    ...input
  };

  const file = `vm-${name}_${ip || "0.0.0.0"}.tfvars`;
  const content = buildVmTfvars(vc, env, { ...merged, name, hostname: name });
  await writeFileOrSudo(path.join(envDir, file), content);
  return { file, name, ip, vcenter: vc, env, content };
}

// Edit an existing VM config — rewrites the file in place.
async function updateVmConfig(vmpilotDir, vc, env, file, input) {
  const envDir = path.join(vmpilotDir, "deploy", vc, env);
  const full = path.join(envDir, file);
  if (!fs.existsSync(full)) throw new Error(`config not found: ${file}`);
  const old = catalog.readVmConfig(vmpilotDir, vc, env, file);
  const key = Object.keys(old.vm_configs)[0] || input.name;
  const oldVm = Object.values(old.vm_configs)[0] || {};

  const merged = {
    ...oldVm,
    name: key,
    hostname: input.hostname || oldVm.hostname || key,
    annotation: input.annotation !== undefined ? input.annotation : oldVm.annotation,
    cpu: input.cpu !== undefined ? Number(input.cpu) : oldVm.cpu,
    memory_mb: input.memory_mb !== undefined ? toMb(input.memory_mb) : oldVm.memory,
    os_disk_gb: input.os_disk_gb !== undefined ? toGb(input.os_disk_gb) : toGb(oldVm.disk_size),
    firmware: input.firmware !== undefined ? input.firmware : oldVm.firmware,
    cpu_hot: input.cpu_hot !== undefined ? input.cpu_hot : oldVm.enable_cpu_hot_add,
    mem_hot: input.mem_hot !== undefined ? input.mem_hot : oldVm.enable_memory_hot_add,
    provisioning: input.provisioning !== undefined
      ? input.provisioning
      : (oldVm.eagerly_scrub ? "eager" : (oldVm.thin_provisioned ? "thin" : "thick")),
    ip_address: input.ip_address !== undefined ? input.ip_address : (oldVm.ip_address || ""),
    netmask: input.netmask !== undefined ? Number(input.netmask) : oldVm.netmask,
    gateway: input.gateway !== undefined ? input.gateway : oldVm.gateway,
    dns_servers: input.dns_servers !== undefined ? input.dns_servers : (oldVm.dns_servers || []),
    ipam_enabled: input.ipam_enabled !== undefined ? input.ipam_enabled : oldVm.ipam_enabled,
    os_partitions: input.os_partitions !== undefined ? input.os_partitions : (oldVm.os_partitions || []),
    data_disks: input.data_disks !== undefined ? input.data_disks : (oldVm.data_disks || []),
    lvm_config: input.lvm_config !== undefined ? input.lvm_config : (oldVm.lvm_config || []),
    mount_points: input.mount_points !== undefined ? input.mount_points : (oldVm.mount_points || []),
    extra_users: input.extra_users !== undefined ? input.extra_users : (oldVm.extra_users || []),
    disable_auto_updates: input.disable_auto_updates !== undefined ? input.disable_auto_updates : (oldVm.disable_auto_updates !== false),
    enable_node_exporter: input.enable_node_exporter !== undefined ? input.enable_node_exporter : (oldVm.enable_node_exporter === true),
    datacenter: input.datacenter !== undefined ? input.datacenter : (old.top.datacenter || ""),
    cluster: input.cluster !== undefined ? input.cluster : (old.top.cluster || ""),
    datastore: input.datastore !== undefined ? input.datastore : (old.top.datastore || ""),
    network: input.network !== undefined ? input.network : (old.top.network || ""),
    template: input.template !== undefined ? input.template : (old.top.template || ""),
    resource_pool: input.resource_pool !== undefined ? input.resource_pool : (old.top.resource_pool || "Resources"),
    host: input.host !== undefined ? input.host : (oldVm.host || ""),
    ipam_base_ip: input.ipam_base_ip !== undefined ? input.ipam_base_ip : (old.top.ipam_base_ip || ""),
    ssh_public_key: input.ssh_public_key !== undefined ? input.ssh_public_key : (old.top.ssh_public_key || "")
  };

  const newFile = `vm-${key}_${merged.ip_address || "0.0.0.0"}.tfvars`;
  const content = buildVmTfvars(vc, env, merged);
  await writeFileOrSudo(path.join(envDir, newFile), content);
  if (newFile !== file && fs.existsSync(full)) {
    await rmOrSudo(full);
  }
  return { file: newFile, name: key, vcenter: vc, env, content };
}

async function deleteVmConfig(vmpilotDir, vc, env, file) {
  const safe = String(file).replace(/[^a-zA-Z0-9._-]/g, "");
  const full = path.join(vmpilotDir, "deploy", vc, env, safe);
  if (!fs.existsSync(full)) throw new Error("config not found");
  await rmOrSudo(full);
  return { deleted: true, file: safe };
}

module.exports = {
  createVmConfig,
  updateVmConfig,
  deleteVmConfig,
  buildVmTfvars,
  sanitizeVmName
};