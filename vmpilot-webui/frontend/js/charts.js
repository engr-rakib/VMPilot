// charts.js — tiny dependency-free SVG chart components (no CDN, no build step).
// Implements the Phase 2.5 visualization layer: power donut, capacity bars,
// per-VM usage bars, env distribution, job-outcome chart.
import { html, useMemo, useState, useRef } from "/js/core.js";

// CSS variable tokens (kept in sync with themes.css)
const C = {
  ok: "var(--ok)",
  danger: "var(--danger)",
  warn: "var(--warn)",
  accent: "var(--accent)",
  accent2: "var(--accent2)",
  muted: "#3a4a5d",
  track: "#0a0e13",
  text: "var(--text)"
};

const palette = ["#22d3ee", "#2563eb", "#4ade80", "#fbbf24", "#f87171", "#a78bfa", "#34d399", "#f472b6", "#60a5fa", "#facc15"];

// --- Donut (power overview) -------------------------------------------------
// segments: [{ label, value, color }] — draws arcs summing to value totals.
export function Donut({ segments = [], size = 150, thickness = 18, centerTop, centerBottom }) {
  const radius = (size - thickness) / 2;
  const circ = 2 * Math.PI * radius;
  const total = Math.max(1, segments.reduce((a, s) => a + Number(s.value) || 0, 0));

  let acc = 0;
  const arcs = segments.map((s, i) => {
    const frac = (Number(s.value) || 0) / total;
    const offset = acc * circ;
    acc += frac;
    return { ...s, frac, dash: `${frac * circ} ${circ}`, offset };
  });

  return html`
    <div className="donut-wrap" style=${{ width: size, height: size }}>
      <svg width=${size} height=${size} viewBox=${`0 0 ${size} ${size}`} className="donut">
        <circle cx=${size / 2} cy=${size / 2} r=${radius} fill="none" stroke=${C.track} stroke-width=${thickness} />
        ${arcs.map((a) => html`
          <circle key=${a.label + a.offset}
            cx=${size / 2} cy=${size / 2} r=${radius} fill="none"
            stroke=${a.color} stroke-width=${thickness}
            stroke-dasharray=${a.dash} stroke-dashoffset=${-a.offset}
            transform=${`rotate(-90 ${size / 2} ${size / 2})`}
            className="donut-seg" title=${`${a.label}: ${a.value}`} />`)}
      </svg>
      ${(centerTop || centerBottom) && html`
        <div className="donut-center">
          <div className="donut-top">${centerTop}</div>
          <div className="donut-bottom">${centerBottom}</div>
        </div>`}
    </div>`;
}

// --- Horizontal bars (capacity / distribution / job outcome) ----------------
// items: [{ label, value, max?, color?, suffix? }] — max across items when omitted,
// or an explicit `max` for percentage semantics (e.g. "34% used").
export function HBars({ items = [], max, title, unit = "" }) {
  const data = useMemo(() => {
    const m = max ?? Math.max(1, ...items.map((i) => Number(i.max) > 0 ? i.max : Number(i.value) || 0));
    return items.map((i, idx) => {
      const v = Number(i.value) || 0;
      const pct = max || i.max ? Math.min(100, (v / (max || i.max)) * 100) : (v / m) * 100;
      return { ...i, idx, pct: Math.max(0, Math.min(100, pct)), color: i.color || palette[idx % palette.length] };
    });
  }, [items, max]);

  if (!data.length) return html`<p className="muted chart-empty">no data</p>`;

  return html`
    <div className="hbars">
      ${title && html`<div className="hbar-title">${title}</div>`}
      ${data.map((d) => html`
        <div className="hbar-row" key=${d.label + d.idx}>
          <div className="hbar-label" title=${d.label}>${d.label}</div>
          <div className="hbar-track">
            <div className="hbar-fill" style=${{ width: d.pct + "%", background: d.color }} title=${`${d.label}: ${d.value || 0}${d.suffix ?? unit}`} />
          </div>
          <div className="hbar-val">${d.value || 0}${d.suffix ?? unit}</div>
        </div>`)}
    </div>`;
}

// --- Datacenter capacity bars (Inventory header) ---------------------------
// items: [{ label, capacity, suffix, pct, color }] — physical capacity +
// aggregate utilization %. capacity null/NaN → "—"; pct null/NaN → "—" and a
// 0-width fill (never "NaN" / a full bar). Percent-capped at 100.
export function CapBars({ items = [] }) {
  return html`
    <div className="capbars">
      ${items.map((it) => {
        const p = Number(it.pct);
        const pct = Number.isFinite(p) ? Math.max(0, Math.min(100, p)) : null;
        const cap = it.capacity == null || Number.isNaN(Number(it.capacity)) ? "—" : `${it.capacity}${it.suffix || ""}`;
        return html`
          <div className="capbar" key=${it.label}>
            <span className="capbar-label" title=${it.label}>${it.label}</span>
            <span className="capbar-track" title=${`${it.label}: ${pct === null ? "no data" : pct + "% used"}`}>
              ${pct !== null && html`<span className="capbar-fill" style=${{ width: pct + "%", background: it.color || (pct > 85 ? C.danger : C.accent) }} />`}
            </span>
            <span className="capbar-val">${cap}</span>
            <span className="capbar-pct" style=${{ color: pct !== null && pct > 85 ? C.danger : undefined }}>${pct === null ? "—" : pct + "%"}</span>
          </div>`;
      })}
    </div>`;
}

