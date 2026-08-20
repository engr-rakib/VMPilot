// views/Login.js
import { html, useState } from "/js/core.js";
import { login } from "/js/api.js";

export default function Login({ onSuccess }) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      await login(username.trim(), password);
      onSuccess();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return html`
    <div className="login-wrap">
      <form className="login-card" onSubmit=${submit} autoComplete="off">
        <div className="logo">
          <span className="logo-badge">VP</span>
          <h1>VMPilot Console</h1>
          <p className="sub">vSphere Automation — VMPilot Console</p>
        </div>
        <label>
          Username
          <input value=${username} onChange=${(e) => setUsername(e.target.value)} autoFocus autoComplete="username" required />
        </label>
        <label>
          Password
          <input type="password" value=${password} onChange=${(e) => setPassword(e.target.value)} autoComplete="current-password" required />
        </label>
        ${error && html`<p className="error">${error}</p>`}
        <button type="submit" disabled=${busy}>${busy ? "Signing in…" : "Sign in"}</button>
      </form>
    </div>`;
}