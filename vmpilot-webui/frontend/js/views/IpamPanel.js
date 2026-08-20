// views/IpamPanel.js — IPAM snapshot for a vCenter+env: base IP, reserved
// (in-use) IPs from the per-VM config files, and the next free IP from the
// CLI's next_free_ip.sh. Read-only; mirrors scripts/next_free_ip.sh.
import { html, useState, useEffect } from "/js/core.js";
import { getIpam } from "/js/api.js";
import { Spinner, Pill } from "/js/components.js";

export default function IpamPanel({ vc, env }) {
  const [snap, setSnap] = useState(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const load = () => {
    setLoading(true); setErr("");
    getIpam(vc, env).then(setSnap).catch((e) => setErr(e.message)).finally(() => setLoading(false));
  };

  useEffect(load, [vc, env]);

  return html`
    <div className="object-view">
      <div className="object-head">
        <div><h2>🌐 IPAM</h2><div className="muted">${vc} · ${env}</div></div>
        <button className="ghost" onClick=${load} disabled=${loading}>${loading ? "…" : "Refresh"}</button>
      </div>

      ${err && html`<p className="error">${err}</p>`}
      ${loading && !snap && html`<p className="muted"><${Spinner} inline /> scanning…</p>`}

      ${snap && html`
        <div className="card kv-grid">
          <div className="kv"><span className="kv-k">IPAM base IP</span><span className="kv-v">${snap.base_ip || "— (not configured on this vCenter)"}</span></div>
          ${snap.free_ip && html`<div className="kv"><span className="kv-k">Next free IP</span><span className="kv-v ok-num">${snap.free_ip}</span></div>`}
          ${snap.error && html`<div className="kv"><span className="kv-k">Scan status</span><span className="kv-v error">${snap.error}</span></div>`}
        </div>

        <div className="card">
          <h3>Reserved IPs — config files <span className="muted">(${snap.used.length})</span></h3>
          <p className="muted">These are read from the per-VM tfvars (source of truth), so powered-off VMs stay reserved.</p>
          ${snap.used.length === 0 && html`<p className="muted">No per-VM configs in this environment yet.</p>`}
          ${snap.used.length > 0 && html`
            <table className="mini-table">
              <thead><tr><th>IP</th></tr></thead>
              <tbody>
                ${snap.used.map((ip, i) => html`<tr key=${ip + i}><td><code>${ip}</code></td></tr>`)}
              </tbody>
            </table>`}
        </div>
      `}
      ${(!loading && snap && !snap.base_ip && !snap.error) && html`<p className="muted"><${Pill} cls="pending">tip</${Pill}> Set ipam_base_ip on the vCenter (or a per-env override) to enable free-IP scanning.</p>`}
    </div>`;
}