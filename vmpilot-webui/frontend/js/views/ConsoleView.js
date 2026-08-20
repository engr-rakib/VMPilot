// views/ConsoleView.js — SSH console into a deployed VM via the /console socket
// (server spawns `ssh -i <project-key> <user>@<ip>`). MobaXterm-style shell:
// PiP (picture-in-picture) header shows VM name + IP, terminal body, and a live
// utilization footer (CPU / RAM / disk) polled from the monitor live endpoint.
import { html, useEffect, useRef, useState } from "/js/core.js";
import { getLiveVms } from "/js/api.js";
import { attachClipboard } from "/js/xterm-clip.js";

const THEME = {
  background: "#0b0f14",
  foreground: "#d4d8dd",
  cursor: "#7dd3fc",
  selectionBackground: "#1e3a5f",
  black: "#0b0f14", red: "#f87171", green: "#4ade80", yellow: "#facc15",
  blue: "#60a5fa", magenta: "#c084fc", cyan: "#22d3ee", white: "#d4d8dd"
};

const LIVE_POLL_MS = 10000;

export default function ConsoleView({ vm, name, vc, user, diskGb, onClose, hidePin }) {
  const hostRef = useRef(null);
  const [status, setStatus] = useState("connecting"); // connecting|open|closed
  const [live, setLive] = useState(null);             // {cpuPct, memPct, memUsedMB, memTotalMB, diskGb, netKBps}
  const [pin, setPin] = useState(false);              // PiP mini-mode
  const termRef = useRef(null);
  const sockRef = useRef(null);

  useEffect(() => {
    const Terminal = window.Terminal;
    const FitAddon = (window.FitAddon && window.FitAddon.FitAddon) || window.FitAddon;
    if (!Terminal || !FitAddon) { setStatus("closed"); return; }

    const term = new Terminal({
      cursorBlink: true, fontSize: 13,
      fontFamily: '"Courier New", Courier, monospace',
      theme: THEME, scrollback: 5000
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(hostRef.current);
    fit.fit();
    termRef.current = term;

    const io = window.io;
    if (!io) { setStatus("closed"); return; }
    const sock = io(`/console?vm=${encodeURIComponent(vm || "")}&user=${encodeURIComponent(user || "ubuntu")}`, {
      transports: ["websocket", "polling"]
    });
    sockRef.current = sock;

    sock.on("ready", () => { setStatus("open"); term.writeln(`\x1b[33m[connected to ${user}@${vm}]\x1b[0m`); });
    sock.on("data", (d) => term.write(d));
    sock.on("exit", ({ code }) => {
      term.writeln(`\r\n\x1b[31m[console closed (exit ${code})]\x1b[0m`);
      setStatus("closed");
    });
    sock.on("connect_error", () => { term.writeln("\r\n\x1b[31m[connection failed — VM unreachable / key missing]\x1b[0m"); setStatus("closed"); });
    sock.on("disconnect", () => { if (status !== "closed") { term.writeln("\r\n\x1b[31m[disconnected]\x1b[0m"); setStatus("closed"); } });

    term.onData((d) => sock.emit("input", d));
    attachClipboard(term);
    // Only emit resize when cols/rows actually change — fit() on every
    // ResizeObserver tick can loop (fit mutates size → observer fires again)
    // and flood the server with resize events while the terminal collapses.
    let lastCols = 0, lastRows = 0;
    const onResize = () => {
      try {
        fit.fit();
        if (term.cols !== lastCols || term.rows !== lastRows) {
          lastCols = term.cols; lastRows = term.rows;
          sock.emit("resize", { cols: term.cols, rows: term.rows });
        }
      } catch { /* ignore */ }
    };
    onResize();
    const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver(onResize) : null;
    if (ro) ro.observe(hostRef.current);

    const focusTimer = setTimeout(() => { try { term.focus(); } catch { /* ignore */ } }, 50);

    return () => {
      clearTimeout(focusTimer);
      if (ro) ro.disconnect();
      try { sock.disconnect(); } catch { /* ignore */ }
      try { term.dispose(); } catch { /* ignore */ }
    };
  }, [vm, user]);

  // Poll the live VM snapshot for the utilization footer (CPU/RAM utilization).
  // Deliberately read-only + rate-limit friendly (inventory script file cache).
  useEffect(() => {
    if (!vc || !vm || !name) return;
    let alive = true;
    const poll = () => {
      getLiveVms(vc)
        .then((r) => {
          if (!alive) return;
          const v = Array.isArray(r) ? r : (r && r.vms) || [];
          const m = v.find((x) => x.name === name || x.ip === vm);
          if (m) {
            const cpu = Number(m.cpu || 1) * 2000;
            setLive({
              cpuPct: m.cpuUsageMHz ? Math.min(100, Math.round((m.cpuUsageMHz / cpu) * 100)) : null,
              memPct: m.memUsageMB ? Math.min(100, Math.round((m.memUsageMB / (m.memoryMB || m.memory_mb || 1)) * 100)) : null,
              memUsedMB: m.memUsageMB,
              memTotalMB: m.memoryMB || m.memory_mb,
              diskGb: m.disk_gb || m.diskGb || diskGb,
              netKBps: m.netKBps
            });
          }
        })
        .catch(() => { /* keep last-good; VM may be unreachable */ });
    };
    poll();
    const id = setInterval(poll, LIVE_POLL_MS);
    return () => { alive = false; clearInterval(id); };
  }, [vc, vm, name, diskGb]);

  return html`
    <div className="console-card">
      ${pin && html`<div className="console-pip-mini" data-tip="Click to expand">
        <button className="row" style=${{ gap: 8, alignItems: "center" }} onClick=${() => setPin(false)}>
          <span>🖥 ${name || "VM"} · ${vm}</span>
          <span className="cs-dot" style=${{ background: status === "open" ? "var(--ok)" : "var(--danger)" }}></span>
          ${status === "open" ? "live" : "closed"}
        </button>
      </div>`}
      ${!pin && html`
        <div ref=${hostRef} className="term-host console-term" />
        <div className="console-stats" title="Live VM utilization (polls every 10s)">
          ${live ? html`
          <span className="console-stat" title="CPU utilization">
            <span className="cs-dot" style=${{ background: (live.cpuPct ?? 0) > 85 ? "var(--danger)" : "var(--accent2)" }}></span>
            CPU <b>${live.cpuPct == null ? "—" : live.cpuPct + "%"}</b>
          </span>
          <span className="console-stat" title="RAM utilization">
            <span className="cs-dot" style=${{ background: (live.memPct ?? 0) > 85 ? "var(--danger)" : "var(--accent)" }}></span>
            RAM <b>${live.memPct == null ? "—" : live.memPct + "%"}</b>
            <span className="console-sub">(${live.memUsedMB ? Math.round(live.memUsedMB / 1024) : "?"}G/${live.memTotalMB ? Math.round(live.memTotalMB / 1024) : "?"}G)</span>
          </span>
          <span className="console-stat" title="Configured OS disk">
            <span className="cs-dot" style=${{ background: "var(--ok)" }}></span>
            Disk <b>${live.diskGb ? live.diskGb + "G" : "—"}</b>
          </span>
          <span className="console-stat" title="Network throughput (net.usage KB/s, live)">
            <span className="cs-dot" style=${{ background: (live.netKBps ?? 0) > 0 ? "var(--accent2)" : "var(--muted)" }}></span>
            Net <b>${live.netKBps == null || live.netKBps === 0 ? "—" : (live.netKBps / 1024).toFixed(1) + " MB/s"}</b>
          </span>
          ` : html`<span className="console-stat muted">stats…</span>`}
          <span className="console-stat" style=${{ marginLeft: "auto" }}>
            <span className="pill ${status === "open" ? "ok" : status === "connecting" ? "pending" : "off"}">${status === "open" ? "live" : status === "connecting" ? "connecting" : "closed"}</span>
            ${!hidePin && html`<button className="ghost" data-tip="Pin console (picture-in-picture)" onClick=${() => setPin(true)}>⛶</button>`}
          </span>
        </div>
      `}
    </div>`;
}