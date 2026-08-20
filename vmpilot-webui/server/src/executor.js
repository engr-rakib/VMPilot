"use strict";

const fs = require("fs");
const path = require("path");
const { spawn, execFile } = require("child_process");
const { randomUUID } = require("crypto");

const SCRIPTS = {
  deploy: { file: "scripts/deploy-vm.sh", min: 3, build: (p) => [p.vcenter, p.env, p.vm_name] },
  "deploy-plan": { file: "scripts/deploy-vm.sh", min: 3, build: (p) => [p.vcenter, p.env, p.vm_name, "--plan"] },
  sync: { file: "scripts/deploy-sync.sh", min: 2, build: (p) => [p.vcenter, p.env] },
  "sync-plan": { file: "scripts/deploy-sync.sh", min: 2, build: (p) => [p.vcenter, p.env, "plan"] },
  destroy: { file: "scripts/destroy.sh", min: 3, build: (p) => [p.vcenter, p.env, p.vm_name, "--yes"] },
  backup: { file: null, min: 0, build: () => [] },
  restore: { file: null, min: 1, build: () => [] },
  expand: { file: null, min: 0, build: () => [] }
};

function validateAction(action) {
  return Object.prototype.hasOwnProperty.call(SCRIPTS, action) ? action : null;
}

function buildBackupArgs(vmpilotDir) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const out = path.join(vmpilotDir, "backups", `backup-${stamp}.tar.gz`);
  try { fs.mkdirSync(path.dirname(out), { recursive: true }); } catch { /* repo may be root-owned */ }
  const list = ["deploy", "terraform", "install.sh"];
  return { out, list };
}

// Rotation: keep the newest MAX_BACKUPS web-backup archives (backup-*.tar.gz).
// Pre-restore / pre-destroy state files are never rotated away.
function rotateBackups(vmpilotDir) {
  const MAX_BACKUPS = 5;
  const dir = path.join(vmpilotDir, "backups");
  let files = [];
  try { files = fs.readdirSync(dir).filter((f) => /^backup-.*\.tar\.gz$/.test(f)).sort(); } catch { return; }
  while (files.length > MAX_BACKUPS) {
    const old = files.shift();
    try { fs.rmSync(path.join(dir, old), { force: true }); } catch { /* ignore */ }
  }
}

