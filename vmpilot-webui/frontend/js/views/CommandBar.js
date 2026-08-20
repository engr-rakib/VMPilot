// views/CommandBar.js — the WhatsApp-style command input + quick chips.
// Typing a command (deploy/plan/sync/backup/status/help/…) runs a job via the
// same API as the Jobs tab. Chips are context-aware: for the just-opened or
// selected object. Keyboard: / focuses, Esc blurs, ↑ history, Enter sends.
import { html, useState, useEffect, useRef, useCallback } from "/js/core.js";
import { createJob } from "/js/api.js";

const HELP_LINES = [
  ["deploy  <vc> <env> <vm>", "deploy-vm.sh (apply, one VM)"],
  ["plan    <vc> <env> <vm>", "deploy-vm.sh --plan (dry run)"],
  ["sync    <vc> <env>",      "deploy-sync.sh (reconcile env)"],
  ["syncp   <vc> <env>",      "deploy-sync.sh plan (dry run)"],
  ["destroy <vc> <env> <vm>", "scripts/destroy.sh --yes (safe destroy, guarded)"],
  ["backup",                  "backup.sh (archive + rotate 5)"],
  ["backups",                 "list backup archives + restore"],
  ["ipam    <vc> <env>",      "next free IP + used list (IPAM)"],
  ["create  <vc> <env>",      "open the VM config wizard"],
  ["vcenter",                 "open the vCenter wizard"],
  ["status",                  "setup / environment status (read-only)"],
  ["help",                    "show this reference"]
];

// Parse a command line into { kind, action, params } or { kind: 'help' | 'error', text }
function parseCommand(line, ctx) {
  const t = String(line || "").trim().split(/\s+/).filter(Boolean);
  if (!t.length) return { kind: "error", text: "type a command — try 'help'" };
  const [cmd, ...rest] = t;

  // vCenter / env / vm can come from the command OR the current selection
  const vc = rest[0] || (ctx && ctx.vc) || "";
  const env = rest[1] || (ctx && ctx.env) || "";
  const vm = rest[2] || (ctx && ctx.vm) || "";

  switch (cmd) {
    case "deploy": case "plan": {
      const action = cmd === "deploy" ? "deploy" : "deploy-plan";
      if (!vc || !env || !vm) return { kind: "error", text: `${cmd} needs <vc> <env> <vm> — got vc:'${vc}' env:'${env}' vm:'${vm}'` };
      return { kind: "job", confirm: `${action} ${vc}/${env}/${vm}`, action, params: { vcenter: vc, env, vm_name: vm } };
    }
    case "destroy": {
      if (!vc || !env || !vm) return { kind: "error", text: `destroy needs <vc> <env> <vm> — got vc:'${vc}' env:'${env}' vm:'${vm}'` };
      return { kind: "job", confirm: `DESTROY ${vc}/${env}/${vm} (safe destroy)`, action: "destroy", params: { vcenter: vc, env, vm_name: vm }, destructive: true };
    }
    case "sync": case "syncp": {
      const action = cmd === "sync" ? "sync" : "sync-plan";
      if (!vc || !env) return { kind: "error", text: `${cmd} needs <vc> <env>` };
      return { kind: "job", confirm: `${action} ${vc}/${env}`, action, params: { vcenter: vc, env } };
    }
    case "backup":
      return { kind: "job", confirm: "backup (deploy/ + terraform/)", action: "backup", params: {} };
    case "backups":
      return { kind: "backups" };
    case "ipam": {
      if (!vc || !env) return { kind: "error", text: `ipam needs <vc> <env> — got vc:'${vc}' env:'${env}'` };
      return { kind: "ipam", vc, env };
    }
    case "create":
      if (!vc || !env) return { kind: "error", text: `create needs <vc> <env> — got vc:'${vc}' env:'${env}'` };
      return { kind: "wizard", wizard: { kind: "vm", initial: { vc, env } } };
    case "vcenter":
      return { kind: "wizard", wizard: { kind: "vc", initial: {} } };
    case "help":
      return { kind: "help" };
    case "status":
      return { kind: "status" };
    default:
      return { kind: "error", text: `unknown command '${cmd}' — type 'help'` };
  }
}

// Context-aware chips for a selected object (or empty).
function chipsFor(ctx) {
  const out = [];
  if (ctx && ctx.vm) {
    out.push({ label: `deploy ${ctx.vm}`, line: `deploy ${ctx.vc} ${ctx.env} ${ctx.vm}` });
    out.push({ label: `plan ${ctx.vm}`, line: `plan ${ctx.vc} ${ctx.env} ${ctx.vm}` });
  } else if (ctx && ctx.env) {
    out.push({ label: `sync ${ctx.env}`, line: `sync ${ctx.vc} ${ctx.env}` });
    out.push({ label: `syncp ${ctx.env}`, line: `syncp ${ctx.vc} ${ctx.env}` });
  } else if (ctx && ctx.vc) {
    out.push({ label: `sync ${ctx.vc}`, line: `sync ${ctx.vc} dev` });
  }
  out.push({ label: "backup", line: "backup" });
  out.push({ label: "backups", line: "backups" });
  out.push({ label: "status", line: "status" });
  out.push({ label: "help", line: "help" });
  return out;
}

