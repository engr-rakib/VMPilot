// views/EnvStatus.js — setup / environment status read-only view.
// Mirrors what install.sh checks: tool binaries, keys, terraform init,
// state backend (local vs S3), vCenters, credentials. Read-only.
import { html, useState, useEffect, useCallback } from "/js/core.js";
import { getEnvStatus } from "/js/api.js";
import { Spinner, Pill } from "/js/components.js";

function ToolRow({ name, version }) {
  const ok = version !== "missing";
  return html`
    <div className="kv" key=${name}>
      <span className="kv-k">${name}</span>
      <span className="kv-v">${ok ? version : html`<span className="error">missing</span>`}</span>
    </div>`;
}

export default function EnvStatus({ onOpen }) {
  const [st, setSt] = useState(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const load = useCallback(() => {
    setLoading(true); setErr("");
    getEnvStatus().then(setSt).catch((e) => setErr(e.message)).finally(() => setLoading(false));
  }, []);

  useEffect(load, [load]);

  const backendPill = {
    local: ["ok", "local"], remote: ["ok", "remote"], s3: ["ok", "S3"], none: ["pending", "not initialized"]
  }[st?.state_backend] || ["pending", st?.state_backend || "unknown"];

  return html`
    <div className="object-view">
      <div className="object-head">
        <div><h2>🖧 Setup status</h2><div className="muted">install.sh-readiness — read-only</div></div>
        <button className="ghost" onClick=${load} disabled=${loading}>${loading ? "…" : "Refresh"}</button>
      </div>

      ${err && html`<p className="error">${err}</p>`}
      ${loading && !st && html`<p className="muted"><${Spinner} inline /> checking environment…</p>`}

      ${st && html`
        <div className="card">
          <h3>Tools</h3>
          <div className="kv-grid">
            ${Object.entries(st.tools || {}).map(([k, v]) => html`<${ToolRow} key=${k} name=${k} version=${v} />`)}
          </div>
        </div>

        <div className="dash-columns">
          <div className="card dash-panel">
            <h3>State &amp; keys</h3>
            <div className="kv-grid">
              <div className="kv"><span className="kv-k">Terraform backend</span><span className="kv-v"><${Pill} cls=${backendPill[0]}>${backendPill[1]}</${Pill}></span></div>
              <div className="kv"><span className="kv-k">State files</span><span className="kv-v">${st.state_files}</span></div>
              <div className="kv"><span className="kv-k">Terraform init</span><span className="kv-v">${st.tools_present ? "✓" : "not initialized"}</span></div>
              <div className="kv"><span className="kv-k">Age key (sops-age/)</span><span className="kv-v">${st.age_key ? "✓ present" : "missing"}</span></div>
              <div className="kv"><span className="kv-k">SOPS config (.sops.yaml)</span><span className="kv-v">${st.sops_config ? "✓ present" : "missing"}</span></div>
              <div className="kv"><span className="kv-k">Encrypted creds</span><span className="kv-v">${st.has_credentials} vCenter(s)</span></div>
            </div>
          </div>

          <div className="card dash-panel">
            <h3>Fleet</h3>
            <div className="kv-grid">
              <div className="kv"><span className="kv-k">vCenters</span><span className="kv-v">${st.vcenters}</span></div>
              <div className="kv"><span className="kv-k">VM configs</span><span className="kv-v">${st.vm_configs}</span></div>
            </div>
            <p className="muted">vCenter inventory &amp; per-env overrides are editable from the console navigator — add a vCenter with <b>cmd: vcenter</b>, create a VM with <b>cmd: create &lt;vc&gt; &lt;env&gt;</b>.</p>
          </div>
        </div>

        <div className="card">
          <h3>Paths</h3>
          <div className="kv-grid">
            <div className="kv"><span className="kv-k">Repo root</span><span className="kv-v"><code>${st.repo_root}</code></span></div>
            <div className="kv"><span className="kv-k">Deploy path</span><span className="kv-v"><code>${st.deploy_path}</code></span></div>
            <div className="kv"><span className="kv-k">Scripts path</span><span className="kv-v"><code>${st.scripts_path}</code></span></div>
          </div>
        </div>
      `}
    </div>`;
}