// List backup archives (web-backup naming) + any pre-restore state snapshots.
function listBackups(vmpilotDir) {
  const dir = path.join(vmpilotDir, "backups");
  let files = [];
  try { files = fs.readdirSync(dir); } catch { return []; }
  const out = [];
  for (const f of files) {
    const p = path.join(dir, f);
    let st = null;
    try { st = fs.statSync(p); } catch { continue; }
    if (!st.isFile()) continue;
    if (/^backup-.*\.tar\.gz$/.test(f) || /^pre-(restore|destroy)-.*/.test(f)) {
      out.push({
        id: f,
        filename: f,
        kind: /^pre-(restore|destroy)-/.test(f) ? "snapshot" : "backup",
        size: st.size,
        mtime: st.mtimeMs
      });
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime);
}

// --- credential handling (mirrors scripts/create-vm-config.sh) -------------
async function readFileOrSudo(path) {
  try {
    return fs.readFileSync(path, "utf8");
  } catch (e) {
    if (e.code !== "EACCES" && e.code !== "EPERM") throw e;
    // container runs as uid 1000 with passwordless sudo — fall back for
    // root-owned 0600 secret files (lab/deploy hosts often keep them so).
    const { stdout } = await new Promise((resolve, reject) => {
      execFile("sudo", ["-n", "cat", path], { maxBuffer: 4 * 1024 * 1024 }, (err, so) => {
        if (err) return reject(new Error(`cannot read ${path}: permission denied`));
        resolve({ stdout: so });
      });
    });
    return stdout;
  }
}

async function writeFileOrSudo(file, content, mode) {
  try {
    fs.writeFileSync(file, content, { mode: mode || 0o644 });
    return;
  } catch (e) {
    if (e.code !== "EACCES" && e.code !== "EPERM") throw e;
    // root-owned repo — write via passwordless sudo (container grants it).
    // Stage the temp file in a writable dir, then sudo mv it into place.
    const tmp = path.join(require("os").tmpdir(), `vmptmp-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    fs.writeFileSync(tmp, content, { mode: mode || 0o644 });
    try {
      await new Promise((resolve, reject) => {
        execFile("sudo", ["-n", "sh", "-c", `cp "${tmp}" "${file}" && chmod 0644 "${file}"`], (err) => (err ? reject(err) : resolve()));
      });
    } finally {
      fs.rmSync(tmp, { force: true });
    }
  }
}

// Live SSH command helper for the expand-disk job (BatchMode — same key the
// console/probe uses). Returns stdout or rejects with a trimmed error.
const EXPAND_SSH_BASE = [
  "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=/dev/null",
  "-o", "ConnectTimeout=5",
  "-o", "ServerAliveInterval=10",
  "-o", "BatchMode=yes"
];

function sshRun(keyPath, user, ip, command, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    execFile("ssh", ["-i", keyPath, ...EXPAND_SSH_BASE, `${user}@${ip}`, command],
      { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024, env: { ...process.env, TERM: "dumb" } },
      (err, stdout, stderr) => {
        if (err) return reject(new Error((stderr || stdout || err.message || "").toString().trim().slice(0, 400)));
        resolve(stdout.toString("utf8"));
      });
  });
}

async function decryptCreds(vmpilotDir, vcenter) {
  const credFile = path.join(vmpilotDir, "secure", vcenter, "credentials.tfvars");
  if (!fs.existsSync(credFile)) return null;
  let text = await readFileOrSudo(credFile);

  const grab = (key) => {
    const m = text.match(new RegExp(`${key}\\s*=\\s*"([^"]*)"`));
    return m ? m[1] : "";
  };

  // plaintext already? (committed demo files are plaintext)
  if (grab("vsphere_server") && grab("vsphere_user") && grab("vsphere_password")) {
    return { url: grab("vsphere_server"), user: grab("vsphere_user"), pass: grab("vsphere_password") };
  }

  // otherwise decrypt with sops (age key mounted at repo's sops-age/)
  try {
    // stage the content into a readable temp file (sops opens the path itself)
    const tmp = path.join(require("os").tmpdir(), `creds-${vcenter}-${Date.now()}.tfvars`);
    fs.writeFileSync(tmp, text, { mode: 0o600 });
    let env = {};
    const ageKey = path.join(vmpilotDir, "sops-age", "keys.txt");
    if (fs.existsSync(ageKey)) {
      // also stage the age key (it is typically 0600 too)
      const keyText = await readFileOrSudo(ageKey);
      const keyTmp = path.join(require("os").tmpdir(), `keys-${Date.now()}.txt`);
      fs.writeFileSync(keyTmp, keyText, { mode: 0o600 });
      env = { SOPS_AGE_KEY_FILE: keyTmp };
      try {
        text = await runCmd("sops", ["--decrypt", tmp], "/", 20000, env);
        return { url: grab("vsphere_server"), user: grab("vsphere_user"), pass: grab("vsphere_password") };
      } finally {
        fs.rmSync(keyTmp, { force: true });
        fs.rmSync(tmp, { force: true });
      }
    }
  } catch {
    return null;
  }
}

function runCmd(cmd, args, cwd, timeoutMs = 20000, env = {}) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { cwd, timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024, env: { ...process.env, ...env } }, (err, stdout) => {
      if (err) return reject(err);
      resolve(stdout.toString("utf8"));
    });
  });
}

