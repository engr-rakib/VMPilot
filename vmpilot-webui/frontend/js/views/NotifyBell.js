// views/NotifyBell.js — notification bell + dropdown panel in the shell top bar.
// Polls the unseen-count every 12s; clicking opens the dropdown (loading the
// full list lazily) and marks everything seen. Individual alerts can be
// acknowledged, and the whole log can be cleared.
// Props:
//   onOpen(alert)  — clicking a specific notification (navigate to its task/event)
//   onOpenAll()    — clicking "view all" → the Events page
import { html, useState, useEffect, useRef } from "/js/core.js";
import { getAlerts, getAlertsUnseen, markAlertsSeen, clearAlerts } from "/js/api.js";
import { suggestLine } from "/js/alerts-util.js";

const sevIcon = (a) => {
  if (a.kind === "event") return a.severity === "warn" ? "⚠️" : "🔔";
  return a.severity === "critical" ? "🔴" : a.severity === "warn" ? "🟠" : "🔵";
};

const timeAgo = (at) => {
  const s = Math.max(0, Math.floor((Date.now() - Number(at)) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
};

export default function NotifyBell({ onOpen, onOpenAll }) {
  const [open, setOpen] = useState(false);
  const [unseen, setUnseen] = useState(0);
  const [alerts, setAlerts] = useState(null);
  const [error, setError] = useState("");
  const rootRef = useRef(null);

  const pollCount = () => getAlertsUnseen().then((r) => setUnseen(r.count || 0)).catch(() => {});
  const loadList = () => {
    setAlerts(null);
    getAlerts()
      .then((arr) => {
        setAlerts(Array.isArray(arr) ? arr : []);
        const unseenIds = (Array.isArray(arr) ? arr : []).filter((a) => !a.seen).map((a) => a.id);
        if (unseenIds.length) markAlertsSeen(unseenIds).catch(() => {});
        setUnseen(0);
      })
      .catch((e) => setError(e.message));
  };

  const toggle = () => {
    if (!open) loadList();
    setOpen(!open);
  };

  const go = (a) => {
    setOpen(false);
    if (onOpen) onOpen(a);
  };

  useEffect(() => {
    pollCount();
    const id = setInterval(pollCount, 12000);
    return () => clearInterval(id);
  }, []);

  // close when clicking outside
  useEffect(() => {
    if (!open) return;
    const h = (e) => { if (rootRef.current && !rootRef.current.contains(e.target)) setOpen(false); };
    document.addEventListener("mousedown", h);
    return () => document.removeEventListener("mousedown", h);
  }, [open]);

  return html`
    <div className="notify" ref=${rootRef}>
      <button className="ghost notify-bell" onClick=${toggle} data-tip="Notifications">
        <span>🔔</span>
        ${unseen > 0 && html`<span className="notify-badge">${unseen > 9 ? "9+" : unseen}</span>`}
      </button>
      ${open && html`
        <div className="notify-drop">
          <div className="notify-head">
            <span className="notify-title">Notifications</span>
            <button className="mini" onClick=${(e) => { e.stopPropagation(); clearAlerts().then(() => setAlerts([])).catch(() => {}); }} data-tip="Clear all">clear</button>
          </div>
          <div className="notify-list">
            ${error && html`<p className="muted">${error}</p>`}
            ${!alerts && html`<p className="muted">loading…</p>`}
            ${alerts && alerts.length === 0 && html`<p className="muted">No notifications yet.</p>`}
            ${(alerts || []).map((a) => html`
              <div key=${a.id} className=${a.seen ? "notify-item seen" : "notify-item"}
                onClick=${() => go(a)}>
                <span className="notify-ico">${sevIcon(a)}</span>
                <div className="notify-body">
                  <div className="notify-line"><strong>${a.label}</strong> ${a.value ? html`<span className=${a.severity === "critical" ? "danger" : "warn"}>${a.value}</span>` : ""}</div>
                  ${a.kind === "resource" && suggestLine(a) ? html`<div className="notify-suggest">${suggestLine(a)}</div>` : ""}
                  <div className="notify-sub">
                    ${[a.vc, a.env, a.vm].filter(Boolean).join(" / ") || "—"}
                    ${a.user ? html` <span className="muted">· by ${a.user}</span>` : ""}
                    <span className="muted"> · ${timeAgo(a.at)}</span>
                    ${a.task_id ? html` <span className="muted">→ open task</span>` : a.kind === "resource" && a.vc
                      ? (a.label || "").startsWith("Host ")
                        ? html` <span className="muted">→ open host</span>`
                        : (a.label || "").startsWith("Datastore")
                          ? html` <span className="muted">→ open vCenter</span>`
                          : html` <span className="muted">→ open VM</span>`
                      : ""}
                  </div>
                </div>
              </div>`)}
          </div>
          <div className="notify-foot">
            <button className="ghost" onClick=${() => { setOpen(false); if (onOpenAll) onOpenAll(); }}>
              View all events →
            </button>
          </div>
        </div>`}
    </div>`;
}