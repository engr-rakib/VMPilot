"use strict";

// Live guest-OS probe via SSH (the same key the console uses — added by
// cloud-init for the `ubuntu` user). govc/vSphere API cannot see guest state
// (passwd, who, df, failed services), so we read it over SSH. BatchMode=yes so
// no password prompts; results are cached per-IP (~10s) to avoid SSH storms.

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

const CACHE_TTL_MS = 10000;
const TIMEOUT_MS = 9000;

function run(cmd, args, cwd, timeoutMs = TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { cwd, timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024, env: { ...process.env, TERM: "dumb" } },
      (err, stdout) => (err ? reject(err) : resolve(stdout.toString("utf8"))));
  });
}

const SSH_BASE = [
  "-o", "StrictHostKeyChecking=no",
  "-o", "UserKnownHostsFile=/dev/null",
  "-o", "ConnectTimeout=5",
  "-o", "ServerAliveInterval=10",
  "-o", "BatchMode=yes"
];

const SCRIPT = `
set -e
echo '<<USERS>>'
getent passwd | awk -F: '$3>=1000 && $7!="/usr/sbin/nologin" && $7!="/bin/false" {printf "%s:%s:%s\\n", $1, $3, $7}'
echo '<<WHO>>'
who -u 2>/dev/null || true
echo '<<DF>>'
df -h --output=source,size,used,avail,pcent,target 2>/dev/null | awk 'NR==1 || $1!="tmpfs" && $1!="devtmpfs" && $1!="overlay" && $1!="udev"'
echo '<<SVC>>'
systemctl --failed --no-legend --plain 2>/dev/null | head -20 || true
echo '<<MEM>>'
awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d %d\\n", t/1024, a/1024}' /proc/meminfo
echo '<<LOAD>>'
cat /proc/loadavg
echo '<<KERNEL>>'
uname -r
echo '<<UPTIME>>'
cat /proc/uptime
echo '<<HOSTNAME>>'
hostname
echo '<<LSBLK>>'
lsblk -b -J -o NAME,TYPE,SIZE,FSSIZE,FSUSED,FSUSE%,MOUNTPOINT 2>/dev/null || true
echo '<<OSVER>>'
grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true
echo '<<LASTUPD>>'
sudo -n grep -m1 'Start-Date' /var/log/apt/history.log 2>/dev/null || stat -c '%y' /var/log/apt/history.log 2>/dev/null || true
echo '<<AUDIT>>'
sudo -n sh -c 'grep -E "session (opened|closed) for user|sudo: +[A-Za-z0-9_]+ :|New session .* of user" /var/log/auth.log 2>/dev/null | tail -n 25' 2>/dev/null || true
echo '<<NET>>'
ip -o -4 addr show 2>/dev/null | awk '$2!="lo" && $3=="inet" {sub(/\\/.*/,"",$4); print $2" "$4}' || true
echo '<<SWAP>>'
awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{if(t) printf "%d %d\\n", t/1024, (t-f)/1024}' /proc/meminfo
echo '<<PORTS>>'
ss -tulnp 2>/dev/null | awk 'NR>1 {print $1" "$5}' | sed 's/\[::\]/*/' | sed 's/0.0.0.0/*/' | sort -u | head -25 || true
echo '<<PROC>>'
ps -eo pid,comm,%cpu,%mem,user --sort=-%cpu --no-headers 2>/dev/null | head -8 || true
echo '<<UPGR>>'
sudo -n apt list --upgradable 2>/dev/null | grep -c '^' || echo 0
`;

