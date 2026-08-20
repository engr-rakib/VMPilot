// views/SecureFile.js — raw text editor for secure/<vc>/ files.
// Left-panel "Secure" root browses vCenter inventory + per-env policies
// (vcenter.tfvars, vm-defaults.conf, user-groups.tfvars). Read + save raw text;
// credentials.tfvars is encrypted → shown read-only.
import { html, useState, useEffect } from "/js/core.js";
import { getSecureFile, saveSecureFile } from "/js/api.js";
import { Spinner } from "/js/components.js";

export default function SecureFile({ vc, rel, refresh, refreshKey }) {
  const [data, setData] = useState(null);     // { raw }
  const [raw, setRaw] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");

  const load = () => {
    setLoading(true); setErr("");
    getSecureFile(vc, rel).then((d) => {
      setData(d); setRaw(d.raw || "");
    }).catch((e) => setErr(e.message)).finally(() => setLoading(false));
  };

  useEffect(load, [vc, rel, refreshKey]);

  const name = String(rel || "").split("/").pop() || rel;
  const isCreds = name === "credentials.tfvars";
  const isPolicy = name === "user-groups.tfvars";
  const editable = !isCreds;

  const save = async () => {
    setSaving(true); setErr(""); setMsg("");
    try {
      await saveSecureFile(vc, rel, raw);
      setMsg("Saved — changes apply to the next deploy of VMs using this config.");
      refresh && refresh();
    } catch (e) { setErr(e.message); }
    finally { setSaving(false); }
  };

  return html`
    <div className="object-view">
      <div className="object-head">
        <div>
          <h2>${isPolicy ? "🔐 " : "📄 "}${rel}</h2>
          <div className="muted">secure/${vc}/${rel} ${isCreds ? "· encrypted (read-only)" : ""}</div>
        </div>
        <div className="row">
          <button className="ghost" onClick=${load} disabled=${loading}>${loading ? "…" : "Reload"}</button>
          ${editable && html`<button className="ghost primary-ghost" disabled=${saving} onClick=${save}>${saving ? "Saving…" : "Save"}</button>`}
        </div>
      </div>

      ${err && html`<p className="error">${err}</p>`}
      ${msg && html`<p className="ok">${msg}</p>`}
      ${loading && !data && html`<p className="muted"><${Spinner} inline /> reading…</p>`}

      ${data && html`
        ${isPolicy && html`
          <p className="muted" style=${{ margin: "0 0 10px" }}>
            Per-env user group policy — groups defined here grant OS access to VM
            extra_users in this environment. Changes apply on the <b>next deploy</b> of
            each VM that references these groups (a missing file = legacy full-sudo fallback).
          </p>`}
        ${isCreds && html`
          <p className="muted" style=${{ margin: "0 0 10px" }}>
            🔒 SOPS-encrypted credentials. Content is hidden — manage the password via the
            vCenter wizard (Edit vCenter → new password).
          </p>`}
        <textarea className="code-edit" rows=${20} value=${raw} onChange=${(e) => setRaw(e.target.value)}
          spellCheck=${false} readOnly=${!editable} />
      `}
    </div>`;
}
