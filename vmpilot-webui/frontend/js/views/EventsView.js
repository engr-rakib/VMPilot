// views/EventsView.js — vCenter-style Events & Activity ledger.
// Category tabs (Summary / Notifications / Events / Tasks / System), each
// newest-first with a UNIFORM table design (same colgroup across all tabs).
// Every job-related row can EXPAND INLINE to show the detailed live log
// (accordion) — no navigation away from this page, so the workflow never breaks.
//   • a VM-only row (resource/system) keeps the "→ config" link to Inventory.
//   • a row with a task_id gets a "▸ log" toggle that expands the JobThread.
// The Summary stat-cards are clickable → jump to the matching tab/filter.
// The Events tab is paginated (Prev/Next, 50/page); Notifications keeps its own
// latest-200 list so paging never hides a warn/critical alert.
// The When column shows an absolute HH:mm:ss timestamp (title = relative + full).
// Deep-link: `initial.openTaskId` (from a bell click) opens the Events page and
// auto-expands that task's log inline.
import { html, useState, useEffect, useRef } from "/js/core.js";
import { getEvents, getEventsSummary, getTasks, getJob, listMonitorVcs, markEventsSeen, actionLabel } from "/js/api.js";
import { Spinner, Pill } from "/js/components.js";
import { suggestLine } from "/js/alerts-util.js";
import JobThread from "/js/views/JobThread.js";

const PAGE = 50;

const sevClass = (s) => s === "critical" ? "off" : s === "warn" ? "pending" : "ok";

const timeAgo = (at) => {
  if (!at) return "—";
  const s = Math.max(0, Math.floor((Date.now() - Number(at)) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
};

const fullDt = (at) => {
  if (!at) return "";
  try { return new Date(Number(at)).toLocaleString(); } catch { return ""; }
};

// Absolute timestamp shown in the When column: HH:mm:ss today, else date+time.
const fmtTs = (at) => {
  if (!at) return "—";
  const d = new Date(Number(at));
  if (Number.isNaN(d.getTime())) return "—";
  const p = (n) => String(n).padStart(2, "0");
  const today = new Date().toDateString() === d.toDateString();
  return today
    ? `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
    : `${p(d.getDate())}/${p(d.getMonth() + 1)}/${String(d.getFullYear()).slice(2)} ${p(d.getHours())}:${p(d.getMinutes())}`;
};

const dur = (a, b) => {
  if (!a || !b) return "—";
  const s = Math.max(0, Math.round((b - a) / 1000));
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${s % 60}s`;
};

const statusCls = (st) => st === "success" ? "ok" : st === "failed" ? "off" : "pending";

const kindIco = (k) => k === "resource" ? "📈" : k === "power" ? "⚡" : k === "system" ? "🛠" : "🧰";

// Inline detailed log for an event row that only carries a task_id.
// Fetches the job, then renders the live JobThread (stepper + output).
function JobExpand({ id }) {
  const [job, setJob] = useState(null);
  const [err, setErr] = useState("");
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let a = true;
    setErr("");
    setJob(null);
    getJob(id).then((j) => { if (a) setJob(j); })
      .catch((e) => { if (a) setErr((e && e.message) || "failed to load job log"); });
    return () => { a = false; };
  }, [id, tick]);
  if (err) return html`<p className="muted">${err} <button className="mini" onClick=${() => setTick((t) => t + 1)}>retry</button></p>`;
  if (!job) return html`<p className="muted"><${Spinner} inline /> loading log…</p>`;
  return html`<${JobThread} job=${job} />`;
}

