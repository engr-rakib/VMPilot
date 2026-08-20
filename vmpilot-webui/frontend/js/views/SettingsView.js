// views/SettingsView.js — Settings panel: Users + RBAC roles (create role,
// assign permissions) + Alerting/notifications configuration. Permission-gated
// (users.manage / settings.manage); the UI hides edit controls without them.
import { html, useState, useEffect } from "/js/core.js";
import {
  getUsers, createUser, updateUser, deleteUser,
  getRoles, createRole, updateRole, deleteRole,
  getAlerting, saveAlerting, testAlerting
} from "/js/api.js";
import { Spinner, Pill } from "/js/components.js";

const PERM_LABELS = {
  view: "View (read everything)",
  deploy: "Deploy / plan / sync / destroy / power / backup",
  "config.write": "Create / edit VM configs, secure files, vCenters",
  terminal: "Terminal",
  "users.manage": "Manage users + roles",
  "settings.manage": "Alerting / SMTP settings"
};

export default function SettingsView({ me }) {
  const [tab, setTab] = useState("users"); // users | roles | alerting
  const [users, setUsers] = useState(null);
  const [rolesData, setRolesData] = useState(null); // { roles[], permissions[] }
  const [alerting, setAlerting] = useState(null);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState("");
  const [testResult, setTestResult] = useState("");
  const [newUser, setNewUser] = useState({ username: "", password: "", role: "viewer" });
  const [newRole, setNewRole] = useState({ name: "", description: "", perms: [] });
  const [editing, setEditing] = useState(null); // { name, permissions, description } working copy
  const [resetPw, setResetPw] = useState(null); // { id, username, value }

  const canManageUsers = me && me.permissions && me.permissions.includes("users.manage");
  const canManageSettings = me && me.permissions && me.permissions.includes("settings.manage");

  const flash = (m) => { setSaved(m); setTimeout(() => setSaved(""), 2500); };

  const reloadRoles = () => getRoles().then(setRolesData).catch((e) => setError(e.message));

  useEffect(() => {
    if (canManageUsers) getUsers().then(setUsers).catch((e) => setError(e.message));
    if (canManageUsers) reloadRoles();
  }, [canManageUsers]);

  useEffect(() => {
    getAlerting().then(setAlerting).catch((e) => setError(e.message));
  }, []);

  const roles = (rolesData && rolesData.roles) || [];
  const perms = (rolesData && rolesData.permissions) || [];

  const setCfg = (patch) => setAlerting((c) => ({ ...c, ...patch }));

  const doAddUser = async () => {
    try {
      await createUser(newUser);
      setNewUser({ username: "", password: "", role: roles.length ? roles[0].name : "viewer" });
      setUsers(await getUsers());
      flash("user created");
    } catch (e) { setError(e.message); }
  };

  const doUpdateUser = async (u, patch) => {
    try {
      await updateUser(u.id, patch);
      setUsers(await getUsers());
      flash("user updated");
    } catch (e) { setError(e.message); }
  };

  const doDeleteUser = async (u) => {
    if (!confirm(`Delete user ${u.username}?`)) return;
    try {
      await deleteUser(u.id);
      setUsers(await getUsers());
      flash("user deleted");
    } catch (e) { setError(e.message); }
  };

  const doResetPw = async (id, username) => {
    if (!resetPw || !resetPw.value) return;
    if (!confirm(`Reset password for ${username}?`)) return;
    try {
      await updateUser(id, { password: resetPw.value });
      setResetPw(null);
      setUsers(await getUsers());
      flash("password reset");
    } catch (e) { setError(e.message); }
  };

  const doAddRole = async () => {
    try {
      await createRole({ name: newRole.name, description: newRole.description, permissions: newRole.perms });
      setNewRole({ name: "", description: "", perms: [] });
      await reloadRoles();
      flash("role created");
    } catch (e) { setError(e.message); }
  };

  const doSaveRole = async (name) => {
    try {
      await updateRole(name, { permissions: editing.permissions, description: editing.description });
      await reloadRoles();
      setEditing(null);
      flash("role updated");
    } catch (e) { setError(e.message); }
  };

  const doDeleteRole = async (role) => {
    if (!confirm(`Delete role ${role.name}? Users assigned to it will fall back to viewer.`)) return;
    try {
      const r = await deleteRole(role.name);
      await reloadRoles();
      flash("role deleted" + (r.reassigned ? ` (${r.reassigned} users → viewer)` : ""));
    } catch (e) { setError(e.message); }
  };

  const togglePerm = (list, p) => list.includes(p) ? list.filter((x) => x !== p) : [...list, p];

  return html`
    <div className="page">
      <div className="page-head">
        <h2>Settings</h2>
        <div className="row">
          <button className=${tab === "users" ? "ghost active-tab" : "ghost"} onClick=${() => setTab("users")}>Users</button>
          <button className=${tab === "roles" ? "ghost active-tab" : "ghost"} onClick=${() => setTab("roles")}>Roles</button>
          <button className=${tab === "alerting" ? "ghost active-tab" : "ghost"} onClick=${() => setTab("alerting")}>Alerting</button>
        </div>
      </div>

      ${error && html`<p className="error">${error}</p>`}
      ${saved && html`<p className="ok-note">${saved}</p>`}
      ${!me && html`<p className="muted"><${Spinner} inline /> loading…</p>`}

      ${tab === "users" && (canManageUsers ? html`
        <div className="card settings-block">
          <table className="mini-table">
            <thead><tr><th>Username</th><th>Role</th><th>Status</th><th>Last login</th><th>Password</th><th></th></tr></thead>
            <tbody>
              ${(users || []).map((u) => html`
                <tr key=${u.id}>
                  <td><strong>${u.username}</strong>${u.username === me.user ? html` <span className="muted">(you)</span>` : ""}</td>
                  <td>
                    <select className="mini-select" value=${u.role} onChange=${(e) => doUpdateUser(u, { role: e.target.value })}
                      disabled=${u.role === "admin" && (users || []).filter((x) => x.role === "admin").length <= 1}>
                      ${roles.map((r) => html`<option key=${r.name} value=${r.name}>${r.name}${r.builtin ? "" : " (custom)"}</option>`)}
                    </select>
                  </td>
                  <td>
                    ${u.disabled ? html`<${Pill} cls="off">disabled</${Pill}>`
                      : html`<button className="mini" onClick=${() => doUpdateUser(u, { disabled: true })} data-tip="Disable account">disable</button>`}
                  </td>
                  <td className="muted">${u.last_login ? new Date(u.last_login).toLocaleString() : "never"}</td>
                  <td>
                    ${resetPw && resetPw.id === u.id ? html`
                      <div className="row" style=${{ gap: 4 }}>
                        <input type="password" className="mini-input" placeholder="new password" value=${resetPw.value}
                          onChange=${(e) => setResetPw({ ...resetPw, value: e.target.value })} />
                        <button className="mini" onClick=${() => doResetPw(u.id, u.username)} data-tip="Save new password">ok</button>
                        <button className="mini" onClick=${() => setResetPw(null)}>✕</button>
                      </div>`
                      : html`<button className="mini" onClick=${() => setResetPw({ id: u.id, username: u.username, value: "" })} data-tip="Reset password">reset pw</button>`}
                  </td>
                  <td>
                    ${u.username !== me.user ? html`<button className="mini" onClick=${() => doDeleteUser(u)} data-tip="Delete user">✕</button>` : ""}
                  </td>
                </tr>`)}
              ${(!users || users.length === 0) && html`<tr><td colSpan="6" className="muted">No users.</td></tr>`}
            </tbody>
          </table>
          ${users === null && html`<p className="muted"><${Spinner} inline /> loading…</p>`}

          <h4 className="sec-label">Add a user</h4>
          <div className="settings-grid">
            <label className="settings-field"><span>Username</span>
              <input placeholder="username" value=${newUser.username}
                onChange=${(e) => setNewUser({ ...newUser, username: e.target.value })} /></label>
            <label className="settings-field"><span>Password</span>
              <input type="password" placeholder="password" value=${newUser.password}
                onChange=${(e) => setNewUser({ ...newUser, password: e.target.value })} /></label>
            <label className="settings-field"><span>Role</span>
              <select value=${newUser.role} onChange=${(e) => setNewUser({ ...newUser, role: e.target.value })}>
                ${roles.map((r) => html`<option key=${r.name} value=${r.name}>${r.name}${r.builtin ? "" : " (custom)"}</option>`)}
              </select></label>
          </div>
          <div className="row" style=${{ gap: 8, marginTop: 10 }}>
            <button className="primary sm" onClick=${doAddUser}>+ Add user</button>
            ${newUser.username && html`<span className="muted">will create "${newUser.username}"</span>`}
          </div>
        </div>`
      : html`<div className="card settings-block"><p className="muted">You need the users.manage permission to manage users.</p></div>`)}

      ${tab === "roles" && (canManageUsers ? html`
        <div className="card settings-block">
          <p className="muted">Custom roles are permission sets you can assign to users. Built-in roles (viewer / operator / admin) can't be deleted.</p>

          ${(rolesData === null) ? html`<p className="muted"><${Spinner} inline /> loading…</p>` : html`
          ${roles.map((role) => {
            const isEdit = editing && editing.name === role.name;
            const perms = isEdit ? editing.permissions : role.permissions;
            return html`
            <div className="card role-card" key=${role.name}>
              <div className="row" style=${{ gap: 8, alignItems: "center", flexWrap: "wrap" }}>
                <strong>${role.name}</strong>
                ${role.builtin ? html`<${Pill} cls="env">builtin</${Pill}>` : html`<${Pill} cls="pending">custom</${Pill}>`}
                ${isEdit ? html`
                  <input className="role-desc" value=${editing.description}
                    onChange=${(e) => setEditing({ ...editing, description: e.target.value })} />`
                  : html`<span className="muted">${role.description || ""}</span>`}
                <span style=${{ flex: 1 }}></span>
                ${isEdit ? html`
                  <button className="mini" onClick=${() => doSaveRole(role.name)} data-tip="Save changes">save</button>
                  <button className="mini" onClick=${() => setEditing(null)}>cancel</button>`
                  : html`<button className="mini" onClick=${() => setEditing({ name: role.name, permissions: [...role.permissions], description: role.description })} data-tip="Edit permissions">edit</button>`}
                ${!role.builtin && !isEdit && html`<button className="mini" onClick=${() => doDeleteRole(role)} data-tip="Delete role">✕</button>`}
              </div>
              <div className="role-perms">
                ${perms.map((p) => {
                  const on = perms.includes(p);
                  return html`
                    <label className="checkline">
                      ${isEdit ? html`
                        <input type="checkbox" checked=${on}
                          onChange=${() => setEditing({ ...editing, permissions: togglePerm(editing.permissions, p) })} />`
                        : html`<input type="checkbox" checked=${on} disabled />`}
                      <span>${PERM_LABELS[p] || p}</span>
                    </label>`;
                })}
              </div>
            </div>`;
          })}
          `}

          <div className="role-new">
            <h4 className="sec-label">Create a new role</h4>
            <div className="settings-grid">
              <label className="settings-field"><span>Role name</span>
                <input placeholder="e.g. netadmin" value=${newRole.name}
                  onChange=${(e) => setNewRole({ ...newRole, name: e.target.value })} /></label>
              <label className="settings-field"><span>Description</span>
                <input placeholder="what this role is for (optional)" value=${newRole.description}
                  onChange=${(e) => setNewRole({ ...newRole, description: e.target.value })} /></label>
            </div>
            <h5 className="sec-label" style=${{ marginTop: 10 }}>Permissions</h5>
            <div className="role-perms">
              ${perms.map((p) => html`
                <label className="checkline">
                  <input type="checkbox" checked=${newRole.perms.includes(p)}
                    onChange=${() => setNewRole({ ...newRole, perms: togglePerm(newRole.perms, p) })} />
                  <span>${PERM_LABELS[p] || p}</span>
                </label>`)}
            </div>
            <div className="row" style=${{ gap: 8, marginTop: 12 }}>
              <button className="primary sm" onClick=${doAddRole}>+ Create role</button>
              ${newRole.name && html`<span className="muted">will create role "${newRole.name}"</span>`}
            </div>
          </div>
        </div>`
      : html`<div className="card settings-block"><p className="muted">You need the users.manage permission to manage roles.</p></div>`)}

      ${tab === "alerting" && html`
        <div className="card settings-block">
          ${!alerting ? html`<p className="muted"><${Spinner} inline /> loading…</p>` : html`
          <div className="settings-grid">
            <label className="settings-field">
              <span>Resource alerts (CPU/RAM)</span>
              <input type="checkbox" checked=${alerting.resource_enabled}
                onChange=${(e) => setCfg({ resource_enabled: e.target.checked })} />
            </label>
            <label className="settings-field">
              <span>Event alerts (power / jobs)</span>
              <input type="checkbox" checked=${alerting.event_enabled}
                onChange=${(e) => setCfg({ event_enabled: e.target.checked })} />
            </label>
            <label className="settings-field">
              <span>CPU warn %</span>
              <input type="number" min="1" max="100" value=${alerting.cpu_warn}
                onChange=${(e) => setCfg({ cpu_warn: Number(e.target.value) })} />
            </label>
            <label className="settings-field">
              <span>CPU critical %</span>
              <input type="number" min="1" max="100" value=${alerting.cpu_crit}
                onChange=${(e) => setCfg({ cpu_crit: Number(e.target.value) })} />
            </label>
            <label className="settings-field">
              <span>RAM warn %</span>
              <input type="number" min="1" max="100" value=${alerting.mem_warn}
                onChange=${(e) => setCfg({ mem_warn: Number(e.target.value) })} />
            </label>
            <label className="settings-field">
              <span>RAM critical %</span>
              <input type="number" min="1" max="100" value=${alerting.mem_crit}
                onChange=${(e) => setCfg({ mem_crit: Number(e.target.value) })} />
            </label>
            <label className="settings-field">
              <span>Datastore warn %</span>
              <input type="number" min="1" max="100" value=${alerting.disk_warn}
                onChange=${(e) => setCfg({ disk_warn: Number(e.target.value) })} />
            </label>
            <label className="settings-field">
              <span>Datastore critical %</span>
              <input type="number" min="1" max="100" value=${alerting.disk_crit}
                onChange=${(e) => setCfg({ disk_crit: Number(e.target.value) })} />
            </label>
            <label className="settings-field">
              <span>Host down alerts</span>
              <input type="checkbox" checked=${alerting.host_down_enabled !== false}
                onChange=${(e) => setCfg({ host_down_enabled: e.target.checked })} />
            </label>
            <label className="settings-field">
              <span>Delivery</span>
              <select value=${alerting.delivery} onChange=${(e) => setCfg({ delivery: e.target.value })}>
                <option value="bell">Bell only</option>
                <option value="email">Email only</option>
                <option value="both">Bell + email</option>
              </select>
            </label>
          </div>

          <h4 className="sec-label">SMTP</h4>
          <div className="settings-grid">
            <label className="settings-field"><span>Host</span>
              <input value=${alerting.smtp.host} onChange=${(e) => setCfg({ smtp: { ...alerting.smtp, host: e.target.value } })} /></label>
            <label className="settings-field"><span>Port</span>
              <input type="number" value=${alerting.smtp.port} onChange=${(e) => setCfg({ smtp: { ...alerting.smtp, port: Number(e.target.value) } })} /></label>
            <label className="settings-field"><span>TLS/secure</span>
              <input type="checkbox" checked=${alerting.smtp.secure} onChange=${(e) => setCfg({ smtp: { ...alerting.smtp, secure: e.target.checked } })} /></label>
            <label className="settings-field"><span>User</span>
              <input value=${alerting.smtp.user} onChange=${(e) => setCfg({ smtp: { ...alerting.smtp, user: e.target.value } })} /></label>
            <label className="settings-field"><span>Password ${alerting.smtp.password === "__set__" ? " (set — leave blank to keep)" : ""}</span>
              <input type="password" placeholder=${alerting.smtp.password === "__set__" ? "••••••" : ""}
                onChange=${(e) => setCfg({ smtp: { ...alerting.smtp, password: e.target.value } })} /></label>
            <label className="settings-field"><span>From</span>
              <input value=${alerting.smtp.from} onChange=${(e) => setCfg({ smtp: { ...alerting.smtp, from: e.target.value } })} /></label>
            <label className="settings-field"><span>To (comma separated)</span>
              <input value=${alerting.smtp.to} onChange=${(e) => setCfg({ smtp: { ...alerting.smtp, to: e.target.value } })} /></label>
          </div>

          <div className="row" style=${{ gap: 8, marginTop: 12 }}>
            ${canManageSettings ? html`
            <button className="primary sm" onClick=${async () => {
              try {
                setAlerting(await saveAlerting(alerting));
                flash("alerting settings saved");
              } catch (e) { setError(e.message); }
            }}>Save alerting settings</button>
            <button className="ghost" onClick=${async () => {
              setTestResult("");
              try {
                const r = await testAlerting();
                setTestResult(r.ok ? "✓ test email sent" : `✗ ${r.error}`);
              } catch (e) { setTestResult("✗ " + e.message); }
            }}>Send test email</button>`
            : html`<p className="muted">Read-only view — you need the settings.manage permission to modify alerting.</p>`}
            ${testResult && html`<span className="muted">${testResult}</span>`}
          </div>
          `}
        </div>`}
    </div>`;
}