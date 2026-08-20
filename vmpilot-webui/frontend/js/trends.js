// trends.js — shared datacenter trend rail + capacity donut helpers.
// Dashboard uses DcTrends inside per-datacenter blocks; Monitor uses DcDonuts
// in each vCenter header row. One batch call (getDcTrends) serves both.
import { html, useState, useEffect } from "/js/core.js";
import { getDcTrends } from "/js/api.js";
import { Spinner } from "/js/components.js";
import { TrendChart, Donut } from "/js/charts.js";

// Evenly downsample to ≤ n points (keeps the window span, trims render cost).
export const downSample = (pts, n) => {
  if (!Array.isArray(pts) || pts.length <= n) return pts || [];
  const step = pts.length / n;
  return pts.filter((_, i) => Math.floor(i / step) !== Math.floor((i + 1) / step) || i === pts.length - 1);
};
export const RAIL_COLORS = ["#22d3ee", "#2563eb", "#4ade80", "#fbbf24", "#f87171", "#a78bfa", "#34d399", "#f472b6", "#60a5fa", "#facc15"];

// Grafana-style trend rail for a vCenter: 5 TrendChart panels (CPU / Memory /
// Datastore used / Net I/O / Disk I/O), one line per host/datastore, 6h/24h/72h
// chips. SWR: last-good stays on failed refresh; failed first load = error+Retry.
export function DcTrends({ vc }) {
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

// Datacenter capacity items from a monitor vCenter payload: vCPU = host cores,
// RAM = host memory GB, Disk = datastore TB, each with aggregate utilization %.
// pct stays null when the live source (hosts/datastores/usage fields) is missing
// so the UI renders "—" — never NaN or a full-width/full-ring bar.
export function dcCapItems(v) {
  const hosts = v.hosts || [];
  const datastores = v.datastores || [];
  const hostCores = hosts.reduce((a, h) => a + (h.cpuCores || 0), 0);
  const hostMhzTot = hosts.reduce((a, h) => a + ((h.cpuCores || 0) * (h.cpuMhz || 0)), 0);
  const cpuUsgMhz = hosts.reduce((a, h) => a + (h.cpuUsageMHz || 0), 0);
  const hostMemMb = hosts.reduce((a, h) => a + (h.memoryMB || 0), 0);
  const memUsgMb = hosts.reduce((a, h) => a + (h.memUsageMB || 0), 0);
  const totalDs = datastores.reduce((a, d) => a + ((d.capacity || 0) - (d.free || 0)), 0);
  const totalDsCap = datastores.reduce((a, d) => a + (d.capacity || 0), 0);
  const pct = (used, total) => (total ? Math.min(100, Math.round((used / total) * 100)) : null);
  const dcCpuPct = hostMhzTot && hosts.some((h) => h.cpuUsageMHz != null) ? pct(cpuUsgMhz, hostMhzTot) : null;
  const dcMemPct = hostMemMb && hosts.some((h) => h.memUsageMB != null) ? pct(memUsgMb, hostMemMb) : null;
  const dcDsPct = totalDsCap && datastores.some((d) => d.free != null) ? pct(totalDs, totalDsCap) : null;
  return {
    items: [
      { label: "vCPU", capText: hostCores ? hostCores + " cores" : "—", pct: dcCpuPct, color: "var(--accent2)" },
      { label: "RAM", capText: hostMemMb ? Math.round(hostMemMb / 1024) + " GB" : "—", pct: dcMemPct, color: "var(--accent)" },
      { label: "Disk", capText: totalDsCap ? (totalDsCap / 1024 ** 4).toFixed(1) + " TB" : "—", pct: dcDsPct, color: "var(--ok)" }
    ],
    noLive: hosts.length === 0 || datastores.length === 0,
    totalDsCap, totalDs
  };
}

// Small capacity donuts for a vCenter header row (Inventory): one ring per
// CPU/RAM/Disk — center = utilization %, caption = physical capacity.
export function DcDonuts({ items = [], size = 62, thickness = 7 }) {
  return html`
    <div className="vc-donuts" data-tip="Datacenter physical capacity + live utilization (hosts/datastores)">
      ${items.map((it) => {
        const p = (it.pct == null || Number.isNaN(it.pct)) ? null : Math.max(0, Math.min(100, it.pct));
        const segs = p == null
          ? [{ label: it.label, value: 0, color: "var(--track)" }]
          : [{ label: it.label, value: p, color: it.color }, { label: it.label + " free", value: 100 - p, color: "var(--track)" }];
        return html`
          <div className="vc-donut" key=${it.label}>
            <${Donut} segments=${segs} size=${size} thickness=${thickness}
              centerTop=${p == null ? "—" : p + "%"} centerBottom=${it.label} />
            <div className="vc-donut-cap">${it.capText}</div>
          </div>`;
      })}
    </div>`;
}