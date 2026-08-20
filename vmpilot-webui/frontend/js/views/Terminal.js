// views/Terminal.js — full interactive shell via xterm.js + node-pty.
import { html, useEffect, useRef, useState } from "/js/core.js";
import { attachClipboard } from "/js/xterm-clip.js";

const THEME = {
  background: "#0b0f14",
  foreground: "#d4d8dd",
  cursor: "#7dd3fc",
  selectionBackground: "#1e3a5f",
  black: "#0b0f14",
  red: "#f87171",
  green: "#4ade80",
  yellow: "#facc15",
  blue: "#60a5fa",
  magenta: "#c084fc",
  cyan: "#22d3ee",
  white: "#d4d8dd"
};

export default function TerminalView() {
  const hostRef = useRef(null);
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    const Terminal = window.Terminal;
    // xterm-addon-fit's UMD exposes the class as a named export on the global
    // (window.FitAddon = { FitAddon: class }), not the class itself.
    const FitAddon = (window.FitAddon && window.FitAddon.FitAddon) || window.FitAddon;
    if (!Terminal || !FitAddon) return;

    const term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: '"JetBrains Mono", Menlo, Consolas, monospace',
      theme: THEME,
      scrollback: 10000
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(hostRef.current);
    fit.fit();

    const socket = window.io("/terminal");

    socket.on("connect", () => {
      setConnected(true);
      term.focus();
      socket.emit("resize", { cols: term.cols, rows: term.rows });
    });
    socket.on("ready", () => term.focus());
    socket.on("data", (d) => term.write(d));
    socket.on("disconnect", () => {
      setConnected(false);
      term.write("\r\n\x1b[31m[connection closed — reload to reconnect]\x1b[0m\r\n");
    });

    term.onData((d) => socket.emit("input", d));
    attachClipboard(term);

    function onResize() {
      try {
        fit.fit();
        socket.emit("resize", { cols: term.cols, rows: term.rows });
      } catch { /* ignore */ }
    }
    window.addEventListener("resize", onResize);

    return () => {
      window.removeEventListener("resize", onResize);
      socket.disconnect();
      term.dispose();
    };
  }, []);

  return html`
    <div className="term-wrap">
      <div className="term-host">
        <div className=${`term-status ${connected ? "ok" : ""}`}>
          ${connected ? "● connected" : "○ disconnected"}
        </div>
        <div className="term-inner" ref=${hostRef} />
      </div>
    </div>`;
}