function parse(raw) {
  const sec = {};
  let cur = null;
  for (const line of raw.split("\n")) {
    const m = line.match(/^<<(\w+)>>$/);
    if (m) { cur = m[1]; sec[cur] = []; continue; }
    if (cur) sec[cur].push(line);
  }
  const users = (sec.USERS || []).map((l) => {
    const [name, uid, shell] = l.split(":");
    return { name, uid, shell };
  }).filter((u) => u.name);
  const who = (sec.WHO || []).filter(Boolean).map((l) => {
    const t = l.trim().split(/\s+/);
    return { user: t[0], tty: t[1], from: t[2] && t[2].startsWith("(") ? t[2].slice(1, -1) : (t[2] || ""), at: t[3] || "" };
  });
  const disk = (sec.DF || []).filter(Boolean).map((l) => {
    const t = l.trim().split(/\s+/);
    if (t.length < 6 || t[0] === "Filesystem") return null;
    return { device: t[0], size: t[1], used: t[2], avail: t[3], pct: t[4].replace("%", ""), mount: t.slice(5).join(" ") };
  }).filter(Boolean);
  const services_failed = (sec.SVC || []).filter(Boolean).map((l) => {
    const t = l.trim().split(/\s+/);
    return { name: t[0], state: t[1] || "failed" };
  });
  const memParts = (sec.MEM && sec.MEM[0] || "").split(/\s+/).map(Number);
  const mem = memParts.length >= 2 && memParts[0] ? {
    total: memParts[0], used: memParts[0] - memParts[1], avail: memParts[1],
    pct: memParts[0] ? Math.round(((memParts[0] - memParts[1]) / memParts[0]) * 100) : 0
  } : null;
  const loadParts = (sec.LOAD && sec.LOAD[0] || "").split(/\s+/).map(Number);
  const uptimeSec = Number((sec.UPTIME && sec.UPTIME[0] || "0").split(" ")[0]) || 0;
  const d = new Date(uptimeSec * 1000);
  const uptime = d.toISOString().slice(11, 19);

  // Per-physical-disk breakdown from `lsblk -J`, preserved as a TREE exactly like
  // lsblk output (disk → partition → lvm → mount). Each disk card renders its own
  // hierarchy with indentation; a node carries its fs usage (pct/mount) when it
  // has a filesystem. This also captures LVM volumes, so no separate LVM card is
  // needed in the UI.
  const cleanNode = (node) => {
    const out = {
      name: node.name || "",
      type: node.type || "part",
      size: Number(node.size) || 0
    };
    if (node.mountpoint && String(node.mountpoint) !== "[SWAP]") out.mount = String(node.mountpoint);
    if (node.mountpoint && String(node.mountpoint) === "[SWAP]") out.mount = "[SWAP]";
    const fsSize = Number(node.fssize) || 0;
    const fsUsed = Number(node.fsused) || 0;
    if (fsSize > 0) {
      out.fssize = fsSize;
      out.fsused = fsUsed;
      const pctRaw = (node["fsuse%"] || "").replace("%", "");
      const pct = parseInt(pctRaw, 10);
      out.pct = Number.isFinite(pct) ? pct : Math.round((fsUsed / fsSize) * 100);
    }
    const kids = (node.children || []).map(cleanNode);
    if (kids.length) out.children = kids;
    return out;
  };
  let disks = [];
  try {
    const raw = (sec.LSBLK || []).join("\n").trim();
    if (raw) {
      const blk = JSON.parse(raw);
      disks = (blk.blockdevices || []).filter((b) => (b.type || "") === "disk").map(cleanNode);
    }
  } catch { /* lsblk parse best-effort */ }

  // OS version + last package/OS update + user-audit trail from auth.log
  // (sudo.log Defaults logfile from cloud-init 99-vmpilot-audit). auth.log is
  // only readable via sudo — when the VM lacks passwordless sudo this stays empty
  // and the UI simply shows the "auditing unavailable" fallback.
  const os_version = (sec.OSVER && sec.OSVER[0] || "").trim();
  const last_update = (sec.LASTUPD && sec.LASTUPD[0] || "").trim() || null;

  // Network interfaces (name + IPv4), swap usage (total/used MB), listening
  // TCP/UDP ports, top CPU consumers and pending apt-upgrade count — quick
  // troubleshooting aids for the operator, no extra round-trips.
  const net_ifaces = (sec.NET || []).filter(Boolean).map((l) => {
    const t = l.trim().split(/\s+/);
    return t.length >= 2 ? { name: t[0], ip: t[1] } : null;
  }).filter(Boolean);
  const swapParts = (sec.SWAP && sec.SWAP[0] || "").split(/\s+/).map(Number);
  const swap = swapParts.length >= 2 && swapParts[0] ? {
    total: swapParts[0], used: swapParts[1],
    pct: swapParts[0] ? Math.round((swapParts[1] / swapParts[0]) * 100) : 0
  } : null;
  const ports = (sec.PORTS || []).filter(Boolean).map((l) => l.trim()).slice(0, 25);
  const top_procs = (sec.PROC || []).filter(Boolean).map((l) => {
    const t = l.trim().split(/\s+/);
    if (t.length < 5) return null;
    return { pid: t[0], comm: t[1], cpu: t[2], mem: t[3], user: t[4] };
  }).filter(Boolean).slice(0, 8);
  const pending_updates = Number((sec.UPGR && sec.UPGR[0] || "0").trim()) || 0;
  const audit = (sec.AUDIT || []).filter(Boolean).map((l) => {
    const t = l.trim().split(/\s+/);
    const ts = t[0] || "";
    const line = l;
    let user = "", action = "";
    let m = line.match(/session opened for user (\S+)/);
    if (m) { action = "login"; user = m[1]; }
    else {
      m = line.match(/session closed for user (\S+)/);
      if (m) { action = "logout"; user = m[1]; }
      else {
        m = line.match(/sudo:\s+(\S+)\s*:/);
        if (m) { action = "sudo"; user = m[1]; }
        else {
          m = line.match(/New session \d+ of user (\S+)\./);
          if (m) { action = "session"; user = m[1]; }
        }
      }
    }
    if (!user) return null;
    // auth.log sometimes emits "root(uid=0)" / "ubuntu(uid=1000)" — keep bare name.
    user = user.replace(/\(uid=\d+\)/, "");
    return { ts, user, action };
  }).filter(Boolean).slice(-20).reverse();

  return {
    users, who, disk, services_failed, mem,
    disks,
    os_version, last_update, audit,
    net_ifaces, swap, ports, top_procs, pending_updates,
    load: loadParts.slice(0, 3),
    kernel: (sec.KERNEL && sec.KERNEL[0] || "").trim(),
    uptime,
    hostname: (sec.HOSTNAME && sec.HOSTNAME[0] || "").trim()
  };
}