// --- govc helpers (vCenter-style VM listing / power) -----------------------
async function runGovc(vmpilotDir, vcenter, args, timeoutMs = 30000) {
  const creds = await decryptCreds(vmpilotDir, vcenter);
  if (!creds) return { ok: false, error: "no usable credentials for " + vcenter };
  // govc writes a session cache under $HOME/.govmomi — the container user's
  // real home may be root-owned (sudo-run jobs write there), which makes govc
  // fail with "permission denied". Point HOME at a writable per-run temp dir.
  const govHome = path.join(require("os").tmpdir(), `govhome-${process.pid}-${Date.now()}`);
  fs.mkdirSync(govHome, { recursive: true });
  const env = {
    ...process.env,
    GOVC_URL: creds.url,
    GOVC_USERNAME: creds.user,
    GOVC_PASSWORD: creds.pass,
    GOVC_INSECURE: "1",
    TERM: "dumb",
    HOME: govHome
  };
  try {
    const out = await runCmd("govc", args, vmpilotDir, timeoutMs, env);
    return { ok: true, out };
  } catch (e) {
    return { ok: false, error: (e.stderr || e.message || "").toString().slice(0, 400) };
  }
}

async function vmPower(vmpilotDir, vcenter, name, action) {
  const a = String(action);
  const args = (a) => {
    if (a === "on") return ["vm.power", "-on", name];
    if (a === "off") return ["vm.power", "-off", name];
    if (a === "forceoff") return ["vm.power", "-off", "-force", name];
    if (a === "reset") return ["vm.power", "-reset", name];
    if (a === "reboot") return ["vm.power", "-reboot", name];
    if (a === "shutdown") return ["vm.power", "-shutdown", name];
    return null;
  };
  const argv = args(a);
  if (!argv) return { ok: false, error: "bad power action: " + a };
  const result = await runGovc(vmpilotDir, vcenter, argv, 30000);
  // govc fails with "The attempted operation cannot be performed in the current
  // state (Powered off/on)" when the VM is already in the desired state (stale
  // live cache). That is not an error — treat it as success (idempotent power).
  if (!result.ok && /cannot be performed in the current state/i.test(result.error || "")) {
    return { ok: true, already: true };
  }
  return result;
}

// --- vCenters / configs mirror --------------------------------------------
function listVcenters(vmpilotDir) {
  const dir = path.join(vmpilotDir, "secure");
  if (!fs.existsSync(dir)) return [];
  const result = [];
  for (const vc of fs.readdirSync(dir)) {
    const vdir = path.join(dir, vc);
    if (!fs.statSync(vdir).isDirectory()) continue;
    if (!fs.existsSync(path.join(vdir, "credentials.tfvars")) && !fs.existsSync(path.join(vdir, "vcenter.tfvars"))) continue;
    const envs = fs.readdirSync(vdir).filter((p) => {
      try { return fs.statSync(path.join(vdir, p)).isDirectory(); } catch { return false; }
    });
    if (envs.length > 0) result.push({ vcenter: vc, envs: envs.sort() });
  }
  return result;
}

function listConfigs(vmpilotDir) {
  const dir = path.join(vmpilotDir, "deploy");
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const vc of fs.readdirSync(dir)) {
    const vdir = path.join(dir, vc);
    if (!fs.statSync(vdir).isDirectory()) continue;
    for (const env of fs.readdirSync(vdir)) {
      const edir = path.join(vdir, env);
      if (!fs.statSync(edir).isDirectory()) continue;
      for (const f of fs.readdirSync(edir)) {
        if (f.startsWith("vm-") && f.endsWith(".tfvars")) {
          const m = f.match(/^vm-(.+)_\d+\.\d+\.\d+\.\d+\.tfvars$/);
          out.push({ vcenter: vc, env, file: f, name: m ? m[1] : f });
        }
      }
    }
  }
  return out;
}

// --- job runner ------------------------------------------------------------
function repoAccessible(vmpilotDir, scriptRel) {
  try {
    fs.accessSync(path.join(vmpilotDir, scriptRel || "scripts/deploy-vm.sh"), fs.constants.R_OK);
    return true;
  } catch {
    // repo owned by root (lab / locked-down hosts) — container uid 1000 must
    // run the CLI through passwordless sudo (image grants the vmpilot user).
    return false;
  }
}

function createJob(jobs, params, user) {
  const id = randomUUID();
  const job = {
    id, action: params.action, status: "queued", params,
    user, exit_code: null, started_at: Date.now(), finished_at: null
  };
  const outFile = path.join(jobs.dataDir, "jobs", `${id}.log`);
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  job.output_path = outFile;
  jobs.create(job);
  return job;
}

