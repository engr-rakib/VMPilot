"use strict";

const fs = require("fs");
const os = require("os");
const { spawn } = require("node-pty");
const auth = require("./auth");

const MAX_TERMINALS = 8;
const consoleSessions = new Map();

function attachTerminal(io, config) {
  const ns = io.of("/terminal");
  const active = new Set();

  ns.use((socket, next) => {
    const token = auth.tokenFromCookieHeader(socket.handshake.headers.cookie);
    const payload = token ? auth.verifyToken(token) : null;
    if (!payload) return next(new Error("unauthorized"));
    socket.auth = payload;
    next();
  });

  ns.on("connection", (socket) => {
    if (active.size >= MAX_TERMINALS) {
      socket.emit("data", "\r\n\x1b[31m[too many terminals open — try again]\x1b[0m\r\n");
      socket.disconnect(true);
      return;
    }

    const cwd = fs.existsSync(config.vmpilotDir) ? config.vmpilotDir : os.homedir();
    const pty = spawn(config.terminalShell, [], {
      name: "xterm-256color",
      cols: 80,
      rows: 24,
      cwd,
      env: {
        ...process.env,
        TERM: "xterm-256color",
        LANG: "C.UTF-8",
        SHELL: config.terminalShell,
        VMPILOT_HOME: config.vmpilotDir
      },
      uid: config.terminalUid,
      gid: config.terminalGid
    });
    active.add(socket.id);

    socket.emit("ready", { cwd });
    socket.on("input", (d) => {
      if (typeof d === "string") pty.write(d);
    });
    socket.on("resize", (d) => {
      try {
        pty.resize(Number(d.cols) || 80, Number(d.rows) || 24);
      } catch { /* ignore */ }
    });

    pty.onData((d) => socket.emit("data", d));
    pty.onExit(() => socket.disconnect(true));

    socket.on("disconnect", () => {
      active.delete(socket.id);
      try { pty.kill(); } catch { /* ignore */ }
    });
  });
}

module.exports = { attachTerminal, attachConsole, activeConsoleSessions };

// VM console: SSH into a deployed VM using the project SSH key (the same key
// cloud-init adds for the `ubuntu` user — see terraform/modules/vm/cloud-init/
// userdata.yaml). Socket namespace /console?vm=<ip>&user=<name>. Auth-gated
// like /terminal. Max active consoles shared with terminals.
function attachConsole(io, config) {
  const ns = io.of("/console");
  const active = new Set();

  ns.use((socket, next) => {
    const token = auth.tokenFromCookieHeader(socket.handshake.headers.cookie);
    const payload = token ? auth.verifyToken(token) : null;
    if (!payload) return next(new Error("unauthorized"));
    socket.auth = payload;
    next();
  });

  ns.on("connection", (socket) => {
    if (active.size >= MAX_TERMINALS) {
      socket.emit("data", "\r\n\x1b[31m[too many consoles open — try again]\x1b[0m\r\n");
      socket.disconnect(true);
      return;
    }
    const vm = String(socket.handshake.query.vm || "").trim();
    const user = String(socket.handshake.query.user || config.sshUser).trim();
    if (!vm) {
      socket.emit("data", "\r\n\x1b[31m[no VM target — console requires vm=<ip>]\x1b[0m\r\n");
      socket.disconnect(true);
      return;
    }
    const key = config.sshKeyPath;
    if (!key || !fs.existsSync(key)) {
      socket.emit("data", `\r\n\x1b[31m[SSH key not found (${key}) — mount the project key]\x1b[0m\r\n`);
      socket.disconnect(true);
      return;
    }
    const args = [
      "-i", key,
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=15",
      "-tt",
      `${user}@${vm}`
    ];
    const pty = spawn("ssh", args, {
      name: "xterm-256color",
      cols: 80,
      rows: 24,
      env: { ...process.env, TERM: "xterm-256color", LANG: "C.UTF-8" }
    });
    active.add(socket.id);
    consoleSessions.set(socket.id, { vm, user, ip: vm, since: Date.now(), socket: socket.id });
    if (typeof config.onEvent === "function") config.onEvent({ kind: "console", severity: "info", vc: "", env: "", vm: vm === user ? "" : vm, label: `SSH session opened`, value: `${user}@${vm}` });

    socket.emit("ready", { vm, user });
    pty.onData((d) => socket.emit("data", d));
    socket.on("input", (d) => {
      if (typeof d === "string") pty.write(d);
    });
    socket.on("resize", (d) => {
      try {
        pty.resize(Number(d.cols) || 80, Number(d.rows) || 24);
      } catch { /* ignore */ }
    });
    pty.onExit(({ exitCode }) => {
      if (typeof config.onEvent === "function") config.onEvent({ kind: "console", severity: "info", vc: "", env: "", vm: vm === user ? "" : vm, label: `SSH session closed`, value: `${user}@${vm} (exit ${exitCode})` });
      try { socket.emit("exit", { code: exitCode }); } catch { /* ignore */ }
      socket.disconnect(true);
    });
    socket.on("disconnect", () => {
      active.delete(socket.id);
      consoleSessions.delete(socket.id);
      try { pty.kill(); } catch { /* ignore */ }
    });
  });
}

function activeConsoleSessions() {
  return Array.from(consoleSessions.values()).map((s) => ({ vm: s.vm, ip: s.ip, user: s.user, since: s.since }));
}

function activeConsoleSessions() {
  return Array.from(sessions.values()).map((s) => ({ vm: s.vm, ip: s.ip, user: s.user, since: s.since }));
}

module.exports = { attachTerminal, attachConsole, activeConsoleSessions };
