// views/BackupPanel.js — backup archives: list, create, restore (guarded).
// Phase 2.5/W5: GET /api/backups → table of archives (+ size/date, rotation
// keeps 5); "New backup" runs the standard backup job; "Restore" requires a
// typed-name confirm (the server pre-saves current state first).
import { html, useState, useEffect } from "/js/core.js";
import { getBackups, createJob, restoreBackup } from "/js/api.js";
import { Spinner, Pill } from "/js/components.js";

const human = (bytes) => {
  if (bytes == null) return "—";
  const gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return gb.toFixed(1) + " GB";
  const mb = bytes / (1024 * 1024);
  if (mb >= 1) return mb.toFixed(0) + " MB";
  return Math.round(bytes / 1024) + " KB";
};

export default function BackupPanel({ refresh }) {
  const [list, setList] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState("");
  const [confirmName, setConfirmName] = useState("");

  const load = async () => {
    setLoading(true); setErr("");
    try { setList(await getBackups()); } catch (e) { setErr(e.message); }
    finally { setLoading(false); }
  };

  useEffect(() => { load(); }, [ refresh && 0, refresh ]);

  const doBackup = async () => {
    setBusy("new"); setErr(""); setMsg("");
    try {
      const job = await createJob({ action: "backup" });
      setMsg(`Backup job ${job.id.slice(0, 8)}… started — check the Jobs tab for output.`);
      setTimeout(load, 2500);
    } catch (e) { setErr(e.message); }
    finally { setBusy(""); }
  };

  const doRestore = async (filename) => {
    if (confirmName !== filename) return setErr("Type the archive filename exactly to confirm restore.");
    setBusy(filename); setErr(""); setMsg("");
    try {
      const job = await restoreBackup(filename);
      setMsg(`Restore job ${job.id.slice(0, 8)}… started. Current state is pre-saved under backups/ first.`);
      setConfirmName("");
    } catch (e) { setErr(e.message); }
    finally { setBusy(""); }
  };

  const backups = list.filter((b) => b.kind === "backup");
  const snapshots = list.filter((b) => b.kind === "snapshot");

  return html`
    <div className="object-view">
      <div className="object-head">
        <div><h2>💾 Backups</h2><div className="muted">Rotating archives (keeps last 5) · pre-restore state snapshots are never rotated</div></div>
        <div className="row">
          <button className="ghost primary-ghost" disabled=${busy === "new"} onClick=${doBackup}>${busy === "new" ? "…" : "New backup"}</button>
          <button className="ghost" onClick=${load} disabled=${loading}>${loading ? "…" : "Refresh"}</button>
        </div>
      </div>

      ${err && html`<p className="error">${err}</p>`}
      ${msg && html`<p className="ok">${msg}</p>`}
      ${loading && !backups.length && html`<p className="muted"><${Spinner} inline /> reading backups/ …</p>`}

      <div className="card">
        <h3>Backup archives <span className="muted">(${backups.length})</span></h3>
        ${backups.length === 0 && html`<p className="muted">No backups yet — click “New backup”.</p>`}
        <table className="mini-table">
          <thead><tr><th>Archive</th><th>Size</th><th>Created</th><th>Actions</th></tr></thead>
          <tbody>
            ${backups.map((b) => html`
              <tr key=${b.id}>
                <td><code>${b.filename}</code></td>
                <td>${human(b.size)}</td>
                <td className="muted">${new Date(b.mtime).toLocaleString()}</td>
                <td>
                  ${confirmName === b.filename ? html`
                    <div className="row restore-row">
                      <input value=${confirmName} onChange=${(e) => setConfirmName(e.target.value)} placeholder="type filename to confirm" />
                      <button className="ghost danger" disabled=${busy} onClick=${() => doRestore(b.filename)}>Confirm restore</button>
                      <button className="ghost" onClick=${() => setConfirmName("")}>✕</button>
                    </div>`
                  : html`
                    <div className="row">
                      <button className="ghost danger" onClick=${() => { setConfirmName(b.filename); setErr(""); }}>Restore</button>
                    </div>`}
                </td>
              </tr>`)}
          </tbody>
        </table>
        <p className="muted">💡 Restore overwrites deploy/, terraform/ and install.sh with the archived content — the current state files are copied to <code>backups/pre-restore-*</code> first so nothing is lost.</p>
      </div>

      ${snapshots.length > 0 && html`
        <div className="card">
          <h3>Pre-restore / pre-destroy state snapshots <span className="muted">(${snapshots.length})</span></h3>
          <table className="mini-table">
            <thead><tr><th>Snapshot</th><th>Size</th><th>Created</th></tr></thead>
            <tbody>
              ${snapshots.map((b) => html`
                <tr key=${b.id}><td><code>${b.filename}</code></td><td>${human(b.size)}</td><td className="muted">${new Date(b.mtime).toLocaleString()}</td></tr>`)}
            </tbody>
          </table>
        </div>`}
    </div>`;
}