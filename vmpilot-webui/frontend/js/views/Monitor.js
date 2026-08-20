// views/Monitor.js — infrastructure monitoring: per-vCenter → datacenter →
// host → node (VM) resource drill-down. Each vCenter card loads INDEPENDENTLY
// (own skeleton + error) so a slow or unreachable vCenter never blocks the page.
//
// Layout per vCenter card:
//   1. header summary (VM counts, CPU/RAM/disk totals)
//   2. HOSTS table  — per-ESXi host: CPU + RAM utilization bars (live govc)
//   3. DATASTORES table — capacity/free + % used bars
//   4. VM tables per env — configured + live CPU/RAM utilization
import { html, useState, useEffect, useRef } from "/js/core.js";
import { listMonitorVcs, getMonitorVc, getTrends, getEvents, getConsoleSessions, getGuestData, setVmPower, getTasks, createJob } from "/js/api.js";
import { Spinner, Pill } from "/js/components.js";
import { MiniBar, TrendChart } from "/js/charts.js";
import { dcCapItems, DcDonuts } from "/js/trends.js";
import ExpandPip from "/js/views/ExpandConsole.js";

const pct = (used, total) => {
  if (!total || !used) return 0;
  return Math.min(100, Math.round((used / total) * 100));
};

// Configured totals from the tfvars (per-env vm configs).
const envTotals = (v) => v.envs.reduce((a, e) => {
  e.vms.forEach((vm) => {
    a.cpu += Number(vm.cpu) || 0;
    a.mem += (vm.memory_mb || 0) / 1024;
    a.disk += Number(vm.disk_gb) || 0;
  });
  return a;
}, { cpu: 0, mem: 0, disk: 0 });

// Module-level cache so re-entering the view (remount) restores the last data
// instantly — no full-page "querying vCenters…"/blank on every nav. Background
// refresh then updates it in place (stale-while-revalidate). Also persisted to
// sessionStorage so a browser reload (F5) shows the last data immediately.
const CACHE_KEY = "vmp_mon_cache";
const readCache = () => { try { return JSON.parse(sessionStorage.getItem(CACHE_KEY)) || {}; } catch { return {}; } };
const writeCache = (c) => { try { sessionStorage.setItem(CACHE_KEY, JSON.stringify(c)); } catch { /* quota/private-mode: ignore */ } };
const cardCache = readCache();

