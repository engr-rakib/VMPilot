// views/Dashboard.js — monitoring-first overview with the Phase 2.5 chart layer.
// Each vCenter card loads INDEPENDENTLY (own skeleton) and streams in — a slow
// or unreachable vCenter shows its own inline error and never blocks the page.
import { html, useState, useEffect, useCallback } from "/js/core.js";
import { listMonitorVcs, getMonitorVc, listJobs, getAlerts, getOperatorStats, getTrends } from "/js/api.js";
import { Spinner, Pill } from "/js/components.js";
import { Donut, HBars, MiniBar, Sparkline } from "/js/charts.js";

// On a background-refresh failure, keep the last good data (with an error note)
// instead of blanking the card. Only cards with NO data fall back to 'err'.
const patchErr = (c, vc, msg) => {
  const prev = c[vc];
  return prev && prev.data
    ? { ...c, [vc]: { ...prev, refreshing: false, error: msg } }
    : { ...c, [vc]: { state: "err", error: msg } };
};

// Module-level cache so re-entering the view (remount) restores the last data
// instantly — no full-page "collecting…" spinner. Background refresh then
// updates it in place (stale-while-revalidate). Also persisted to sessionStorage
// so a browser reload (F5) shows the last data immediately instead of blanking.
const CACHE_KEY = "vmp_dash_cache";
const readCache = () => { try { return JSON.parse(sessionStorage.getItem(CACHE_KEY)) || {}; } catch { return {}; } };
const writeCache = (c) => { try { sessionStorage.setItem(CACHE_KEY, JSON.stringify(c)); } catch { /* quota/private-mode: ignore */ } };
const cardCache = readCache();