export default function CommandBar({ catalog, onOpen, onWizard, onNav, pushJob, onCommand }) {
  const [line, setLine] = useState("");
  const [history, setHistory] = useState([]);
  const [hi, setHi] = useState(-1);              // history index
  const [status, setStatus] = useState(null);    // {kind:'ok'|'err'|'pending', text}
  const [confirm, setConfirm] = useState(null);  // { ..., action, params }
  const [busy, setBusy] = useState(false);
  const inputRef = useRef(null);

  // derive the most recent "context" from the catalog's configured VMs (latest)
  const ctx = useCallback(() => {
    const vms = catalog.flatMap((v) => v.envs.flatMap((e) => e.vm_configs.map((c) => ({ vc: v.vcenter, env: e.env, vm: c.name }))));
    const last = vms[vms.length - 1];
    return last || null;
  }, [catalog]);

const send = useCallback((raw) => {
    if (!raw || !raw.trim()) return;
    const r = parseCommand(raw, ctx());
    setStatus(null); setConfirm(null); setHi(-1);
    if (r.kind === "error") return setStatus({ kind: "err", text: r.text });
    if (r.kind === "help") { onCommand(); return setStatus({ kind: "ok", text: "see chips / type deploy|destroy|sync|backup|backups|ipam|create|vcenter|status" }); }
    if (r.kind === "status") { dropCommand(raw); if (onOpen) onOpen({ kind: "envstatus" }); onCommand(); return setStatus({ kind: "ok", text: "opened Setup status" }); }
    if (r.kind === "backups") { dropCommand(raw); if (onOpen) onOpen({ kind: "backups" }); onCommand(); return setStatus({ kind: "ok", text: "opened Backups" }); }
    if (r.kind === "ipam") { dropCommand(raw); if (onOpen) onOpen({ kind: "ipam", vc: r.vc, env: r.env }); onCommand(); return setStatus({ kind: "ok", text: `opened IPAM ${r.vc}/${r.env}` }); }
    if (r.kind === "wizard") { dropCommand(raw); onWizard(r.wizard); onCommand(); return setStatus({ kind: "ok", text: r.wizard.kind === "vc" ? "opened vCenter wizard" : `opened VM wizard for ${r.wizard.initial.vc}/${r.wizard.initial.env || ""}` }); }
    if (r.confirm) return setConfirm(r);           // wait for explicit confirm
    setHistory((h) => [raw, ...h].slice(0, 30));
  }, [ctx, onCommand, onNav, onOpen, onWizard]);

  // drop a non-job command from the datalist history so it doesn't re-run blindly
  const dropCommand = (raw) => setHistory((h) => [raw, ...h].slice(0, 30));

  const doRun = useCallback(async (r) => {
    setBusy(true); setStatus({ kind: "pending", text: `starting ${r.action}…` });
    try {
      const job = await createJob({ action: r.action, ...r.params });
      setStatus({ kind: "ok", text: `job ${job.id.slice(0, 8)}… started → streaming below` });
      setHistory((h) => [line, ...h].slice(0, 30));
      setLine(""); setConfirm(null);
      pushJob(job);
      onCommand();
    } catch (e) {
      setStatus({ kind: "err", text: e.message });
    } finally { setBusy(false); }
  }, [line, pushJob, onCommand]);

  const submit = (ev) => { ev.preventDefault(); send(line); if (confirm) doRun(confirm); else if (!confirm && line.trim()) { /* history saved on confirm */ } };
  const chips = chipsFor(ctx());

  // global / key handler
  useEffect(() => {
    const h = (e) => {
      if (e.key === "/" && document.activeElement !== inputRef.current) { e.preventDefault(); inputRef.current && inputRef.current.focus(); }
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, []);

  const onKey = (e) => {
    if (e.key === "ArrowUp") { e.preventDefault(); setHi((i) => { const n = Math.min(i + 1, history.length - 1); if (n >= 0) setLine(history[n]); return n; }); }
    else if (e.key === "ArrowDown") { e.preventDefault(); setHi((i) => { const n = Math.max(i - 1, -1); if (n === -1) setLine(""); return n; }); }
    else if (e.key === "Escape") { setConfirm(null); setStatus(null); inputRef.current && inputRef.current.blur(); }
  };

  return html`
    <div className="cmdbar" onClick=${() => inputRef.current && inputRef.current.focus()}>
      ${chips.length > 0 && html`
        <div className="cmd-chips">
          ${chips.map((c) => html`<button key=${c.label} className="chip" onClick=${() => send(c.line)}>${c.label}</button>`)}
        </div>`}

      ${status && html`<div className="cmd-status ${status.kind === "err" ? "err" : status.kind === "ok" ? "ok" : "pending"}">${status.text}</div>`}

      ${confirm ? html`
        <div className="cmd-confirm">
          <span className="muted">Run</span>
          <code>${confirm.confirm}</code>
          <button className="ghost primary-ghost" disabled=${busy} onClick=${() => doRun(confirm)}>Yes, run</button>
          <button className="ghost" onClick=${() => setConfirm(null)}>Cancel</button>
        </div>`
      : html`
        <form className="cmd-input-row" onSubmit=${submit}>
          <span className="cmd-prompt">vmpilot&gt;</span>
          <input ref=${inputRef} value=${line} onChange=${(e) => setLine(e.target.value)}
            onKeyDown=${onKey} placeholder="deploy <vc> <env> <vm> · plan · sync · backup · status · help  (press /)" autoComplete="off" spellCheck=${false} />
          <button className="primary" type="submit" disabled=${busy || !line.trim()}>Send</button>
        </form>`}

      ${!confirm && history.length > 0 && html`
        <div className="cmd-datalist">
          <input list="cmdhx" value="" aria-hidden="true" /><datalist id="cmdhx">${history.map((h) => html`<option key=${h} value=${h} />`)}</datalist>
        </div>`}
    </div>`;
}