export default function EventsView({ resolveVm, onOpenVm, onHost, onVc, initial }) {
  const [tab, setTab] = useState("summary");     // summary|notifications|events|tasks|system
  const [vcs, setVcs] = useState([]);
  const [summary, setSummary] = useState(null);
  const [events, setEvents] = useState(null);
  const [notifs, setNotifs] = useState(null);
  const [tasks, setTasks] = useState(null);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState({ vc: "", kind: "", severity: "" });
  const [nf, setNf] = useState({ vc: "", severity: "" });
  const [taskFilter, setTaskFilter] = useState({ vc: "", action: "", status: "" });
  const [evPage, setEvPage] = useState(0);
  const [hasMore, setHasMore] = useState(false);
  const [expanded, setExpanded] = useState("");
  const [refreshing, setRefreshing] = useState(false);

  // Deep-link from the bell: jump to the Tasks tab and auto-expand that task's
  // log inline. Re-triggers whenever initial.openTaskId changes (primitive dep),
  // so clicking a different notification while already on this page still works.
  const deepId = initial && initial.openTaskId;
  useEffect(() => {
    if (deepId) {
      setTab("tasks");
      setExpanded(deepId);
    }
  }, [deepId]);

  // keep the latest filter/page so the 30s background poll never goes stale
  const filterRef = useRef({ ...filter, evPage });
  useEffect(() => { filterRef.current = { ...filter, evPage }; }, [filter, evPage]);

  useEffect(() => { listMonitorVcs().then(setVcs).catch(() => {}); }, []);

  const loadEvents = () => {
    const f = filterRef.current;
    return Promise.all([
      getEvents({ vc: f.vc, kind: f.kind, severity: f.severity, offset: f.evPage * PAGE, limit: PAGE })
        .then((arr) => { const a = Array.isArray(arr) ? arr : []; setEvents(a); setHasMore(a.length === PAGE); })
        .catch((e) => setError(e.message)),
      getEventsSummary().then(setSummary).catch(() => {})
    ]);
  };
  const loadNotifs = () => getEvents({ limit: 200 }).then(setNotifs).catch(() => {});
  const loadTasks = () => getTasks(taskFilter).then(setTasks).catch((e) => setError(e.message));

  useEffect(() => { loadEvents(); }, [JSON.stringify(filter), evPage]);
  useEffect(() => { loadNotifs(); }, []);
  useEffect(() => { loadTasks(); }, [JSON.stringify(taskFilter)]);

  useEffect(() => {
    const id = setInterval(() => { loadEvents(); loadNotifs(); loadTasks(); }, 30000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const refreshAll = async () => {
    setRefreshing(true);
    await Promise.all([loadEvents(), loadNotifs(), loadTasks()]);
    setRefreshing(false);
  };

  const toggleExpand = (id) => setExpanded((x) => (x === id ? "" : id));

  const markAll = () => {
    const rows = notifRows();
    markEventsSeen(rows.filter((e) => !e.seen).map((e) => e.id)).then((r) => {
      if (r && typeof r.unseen === "number") getEventsSummary().then(setSummary).catch(() => {});
    }).catch(() => {});
    setNotifs((ns) => (ns || []).map((e) => ({ ...e, seen: 1 })));
  };

  const notifRows = () => {
    const ns = notifs || [];
    const nfilters = (e) =>
      (e.severity === "critical" || e.severity === "warn") &&
      (!nf.vc || e.vc === nf.vc) &&
      (!nf.severity || e.severity === nf.severity);
    return ns.filter(nfilters);
  };

  const sev = (s) => (summary && summary.by_severity && summary.by_severity[s]) || 0;
  const running = (tasks || []).filter((t) => t.status === "running" || t.status === "queued").length;

  const openEventVm = (e) => {
    const r = resolveVm && resolveVm(e.vc, e.vm);
    if (r && onOpenVm) onOpenVm(r.vc, r.env, r.file);
  };
  const openEventHost = (e) => { if (onHost) onHost(e.vc, e.vm); };
  const openEventVc = (e) => { if (onVc) onVc(e.vc); };

  // Summary card navigation (clickable — jump to the matching tab/filter).
  const goNotifs = (sev2) => { setNf((n) => ({ ...n, severity: sev2 || "" })); setTab("notifications"); };
  const goTasks = (status) => { setTaskFilter((t) => ({ ...t, status: status || "" })); setTab("tasks"); };
  const setFilterBoth = (next) => { setFilter(next); setEvPage(0); };

  // summary "latest activity" = recent events + tasks merged, newest first
  const activity = () => {
    const ev = (events || []).map((e) => ({ key: "ev-" + e.id, t: e.at, kind: "event", e }));
    const tk = (tasks || []).map((t) => ({ key: "tk-" + t.id, t: t.started_at, kind: "task", t }));
    return [...ev, ...tk].sort((a, b) => (Number(b.t) || 0) - (Number(a.t) || 0)).slice(0, 12);
  };

  const TABS = [
    { id: "summary", label: "Summary" },
    { id: "notifications", label: `Notifications${(summary && summary.unseen) ? ` (${summary.unseen})` : ""}` },
    { id: "events", label: "Events" },
    { id: "tasks", label: `Tasks${running ? ` (${running})` : ""}` },
    { id: "system", label: "System" }
  ];

  const tableScroll = (body) => html`<div className="table-scroll"><table className="mini-table">${body}</table></div>`;

  // Uniform colgroup shared by every event-style table.
  const EVCOLS = html`<colgroup>
    <col style=${{ width: "8%" }} /><col style=${{ width: "11%" }} />
    <col style=${{ width: "30%" }} /><col style=${{ width: "27%" }} />
    <col style=${{ width: "13%" }} /><col style=${{ width: "11%" }} />
  </colgroup>`;

  // Action cell for an event row, matched to what the row actually points at:
  //   • job rows            → expand the live log inline
  //   • Host* resource rows → deep-link to that host in Inventory (→ host)
  //   • Datastore* rows     → deep-link to that vCenter in Inventory (→ vCenter)
  //   • VM rows (resolvable)→ link to the VM config (→ cfg)
  // A raw config file can't help a host alert, so host/datastore rows never get
  // "→ cfg" (the resolve check below is a real lookup, not just a truthy fn).
  const evActions = (e) => {
    const label = e.label || "";
    if (e.task_id) return html`<button className="mini" data-tip=${expanded === e.task_id ? "Close log" : "Expand detailed log"} onClick=${() => toggleExpand(e.task_id)}>${expanded === e.task_id ? "▾" : "▸"} log</button>`;
    if (label.startsWith("Host ") && e.vm && onHost)
      return html`<button className="mini" data-tip="Open this host in Inventory" onClick=${() => openEventHost(e)}>→ host</button>`;
    if (label.startsWith("Datastore") && e.vc && onVc)
      return html`<button className="mini" data-tip="Open this vCenter in Inventory" onClick=${() => openEventVc(e)}>→ vCenter</button>`;
    if (e.vm && onOpenVm && resolveVm && resolveVm(e.vc, e.vm))
      return html`<button className="mini" data-tip="Open VM config" onClick=${() => openEventVm(e)}>→ cfg</button>`;
    return "";
  };
  const evExpandRow = (e) => (e.task_id && expanded === e.task_id)
    ? html`<tr key=${e.id + "-exp"} className="ev-expand-row"><td colSpan="6" className="ev-expand-cell"><${JobExpand} id=${e.task_id} /></td></tr>`
    : "";
  const evWhen = (at) => html`<td className="muted" title=${`${timeAgo(at)} · ${fullDt(at)}`}>${fmtTs(at)}</td>`;
  const evTarget = (e) => html`<td>${[e.vc, e.env, e.vm].filter(Boolean).join(" / ") || "—"}</td>`;
  // Label cell: value + user, plus (for resource alerts) an actionable
  // suggestion and how long the alert has been active.
  const evLabel = (e) => html`<td>
    <strong>${e.label}</strong> ${e.value ? html`<span className=${e.severity === "critical" ? "danger" : "warn"}>${e.value}</span>` : ""}${e.user ? html` <span className="muted">· by ${e.user}</span>` : ""}
    ${e.kind === "resource" && suggestLine(e) ? html`<div className="ev-suggest">${suggestLine(e)}</div>` : ""}
  </td>`;

  return html`
    <div className="page">
      <div className="page-head">
        <h2>Events & Activity</h2>
        <div className="row">
          ${TABS.map((t) => html`
            <button key=${t.id} className=${tab === t.id ? "ghost active-tab" : "ghost"} onClick=${() => setTab(t.id)}>${t.label}</button>`)}
          <button className="ghost ev-refresh" onClick=${refreshAll} disabled=${refreshing} data-tip="Refresh all">
            <span className=${refreshing ? "ev-refresh-ico spin" : "ev-refresh-ico"}>⟳</span> Refresh
          </button>
        </div>
      </div>

      ${error && html`<p className="error">${error}</p>`}

      ${tab === "summary" ? html`
        <div className="ev-overview">
          <button className="ev-card stat-card ${tab === "notifications" ? "active" : ""}" data-tip="Open Notifications (unseen alerts)" onClick=${() => goNotifs("")}>
            <span className="stat-label">Unseen</span>
            <span className="stat-num ${summary && summary.unseen ? "off-num" : ""}">${(summary && summary.unseen) || 0}</span>
          </button>
          <button className="ev-card stat-card" data-tip="Open critical notifications" onClick=${() => goNotifs("critical")}>
            <span className="stat-label">Critical</span>
            <span className="stat-num ${sev("critical") ? "off-num" : ""}">${sev("critical")}</span>
          </button>
          <button className="ev-card stat-card" data-tip="Open warning notifications" onClick=${() => goNotifs("warn")}>
            <span className="stat-label">Warning</span>
            <span className="stat-num ${sev("warn") ? "pending-num" : ""}">${sev("warn")}</span>
          </button>
          <button className="ev-card stat-card" data-tip="Open all tasks" onClick=${() => goTasks("")}>
            <span className="stat-label">Tasks</span>
            <span className="stat-num">${(tasks && tasks.length) || 0}</span>
          </button>
          <button className="ev-card stat-card" data-tip="Open running tasks" onClick=${() => goTasks("running")}>
            <span className="stat-label">Running</span>
            <span className="stat-num ${running ? "pending-num" : ""}">${running}</span>
          </button>
          <button className="ev-card stat-card" data-tip="Open failed tasks" onClick=${() => goTasks("failed")}>
            <span className="stat-label">Failed</span>
            <span className="stat-num ${(tasks || []).filter((t) => t.status === "failed").length ? "off-num" : ""}">${(tasks || []).filter((t) => t.status === "failed").length}</span>
          </button>
        </div>
        <h3 className="muted" style=${{ marginTop: 0, fontSize: 13 }}>Latest activity</h3>
        ${!events || !tasks ? html`<p className="muted"><${Spinner} inline /> loading…</p>` :
          activity().length === 0 ? html`<p className="muted">No activity yet.</p>` : html`
        <div className="table-scroll">
        <table className="mini-table">
          ${EVCOLS}
          <thead><tr><th>Type</th><th>Severity/Status</th><th>Label / Action</th><th>Target</th><th>When</th><th></th></tr></thead>
          <tbody>
            ${activity().map((a) => a.kind === "event" ? html`
              <tr key=${a.key} className=${expanded === a.e.task_id ? "ev-expand-on" : ""}>
                <td>${kindIco(a.e.kind)} ${a.e.kind}</td>
                <td><${Pill} cls=${sevClass(a.e.severity)}>${a.e.severity}</${Pill}></td>
                ${evLabel(a.e)}
                ${evTarget(a.e)}
                ${evWhen(a.e.at)}
                <td>${evActions(a.e)}</td>
              </tr>${evExpandRow(a.e)}` : html`
              <tr key=${a.key} className=${expanded === a.t.id ? "ev-expand-on" : ""}>
                <td>🧰 task</td>
                <td><${Pill} cls=${statusCls(a.t.status)}>${a.t.status}</${Pill}></td>
                <td><strong>${actionLabel(a.t.action)}</strong>${a.t.user ? html` <span className="muted">· by ${a.t.user}</span>` : ""}</td>
                <td>${[a.t.target_vc, a.t.target_env, a.t.target_vm].filter(Boolean).join(" / ") || "—"}</td>
                <td className="muted" title=${`${timeAgo(a.t.started_at)} · ${fullDt(a.t.started_at)}`}>${fmtTs(a.t.started_at)}</td>
                <td><button className="mini" data-tip="Expand detailed log" onClick=${() => toggleExpand(a.t.id)}>${expanded === a.t.id ? "▾" : "▸"} log</button></td>
              </tr>
              ${expanded === a.t.id ? html`<tr key=${a.key + "-exp"} className="ev-expand-row"><td colSpan="6" className="ev-expand-cell"><${JobThread} job=${a.t} /></td></tr>` : ""}`)}
          </tbody>
        </table>
        </div>`}
      ` : ""}

      ${tab === "notifications" ? html`
        <div className="ev-filters">
          <select value=${nf.vc} onChange=${(e) => setNf({ ...nf, vc: e.target.value })}>
            <option value="">All vCenters</option>
            ${vcs.map((v) => html`<option key=${v} value=${v}>${v}</option>`)}
          </select>
          <select value=${nf.severity} onChange=${(e) => setNf({ ...nf, severity: e.target.value })}>
            <option value="">All severities</option>
            <option value="critical">Critical</option>
            <option value="warn">Warning</option>
          </select>
          <span className="muted">${notifs ? notifRows().length + " alerts" : ""}</span>
          <button className="ghost" style=${{ marginLeft: "auto" }} onClick=${markAll} disabled=${!notifRows().some((e) => !e.seen)}>Mark all seen</button>
        </div>
        ${!notifs ? html`<p className="muted"><${Spinner} inline /> loading…</p>` : html`
        <div className="table-scroll">
        <table className="mini-table">
          ${EVCOLS}
          <thead><tr><th>Type</th><th>Severity</th><th>Label</th><th>Target</th><th>When</th><th></th></tr></thead>
          <tbody>
            ${notifRows().map((e) => html`
              <tr key=${e.id} className=${(e.seen ? "" : "unseen") + (expanded === e.task_id ? " ev-expand-on" : "")}>
                <td>${kindIco(e.kind)} ${e.kind}</td>
                <td><${Pill} cls=${sevClass(e.severity)}>${e.severity}</${Pill}></td>
                ${evLabel(e)}
                ${evTarget(e)}
                ${evWhen(e.at)}
                <td>${evActions(e)}</td>
              </tr>${evExpandRow(e)}`)}
            ${notifRows().length === 0 && html`<tr><td colSpan="6" className="muted">No notifications. All clear.</td></tr>`}
          </tbody>
        </table>
        </div>`}
      ` : ""}

      ${tab === "events" ? html`
        <div className="row ev-filters">
          <select value=${filter.vc} onChange=${(e) => setFilterBoth({ ...filter, vc: e.target.value })}>
            <option value="">All vCenters</option>
            ${vcs.map((v) => html`<option key=${v} value=${v}>${v}</option>`)}
          </select>
          <select value=${filter.kind} onChange=${(e) => setFilterBoth({ ...filter, kind: e.target.value })}>
            <option value="">All kinds</option>
            <option value="resource">Resource</option>
            <option value="event">Event</option>
            <option value="system">System</option>
          </select>
          <select value=${filter.severity} onChange=${(e) => setFilterBoth({ ...filter, severity: e.target.value })}>
            <option value="">All severities</option>
            <option value="critical">Critical</option>
            <option value="warn">Warning</option>
            <option value="info">Info</option>
          </select>
          <span className="muted">${summary ? `critical ${sev("critical")} · warn ${sev("warn")} · unseen ${summary.unseen}` : ""}</span>
        </div>
        ${!events ? html`<p className="muted"><${Spinner} inline /> loading…</p>` : html`
        <div className="table-scroll">
        <table className="mini-table">
          ${EVCOLS}
          <thead><tr><th>Type</th><th>Severity</th><th>Label</th><th>Target</th><th>When</th><th></th></tr></thead>
          <tbody>
            ${events.map((e) => html`
              <tr key=${e.id} className=${expanded === e.task_id ? "ev-expand-on" : ""}>
                <td>${kindIco(e.kind)} ${e.kind}</td>
                <td><${Pill} cls=${sevClass(e.severity)}>${e.severity}</${Pill}></td>
                ${evLabel(e)}
                ${evTarget(e)}
                ${evWhen(e.at)}
                <td>${evActions(e)}</td>
              </tr>${evExpandRow(e)}`)}
            ${events.length === 0 && html`<tr><td colSpan="6" className="muted">No events match the filters.</td></tr>`}
          </tbody>
        </table>
        </div>
        <div className="ev-pager">
          <span className="muted">${events.length} on page ${evPage + 1}</span>
          <button className="ghost" disabled=${evPage === 0} onClick=${() => setEvPage(evPage - 1)}>← Prev</button>
          <button className="ghost" disabled=${!hasMore} onClick=${() => setEvPage(evPage + 1)}>Next →</button>
        </div>`}
      ` : ""}

      ${tab === "tasks" ? html`
        <div className="row ev-filters">
          <select value=${taskFilter.vc} onChange=${(e) => setTaskFilter({ ...taskFilter, vc: e.target.value })}>
            <option value="">All vCenters</option>
            ${vcs.map((v) => html`<option key=${v} value=${v}>${v}</option>`)}
          </select>
          <select value=${taskFilter.action} onChange=${(e) => setTaskFilter({ ...taskFilter, action: e.target.value })}>
            <option value="">All actions</option>
            <option value="deploy">deploy</option>
            <option value="deploy-plan">plan</option>
            <option value="sync">sync</option>
            <option value="sync-plan">sync-plan</option>
            <option value="destroy">destroy</option>
            <option value="power">power</option>
            <option value="backup">backup</option>
            <option value="restore">restore</option>
            <option value="expand">expand</option>
          </select>
          <select value=${taskFilter.status} onChange=${(e) => setTaskFilter({ ...taskFilter, status: e.target.value })}>
            <option value="">All status</option>
            <option value="queued">queued</option>
            <option value="running">running</option>
            <option value="success">success</option>
            <option value="failed">failed</option>
          </select>
          <span className="muted">${tasks ? tasks.length + " tasks" : ""}</span>
        </div>
        ${!tasks ? html`<p className="muted"><${Spinner} inline /> loading…</p>` : html`
        <div className="table-scroll">
        <table className="mini-table">
          <colgroup>
            <col style=${{ width: "10%" }} /><col style=${{ width: "12%" }} />
            <col style=${{ width: "24%" }} /><col style=${{ width: "10%" }} />
            <col style=${{ width: "11%" }} /><col style=${{ width: "9%" }} />
            <col style=${{ width: "14%" }} /><col style=${{ width: "10%" }} />
          </colgroup>
          <thead><tr><th>Task</th><th>Action</th><th>Target</th><th>User</th><th>Status</th><th>Duration</th><th>Started</th><th></th></tr></thead>
          <tbody>
            ${tasks.map((t) => html`
              <tr key=${t.id} className=${expanded === t.id ? "ev-expand-on" : ""}>
                <td><code>${t.id.slice(-8)}</code></td>
                <td>${actionLabel(t.action)}</td>
                <td>${[t.target_vc, t.target_env, t.target_vm].filter(Boolean).join(" / ") || "—"}</td>
                <td>${t.user || "—"}</td>
                <td><${Pill} cls=${statusCls(t.status)}>${t.status}</${Pill}></td>
                <td className="muted" title=${`${fullDt(t.finished_at)}`}>${dur(t.started_at, t.finished_at)}</td>
                <td className="muted" title=${`${timeAgo(t.started_at)} · ${fullDt(t.started_at)}`}>${fmtTs(t.started_at)}</td>
                <td><button className="mini" data-tip="Expand detailed log" onClick=${() => toggleExpand(t.id)}>${expanded === t.id ? "▾" : "▸"} log</button></td>
              </tr>
              ${expanded === t.id ? html`<tr key=${t.id + "-exp"} className="ev-expand-row"><td colSpan="8" className="ev-expand-cell"><${JobThread} job=${t} /></td></tr>` : ""}`)}
            ${tasks.length === 0 && html`<tr><td colSpan="8" className="muted">No tasks yet. Start a deploy/plan/sync to see it here.</td></tr>`}
          </tbody>
        </table>
        </div>`}
      ` : ""}

      ${tab === "system" ? html`
        <div className="ev-filters">
          <select value=${filter.vc} onChange=${(e) => setFilterBoth({ ...filter, vc: e.target.value })}>
            <option value="">All vCenters</option>
            ${vcs.map((v) => html`<option key=${v} value=${v}>${v}</option>`)}
          </select>
          <select value=${filter.kind} onChange=${(e) => setFilterBoth({ ...filter, kind: e.target.value })}>
            <option value="">All kinds</option>
            <option value="resource">Resource</option>
            <option value="system">System</option>
            <option value="event">Event</option>
          </select>
          <select value=${filter.severity} onChange=${(e) => setFilterBoth({ ...filter, severity: e.target.value })}>
            <option value="">All severities</option>
            <option value="critical">Critical</option>
            <option value="warn">Warning</option>
            <option value="info">Info</option>
          </select>
          <span className="muted">${events ? events.filter((e) => e.kind === "system" || e.kind === "resource").length + " system/resource events" : ""}</span>
        </div>
        ${!events ? html`<p className="muted"><${Spinner} inline /> loading…</p>` : html`
        <div className="table-scroll">
        <table className="mini-table">
          ${EVCOLS}
          <thead><tr><th>Type</th><th>Severity</th><th>Label</th><th>Target</th><th>When</th><th></th></tr></thead>
          <tbody>
            ${events.filter((e) => e.kind === "system" || e.kind === "resource").map((e) => html`
              <tr key=${e.id} className=${expanded === e.task_id ? "ev-expand-on" : ""}>
                <td>${kindIco(e.kind)} ${e.kind}</td>
                <td><${Pill} cls=${sevClass(e.severity)}>${e.severity}</${Pill}></td>
                ${evLabel(e)}
                ${evTarget(e)}
                ${evWhen(e.at)}
                <td>${evActions(e)}</td>
              </tr>${evExpandRow(e)}`)}
            ${events.filter((e) => e.kind === "system" || e.kind === "resource").length === 0 && html`<tr><td colSpan="6" className="muted">No system activity yet.</td></tr>`}
          </tbody>
        </table>
        </div>`}
      ` : ""}
    </div>`;
}