// --- MiniBar (per-VM usage in tables) ----------------------------------------
// A compact inline bar: label text + thin track + fill + numeric value.
export function MiniBar({ value, max = 100, color = C.accent, label, suffix = "", hideValue = false }) {
  const pct = Math.max(0, Math.min(100, max ? (value / max) * 100 : 0));
  return html`
    <span className="minibar" title=${label}>
      ${label && html`<span className="minibar-label">${label}</span>`}
      <span className="minibar-track"><span className="minibar-fill" style=${{ width: pct + "%", background: color }} /></span>
      ${!hideValue && html`<span className="minibar-val">${value}${suffix}</span>`}
    </span>`;
}

// --- Power donut convenience -------------------------------------------------
// Builds on/off/pending segments from committed totals; fit = "configured".
export function PowerDonut({ on = 0, off = 0, pending = 0, size = 150 }) {
  const segs = [
    { label: "Powered on", value: on, color: C.ok },
    { label: "Powered off", value: off, color: C.danger },
    { label: "Pending / undeployed", value: pending, color: C.warn }
  ].filter((s) => s.value > 0);
  const total = on + off + pending;
  return html`
    <div className="donut-flex">
      <${Donut} segments=${segs} size=${size} centerTop=${total} centerBottom="VMs" />
      <div className="donut-legend">
        ${segs.map((s) => html`
          <div key=${s.label} className="dl-row">
            <span className="dl-dot" style=${{ background: s.color }} />
            <span className="dl-label">${s.label}</span>
            <span className="dl-val">${s.value}</span>
          </div>`)}
      </div>
    </div>`;
}