function cachePath(vmpilotDir, ip) {
  return path.join(vmpilotDir, ".cache", `guest-${ip}.json`);
}

async function probeGuest(vmpilotDir, ip, sshKeyPath, sshUser) {
  if (!ip || !sshKeyPath || !fs.existsSync(sshKeyPath)) {
    return { ok: false, error: "guest probe unavailable (no SSH key or target)" };
  }
  const cache = cachePath(vmpilotDir, ip);
  try {
    if (fs.existsSync(cache)) {
      const st = fs.statSync(cache);
      if (Date.now() - st.mtimeMs < CACHE_TTL_MS) {
        const c = JSON.parse(fs.readFileSync(cache, "utf8"));
        if (c && c.ok) return c;
      }
    }
  } catch { /* stale/corrupt → re-probe */ }

  const args = ["-i", sshKeyPath, ...SSH_BASE, `${sshUser}@${ip}`, SCRIPT];
  try {
    const raw = await run("ssh", args, vmpilotDir, TIMEOUT_MS);
    const data = parse(raw);
    const result = { ok: true, at: Date.now(), ip, data };
    try {
      fs.mkdirSync(path.dirname(cache), { recursive: true });
      fs.writeFileSync(cache, JSON.stringify(result));
    } catch { /* cache best-effort */ }
    return result;
  } catch (e) {
    const err = { ok: false, at: Date.now(), ip, error: (e.message || "ssh failed").slice(0, 200) };
    try {
      if (fs.existsSync(cache)) { // keep last-good on transient failure
        const c = JSON.parse(fs.readFileSync(cache, "utf8"));
        if (c && c.ok && Date.now() - c.at < 30000) return { ...c, stale: true };
      }
    } catch { /* ignore */ }
    return err;
  }
}

module.exports = { probeGuest };