export default function Monitor({ onOpen, onConsole, focus, onJob }) {
  const cachedVcs = Object.keys(cardCache);
  const [vcs, setVcs] = useState(cachedVcs.length ? cachedVcs : null);
  const [cards, setCards] = useState(() => {
    const init = {};
    for (const vc of Object.keys(cardCache)) init[vc] = { state: "ok", data: cardCache[vc], refreshing: false, error: "" };
    return init;
  });    // vc -> {state:'load'|'ok'|'err', data?}
  const [error, setError] = useState("");
  const [filter, setFilter] = useState("all"); // all | on | off | pending | deployed
  const vcsRef = useRef(vcs);
  vcsRef.current = vcs;

  // stale-while-revalidate: keep the last good card rendered during background
  // refresh so Monitor never blanks to "loading…" on the 30s sync.
  const loadOne = (vc) => {
    setCards((c) => {
      const prev = c[vc];
      return prev && prev.data
        ? { ...c, [vc]: { ...prev, refreshing: true } }
        : { ...c, [vc]: { state: "load" } };
    });
    getMonitorVc(vc)
      .then((r) => {
        if (r && r.error) { setCards((c) => patchErr(c, vc, r.error)); return; }
        cardCache[vc] = r;
        writeCache(cardCache);
        setCards((c) => ({ ...c, [vc]: { state: "ok", data: r, refreshing: false, error: "" } }));
      })
      .catch((e) => setCards((c) => patchErr(c, vc, e.message)));
  };

  const loadAll = () => (vcsRef.current || []).forEach(loadOne);
  const loadNamed = (names) => (names || []).forEach(loadOne);

  const syncing = Object.keys(cards).some((vc) => cards[vc] && cards[vc].refreshing);

  useEffect(() => {
    let alive = true;
    listMonitorVcs().then((names) => {
      if (!alive) return;
      setVcs(names);
      loadNamed(names);                     // fire all requests in parallel
    }).catch((e) => setError(e.message));
    const id = setInterval(() => { if (alive) loadAll(); }, 30000);
    return () => { alive = false; clearInterval(id); };
  }, []);

  // Deep-link to a vCenter (datastore alert): scroll that vCenter card into
  // view. Re-runs when the vCenter list arrives so a late-loaded card still
  // lands correctly.
  useEffect(() => {
    if (focus && focus.vc && !focus.host && !focus.vm && focus.ts) {
      const el = document.querySelector(`[data-vccard="${CSS.escape(focus.vc)}"]`);
      if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [focus && focus.ts, vcs.length]);

  return html`
    <div className="page">
      <div className="page-head"><h2>Inventory</h2>
        <div className="row" style=${{ gap: 8 }}>
          ${syncing && html`<span className="muted"><${Spinner} inline /> syncing…</span>`}
          <button className="ghost" onClick=${() => loadAll()} data-tip="Refresh all vCenters now">Refresh</button>
        </div>
      </div>

      ${error && html`<p className="error">${error}</p>`}
      ${!vcs && html`<p className="muted"><${Spinner} inline /> querying vCenters…</p>`}
      ${vcs && vcs.length === 0 && html`<p className="muted">No vCenters configured. Add one to begin.</p>`}
      ${(vcs || []).map((vc) => html`
        <${VcCard} key=${vc} vc=${vc} st=${cards[vc]} onOpen=${onOpen} onConsole=${onConsole} onJob=${onJob} loadOne=${loadOne} filter=${filter} setFilter=${setFilter} focus=${focus && focus.vc === vc ? focus : null} />
      `)}
    </div>`;
}

// On background-refresh failure keep the last good data instead of blanking.
const patchErr = (c, vc, msg) => {
  const prev = c[vc];
  return prev && prev.data
    ? { ...c, [vc]: { ...prev, refreshing: false, error: msg } }
    : { ...c, [vc]: { state: "err", error: msg } };
};

function VcCard({ vc, st, onOpen, onConsole, onJob, loadOne, filter, setFilter, focus }) {
  const [infraOpen, setInfraOpen] = useState(false);
  const [vmsOpen, setVmsOpen] = useState(true);
  const [powerBusy, setPowerBusy] = useState("");   // vm-name while a govc power call runs
  const [sortKey, setSortKey] = useState("name");   // name|ip|cpu|mem|disk|power
  const [sortDir, setSortDir] = useState(1);        // 1 asc | -1 desc
  const [hlHost, setHlHost] = useState("");         // host row highlighted after a deep-link

  // Deep-link from a Host resource alert: open the Infrastructure section and
  // scroll to + flash the focused host row. Re-runs when host data arrives so a
  // late-loaded card still lands on the right row.
  useEffect(() => {
    if (focus && focus.host && focus.ts) {
      setInfraOpen(true);
      setHlHost(focus.host);
      const t = setTimeout(() => setHlHost(""), 4000);
      const el = document.querySelector(`[data-hostrow="${CSS.escape(focus.host)}"]`);
      if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
      return () => clearTimeout(t);
    }
  }, [focus && focus.ts, focus && focus.host]);

  // Power a deployed VM on/off via govc, then refresh this card so the live
  // snapshot (power/CPU/RAM) reflects the new state.
  const powerVm = async (vm, action) => {
    if (powerBusy) return;
    setPowerBusy(vm.name);
    try {
      await setVmPower(v.vcenter, vm.name, action);
      loadOne(vc);
    } catch (e) { /* transient; next refresh shows real state */ }
    finally { setPowerBusy(""); }
  };

  if (!st || st.state === "load") {
    return html`<div className="card vc-block" key=${vc}>
      <h3>🖥 ${vc}</h3><p className="muted"><${Spinner} inline /> loading…</p></div>`;
  }
  if (st.state === "err") {
    return html`<div className="card vc-block" key=${vc}>
      <h3>🖥 ${vc}</h3><p className="error">${st.error || "failed to load"}</p>
      <button className="ghost" onClick=${() => loadOne(vc)}>Retry</button></div>`;
  }
  const v = st.data && st.data.vcenter;
  if (!v) return "";
  const syncing = st.refreshing;
  const t = envTotals(v);
  const dcName = (v.inventory && v.inventory.datacenter) || "—";
  const hosts = v.hosts || [];
  const datastores = v.datastores || [];
  const hostCpuMax = Math.max(1, ...hosts.map((h) => (h.cpuCores || 0) * (h.cpuMhz || 0)));
  const hostMemMax = Math.max(1, ...hosts.map((h) => (h.memoryMB || 0)));
  const totalDs = datastores.reduce((a, d) => a + ((d.capacity || 0) - (d.free || 0)), 0);
  const totalDsCap = datastores.reduce((a, d) => a + (d.capacity || 0), 0);

  // Datacenter-level capacity (physical hosts/datastores) + aggregate utilization
  // via the shared trends helper; feeds the small header donuts.
  const cap = dcCapItems(v);
  const dcCapItemsArr = cap.items;
  const noLive = cap.noLive;

  const vmsCpuMax = Math.max(1, ...v.envs.flatMap((e) => e.vms).map((vm) => Number(vm.cpu) || 0));
  const vmsMemMax = Math.max(1, ...v.envs.flatMap((e) => e.vms).map((vm) => (vm.memory_mb || 0) / 1024));
  const allVms = v.envs.flatMap((e) => e.vms);
  const vmSummary = {
    envs: v.envs.length,
    total: allVms.length,
    on: allVms.filter((m) => m.power === "poweredOn").length,
    off: allVms.filter((m) => m.power === "poweredOff").length,
    pending: allVms.filter((m) => m.power === "notDeployed" || m.power === "unknown" || m.power === "pending").length
  };

  return html`
    <div className="card vc-block" data-vccard=${vc} key=${vc}>
      <h3 className="clickable" data-tip="Open this vCenter's config inventory" onClick=${() => onOpen({ vc: v.vcenter, env: "", file: "" })}>
        🖥 ${v.vcenter}
        ${syncing && html`<span className="muted"> · <${Spinner} inline /></span>`}
        ${!v.live_ok && html`<span className="muted"> · ⚠ ${v.live_error || "no live data"}</span>`}
        <span className="muted"> · ${dcName} · ${v.summary.vm_count} VMs · ${v.summary.powered_on} on ·
          ${hosts.length} hosts · ${datastores.length} datastores</span>
      </h3>

      <div className="vc-body">
      <div className="vc-main">
      <div className="vc-capacity">
        <${CapBars} items=${dcCapItems} />
        <p className="muted vc-cap-note" title="Configured totals from the VM configs (tfvars) — the datacenter header now shows physical host/datastore capacity + live utilization">
          allocated to VMs: ${t.cpu} vCPU · ${Math.round(t.mem)} GB · ${Math.round(t.disk)} GB
          ${noLive ? " · no live host/datastore data" : ""}
        </p>
      </div>

      <div className="mon-sec">
        <div className="mon-sec-head" onClick=${() => setInfraOpen(!infraOpen)} data-tip="Toggle infrastructure details (hosts + datastores)">
          <span className="mon-sec-chev ${infraOpen ? "open" : ""}">▸</span>
          <strong>Infrastructure</strong>
          <span className="muted">Hosts · Datastores</span>
          ${!infraOpen && html`<span className="mon-sec-summary">${hosts.length} hosts · ${datastores.length} datastores · ${totalDsCap ? pct(totalDs, totalDsCap) + "% disk used" : "no datastores"}</span>`}
        </div>
        ${infraOpen && html`
          ${hosts.length > 0 && html`
            <h4 className="sec-label">🏭 Hosts <span className="muted">· ${dcName}</span></h4>
            <div className="table-scroll">
            <table className="mini-table">
              <colgroup>
                <col style=${{ width: "16%" }} /><col style=${{ width: "12%" }} />
                <col style=${{ width: "10%" }} /><col style=${{ width: "11%" }} />
                <col style=${{ width: "8%" }} /><col style=${{ width: "11%" }} />
                <col style=${{ width: "7%" }} /><col style=${{ width: "8%" }} />
                <col style=${{ width: "8%" }} /><col style=${{ width: "9%" }} />
              </colgroup>
              <thead>
                <tr><th>Host</th><th>IP</th><th>vCPU</th><th>CPU util</th><th>RAM</th><th>RAM util</th><th>Net</th><th>Disk IO</th><th>State</th><th>Datastores</th></tr>
              </thead>
              <tbody>
                ${hosts.map((h) => html`
                  <tr key=${h.name} data-hostrow=${h.name} className=${hlHost === h.name ? "hl-host" : ""}>
                    <td><strong>${h.name}</strong></td>
                    <td>${h.ip || "—"}</td>
                    <td>${h.cpuCores || 0} × ${h.cpuMhz || 0} MHz</td>
                    <td>${(h.cpuCores || 0) * (h.cpuMhz || 0) > 0
                      ? html`<${MiniBar} value=${pct(h.cpuUsageMHz, (h.cpuCores * h.cpuMhz))} max=${100} suffix="%" label="CPU" color=${pct(h.cpuUsageMHz, (h.cpuCores * h.cpuMhz)) > 85 ? "var(--danger)" : "var(--accent2)"} />`
                      : "—"}</td>
                    <td>${h.memoryMB ? (h.memoryMB / 1024).toFixed(0) + " GB" : "—"}</td>
                    <td>${h.memoryMB ? html`<${MiniBar} value=${pct(h.memUsageMB, h.memoryMB)} max=${100} suffix="%" label="RAM" color=${pct(h.memUsageMB, h.memoryMB) > 85 ? "var(--danger)" : "var(--accent)"} />` : "—"}</td>
                    <td>${h.netKBps ? h.netKBps + " KB/s" : "—"}</td>
                    <td>${h.diskKBps ? h.diskKBps + " KB/s" : "—"}</td>
                    <td>${(h.powerState && h.powerState !== "poweredOn") || (h.connectionState && h.connectionState !== "connected")
                      ? html`<${Pill} cls="crit">down</${Pill}>`
                      : h.overallStatus && h.overallStatus !== "green"
                        ? html`<${Pill} cls=${h.overallStatus === "red" ? "crit" : "warn"}>${h.overallStatus}</${Pill}>`
                        : html`<${Pill} cls="ok">up</${Pill}>`}</td>
                    <td>${(h.datastores || []).length}</td>
                  </tr>`)}
              </tbody>
            </table>
            </div>`}

          ${datastores.length > 0 && html`
            <h4 className="sec-label">💾 Datastores <span className="muted">· ${totalDsCap ? pct(totalDs, totalDsCap) + "% used" : ""}</span></h4>
            <div className="table-scroll">
            <table className="mini-table">
              <colgroup>
                <col style=${{ width: "38%" }} /><col style=${{ width: "18%" }} />
                <col style=${{ width: "18%" }} /><col style=${{ width: "26%" }} />
              </colgroup>
              <thead>
                <tr><th>Datastore</th><th>Capacity</th><th>Free</th><th>Used</th></tr>
              </thead>
              <tbody>
                ${datastores.map((d) => html`
                  <tr key=${d.name}>
                    <td><strong>${d.name}</strong></td>
                    <td>${(d.capacity / 1024 ** 4).toFixed(1)} TB</td>
                    <td>${(d.free / 1024 ** 4).toFixed(1)} TB</td>
                    <td><${MiniBar} value=${pct(d.capacity - d.free, d.capacity)} max=${100} suffix="%" label="used" color=${pct(d.capacity - d.free, d.capacity) > 85 ? "var(--danger)" : "var(--ok)"} /></td>
                  </tr>`)}
              </tbody>
            </table>
            </div>`}
          ${hosts.length === 0 && datastores.length === 0 && html`<p className="muted">No infrastructure data.</p>`}
        `}
      </div>

      <div className="mon-sec">
        <div className="mon-sec-head" onClick=${() => setVmsOpen(!vmsOpen)} data-tip="Toggle VM environments (per-env VM tables)">
          <span className="mon-sec-chev ${vmsOpen ? "open" : ""}">▸</span>
          <strong>VM Environments</strong>
          <span className="muted">${vmSummary.total} VMs</span>
          ${!vmsOpen && html`<span className="mon-sec-summary"><${Pill} cls="ok">${vmSummary.on} on</${Pill}> <${Pill} cls="off">${vmSummary.off} off</${Pill}> <${Pill} cls="pending">${vmSummary.pending} pending</${Pill}> · ${vmSummary.envs} env(s)</span>`}
        </div>
        ${vmsOpen && html`
          <div className="mon-filter" style=${{ gap: 6, flexWrap: "wrap", padding: "8px 10px 2px" }}>
            ${[
              { id: "all", label: "All VMs" },
              { id: "on", label: "Powered on" },
              { id: "off", label: "Powered off" },
              { id: "pending", label: "Not deployed" },
              { id: "deployed", label: "Deployed" }
            ].map((f) => html`
              <button key=${f.id} className=${filter === f.id ? "chip active" : "chip"} data-tip=${f.label === "All VMs" ? "Show every VM" : f.label === "Powered on" ? "Show only running VMs" : f.label === "Powered off" ? "Show only powered-off VMs" : f.label === "Not deployed" ? "Show VMs not yet deployed" : "Show deployed VMs (on or off)"} onClick=${() => setFilter(f.id)}>${f.label}</button>`)}
          </div>
          ${v.envs.map((e) => {
            const match = (vm) => filter === "all" ? true
              : filter === "on" ? vm.power === "poweredOn"
              : filter === "off" ? vm.power === "poweredOff"
              : filter === "pending" ? (vm.power === "notDeployed" || vm.power === "unknown" || vm.power === "pending")
              : vm.power !== "notDeployed" && vm.power !== "unknown" && vm.power !== "pending"; // deployed
            const vms = (e.vms || []).filter(match).slice().sort((a, b) => {
              let av, bv;
              if (sortKey === "ip") { av = a.ip || ""; bv = b.ip || ""; }
              else if (sortKey === "cpu") { av = Number(a.cpu) || 0; bv = Number(b.cpu) || 0; }
              else if (sortKey === "mem") { av = Number(a.memory_mb) || 0; bv = Number(b.memory_mb) || 0; }
              else if (sortKey === "disk") { av = Number(a.total_disk_gb) || Number(a.disk_gb) || 0; bv = Number(b.total_disk_gb) || Number(b.disk_gb) || 0; }
              else if (sortKey === "osdisk") { av = Number(a.disk_gb) || 0; bv = Number(b.disk_gb) || 0; }
              else if (sortKey === "datadisk") { av = (a.data_disk_gb || []).reduce((s, x) => s + x, 0) || 0; bv = (b.data_disk_gb || []).reduce((s, x) => s + x, 0) || 0; }
              else if (sortKey === "power") { const rank = (p) => p === "poweredOn" ? 0 : p === "poweredOff" ? 1 : 2; av = rank(a.power); bv = rank(b.power); }
              else { av = (a.name || "").toLowerCase(); bv = (b.name || "").toLowerCase(); }
              return av < bv ? -sortDir : av > bv ? sortDir : 0;
            });
            const toggleSort = (k) => {
              if (sortKey === k) setSortDir((d) => -d);
              else { setSortKey(k); setSortDir(1); }
            };
            const thBtn = (k, label) => html`<th><button className="th-sort ${sortKey === k ? "active" : ""}" data-tip=${"Sort by " + label} onClick=${() => toggleSort(k)}>${label} ${sortKey === k ? (sortDir === 1 ? "▲" : "▼") : ""}</button></th>`;
            const eOn = (e.vms || []).filter((m) => m.power === "poweredOn").length;
            const eOff = (e.vms || []).filter((m) => m.power === "poweredOff").length;
            const ePend = (e.vms || []).length - eOn - eOff;
            return html`
            <div className="env-block" key=${e.env}>
              <div className="env-label">
                <span className="env-title"><${Pill} cls="env">${e.env}</${Pill}><span className="muted">${e.vms.length} VM(s)</span></span>
                <span className="env-summary"><${Pill} cls="ok">${eOn} on</${Pill}> <${Pill} cls="off">${eOff} off</${Pill}> <${Pill} cls="pending">${ePend} pending</${Pill}></span>
              </div>
              ${vms.length === 0 ? html`<p className="muted" style=${{ padding: "6px 0" }}>No VMs match the current filter.</p>` : html`
              <div className="table-scroll">
              <table className="mini-table">
                <colgroup>
                  <col style=${{ width: "3%" }} /><col style=${{ width: "16%" }} />
                  <col style=${{ width: "12%" }} /><col style=${{ width: "8%" }} />
                  <col style=${{ width: "8%" }} /><col style=${{ width: "13%" }} />
                  <col style=${{ width: "13%" }} /><col style=${{ width: "27%" }} />
                </colgroup>
                <thead>
                  <tr><th></th>${thBtn("name", "VM")}${thBtn("ip", "IP")}${thBtn("cpu", "vCPU")}${thBtn("mem", "RAM")}${thBtn("osdisk", "OS Disk")}${thBtn("datadisk", "Data Disk")}${thBtn("power", "Power")}</tr>
                </thead>
                <tbody>
                  ${vms.map((vm) => html`<${VmRow} key=${vm.file} vm=${vm} vc=${v.vcenter} env=${e.env} onOpen=${onOpen} onConsole=${onConsole} onJob=${onJob} vmsCpuMax=${vmsCpuMax} vmsMemMax=${vmsMemMax} powerBusy=${powerBusy} onPower=${powerVm} focus=${focus && focus.vm === vm.name ? focus : null} />`)}
                  ${vms.length === 0 && html`<tr><td colSpan="7" className="muted">No VM configs in this environment yet.</td></tr>`}
                </tbody>
              </table>
              </div>`}
            </div>`;
          })}
        `}
      </div>
      </div>
      <aside className="vc-side">
        <${DcTrends} vc=${v.vcenter} />
      </aside>
      </div>
    </div>`;
}

// Right-side Grafana-style trend rail for a vCenter card. One batch call
// (getDcTrends) returns per-entity series for host CPU/RAM/Net/Disk IO +
// datastore used%; each panel = a TrendChart with one line per host/datastore.
// SWR: the last good series stays visible on a failed refresh (never blanks);
// a failed first load shows an error + Retry. 6h/24h/72h windows (server keeps
// 72h of samples). Per-panel empty → TrendChart's "— no trend data yet".
function DcTrends({ vc }) {
  const [hours, setHours] = useState(24);
  const [data, setData] = useState(null);
  const [err, setErr] = useState("");
  const [refreshing, setRefreshing] = useState(false);

  const load = () => {
    getDcTrends(vc, hours)
      .then((r) => { if (r && r.series) { setData(r.series); setErr(""); } })
      .catch((e) => setErr(e.message || "trends failed"))
      .finally(() => setRefreshing(false));
  };

  useEffect(() => {
    setData(null); setErr(""); setRefreshing(true);
    load();
    const id = setInterval(load, 30000);
    return () => clearInterval(id);
  }, [vc, hours]);

  const s = data || {};
  const seriesOf = (kind, labelKey) => Object.entries(s[kind] || {}).map(([entity, pts], i) => ({
    key: labelKey,                       // "net"/"diskio" → formatTrend shows KB/s
    label: entity,
    color: RAIL_COLORS[i % RAIL_COLORS.length],
    points: downSample(pts, 240),
    unit: kind === "host_net" || kind === "host_disk" ? "KB/s" : "pct"
  }));
  const hasAny = ["host_cpu", "host_mem", "host_net", "host_disk", "ds_used"]
    .some((k) => (s[k] && Object.keys(s[k]).length > 0));

  return html`
    <div className="dc-rail">
      <div className="dc-rail-head">
        <strong>📈 Trends</strong>
        <div className="dc-range">
          ${[6, 24, 72].map((h) => html`
            <button key=${h} className=${hours === h ? "chip active" : "chip"} data-tip=${`Show the last ${h}h of samples`} onClick=${() => setHours(h)}>${h}h</button>`)}
        </div>
      </div>
      ${refreshing && !data && !err ? html`<p className="muted"><${Spinner} inline /> loading trends…</p>`
        : err && !data ? html`<div className="error">${err} <button className="ghost" onClick=${load}>Retry</button></div>`
        : !hasAny ? html`<p className="muted">no trend samples yet — they accumulate on every snapshot poll</p>`
        : html`
          <${RailPanel} title="CPU — hosts"><${TrendChart} series=${seriesOf("host_cpu", "cpu")} width=${360} height=${110} timeLabel=${hours + "h"} /></${RailPanel}>
          <${RailPanel} title="Memory — hosts"><${TrendChart} series=${seriesOf("host_mem", "mem")} width=${360} height=${110} timeLabel=${hours + "h"} /></${RailPanel}>
          <${RailPanel} title="Datastore used"><${TrendChart} series=${seriesOf("ds_used", "ds")} width=${360} height=${110} timeLabel=${hours + "h"} /></${RailPanel}>
          <${RailPanel} title="Network I/O — hosts"><${TrendChart} series=${seriesOf("host_net", "net")} width=${360} height=${110} timeLabel=${hours + "h"} /></${RailPanel}>
          <${RailPanel} title="Disk I/O — hosts"><${TrendChart} series=${seriesOf("host_disk", "diskio")} width=${360} height=${110} timeLabel=${hours + "h"} /></${RailPanel}>
        `}
    </div>`;
}

function RailPanel({ title, children }) {
  return html`<div className="dc-panel"><div className="dc-panel-title">${title}</div>${children}</div>`;
}

// Evenly downsample to ≤ n points (keeps the window span, trims render cost).
const downSample = (pts, n) => {
  if (!Array.isArray(pts) || pts.length <= n) return pts || [];
  const step = pts.length / n;
  return pts.filter((_, i) => Math.floor(i / step) !== Math.floor((i + 1) / step) || i === pts.length - 1);
};
const RAIL_COLORS = ["#22d3ee", "#2563eb", "#4ade80", "#fbbf24", "#f87171", "#a78bfa", "#34d399", "#f472b6", "#60a5fa", "#facc15"];

// Power menu for a powered-on VM. Rendered position:fixed so it escapes the
// overflow:hidden table/card ancestors (a relative/absolute menu gets clipped).
// Fixed position is viewport-relative and NOT clipped unless an ancestor has a
// transform/filter — none do here. Opens on hover of the `on` pill.
function PowerMenu({ vm, onPower, powerBusy }) {
  const [pos, setPos] = useState(null);       // {left, top} or null = closed
  const ref = useRef(null);
  const closeTimer = useRef(null);

  const open = () => {
    clearTimeout(closeTimer.current);
    const r = ref.current && ref.current.getBoundingClientRect();
    if (!r) return;
    setPos({ left: Math.min(r.left, window.innerWidth - 160), top: r.bottom + 6 });
  };
  const closeSoon = () => {
    clearTimeout(closeTimer.current);
    closeTimer.current = setTimeout(() => setPos(null), 180);
  };
  const pick = (a) => {
    setPos(null);
    if (onPower) onPower(vm, a);
  };

  return html`
    <span className="pow-wrap" ref=${ref}
      onMouseEnter=${open}
      onMouseLeave=${closeSoon}
      onFocus=${open} onBlur=${closeSoon}>
      <span className="pill ok" data-tip="Powered on — hover for power actions">on ▾</span>
      ${pos && html`<div className="pow-menu" style=${{ left: pos.left + "px", top: pos.top + "px" }}
        onMouseEnter=${() => clearTimeout(closeTimer.current)} onMouseLeave=${closeSoon}>
        <button className="pow-act restart" disabled=${powerBusy === vm.name} data-tip="Reboot the OS (graceful)" onClick=${() => pick("reset")}>Restart</button>
        <button className="pow-act shutdown" disabled=${powerBusy === vm.name} data-tip="Guest OS graceful shutdown" onClick=${() => pick("shutdown")}>Graceful shutdown</button>
        <button className="pow-act off" disabled=${powerBusy === vm.name} data-tip="Power off the VM" onClick=${() => pick("off")}>Power off</button>
        <button className="pow-act force" disabled=${powerBusy === vm.name} data-tip="Hard power off (may lose data)" onClick=${() => pick("forceoff")}>Force power off</button>
      </div>`}
    </span>`;
}

// One VM row in the Monitor table: a ▸ chevron expands an inline utilization
// panel (24h CPU/RAM sparklines + recent events for that VM). Row click opens
// the VM config; the Console button opens an SSH console (project key).
function VmRow({ vm, vc, env, onOpen, onConsole, onJob, vmsCpuMax, vmsMemMax, powerBusy, onPower, focus }) {
  const [open, setOpen] = useState(false);
  const [trends, setTrends] = useState(null);
  const [vmEvents, setVmEvents] = useState(null);
  const [vmTasks, setVmTasks] = useState(null);
  const [sessions, setSessions] = useState(null);
  const [guest, setGuest] = useState(null);
  const [guestErr, setGuestErr] = useState("");
  const [expandDsk, setExpandDsk] = useState("");    // name of the disk being expanded
  const [expandMount, setExpandMount] = useState("/"); // target mount point (LV/partition)
  const [expandSize, setExpandSize] = useState(0);   // new size in GB
  const [expandBusy, setExpandBusy] = useState(false);
  const [expandErr, setExpandErr] = useState("");
  const [expandJobs, setExpandJobs] = useState({});   // disk name -> job (status chip per disk)
  const [pipJob, setPipJob] = useState(null);          // job shown in the Disk Resize execute card

  // Keep the per-disk status chip LIVE: the job object captured at creation is a
  // snapshot (status "queued") — subscribe to the same /jobs socket JobThread
  // uses so queued → running → success/failed propagates to the chip. On
  // success, re-probe the guest so the disk card shows the new grown size.
  useEffect(() => {
    const active = Object.values(expandJobs).some((j) => j.status === "queued" || j.status === "running");
    if (!active || !vm.ip) return;
    const socket = window.io("/jobs");
    const onStatus = ({ jobId, status, exit_code }) => {
      setExpandJobs((cur) => {
        const hit = Object.entries(cur).find(([, j]) => j.id === jobId);
        if (!hit) return cur;
        const [dname, job] = hit;
        if (status === "success") {
          // Done → re-probe guest (shows the grown size) and CLEAR the chip so
          // the disk card returns to the partition tree (not stuck on "done").
          getGuestData({ ip: vm.ip }).then((r) => {
            if (r && r.ok) { setGuest(r); setGuestErr(""); }
            else if (r && r.error) setGuestErr(r.error);
          }).catch(() => setGuestErr("guest probe failed"));
          const next = { ...cur };
          delete next[dname];
          return next;
        }
        return { ...cur, [dname]: { ...job, status, exit_code } };
      });
    };
    socket.on("job:status", onStatus);
    return () => socket.disconnect();
  }, [expandJobs, vm.ip]);

  // Deep-link: a new focus for THIS vm auto-expands the row and scrolls to it.
  useEffect(() => {
    if (focus && focus.ts) {
      setOpen(true);
      const el = document.querySelector(`[data-vmrow="${CSS.escape(vm.file || vm.name)}"]`);
      if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [focus && focus.ts]);
  const poweredOn = vm.power === "poweredOn";
  const poweredOff = vm.power === "poweredOff";

  useEffect(() => {
    if (!open) return;
    let alive = true;
    setTrends(null); setVmEvents(null); setVmTasks(null); setSessions(null); setGuest(null); setGuestErr("");
    const loadAllDetail = () => {
      const kinds = ["cpu", "mem", "diskio", "net"];
      kinds.forEach((k) => {
        getTrends(vc, `vm_${k}`, vm.name, 24).then((t) => { if (alive) setTrends((p) => ({ ...(p || {}), [k]: t })); }).catch(() => {});
      });
      getEvents({ vc, vm: vm.ip || vm.name, limit: 10 }).then((l) => { if (alive) setVmEvents(l); }).catch(() => {});
      getTasks({ vc, vm: vm.name, limit: 10 }).then((l) => { if (alive) setVmTasks(l); }).catch(() => {});
      getConsoleSessions().then((r) => { if (alive) setSessions((r && r.sessions) || []); }).catch(() => {});
      if (vm.ip) getGuestData({ ip: vm.ip }).then((r) => {
        if (!alive) return;
        if (r && r.ok) { setGuest(r); setGuestErr(""); }
        else if (r && r.error) setGuestErr(r.error);
      }).catch(() => { if (alive) setGuestErr("guest probe failed"); });
    };
    loadAllDetail();
    const id = setInterval(loadAllDetail, 30000);   // keep the expanded detail live
    return () => { alive = false; clearInterval(id); };
  }, [open, vc, vm.name]);

  // Fetch per-physical-disk usage trends (auto line per disk) once guest data loads.
  useEffect(() => {
    if (!open || !guest || !guest.data || !guest.data.disks) return;
    let alive = true;
    for (const dsk of guest.data.disks) {
      getTrends(vc, "vm_diskmount", `${vm.name}::${dsk.name}`, 24).then((t) => {
        if (alive) setTrends((p) => ({ ...(p || {}), ["disk:" + dsk.name]: t }));
      }).catch(() => {});
    }
    return () => { alive = false; };
  }, [open, guest, vc, vm.name]);

  // Expand a disk/mount live: grow VMDK + guest FS + tfvars via the expand job.
  // The live console renders INLINE in the disk card (no page navigation);
  // the job is also pushed to the Shell thread so it stays tracked.
  const doExpand = async (dsk) => {
    if (expandBusy || !vm.ip) return;
    const gb = Number(expandSize);
    if (!(gb > 0) || Number.isNaN(gb)) { setExpandErr("enter a valid size in GB"); return; }
    setExpandBusy(true);
    setExpandErr("");
    try {
      const job = await createJob({
        action: "expand",
        vcenter: vc, env, vm_name: vm.name, ip: vm.ip,
        new_size_gb: gb, mount: expandMount, ssh_user: ""
      });
      setExpandJobs((j) => ({ ...j, [dsk.name]: job }));  // status chip in this disk card
      setPipJob(job);                 // auto-open the Disk Resize execute card (floating, wide)
      if (onJob) onJob(job);          // push to Shell thread (tracked), no navigation
      setExpandDsk("");
      setExpandSize(0);
    } catch (e) {
      setExpandErr((e && e.message) || "expand failed");
    } finally {
      setExpandBusy(false);
    }
  };

  const cpuPct = poweredOn && vm.cpuUsageMHz ? Math.min(100, Math.round((vm.cpuUsageMHz / ((vm.cpu || 1) * 2000)) * 100)) : null;
  const memPct = poweredOn && vm.memUsageMB ? Math.min(100, Math.round((vm.memUsageMB / (vm.memory_mb || 1)) * 100)) : null;
  const pts = (k) => (trends && trends[k] && trends[k].points) || [];
  const diskTrends = (name) => (trends && trends["disk:" + name] && trends["disk:" + name].points) || [];
  const gd = guest && guest.data ? guest.data : null;
  const guestDisks = gd ? (gd.disks || []) : [];
  const trendSeries = [
    { key: "cpu", label: "CPU", color: "var(--accent2)", points: pts("cpu") },
    { key: "mem", label: "RAM", color: "var(--accent)", points: pts("mem") },
    { key: "diskio", label: "Disk I/O", color: "var(--ok)", points: pts("diskio"), unit: "KB/s" },
    { key: "net", label: "Net", color: "var(--warn)", points: pts("net"), unit: "KB/s" },
    ...guestDisks.map((d) => ({
      key: "disk:" + d.name,
      label: d.name,
      color: "#a78bfa",
      points: diskTrends(d.name),
      unit: "pct"
    }))
  ];
  const diskCapGb = vm.total_disk_gb ? Number(vm.total_disk_gb) : (vm.disk_gb ? Number(vm.disk_gb) : 0);
  const diskUsedGb = vm.live && vm.live.diskUsedGB ? Math.round(vm.live.diskUsedGB) : null;
  const diskPct = diskUsedGb !== null && diskCapGb > 0 ? Math.min(100, Math.round((diskUsedGb / diskCapGb) * 100)) : null;
  const diskLabel = diskCapGb ? (diskPct !== null ? `${diskUsedGb}/${diskCapGb} GB (${diskPct}%)` : `${diskCapGb} GB`) : "—";
  const diskParts = [];
  if (vm.disk_gb) diskParts.push(`OS ${vm.disk_gb}G`);
  (vm.data_disk_gb || []).forEach((s, i) => diskParts.push(`Data${(vm.data_disk_gb || []).length > 1 ? i + 1 : ""} ${s}G`));
  const diskDetail = diskParts.length ? diskParts.join(" + ") : "";
  const rootMount = (gd && gd.disk || []).find((d) => d.mount === "/");
  const gMem = gd && gd.mem;
  const guestOnline = (gd && gd.who || []).map((w) => w.user);
  const fmtGb = (mb) => mb >= 1024 ? (mb / 1024).toFixed(1) + "G" : Math.round(mb) + "M";
  const fmtBytes = (b) => {
    const n = Number(b) || 0;
    if (n >= 1024 ** 3) return (n / 1024 ** 3).toFixed(1).replace(/\.0$/, "") + "G";
    if (n >= 1024 ** 2) return Math.round(n / 1024 ** 2) + "M";
    if (n >= 1024) return Math.round(n / 1024) + "K";
    return Math.round(n) + "B";
  };
  // Aggregate fs used/size across a disk's fs leaves — for the disk header label.
  const fmtUptime = (hhmmss) => {
    if (!hhmmss) return "—";
    const [h, m, s] = hhmmss.split(":").map(Number);
    const d = Math.floor(h / 24), rh = h % 24;
    const parts = [];
    if (d) parts.push(d + "d");
    if (rh) parts.push(rh + "h");
    if (!d) parts.push((m || 0) + "m");
    return parts.join(" ");
  };
  const fmtDate = (raw) => {
    if (!raw) return "—";
    const m = raw.match(/^(\d{4}-\d{2}-\d{2})/);
    if (m) return m[1];
    return String(raw).slice(0, 10);
  };
  const configMeta = [
    `Disk: ${diskParts.length ? diskParts.join(" + ") : "—"}`,
    `Used: ${diskLabel}`,
    `OS parts: ${vm.os_partitions || "—"}`,
    `LVM vols: ${vm.lvm_volumes || "—"}`,
    vm.extra_users ? `Users: ${vm.extra_users}` : "Users: —",
    `node_exporter: ${vm.enable_node_exporter ? "on" : "off"}`
  ].join("  ·  ");

  return html`
    ${html`<tr className="clickable" data-vmrow=${vm.file || vm.name} onClick=${() => setOpen(!open)} title=${open ? "Click to collapse" : "Click to expand details (24h trends + events)"}>
      <td><span className="vm-chevron ${open ? "open" : ""}" data-tip=${open ? "Hide VM detail" : "Show 24h CPU/RAM trends + events"} onClick=${(ev) => { ev.stopPropagation(); setOpen(!open); }}>▸</span></td>
      <td title=${vm.name}>
        ${vm.name}
        ${poweredOn && vm.live && vm.live.toolsStatus && vm.live.toolsStatus !== "toolsOk" ? html`<span className="muted" title="VMware Tools ${vm.live.toolsStatus}">⚠</span>` : ""}
      </td>
      <td title=${vm.ip || ""}>${vm.ip || "—"}</td>
      <td>
        ${vm.cpu !== undefined ? html`
          <span className="cell-cap" data-tip="Configured vCPU: ${vm.cpu} · live usage ${cpuPct === null ? "—" : cpuPct + "%"}">
            ${vm.cpu}c${cpuPct !== null ? html` <span className="muted" style=${{ fontSize: 11, color: cpuPct > 85 ? "var(--danger)" : "var(--muted)" }}>(${cpuPct}%)</span>` : ""}
          </span>` : "—"}
      </td>
      <td>
        ${vm.memory_mb ? html`
          <span className="cell-cap" data-tip="Configured RAM: ${Math.round(vm.memory_mb / 1024)}G · live usage ${memPct === null ? "—" : memPct + "%"}">
            ${Math.round(vm.memory_mb / 1024)}G${memPct !== null ? html` <span className="muted" style=${{ fontSize: 11, color: memPct > 85 ? "var(--danger)" : "var(--muted)" }}>(${memPct}%)</span>` : ""}
          </span>` : "—"}
      </td>
      <td title=${vm.disk_gb ? "OS disk: " + vm.disk_gb + "G" : ""}>${vm.disk_gb ? html`
          <span className="cell-cap" data-tip=${diskPct !== null ? "Total disk used: " + diskLabel : ""}>
            ${vm.disk_gb}G${diskPct !== null ? html` <span className="muted" style=${{ fontSize: 11, color: diskPct > 85 ? "var(--danger)" : "var(--muted)" }}>(${diskPct}%)</span>` : ""}
          </span>` : "—"}</td>
      <td title=${vm.data_disk_gb && vm.data_disk_gb.length ? "Data disk(s): " + vm.data_disk_gb.join(" + ") + "G" : "No data disk"}>${vm.data_disk_gb && vm.data_disk_gb.length ? html`
          <span className="cell-cap" data-tip=${diskPct !== null ? "Total disk used: " + diskLabel : ""}>${vm.data_disk_gb.map((s) => s + "G").join(" + ")}</span>` : "—"}</td>
      <td>
        <div className="pow-cell">
          ${poweredOn ? html`
            <${PowerMenu} vm=${vm} onPower=${onPower} powerBusy=${powerBusy} />
            ${powerBusy === vm.name && html`<span className="muted"><${Spinner} inline /></span>`}
          ` : poweredOff ? html`
            <button className="pill off pill-btn" disabled=${powerBusy === vm.name} data-tip="Powered off — click to power on"
              onClick=${(ev) => { ev.stopPropagation(); onPower(vm, "on"); }}>off</button>
          ` : html`<span className="pill pending" data-tip="Not deployed yet">pending</span>`}
          ${poweredOn && vm.ip && onConsole ? html`<button className="icon-btn" data-tip="Open SSH console" onClick=${(ev) => { ev.stopPropagation(); onConsole({ ...vm, vc }); }}>🖥</button>` : ""}
        </div>
      </td>
    </tr>`}
    ${open && html`
    <tr className="vm-detail-row">
      <td colSpan="8" style=${{ padding: 0, background: "transparent" }}>
        <div className="vm-detail">
          <p className="vm-meta" title=${configMeta}>${configMeta}</p>
          ${gd && gd.services_failed && gd.services_failed.length ? html`
            <div className="guest-alert danger" data-tip=${gd.services_failed.map((s) => s.name).join(", ")}>
              <span className="guest-alert-ico">⛔</span>
              <span><b>${gd.services_failed.length}</b> failed service(s): ${gd.services_failed.map((s) => s.name).join(", ")}</span>
            </div>` : ""}
          ${rootMount && Number(rootMount.pct) > 85 ? html`
            <div className="guest-alert danger">
              <span className="guest-alert-ico">💾</span>
              <span><b>/</b> disk ${rootMount.pct}% full — used ${rootMount.used} of ${rootMount.size}, only ${rootMount.avail} free</span>
            </div>` : ""}
          <div className="guest-top">
            <div className="vm-card">
              <span className="vm-label">Current activity</span>
              ${!vmEvents ? html`<span className="muted" style=${{ fontSize: 11 }}>loading…</span>`
                : vmEvents.length === 0 && (!vmTasks || vmTasks.length === 0) && (!gd || !gd.audit || !gd.audit.length) ? html`<span className="muted" style=${{ fontSize: 11 }}>No recent activity.</span>`
                : html`<ul className="vm-events">
                  ${(gd && gd.audit || []).slice(0, 4).map((a, i) => html`<li key=${"a" + i} title=${a.ts + " · " + a.user + " " + a.action}>
                    <span>${a.action === "login" ? "🟢" : a.action === "logout" ? "🔴" : a.action === "sudo" ? "🛡" : "🔵"}</span>
                    <span className="vm-val">${a.user}</span> <span className="muted">${a.action}</span> <span className="muted">${a.ts ? new Date(a.ts).toLocaleTimeString() : ""}</span>
                  </li>`)}
                  ${vmEvents.slice(0, 5).map((e) => html`<li title=${(e.at ? new Date(e.at).toLocaleString() : "") + (e.value ? " — " + e.value : "")}>${e.kind === "console" ? "👤" : e.severity === "critical" ? "🔴" : e.severity === "warn" ? "🟠" : "🔵"} ${e.label}</li>`)}
                  ${vmTasks.slice(0, 5).map((t) => html`<li title=${(t.started_at ? new Date(t.started_at).toLocaleString() : "") + " · " + t.action}>${t.status === "running" ? "🟡" : t.status === "done" || t.status === "success" ? "✅" : t.status === "failed" ? "🔴" : "⚪"} ${t.action} <span className="muted">${t.status}</span></li>`)}
                </ul>`}
            </div>
            <div className="vm-card">
              <span className="vm-label">Usage trends — CPU · RAM · Disk I/O · Net</span>
              ${!trends ? html`<span className="muted" style=${{ fontSize: 11 }}>loading…</span>`
                : html`<${TrendChart} series=${trendSeries} width=${560} height=${130} />`}
            </div>
          </div>
          <div className="guest-grid">
            <div className="vm-card">
              <span className="vm-label">System</span>
              ${!guest ? html`<span className="muted" style=${{ fontSize: 11 }}>${guestErr ? "guest probe failed — VM offline?" : "loading…"}</span>`
                : html`<ul className="vm-list">
                  <li title="OS distribution"><span className="vm-k">OS</span><span className="vm-val">${gd.os_version || "—"}</span></li>
                  <li title="Kernel"><span className="vm-k">kernel</span><span className="vm-val">${gd.kernel || "—"}</span></li>
                  <li title="Last OS/package update (apt history)"><span className="vm-k">last upd</span><span className="vm-val">${fmtDate(gd.last_update)}</span></li>
                  <li title="Pending apt upgrades"><span className="vm-k">updates</span><span className=${(gd.pending_updates || 0) > 0 ? "vm-val" : "vm-val"}>${gd.pending_updates ? gd.pending_updates + " pending" : "up to date"}</span></li>
                  <li><span className="vm-k">uptime</span><span className="vm-val">${fmtUptime(gd.uptime)}</span></li>
                  <li><span className="vm-k">load</span><span className="vm-val">${(gd.load || []).join(" ")}</span></li>
                  <li><span className="vm-k">host</span><span className="vm-val">${gd.hostname || "—"}</span></li>
                  ${gMem ? html`<li><span className="vm-k">memory</span><span className=${gMem.pct > 85 ? "danger" : "vm-val"}>${gMem.pct}%</span><span className="muted"> ${fmtGb(gMem.used)}/${fmtGb(gMem.total)}</span></li>` : ""}
                  ${gd.swap && gd.swap.total ? html`<li><span className="vm-k">swap</span><span className=${gd.swap.pct > 50 ? "danger" : "vm-val"}>${gd.swap.pct}%</span><span className="muted"> ${fmtGb(gd.swap.used)}/${fmtGb(gd.swap.total)}</span></li>` : ""}
                  <li><span className="vm-k">net</span><span className="vm-val" title=${(gd.net_ifaces || []).map((n) => n.name + ": " + n.ip).join(" · ")}>${(gd.net_ifaces || []).map((n) => n.ip).join(" ").slice(0, 40)}</span></li>
                </ul>`}
            </div>
            <div className="vm-card">
              <span className="vm-label">Users (live)</span>
              ${!guest ? html`<span className="muted" style=${{ fontSize: 11 }}>${guestErr ? "guest probe failed" : "loading…"}</span>`
                : html`<ul className="vm-list">${(gd && gd.users || []).map((u) => {
                    const on = guestOnline.includes(u.name);
                    return html`<li title=${["uid " + u.uid, u.shell].filter(Boolean).join(" · ")}>
                      ${on ? html`<span className="live-dot" data-tip="Logged in now (who)"></span>` : html`<span className="live-dot-off"></span>`}
                      <span className="vm-val">${u.name}</span> <span className="muted">uid ${u.uid}</span>
                      ${on ? html`<span className="pill ok mini-pill">online</span>` : ""}
                    </li>`;})}</ul>`}
            </div>
            <div className="vm-card">
              <span className="vm-label">Top processes <span className="muted">· CPU</span></span>
              ${!guest ? html`<span className="muted" style=${{ fontSize: 11 }}>${guestErr ? "guest probe failed" : "loading…"}</span>`
                : (gd && gd.top_procs && gd.top_procs.length) ? html`<ul className="vm-list">
                    ${gd.top_procs.slice(0, 6).map((p) => html`<li key=${p.pid} title=${"pid " + p.pid + " · user " + p.user}>
                      <span className="vm-val" style=${{ overflow: "hidden", textOverflow: "ellipsis" }}>${p.comm}</span>
                      <span className="muted">${p.cpu}% CPU</span> <span className="muted">${p.mem}% MEM</span>
                    </li>`)}
                  </ul>` : html`<span className="muted" style=${{ fontSize: 11 }}>—</span>`}
            </div>
            <div className="vm-card">
              <span className="vm-label">Listening ports <span className="muted">· ${(gd && gd.ports || []).length}</span></span>
              ${!guest ? html`<span className="muted" style=${{ fontSize: 11 }}>${guestErr ? "guest probe failed" : "loading…"}</span>`
                : (gd && gd.ports && gd.ports.length) ? html`<div className="lsblk-tree">${gd.ports.map((p, i) => html`
                    <div className="lsblk-row" key=${i}><span className="lsblk-name">${p}</span></div>`)}
                  </div>` : html`<span className="muted" style=${{ fontSize: 11 }}>—</span>`}
            </div>
            ${(guestDisks || []).map((dsk) => {
              // Flatten the lsblk tree into indented rows with branch characters.
              const rows = [];
              const walk = (node, prefix, isLast, isRoot) => {
                rows.push({
                  name: node.name || "",
                  mount: node.mount,
                  pct: node.pct,
                  size: node.size,
                  fssize: node.fssize,
                  fsused: node.fsused,
                  prefix: isRoot ? "" : prefix + (isLast ? "└─ " : "├─ ")
                });
                const kids = node.children || [];
                const childPrefix = isRoot ? "" : prefix + (isLast ? "   " : "│  ");
                kids.forEach((k, i) => walk(k, childPrefix, i === kids.length - 1, false));
              };
              walk(dsk, "", true, true);
              // Mounts available on this disk (LVs/partitions that can be grown).
              const mounts = rows.filter((r) => r.mount && r.mount !== "[SWAP]").map((r) => ({
                mount: r.mount, pct: Number(r.pct), gb: r.fssize ? Math.ceil((r.fssize || 0) / 1073741824) : 0
              }));
              const isExpandTarget = expandDsk === dsk.name;
              const onMountChange = (m) => {
                setExpandMount(m);
                const found = mounts.find((x) => x.mount === m);
                if (found) setExpandSize(found.gb ? found.gb + 5 : 5);
              };
              return html`
            <div className="vm-card" key=${dsk.name}>
              <span className="vm-label">Disk ${dsk.name} <span className="muted">${dsk.size ? fmtBytes(dsk.size) : ""}</span>
                ${poweredOn && vm.ip && mounts.length && !expandJobs[dsk.name] ? html`<button className="mini expand-btn" data-tip="Expand this disk live — grow VMDK + filesystem"
                  onClick=${(e) => { e.stopPropagation(); if (isExpandTarget) { setExpandDsk(""); } else { setExpandDsk(dsk.name); const first = mounts.sort((a, b) => b.pct - a.pct)[0]; setExpandMount(first.mount); setExpandSize(first.gb ? first.gb + 5 : 5); setExpandErr(""); } }}>${isExpandTarget ? "✕" : "↕ Expand"}</button>` : ""}
              </span>
              ${expandJobs[dsk.name] ? html`
                <div className="expand-chip-wrap" onClick=${(ev) => ev.stopPropagation()}>
                  <button className="expand-chip" data-tip="Disk Resize running — click to open the execute card"
                    onClick=${() => setPipJob(expandJobs[dsk.name])}>
                    💾 Disk Resize · ${expandJobs[dsk.name].status === "success" ? "done" : expandJobs[dsk.name].status === "failed" ? "failed" : "running…"}
                  </button>
                  <button className="ghost" data-tip="Close (job keeps running, tracked in Events)" onClick=${() => setExpandJobs((j) => { const n = { ...j }; delete n[dsk.name]; return n; })}>✕</button>
                </div>`
                : isExpandTarget ? html`
                <div className="expand-form" onClick=${(ev) => ev.stopPropagation()}>
                  <div className="expand-row">
                    <label>mount</label>
                    <select value=${expandMount} onChange=${(e) => onMountChange(e.target.value)}>
                      ${mounts.map((m) => html`<option value=${m.mount} key=${m.mount}>${m.mount}${m.pct != null ? " · " + m.pct + "%" : ""}</option>`)}
                    </select>
                  </div>
                  <div className="expand-row">
                    <label>new size (GB)</label>
                    <input type="number" min=${1} value=${expandSize} onChange=${(e) => setExpandSize(Number(e.target.value))} />
                  </div>
                  ${expandErr && html`<div className="error expand-err">${expandErr}</div>`}
                  <div className="expand-row">
                    <button className="pill ok" disabled=${expandBusy} onClick=${() => doExpand(dsk)}>${expandBusy ? "Growing…" : "Grow"}</button>
                    <button className="ghost" disabled=${expandBusy} onClick=${() => setExpandDsk("")}>Cancel</button>
                  </div>
                  <p className="muted expand-note">Live grow: VMDK → partition → filesystem. Config (tfvars) updated so deploy-sync won't shrink it back. Grow only — shrinking is not supported.</p>
                </div>`
                : !guest ? html`<span className="muted" style=${{ fontSize: 11 }}>${guestErr ? "guest probe failed" : "loading…"}</span>`
                : rows.length ? html`<div className="lsblk-tree">${rows.map((r, i) => html`
                    <div className="lsblk-row" key=${r.name + i} title=${r.name + (r.fssize ? " · used " + fmtBytes(r.fsused) + " / " + fmtBytes(r.fssize) : "")}>
                      <span className="lsblk-prefix">${r.prefix}</span>
                      <span className="lsblk-name">${r.name}</span>
                      ${r.mount ? html`<span className="muted lsblk-mount">→${r.mount}</span>` : ""}
                      <span className="muted lsblk-size">${r.fssize ? fmtBytes(r.fssize) : (r.size ? fmtBytes(r.size) : "")}</span>
                      ${r.pct != null ? html`<span className=${Number(r.pct) > 85 ? "danger" : "vm-val"}>${r.pct}%</span>` : ""}
                    </div>`)}</div>`
                : html`<span className="muted" style=${{ fontSize: 11 }}>—</span>`}
            </div>`;})}
          </div>
        </div>
      </td>
    </tr>`}
    ${pipJob && html`<${ExpandPip} job=${pipJob}
      onClose=${() => { setPipJob(null); setExpandJobs((j) => { const n = { ...j }; for (const k of Object.keys(n)) { if (n[k].id === pipJob.id) delete n[k]; } return n; }); }} />`}
  `;
}