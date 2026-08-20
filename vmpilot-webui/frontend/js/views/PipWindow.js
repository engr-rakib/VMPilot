// views/PipWindow.js — ONE unified floating "picture-in-picture" window used by
// EVERY console-ish surface in VMPilot: VM SSH console (ConsolePip), the global
// Terminal (Shell ⌘), and task execution previews (Disk Resize execute card).
// Single chrome = drag on header, corner resize, — minimize, ✕ close, optional
// ⤢ move-to-workspace. A parent can drive minimize externally (bottom ribbon in
// Shell) via onMinimize; otherwise the window self-minimizes to a pill.
import { html, useState, useRef } from "/js/core.js";

export default function PipWindow({
  icon, title, status, w = 560, h = 500, minW = 320, minH = 260,
  minimized, onMinimize, onClose, onMoveWorkspace, children, pill
}) {
  const [selfMin, setSelfMin] = useState(false);
  const [size, setSize] = useState({ w, h });
  const [pos, setPos] = useState(() => ({
    x: Math.max(12, window.innerWidth - w - 24),
    y: Math.max(12, window.innerHeight - h - 24)
  }));
  const wrapRef = useRef(null);
  const drag = useRef(null);
  const resize = useRef(null);

  const min = onMinimize ? minimized : selfMin;
  const setMin = onMinimize ? onMinimize : setSelfMin;

  const onMouseDown = (e) => {
    if (e.target.closest("button")) return; // buttons don't drag
    const r = wrapRef.current.getBoundingClientRect();
    drag.current = { dx: e.clientX - r.left, dy: e.clientY - r.top };
    const move = (ev) => setPos({
      x: Math.max(0, Math.min(window.innerWidth - 60, ev.clientX - drag.current.dx)),
      y: Math.max(0, Math.min(window.innerHeight - 40, ev.clientY - drag.current.dy))
    });
    const up = () => { drag.current = null; window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up); };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  };

  const onResizeDown = (e) => {
    e.stopPropagation();
    e.preventDefault();
    const r = wrapRef.current.getBoundingClientRect();
    resize.current = { w: r.width, h: r.height, x: e.clientX, y: e.clientY };
    const move = (ev) => setSize({
      w: Math.max(minW, Math.min(window.innerWidth - pos.x - 20, resize.current.w + ev.clientX - resize.current.x)),
      h: Math.max(minH, Math.min(window.innerHeight - pos.y - 20, resize.current.h + ev.clientY - resize.current.y))
    });
    const up = () => { resize.current = null; window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up); };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  };

  if (min) {
    // Externally driven minimize (parent renders the bottom-ribbon item). The
    // body STAYS MOUNTED (hidden) so an SSH/xterm session survives minimize.
    if (onMinimize) {
      return html`<div style=${{ display: "none" }} aria-hidden="true">${children}</div>`;
    }
    // Self-contained minimize → a floating pill (click to restore).
    return html`<div className="pip-mini" onClick=${() => setMin(false)}>
      ${pill || html`<span>${icon} ${title}</span>`}
      ${onClose && html`<button className="ghost" onClick=${(e) => { e.stopPropagation(); onClose(); }}>✕</button>`}
    </div>`;
  }

  return html`
    <div ref=${wrapRef} className="pip" style=${{ left: pos.x + "px", top: pos.y + "px", width: size.w + "px", height: size.h + "px" }}>
      <div className="pip-head" onMouseDown=${onMouseDown}>
        <span className="pip-title">${icon} ${title}</span>
        ${status && html`<span className="pip-status">${status}</span>`}
        <span className="pip-actions">
          ${onMoveWorkspace && html`<button className="ghost" data-tip="Move to workspace thread" onClick=${onMoveWorkspace}>⤢</button>`}
          <button className="ghost" data-tip="Minimize to bottom ribbon" onClick=${() => setMin(true)}>—</button>
          ${onClose && html`<button className="ghost" data-tip="Close" onClick=${onClose}>✕</button>`}
        </span>
      </div>
      <div className="pip-body">${children}</div>
      <div className="pip-resize" onMouseDown=${onResizeDown} data-tip="Drag to resize" />
    </div>`;
}