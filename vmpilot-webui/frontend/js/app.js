// app.js — entry point: auth guard + mounts the v3 operator console (Shell).
import { React, html, useState, useEffect } from "./core.js";
import { me } from "./api.js";
import Login from "/js/views/Login.js";
import Shell from "/js/views/Shell.js";

function App() {
  const [authed, setAuthed] = useState(false);
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    let alive = true;
    me().then((u) => alive && setAuthed(Boolean(u)))
      .catch(() => alive && setAuthed(false))
      .finally(() => alive && setChecking(false));
    return () => { alive = false; };
  }, []);

  if (checking) return html`<div className="center"><span className="spinner" /> Checking session…</div>`;
  if (!authed) return html`<${Login} onSuccess=${() => setAuthed(true)} />`;

  return html`<${Shell} onAuthed=${setAuthed} onLogout=${() => setAuthed(false)} />`;
}

window.ReactDOM.createRoot(document.getElementById("root")).render(html`<${App} />`);