function emitLine(io, jobId, line, stream) {
  io.of("/jobs").emit("job:output", { jobId, line, stream });
}

function runBackupJob(io, jobs, job, vmpilotDir) {
  const { out, list } = buildBackupArgs(vmpilotDir);
  const sudo = repoAccessible(vmpilotDir, "install.sh") ? [] : ["sudo", "-n", "-E"];
  const log = fs.createWriteStream(job.output_path, { flags: "a" });
  const cmd = sudo.length ? "sudo" : "bash";
  const cmdArgs = sudo.length
    ? [...sudo, "bash", "-c", `mkdir -p backups && tar -czf "${out}" ${list.join(" ")}`]
    : ["-c", `mkdir -p backups && tar -czf "${out}" ${list.join(" ")}`];
  const child = spawn(cmd, cmdArgs,
    { cwd: vmpilotDir, env: { ...process.env, TERM: "dumb" } });
  child.stdout.on("data", (d) => { const line = d.toString().trim(); if (line) emitLine(io, job.id, line, "o"); log.write(d); });
  child.stderr.on("data", (d) => { const line = d.toString().trim(); if (line) emitLine(io, job.id, line, "e"); log.write(d); });
  child.on("error", (e) => { emitLine(io, job.id, String(e.message || e), "e"); });
  child.on("close", (code) => {
    log.end();
    if (code === 0) rotateBackups(vmpilotDir);
    job.status = code === 0 ? "success" : "failed";
    job.exit_code = code;
    job.finished_at = Date.now();
    jobs.update(job.id, { status: job.status, exit_code: code, finished_at: job.finished_at });
    io.of("/jobs").emit("job:status", { jobId: job.id, status: job.status, exit_code: code });
    if (job._onDone) job._onDone(job, code);
  });
}

// Restore a web backup archive (backups/backup-*.tar.gz) back into the repo.
// Pre-saves the current state file(s) first so nothing is lost, mirroring the
// CLI backup.sh restore semantics. The archive is extracted at the repo root,
// which restores deploy/, terraform/ and install.sh as archived.
function runRestoreJob(io, jobs, job, vmpilotDir) {
  const name = String(job.params.backup_file || job.params.id || "");
  const safe = path.basename(name).replace(/[^a-zA-Z0-9._-]/g, "");
  if (!/^backup-.*\.tar\.gz$/.test(safe)) {
    emitLine(io, job.id, `invalid restore archive: ${name}`, "e");
    return finishJob(io, jobs, job, 1);
  }
  const archive = path.join(vmpilotDir, "backups", safe);
  if (!fs.existsSync(archive)) {
    emitLine(io, job.id, `archive not found: ${safe}`, "e");
    return finishJob(io, jobs, job, 1);
  }
  const sudo = repoAccessible(vmpilotDir, "install.sh") ? [] : ["sudo", "-n", "-E"];
  const log = fs.createWriteStream(job.output_path, { flags: "a" });

  // 1. pre-save current state files verbatim
  const pre = path.join(vmpilotDir, "backups");
  const preScript = `set -e; mkdir -p "${pre}"; for f in terraform/terraform.*.tfstate; do [ -f "$f" ] && cp "$f" "${pre}/pre-restore-$(basename $f)"; done 2>/dev/null || true`;
  const child = spawn(sudo.length ? "sudo" : "bash",
    sudo.length ? [...sudo, "bash", "-c", preScript] : ["-c", preScript],
    { cwd: vmpilotDir, env: { ...process.env, TERM: "dumb" } });
  child.on("close", () => {
    emitLine(io, job.id, "Pre-saved current state (pre-restore snapshots under backups/)");
    // 2. extract the archive at the repo root
    const child2 = spawn(sudo.length ? "sudo" : "bash",
      sudo.length ? [...sudo, "bash", "-c", `cd "${vmpilotDir}" && tar -xzf "${archive}"`]
        : ["-c", `cd "${vmpilotDir}" && tar -xzf "${archive}"`],
      { cwd: vmpilotDir, env: { ...process.env, TERM: "dumb" } });
    child2.stdout.on("data", (d) => { const line = d.toString().trim(); if (line) emitLine(io, job.id, line, "o"); log.write(d); });
    child2.stderr.on("data", (d) => { const line = d.toString().trim(); if (line) emitLine(io, job.id, line, "e"); log.write(d); });
    child2.on("error", (e) => emitLine(io, job.id, String(e.message || e), "e"));
    child2.on("close", (code) => finishJob(io, jobs, job, code, log, () => {
      if (code === 0) emitLine(io, job.id, `Restored: ${safe}`);
      else emitLine(io, job.id, "Restore FAILED — pre-restore state snapshots kept under backups/");
    }));
  });
}