export default function Dashboard({ onOpen, refresh }) {
  const [cards, setCards] = useState(() => {
    const init = {};
    for (const vc of Object.keys(cardCache)) init[vc] = { state: "ok", data: cardCache[vc], refreshing: false, error: "" };
    return init;
  });   // vc -> {state:'load'|'ok'|'err', data?, refreshing?}
  const [jobs, setJobs] = useState([]);
  const [error, setError] = useState("");
  const [alerts, setAlerts] = useState([]);          // recent alert ledger
  const [operators, setOperators] = useState([]);    // operator deploy stats
  const [trends, setTrends] = useState({});          // vc+entity+kind -> points
  const [openOperator, setOpenOperator] = useState(null); // operator name w/ expanded VM list

  const loadOne = useCallback((vc) => {
    // stale-while-revalidate: keep existing data visible while the fresh copy
    // streams in (no blank/"loading…" flicker on background refresh).
    setCards((c) => {
      const prev = c[vc];
      return prev && prev.data
        ? { ...c, [vc]: { ...prev, refreshing: true } }
        : { ...c, [vc]: { state: "load" } };
    });
    getMonitorVc(vc)
      .then((r) => {
        if (r && r.error) { setCards((c) => patchErr(c, vc, r.error)); return; }
        const v = r && r.vcenter;
        if (!v) { setCards((c) => patchErr(c, vc, "empty response")); return; }
        cardCache[vc] = v;
        writeCache(cardCache);
        setCards((c) => ({ ...c, [vc]: { state: "ok", data: v, refreshing: false, error: "" } }));
      })
      .catch((e) => setCards((c) => patchErr(c, vc, e.message)));
  }, []);

  const refreshAll = useCallback((names) => {
    (names || []).forEach(loadOne);
  }, [loadOne]);

  const load = useCallback(async () => {
    setError("");
    try {
      const names = await listMonitorVcs();
      // only seed skeletons for vCenters we've never loaded — existing cards
      // keep their data during background sync.
      setCards((c) => {
        const seed = {};
        names.forEach((vc) => { if (!c[vc]) seed[vc] = { state: "load" }; });
        return { ...c, ...seed };
      });
      refreshAll(names);
      listJobs().then((d) => setJobs(d || [])).catch(() => {});
      getAlerts().then((d) => setAlerts(Array.isArray(d) ? d : [])).catch(() => {});
      getOperatorStats().then((d) => setOperators(Array.isArray(d) ? d : [])).catch(() => {});
      // feed the "latest utilization" sparkline for the first vCenter's top host
      // (CPU trend) from cached data — best-effort, non-blocking.
      const cached = cardCache[names[0]];
      if (cached && cached.hosts && cached.hosts[0]) {
        getTrends(names[0], "host_cpu", cached.hosts[0].name).then((t) => {
          if (t && Array.isArray(t.points)) setTrends((prev) => ({ ...prev, [names[0]]: { points: t.points } }));
        }).catch(() => {});
      }
    } catch (e) {
      setError(e.message || "failed to load dashboard data");
    }
  }, [refreshAll]);

  // NOTE: do NOT pass the async `load` directly to useEffect — React treats
  // the returned Promise as the cleanup function and crashes on unmount.
  useEffect(() => { load(); }, [load]);
  // auto-refresh keeps the dashboard live without a manual click
  useEffect(() => {
    const id = setInterval(() => { load(); }, 30000);
    return () => clearInterval(id);
  }, [load]);
  useEffect(() => { refresh && refresh(); }, []);

  const vcList = Object.keys(cards);
  const readyVcs = vcList.map((vc) => cards[vc]).filter((c) => c && c.state === "ok" && c.data).map((c) => c.data);
  const syncing = vcList.some((vc) => cards[vc] && cards[vc].refreshing);
  const loadingFirst = vcList.some((vc) => cards[vc] && cards[vc].state === "load");

  const totals = readyVcs.reduce((a, v) => ({
    vc: a.vc + 1,
    vms: a.vms + v.summary.vm_count,
    on: a.on + v.summary.powered_on,
    off: a.off + v.summary.powered_off,
    cpu: a.cpu + v.summary.total_cpu,
    mem: a.mem + v.summary.total_mem_gb,
    disk: a.disk + v.summary.total_disk_gb
  }), { vc: 0, vms: 0, on: 0, off: 0, cpu: 0, mem: 0, disk: 0 });

  const pending = totals.vms - totals.on - totals.off;

  const envDist = readyVcs.flatMap((v) => v.envs.map((e) => ({
    label: `${e.env} · ${v.vcenter}`,
    value: e.count
  })));

  const allVms = readyVcs.flatMap((v) => v.envs.flatMap((e) => e.vms.map((vm) => ({ ...vm, vc: v.vcenter, env: e.env }))));
  const vmsCpuMax = Math.max(1, ...allVms.map((vm) => Number(vm.cpu) || 0));
  const vmsMemMax = Math.max(1, ...allVms.map((vm) => (vm.memory_mb || 0) / 1024));
  const vmsDiskMax = Math.max(1, ...allVms.map((vm) => Number(vm.disk_gb) || 0));

  const doneJobs = jobs.filter((j) => j.status === "success" || j.status === "failed");
  const jobSegs = [
    { label: "Success", value: doneJobs.filter((j) => j.status === "success").length, color: "var(--ok)" },
    { label: "Failed", value: doneJobs.filter((j) => j.status === "failed").length, color: "var(--danger)" }
  ].filter((s) => s.value > 0);

  // ---- alert summary (active crit/warn from the event ledger) ----
  const activeAlerts = (alerts || []).filter((a) => a.severity === "critical" || a.severity === "warn").slice(0, 8);
  const critCount = (alerts || []).filter((a) => a.severity === "critical").length;
  const warnCount = (alerts || []).filter((a) => a.severity === "warn").length;

  // ---- datastore + host aggregates (from each vCenter card) ----
  const dsRows = readyVcs.flatMap((v) =>
    (v.datastores || []).map((d) => ({
      vc: v.vcenter, name: d.name,
      usedPct: d.capacity ? Math.round(((d.capacity - (d.free || 0)) / d.capacity) * 100) : 0,
      freeGb: d.free ? Math.round(d.free / 1024 ** 3) : 0,
      capTb: d.capacity ? (d.capacity / 1024 ** 4).toFixed(1) : 0
    }))
  ).sort((a, b) => b.usedPct - a.usedPct).slice(0, 8);

  const hostRows = readyVcs.flatMap((v) =>
    (v.hosts || []).map((h) => {
      const cpuTot = (h.cpuCores || 0) * (h.cpuMhz || 0);
      return {
        vc: v.vcenter, name: h.name,
        cpuPct: cpuTot ? Math.round((h.cpuUsageMHz || 0) / cpuTot * 100) : 0,
        memPct: h.memoryMB ? Math.round((h.memUsageMB || 0) / h.memoryMB * 100) : 0,
        netKBps: h.netKBps || 0, diskKBps: h.diskKBps || 0,
        powerState: h.powerState, connectionState: h.connectionState,
        down: (h.powerState && h.powerState !== "poweredOn") || (h.connectionState && h.connectionState !== "connected")
      };
    })
  ).sort((a, b) => (b.cpuPct - a.cpuPct));

  const hostDownCount = hostRows.filter((h) => h.down).length;

  // ---- network portgroups (host networks union, with host counts) ----
  const pgCounts = {};
  for (const v of readyVcs) for (const h of v.hosts || []) for (const pg of h.networks || []) pgCounts[pg] = (pgCounts[pg] || 0) + 1;
  const portgroups = Object.entries(pgCounts).map(([name, hosts]) => ({ name, hosts })).sort((a, b) => b.hosts - a.hosts).slice(0, 8);
  const netMax = Math.max(1, ...portgroups.map((p) => p.hosts));

  return html`
    <div className="page dash">
      <div className="page-head">
        <h2>Dashboard</h2>
        <div className="row" style=${{ gap: 8 }}>
          ${syncing && html`<span className="muted"><${Spinner} inline /> syncing…</span>`}
          <button className="ghost" onClick=${() => load()} disabled=${loadingFirst}>Refresh</button>
        </div>
      </div>

      ${error && html`<p className="error">${error}</p>`}
      ${vcList.length === 0 && !error && html`<p className="muted"><${Spinner} inline /> collecting…</p>`}
      ${vcList.length === 0 && error && html`<p className="muted">No vCenters configured. Add one to begin.</p>`}
      ${readyVcs.length > 0 && html`
        <div className="stat-grid">
          ${[["🖥", totals.vc, "vCenters"], ["🧱", totals.vms, "Configured VMs"], ["🟢", totals.on, "Powered On", "ok-num"], ["🔴", totals.off, "Powered Off / Pending"], ["⚡", totals.cpu, "vCPU (configured)"], ["🧠", totals.mem + " GB", "RAM (configured)"]].map(([ico, num, label]) =>
            html`<div className="stat-card" key=${label}>
              <div className="stat-ico">${ico}</div>
              <div className="stat-body">
                <div className=${"stat-num " + (label.startsWith("Powered On") ? "ok-num" : "")}>${num}</div>
                <div className="stat-label">${label}</div>
              </div>
            </div>`)}
        </div>

        <div className="dash-columns">
          <div className="card dash-panel">
            <h3>⚕ System health
              <span className="muted">
                ${critCount > 0 ? html`<${Pill} cls="crit">${critCount} critical</${Pill}>` : ""}
                ${warnCount > 0 ? html`<${Pill} cls="warn">${warnCount} warning</${Pill}>` : ""}
                ${hostDownCount > 0 ? html`<${Pill} cls="crit">${hostDownCount} host down</${Pill}>` : html`<${Pill} cls="ok">hosts up</${Pill}>`}
              </span>
            </h3>
            ${activeAlerts.length > 0 ? html`
              <ul className="alert-list">
                ${activeAlerts.map((a) => html`
                  <li key=${a.id}>
                    <span className=${a.severity === "critical" ? "alert-dot crit" : "alert-dot warn"} />
                    <span className="alert-label">${a.label} · ${a.vm || a.vc}</span>
                    <span className="alert-val">${a.value || ""}</span>
                    <span className="muted">${new Date(a.at).toLocaleString()}</span>
                  </li>`)}
              </ul>`
              : html`<p className="muted">No active critical/warning alerts. All systems nominal.</p>`}
          </div>

          <div className="card dash-panel">
            <h3>🗄 Datastore capacity <span className="muted">· top ${dsRows.length} by used%</span></h3>
            ${dsRows.length ? html`<${HBars} items=${dsRows.map((d) => ({
              label: `${d.name} · ${d.vc}`,
              value: d.usedPct, max: 100, suffix: "%",
              color: d.usedPct >= 90 ? "var(--danger)" : d.usedPct >= 75 ? "var(--warn)" : "var(--ok)"
            }))} />` : html`<p className="muted">No datastores.</p>`}
          </div>
        </div>

        <div className="dash-columns">
          <div className="card dash-panel">
            <h3>🖧 Network portgroups <span className="muted">· hosts per portgroup</span></h3>
            ${portgroups.length ? html`<${HBars} items=${portgroups.map((p) => ({
              label: p.name, value: p.hosts, max: netMax, suffix: "h", color: "var(--accent2)"
            }))} />` : html`<p className="muted">No network data.</p>`}
          </div>

          <div className="card dash-panel">
            <h3>👥 Operator activity <span className="muted">· VM deploys by operator</span></h3>
            ${operators.length ? html`
              <div className="mini-table-wrap">
                <table className="mini-table">
                  <colgroup>
                    <col style=${{ width: "34%" }} /><col style=${{ width: "30%" }} /><col style=${{ width: "36%" }} />
                  </colgroup>
                  <tbody>
                    ${operators.filter((o) => o.deploy_count > 0).map((o) => html`
                      <tr key=${o.user} className="clickable" onClick=${() => setOpenOperator(openOperator === o.user ? null : o.user)}>
                        <td><strong>${o.user}</strong></td>
                        <td><${Pill} cls="env">${o.deploy_count} deploys</${Pill}></td>
                        <td className="muted">${o.vms.length} VMs</td>
                      </tr>
                      ${openOperator === o.user && o.vms.slice(0, 10).map((vm) => html`
                        <tr key=${o.user + vm.vm + vm.at} className="sub">
                          <td className="muted">↳ ${vm.vm}</td>
                          <td>${vm.vc}</td>
                          <td>${vm.env} · ${vm.status} · ${vm.at ? new Date(vm.at).toLocaleDateString() : ""}</td>
                        </tr>`)}
                    `)}
                  </tbody>
                </table>
              </div>`
              : html`<p className="muted">No deploy activity yet.</p>`}
          </div>
        </div>

        <div className="dash-columns">
          <div className="card dash-panel">
            <h3>🏭 Host utilization <span className="muted">· top by CPU · ${hostRows.length} hosts</span></h3>
            ${hostRows.length ? html`
              <div className="mini-table-wrap">
                <table className="mini-table">
                  <colgroup>
                    <col style=${{ width: "20%" }} /><col style=${{ width: "16%" }} />
                    <col style=${{ width: "13%" }} /><col style=${{ width: "13%" }} />
                    <col style=${{ width: "12%" }} /><col style=${{ width: "12%" }} />
                    <col style=${{ width: "14%" }} />
                  </colgroup>
                  <thead>
                    <tr><th>Host</th><th>vCenter</th><th>CPU</th><th>RAM</th><th>Net</th><th>Disk IO</th><th>State</th></tr>
                  </thead>
                  <tbody>
                    ${hostRows.slice(0, 8).map((h) => html`
                      <tr key=${h.vc + h.name}>
                        <td><strong>${h.name}</strong></td>
                        <td className="muted">${h.vc}</td>
                        <td><${MiniBar} value=${h.cpuPct} max=${100} suffix="%" label="CPU" color=${h.cpuPct > 85 ? "var(--danger)" : "var(--accent2)"} /></td>
                        <td><${MiniBar} value=${h.memPct} max=${100} suffix="%" label="RAM" color=${h.memPct > 85 ? "var(--danger)" : "var(--accent)"} /></td>
                        <td>${h.netKBps ? h.netKBps + " KB/s" : "—"}</td>
                        <td>${h.diskKBps ? h.diskKBps + " KB/s" : "—"}</td>
                        <td>${h.down ? html`<${Pill} cls="crit">down</${Pill}>` : html`<${Pill} cls="ok">up</${Pill}>`}</td>
                      </tr>`)}
                  </tbody>
                </table>
              </div>`
              : html`<p className="muted">No host data.</p>`}
          </div>

          <div className="card dash-panel">
            <h3>📈 Live vs configured <span className="muted">· CPU trend · top host</span></h3>
            ${trends[readyVcs[0]?.vcenter] && trends[readyVcs[0].vcenter].points && trends[readyVcs[0].vcenter].points.length > 0 ? html`
              <div className="trend-block">
                <${Sparkline} points=${trends[readyVcs[0].vcenter].points} width=${260} height=${44} color="var(--accent)" suffix="%" label="host CPU 24h" />
                <p className="muted">24h CPU trend for ${readyVcs[0].hosts?.[0]?.name || "top host"} · ${readyVcs[0].vcenter}</p>
              </div>`
              : html`<p className="muted">No trend data yet — samples accumulate on each background sync (24h window).</p>`}
            <h4 className="sec-label">Configured vs live</h4>
            <div className="meter-legend">
              <span><span className="dot ok-dot" /> ${readyVcs.reduce((a, v) => a + (v.summary?.vm_count || 0), 0)} configured VMs</span>
              <span>${totals.on} powered on</span>
              <span>${hostRows.length} hosts (${hostDownCount} down)</span>
            </div>
          </div>
        </div>

        <div className="dash-columns">
          <div className="card dash-panel">
            <h3>VMs by environment</h3>
            <${HBars} items=${envDist} />
          </div>

          <div className="card dash-panel">
            <h3>Job outcomes (last ${doneJobs.length})</h3>
            <div className="donut-flex">
              <${Donut} segments=${jobSegs} size=${150} centerTop=${doneJobs.length} centerBottom="jobs" />
              <div className="donut-legend">
                ${jobSegs.map((s) => html`
                  <div key=${s.label} className="dl-row">
                    <span className="dl-dot" style=${{ background: s.color }} />
                    <span className="dl-label">${s.label}</span>
                    <span className="dl-val">${s.value}</span>
                  </div>`)}
                ${jobSegs.length === 0 && html`<div className="muted">No completed jobs yet.</div>`}
              </div>
            </div>
          </div>
        </div>

        <div className="card dash-panel">
          <h3>Latest VM status</h3>
          <div className="table-scroll">
          <table className="mini-table">
            <colgroup>
              <col style=${{ width: "18%" }} /><col style=${{ width: "14%" }} />
              <col style=${{ width: "7%" }} /><col style=${{ width: "11%" }} />
              <col style=${{ width: "14%" }} /><col style=${{ width: "9%" }} />
              <col style=${{ width: "9%" }} /><col style=${{ width: "9%" }} />
              <col style=${{ width: "9%" }} />
            </colgroup>
            <thead><tr><th>VM</th><th>vCenter</th><th>Env</th><th>IP</th><th>Guest OS</th><th>CPU</th><th>RAM</th><th>Disk</th><th>Power</th></tr></thead>
            <tbody>
              ${allVms.slice(0, 100).map((vm, i) => html`
                <tr key=${vm.vc + vm.env + vm.name + i} onClick=${() => onOpen({ vc: vm.vc, env: vm.env, file: vm.file })}>
                  <td>${vm.name}</td>
                  <td className="muted">${vm.vc}</td>
                  <td><${Pill} cls="env">${vm.env}</${Pill}></td>
                  <td>${vm.ip || "—"}</td>
                  <td className="muted">${(vm.live && vm.live.os) || "—"}</td>
                  <td>${vm.cpu != null ? html`<${MiniBar} value=${vm.cpu} max=${vmsCpuMax} label="vCPU" color="var(--accent2)" />` : "—"}</td>
                  <td>${vm.memory_mb ? html`<${MiniBar} value=${(vm.memory_mb / 1024).toFixed(0)} max=${Math.round(vmsMemMax)} suffix="G" label="RAM" color="var(--accent)" />` : "—"}</td>
                  <td>${vm.disk_gb ? html`<${MiniBar} value=${vm.disk_gb} max=${vmsDiskMax} suffix="G" label="disk" color="var(--ok)" />` : "—"}</td>
                  <td>${vm.power === "poweredOn" ? html`<${Pill} cls="ok">on</${Pill}>` : vm.power === "poweredOff" ? html`<${Pill} cls="off">off</${Pill}>` : html`<${Pill} cls="pending">pending</${Pill}>`}</td>
                </tr>`)}
              ${allVms.length === 0 && html`<tr><td colSpan="9" className="muted">No VM configs yet.</td></tr>`}
            </tbody>
          </table>
          </div>
        </div>
      `}

      <div className="dash-columns">
        ${vcList.filter((vc) => cards[vc] && cards[vc].state === "load").map((vc) => html`
          <div className="card dash-panel" key=${vc}><h3>🖥 ${vc}</h3><p className="muted"><${Spinner} inline /> loading…</p></div>`)}
        ${vcList.filter((vc) => cards[vc] && cards[vc].state === "err").map((vc) => html`
          <div className="card dash-panel" key=${vc}><h3>🖥 ${vc}</h3>
            <p className="error">${cards[vc].error || "failed to load"}</p>
            <button className="ghost" onClick=${() => loadOne(vc)}>Retry</button>
          </div>`)}
      </div>
    </div>`;
}