// --- Sparkline (24h trend from the samples table) -----------------------------
// points: [{ts, value}] — a tiny line chart with a last-value label. Downsamples
// to `buckets` for a smooth SVG path. Best-effort: empty → a muted "no data" row.
export function Sparkline({ points = [], width = 160, height = 30, color = C.accent, suffix = "", label = "" }) {
  const { path, last, lastTs, min, max } = useMemo(() => {
    if (!points.length) return { path: "", last: null, lastTs: null, min: 0, max: 0 };
    const pts = points.length > 240 ? points.filter((_, i) => i % Math.ceil(points.length / 240) === 0) : points;
    const vals = pts.map((p) => Number(p.value) || 0);
    const mn = Math.min(...vals);
    const mx = Math.max(...vals);
    const span = mx - mn || 1;
    const W = width, H = height, pad = 2;
    const x = (i) => pad + (i / Math.max(1, pts.length - 1)) * (W - pad * 2);
    const y = (v) => H - pad - ((v - mn) / span) * (H - pad * 2);
    const d = pts.map((p, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(Number(p.value) || 0).toFixed(1)}`).join(" ");
    return { path: d, last: vals[vals.length - 1], lastTs: pts[pts.length - 1].ts, min: mn, max: mx };
  }, [points, width, height]);

  if (!points.length) return html`<span className="muted chart-empty" title=${`${label} — no samples yet`}>— no data</span>`;

  return html`
    <span className="spark" title=${`${label}: last ${last}${suffix} @ ${lastTs ? new Date(lastTs).toLocaleTimeString() : ""} (min ${min} / max ${max})`}>
      <svg width=${width} height=${height} viewBox=${`0 0 ${width} ${height}`} className="spark-svg">
        <path d=${path} fill="none" stroke=${color} stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round" />
      </svg>
      <span className="spark-val" style=${{ color }}>${last}${suffix}</span>
    </span>`;
}

// --- Combined multi-series trend (CPU/RAM/Disk I/O/Net) with hover crosshair ------
// series: [{ key, label, color, points: [{ts, value}], unit }]. Series with
// `unit: "KB/s"` (net/disk I/O) use a relative 0-100 scale of their own window max;
// others are plain %. Hover shows a vertical crosshair + per-series values at the
// nearest timestamp.
export function TrendChart({ series = [], width = 560, height = 120, timeLabel = "24h" }) {
  const [hover, setHover] = useState(null);
  const ref = useRef(null);
  const W = width, H = height, padL = 34, padR = 10, padT = 8, padB = 18;

  const built = useMemo(() => {
    const s = series.map((sr) => {
      const pts = (sr.points || []).filter((p) => Number.isFinite(Number(p.value)));
      return { ...sr, pts };
    }).filter((sr) => sr.pts.length > 1);
    if (!s.length) return null;
    const allTs = s.reduce((a, sr) => a.concat(sr.pts.map((p) => p.ts)), []);
    const t0 = Math.min(...allTs), t1 = Math.max(...allTs);
    const span = Math.max(1, t1 - t0);
    const innerW = W - padL - padR, innerH = H - padT - padB;
    const X = (ts) => padL + ((ts - t0) / span) * innerW;
    const Y = (v, scaleMax) => padT + innerH - Math.min(100, Math.max(0, (v / scaleMax) * 100)) / 100 * innerH;
    const rows = s.map((sr) => {
      const scaleMax = sr.unit === "KB/s" ? Math.max(...sr.pts.map((p) => Number(p.value) || 0), 1) : 100;
      const d = sr.pts.map((p, i) => `${i === 0 ? "M" : "L"}${X(p.ts).toFixed(1)},${Y(Number(p.value), scaleMax).toFixed(1)}`).join(" ");
      return { ...sr, d, scaleMax };
    });
    // gridlines at 25/50/75/100 (relative to scale)
    const grid = [0, 25, 50, 75, 100].map((g) => ({ y: Y(g, 100), label: g }));
    return { rows, t0, t1, span, innerW, innerH, grid };
  }, [series, W, H]);

  if (!built) return html`<span className="muted chart-empty">— no trend data yet</span>`;

  const onMove = (ev) => {
    const el = ref.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    // SVG renders at width:100% while the viewBox is `W` wide — map rendered px
    // back to viewBox coordinates so the crosshair tracks the pointer exactly.
    const scaleX = rect.width ? rect.width / W : 1;
    const px = (ev.clientX - rect.left) / scaleX;
    const innerW = built.innerW;
    const rel = Math.max(0, Math.min(1, (px - padL) / innerW));
    const targetTs = built.t0 + rel * (built.t1 - built.t0);
    // nearest ts across all series
    let best = null, bestDiff = Infinity;
    for (const sr of built.rows) {
      for (const p of sr.pts) {
        const d = Math.abs(p.ts - targetTs);
        if (d < bestDiff) { bestDiff = d; best = p.ts; }
      }
    }
    const cx = padL + ((best - built.t0) / (built.t1 - built.t0)) * innerW;
    const vals = built.rows.map((sr) => {
      const pts = sr.pts;
      let nearest = pts[0], nd = Infinity;
      for (const q of pts) { const d = Math.abs(q.ts - best); if (d < nd) { nd = d; nearest = q; } }
      const val = Number(nearest.value);
      const dotY = padT + built.innerH - Math.min(100, Math.max(0, (val / sr.scaleMax) * 100)) / 100 * built.innerH;
      return { ...sr, value: val, ts: nearest.ts, dotY };
    });
    setHover({ cx, vals });
  };

  return html`
    <div className="trend-wrap">
      <svg ref=${ref} width=${W} height=${H} viewBox=${`0 0 ${W} ${H}`} className="trend-svg"
        onMouseMove=${onMove} onMouseLeave=${() => setHover(null)}>
        ${built.grid.map((g) => html`
          <line x1=${padL} y1=${g.y} x2=${W - padR} y2=${g.y} className="trend-grid" />
          <text x=${padL - 4} y=${g.y + 3} className="trend-y">${g.label}</text>`)}
        <line x1=${padL} y1=${H - padB} x2=${W - padR} y2=${H - padB} className="trend-axis" />
        ${built.rows.map((sr) => html`
          <path d=${sr.d} fill="none" stroke=${sr.color} stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round" className="trend-line" />`)}
        ${hover && html`
          <line x1=${hover.cx} y1=${padT} x2=${hover.cx} y2=${H - padB} className="trend-cursor" />
          ${hover.vals.map((v) => html`
            <circle cx=${hover.cx} cy=${v.dotY} r="3" fill=${v.color} className="trend-dot" />
          `)}
          ${hover.vals.map((v) => html`
            <text x=${hover.cx + 8} y=${padT + 4 + hover.vals.indexOf(v) * 13} className="trend-tip">
              ${v.label} <tspan fill=${v.color}>${formatTrend(v.key, v.value)}</tspan>
            </text>`)}
        `}
      </svg>
      <div className="trend-legend">
        ${built.rows.map((sr) => html`
          <span className="trend-leg"><i style=${{ background: sr.color }} />${sr.label}${sr.unit === "KB/s" ? html` <span className="muted">(KB/s)</span>` : ""}</span>`)}
      </div>
    </div>`;
}

function formatTrend(key, v) {
  if (key === "net" || key === "diskio") return Math.round(v) + " KB/s";
  return Math.round(v) + "%";
}