// Grow a VM's OS disk live from the GUI.
// 1. govc: grow the VMDK to the new total size (only as much as needed — if the
//    LVM VG already has free space we skip the VMDK grow entirely).
// 2. SSH guest: growpart the PV partition → pvresize → lvextend the mount's LV
//    to the requested size (+resize2fs/xfs_growfs for non-LVM partitions).
// 3. tfvars write-back so deploy-sync never plans a shrink (drift-free).
// Emits progress lines to the job socket + log; leaves the VMDK grown + guest
// filesystem usable on any failure (partial state is safe + re-runnable).
function runExpandJob(io, jobs, job, vmpilotDir, opts) {
  const log = fs.createWriteStream(job.output_path, { flags: "a" });
  const emit = (line, stream = "o") => { emitLine(io, job.id, line, stream); log.write(line + "\n"); };
  const { vcenter, env, vm_name, ip, new_size_gb, mount, ssh_user } = job.params;
  const sshKey = (opts && opts.sshKey) || "";
  const sshUser = String(ssh_user || (opts && opts.sshUser) || "ubuntu");
  const targetMount = String(mount || "/");
  const newGb = Number(new_size_gb);

  (async () => {
    if (!vcenter || !env || !vm_name || !ip) throw new Error("missing: vcenter/env/vm_name/ip");
    if (!(newGb > 0) || Number.isNaN(newGb)) throw new Error("invalid new_size_gb: " + new_size_gb);
    if (!fs.existsSync(sshKey)) throw new Error("no SSH key for guest grow: " + sshKey);

    // 1. Resolve the VM inventory path (govc needs it for device listing).
    //    Config hostname can differ from the vCenter VM name (accesspilot-prod
    //    vs accesspilot_prod — deploy names the VM from the tfvars file segment,
    //    which normalizes hyphens to underscores). Try candidates + wildcard.
    emit(`Resolving VM ${vm_name} on ${vcenter} …`);
    const candidates = [vm_name, String(vm_name).replace(/-/g, "_"), String(vm_name).replace(/_/g, "-")];
    let vmPath = "";
    for (const cand of candidates) {
      const r = await runGovc(vmpilotDir, vcenter, ["find", "/", "-type", "m", "-name", cand], 30000);
      if (r.ok && r.out) { vmPath = String(r.out).trim().split("\n")[0]; break; }
    }
    if (!vmPath) {
      const r = await runGovc(vmpilotDir, vcenter, ["find", "/", "-type", "m", "-name", `*${vm_name}*`], 30000);
      if (r.ok) {
        const rows = String(r.out || "").trim().split("\n").filter(Boolean);
        if (rows.length === 1) vmPath = rows[0];
      }
    }
    if (!vmPath) throw new Error("VM not found on vCenter: " + vm_name);
    emit(`VM path: ${vmPath}`);

    // 2. Read current disk device (key + capacity) so we can grow precisely.
    const devRes = await runGovc(vmpilotDir, vcenter, ["object.collect", "-json", vmPath, "config.hardware.device"], 30000);
    if (!devRes.ok) throw new Error("govc device query failed: " + devRes.error);
    const changes = JSON.parse(devRes.out);
    const devs = (changes[0] && changes[0].val && changes[0].val._value) || [];
    const disk = devs.find((d) => d.capacityInKB && d.backing && d.backing.diskMode);
    if (!disk) throw new Error("no virtual disk found on " + vm_name);
    const curDiskGB = Math.round((disk.capacityInKB || 0) / 1048576);
    emit(`OS disk key=${disk.key} current=${curDiskGB}G`);

    // 3. Guest pre-probe: how the mount is backed (LVM LV vs plain partition),
    //    current fs size + VG free space so we only grow the VMDK when needed.
    const pre = [
      "set -e",
      `MOUNT='${targetMount}'`,
      `SRC=$(findmnt -no SOURCE --target "$MOUNT" | head -1)`,
      `[ -n "$SRC" ] || { echo "SRC=NA"; exit 0; }`,
      `echo "SRC=$SRC"`,
      `echo "FST=$(findmnt -no FSTYPE --target "$MOUNT" | head -1)"`,
      `echo "CUR_B=$(df -B1 --output=size "$MOUNT" 2>/dev/null | tail -1 | tr -d ' ')"`,
      `if echo "$SRC" | grep -q /dev/mapper; then`,
      `  LV="$SRC"; VG=$(lvs --noheadings -o vg_name "$LV" 2>/dev/null | tr -d ' ')`,
      `  [ -n "$VG" ] || VG=$(lvs --noheadings -o vg_name "$LV" 2>/dev/null)`,
      `  echo "VG=$VG"`,
      `  echo "LV=$LV"`,
      `  VGF=$(vgs --noheadings -o vg_free --units b "$VG" 2>/dev/null | tr -d ' ')`,
      `  echo "VG_FREE_B=$(echo "$VGF" | sed 's/[^0-9]//g')"`,
      `  PV=$(pvs --noheadings -o pv_name --select "vg_name=$VG" 2>/dev/null | head -1 | tr -d ' ')`,
      `  [ -n "$PV" ] || PV=$(pvs --noheadings -o pv_name 2>/dev/null | head -1 | tr -d ' ')`,
      `  echo "PV=$PV"`,
      `  echo "DISK=$(lsblk -no pkname "$PV" 2>/dev/null | head -1)"`,
      `  echo "PART=$(basename "$PV")"`,
      `else`,
      `  echo "DISK=$(lsblk -no pkname "$SRC" 2>/dev/null | head -1)"`,
      `  echo "PART=$(basename "$SRC")"`,
      `fi`
    ].join("\n");
    emit("Probing guest disk layout over SSH …");
    let probe = "";
    try { probe = await sshRun(sshKey, sshUser, ip, `sudo -n bash -c '${pre.replace(/'/g, "'\\''")}'`, 30000); }
    catch (e) { emit("guest probe failed: " + e.message, "e"); throw new Error("cannot reach guest " + ip); }
    const p = {};
    for (const line of probe.split("\n")) {
      const m = line.match(/^([A-Z_]+)=(.+)$/);
      if (m) p[m[1]] = m[2].trim();
    }
    emit("  " + probe.split("\n").filter((l) => /^[A-Z_]+=/.test(l)).join(" · "));
    if (p.SRC === "NA" || !p.SRC) throw new Error("mount '" + targetMount + "' not found on guest");
    if (p.DISK !== "sda" && p.DISK !== "sdb" && p.DISK !== "sdc" && p.DISK !== "sdd" && p.DISK !== "nvme0n1") {
      // known SCSI/nvme naming — otherwise proceed anyway; growpart will fail loudly
    }
    const curB = Number(p.CUR_B || 0);
    const needB = newGb * 1073741824;
    if (needB <= curB) throw new Error("target " + newGb + "G is not larger than current " + (curB / 1073741824).toFixed(1) + "G");

    // 4. Decide how much VMDK growth is required (VG free space is reused first).
    let growDiskGB = 0;
    if (p.VG) {
      const vgFreeB = Number(p.VG_FREE_B || 0);
      const missingB = needB - curB - vgFreeB;
      if (missingB > 0) growDiskGB = Math.ceil(missingB / 1073741824);
      emit(`LVM: VG ${p.VG} free ${(vgFreeB / 1073741824).toFixed(1)}G → VMDK grow ${growDiskGB}G`);
    } else {
      growDiskGB = newGb - Math.floor(curB / 1073741824);
      if (growDiskGB <= 0) throw new Error("plain partition: target must exceed current partition size");
    }

    if (growDiskGB > 0) {
      const newTotalGB = curDiskGB + growDiskGB;
      emit(`Growing VMDK ${curDiskGB}G → ${newTotalGB}G …`);
      const grow = await runGovc(vmpilotDir, vcenter,
        ["vm.disk.change", "-vm", vmPath, "-disk.key", String(disk.key), "-size", newTotalGB + "G"], 120000);
      if (!grow.ok) throw new Error("VMDK grow failed: " + grow.error);
      emit("VMDK grown OK");
    } else {
      emit("VMDK already large enough — only extending the guest filesystem");
    }

    // 5. Guest-side grow.
    const gscript = [
      "set -e",
      `MOUNT='${targetMount}'`,
      `DISK='${p.DISK}'; PART='${p.PART}'`,
      `PARTNUM=$(echo "$PART" | grep -oE '[0-9]+$')`,
      `DEV=/dev/$DISK$PARTNUM`,
      `NEW_GB=${newGb}`,
      `# After a live VMDK grow the guest SCSI device must be re-scanned before`,
      `# growpart can see the new capacity (kernel caches the old device size).`,
      `for f in /sys/class/scsi_device/*/device/rescan; do echo 1 > "$f" 2>/dev/null || true; done`,
      `sleep 1`,
      `if [ -n "${p.VG}" ]; then`,
      `  growpart /dev/$DISK $PARTNUM 2>/dev/null || true`,
      `  pvresize $DEV`,
      `  lvextend -r -L ${newGb}G "${p.LV}"`,
      `else`,
      `  FST='${p.FST}'`,
      `  growpart /dev/$DISK $PARTNUM 2>/dev/null || true`,
      `  partprobe /dev/$DISK 2>/dev/null || true`,
      `  if [ "$FST" = "xfs" ]; then xfs_growfs "$MOUNT"; else resize2fs $DEV; fi`,
      `fi`,
      `echo "AFTER_B=$(df -B1 --output=size "$MOUNT" 2>/dev/null | tail -1 | tr -d ' ')"`
    ].join("\n");
    emit(`Growing guest filesystem at ${targetMount} → ${newGb}G …`);
    let growOut = "";
    try { growOut = await sshRun(sshKey, sshUser, ip, `sudo -n bash -c '${gscript.replace(/'/g, "'\\''")}'`, 90000); }
    catch (e) { throw new Error("guest grow failed: " + e.message); }
    const afterB = (growOut.match(/AFTER_B=(\d+)/) || [])[1];
    emit("  " + growOut.split("\n").filter((l) => l.trim()).join(" · "));
    emit(`Guest filesystem now ${afterB ? (Number(afterB) / 1073741824).toFixed(1) + "G" : "resized"} (target ${newGb}G)`);

    // 6. tfvars write-back (drift-free): disk_size + os_partitions mount size.
    try {
      const cfg = listConfigs(vmpilotDir).find((c) =>
        (c.vcenter === vcenter && c.env === env) &&
        (c.name === vm_name || c.name === String(vm_name).replace(/-/g, "_") || c.name === String(vm_name).replace(/_/g, "-") || (ip && c.file.includes(ip))));
      if (cfg) {
        const tfvars = path.join(vmpilotDir, "deploy", vcenter, env, cfg.file);
        let text = await readFileOrSudo(tfvars);
        const newTotal = curDiskGB + growDiskGB;
        const lineRe = new RegExp(`(\\s*mount_point\\s*=\\s*"${targetMount.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}"[^\\n]*?size\\s*=\\s*")[^"]*(")`, "g");
        let changed = false;
        // Rewrite disk_size when it differs from the LIVE disk — a previous
        // partial run may have left tfvars stale while govc/guest are already grown.
        const curTfvars = Number((text.match(/disk_size\s*=\s*(\d+)/) || [])[1]);
        if (curTfvars !== newTotal) {
          text = text.replace(/(disk_size\s*=\s*)\d+/, `$1${newTotal}`);
          changed = true;
        }
        const lineCount = text.match(lineRe) ? text.match(lineRe).length : 0;
        if (lineCount > 0) {
          text = text.replace(lineRe, `$1${newGb}G$2`);
          changed = true;
        }
        if (changed) {
          await writeFileOrSudo(tfvars, text);
          emit(`tfvars updated: deploy/${vcenter}/${env}/${cfg.file} (disk_size + ${targetMount} size)`);
        } else {
          emit("tfvars already in sync — no write needed");
        }
      } else {
        emit("warning: could not locate tfvars for write-back (config will drift)", "e");
      }
    } catch (e) {
      emit("warning: tfvars write-back failed: " + e.message, "e");
    }

    emit("Done — disk expanded. Monitoring will pick up the new size on next refresh.");
    finishJob(io, jobs, job, 0, log);
  })().catch((e) => {
    emit("Expand FAILED: " + (e && e.message || e), "e");
    emit("Partial state (if any) is safe — VMDK/fs are larger, never smaller. Re-run to finish.", "e");
    finishJob(io, jobs, job, 1, log);
  });
}

function finishJob(io, jobs, job, code, log, trailing) {
  if (log) { if (trailing) trailing(); log.end(); }
  job.status = code === 0 ? "success" : "failed";
  job.exit_code = code;
  job.finished_at = Date.now();
  jobs.update(job.id, { status: job.status, exit_code: code, finished_at: job.finished_at });
  io.of("/jobs").emit("job:status", { jobId: job.id, status: job.status, exit_code: code });
  if (job._onDone) job._onDone(job, code);
}

function runScriptJob(io, jobs, job, vmpilotDir) {
  const spec = SCRIPTS[job.action];
  const script = path.join(vmpilotDir, spec.file);
  const args = spec.build(job.params);
  // bash the script directly when readable as uid 1000; else via sudo.
  const sudo = repoAccessible(vmpilotDir, spec.file) ? [] : ["sudo", "-n", "-E"];
  const log = fs.createWriteStream(job.output_path, { flags: "a" });
  const ageKey = path.join(vmpilotDir, "sops-age", "keys.txt");
  const extraEnv = fs.existsSync(ageKey) ? { SOPS_AGE_KEY_FILE: ageKey } : {};
  const child = spawn(sudo.length ? "sudo" : "bash",
    sudo.length ? [...sudo, "bash", script, ...args] : [script, ...args],
    { cwd: vmpilotDir, env: { ...process.env, TERM: "dumb", NO_COLOR: "1", VMPILOT_HOME: vmpilotDir, ...extraEnv } });

  if (spec.stdin) {
    child.stdin.write(spec.stdin);
    child.stdin.end();
  }

  child.stdout.on("data", (d) => { emitLine(io, job.id, d.toString(), "o"); log.write(d); });
  child.stderr.on("data", (d) => { emitLine(io, job.id, d.toString(), "e"); log.write(d); });
  child.on("error", (e) => { emitLine(io, job.id, String(e.message || e), "e"); });
  child.on("close", (code) => {
    log.end();
    job.status = code === 0 ? "success" : "failed";
    job.exit_code = code;
    job.finished_at = Date.now();
    jobs.update(job.id, { status: job.status, exit_code: code, finished_at: job.finished_at });
    io.of("/jobs").emit("job:status", { jobId: job.id, status: job.status, exit_code: code });
    if (job._onDone) job._onDone(job, code);
  });
}

function startJob(io, jobs, job, vmpilotDir, opts) {
  job.status = "running";
  jobs.update(job.id, { status: "running", started_at: job.started_at });
  io.of("/jobs").emit("job:status", { jobId: job.id, status: "running" });
  job._onDone = opts && opts.onJobEvent;
  if (job.action === "backup") runBackupJob(io, jobs, job, vmpilotDir);
  else if (job.action === "restore") runRestoreJob(io, jobs, job, vmpilotDir);
  else if (job.action === "expand") runExpandJob(io, jobs, job, vmpilotDir, opts);
  else runScriptJob(io, jobs, job, vmpilotDir);
}

module.exports = {
  validateAction, createJob, startJob,
  listVcenters, listConfigs, vmPower, decryptCreds,
  listBackups
};