// views/Shell.js — VMPilot Console v3 shell.
// WhatsApp-desktop inspired: left navigator (vCenter tree + view icons),
// a chat-style workspace thread of opened objects, and a persistent
// command bar. Compact footprint — every opened object stacks newest-at-the-bottom.
import { html, useState, useEffect, useRef, useCallback, useMemo } from "/js/core.js";
import { getInventory, getEnvStatus, getSecureTree, getMonitor, logout, getTask, me, actionLabel } from "/js/api.js";
import { VcenterPanel, EnvPanel, VmPanel } from "/js/views/Inventory.js";
import Dashboard from "/js/views/Dashboard.js";
import MonitorView from "/js/views/Monitor.js";
import EventsView from "/js/views/EventsView.js";

import VCenterWizard from "/js/views/VCenterWizard.js";
import VmConfigForm from "/js/views/VmConfigForm.js";
import CommandBar from "/js/views/CommandBar.js";
import JobThread from "/js/views/JobThread.js";
import BackupPanel from "/js/views/BackupPanel.js";
import IpamPanel from "/js/views/IpamPanel.js";
import SettingsView from "/js/views/SettingsView.js";
import EnvStatus from "/js/views/EnvStatus.js";
import TerminalView from "/js/views/Terminal.js";
import ConsoleView from "/js/views/ConsoleView.js";
import ConsolePip from "/js/views/ConsolePip.js";
import PipWindow from "/js/views/PipWindow.js";
import SecureFile from "/js/views/SecureFile.js";
import NotifyBell from "/js/views/NotifyBell.js";
import { Spinner, Pill } from "/js/components.js";

let uid = 0;
const nextId = () => `t${++uid}`;

const VIEWS = [
  { id: "dashboard", label: "Dashboard", icon: "◎" },
  { id: "monitor", label: "Inventory", icon: "◈" },
  { id: "events", label: "Events", icon: "⚡" },
  { id: "backups", label: "Backups", icon: "⌂" },
  { id: "terminal", label: "Terminal", icon: "⌘" }
];

export default function Shell({ onAuthed, onLogout }) {
  const [catalog, setCatalog] = useState([]);
  const [envStatus, setEnvStatus] = useState(null);
  const [authed, setAuthed] = useState(true);
  const [nav, setNav] = useState("dashboard"); // dashboard|monitor|events|backups|terminal|thread
  const [thread, setThread] = useState([]);    // chat stack of opened objects
  const [treeOpen, setTreeOpen] = useState({});
  const [sel, setSel] = useState({ vc: "", env: "" });   // current explorer selection (VS Code style)
  const [monitorFocus, setMonitorFocus] = useState(null);  // {vc, vm, ts} — deep-link target for Inventory
  const [refreshKey, setRefreshKey] = useState(0);
  const [search, setSearch] = useState("");
  const [wizard, setWizard] = useState(null);   // { kind: 'vc'|'vm', initial }
  const [cmdMode, setCmdMode] = useState(false);
  const [secure, setSecure] = useState([]);       // secure/ tree (per-vCenter files + per-env files)
  const [monitor, setMonitor] = useState([]);      // live power/status snapshot (per VM) for tree marking
  const [explorerTab, setExplorerTab] = useState("config"); // "config" | "secure"
  const [reloading, setReloading] = useState(false);
  const [meInfo, setMeInfo] = useState(null);
  const [consolePips, setConsolePips] = useState([]); // floating console popups {vm,name,vc,user,diskGb,min}
  const [termPip, setTermPip] = useState(false);      // global terminal popup (⌘) — same PipWindow chrome
  const [taskDeep, setTaskDeep] = useState("");       // bell deep-link → Events tab inline task-log expand
  const threadRef = useRef(null);

  const refresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  const reload = useCallback(() => {
    setReloading(true);
    refresh();
    setTimeout(() => setReloading(false), 600);
  }, [refresh]);

  // render a view safely: capture errors during render so the whole app
  // doesn't become blank when a component throws at render time.
  const safeRender = (renderFn) => {
    try { return renderFn(); }
    catch (e) { return html`<div className="error">Render error: ${e && e.message ? e.message : String(e)}</div>`; }
  };

  const renderViewOrFallback = (id, renderFn) => {
    try { return renderFn(); }
    catch (e) {
      return html`<div className="error">View "${id}" failed to render: ${e && e.message ? e.message : String(e)}
        <div className="row" style=${{ marginTop: 8 }}>
          <button className="ghost" onClick=${() => runNav("dashboard")}>Dashboard</button>
        </div>
      </div>`;
    }
  };

  useEffect(() => {
    if (!authed) return;
    getInventory().then(setCatalog).catch(() => {});
    getEnvStatus().then(setEnvStatus).catch(() => {});
    getMonitor().then((m) => setMonitor(Array.isArray(m?.vcenters) ? m.vcenters : [])).catch(() => {});
    me().then(setMeInfo).catch(() => {});
  }, [authed, refreshKey]);

  useEffect(() => {
    if (!authed) return;
    getSecureTree().then(setSecure).catch(() => {});
  }, [authed, refreshKey]);

  // auto-scroll chat thread to the newest card
  useEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [thread.length]);

  // ─── thread/object ops ─────────────────────────────────────────────
  // Same card never opens twice: if a card of the same kind AND identity
  // (vc/env/file/rel) already exists, it is replaced in place (moves to the
  // end) instead of stacking a duplicate. Different cards still stack as a
  // conversation thread.
  const openObject = useCallback((kind, sel) => {
    const card = { id: nextId(), kind, ...sel };
    const same = (c) => c.kind === kind &&
      (c.vc || "") === (card.vc || "") &&
      (c.env || "") === (card.env || "") &&
      (c.file || "") === (card.file || "") &&
      (c.vm || "") === (card.vm || "") &&
      (c.rel || "") === (card.rel || "");
    setThread((t) => [...t.filter((c) => !same(c)), card]);
    setNav("thread");
    setCmdMode(false);
  }, []);

  const openVc = (vc) => openObject("vc", { vc, env: "", file: "" });
  const openEnv = (vc, env) => openObject("env", { vc, env, file: "" });
  const openVm = (vc, env, file) => openObject("vm", { vc, env, file });
  const openBackups = () => openObject("backups", {});
  const openConsole = (vm, user) => openObject("console", { vm: vm && vm.ip, name: vm && vm.name, vc: vm && vm.vc, diskGb: vm && vm.disk_gb, user });
  // Open a floating PiP console popup (Monitor 🖥) — no navigation. Reuses the
  // same console object (same VM+user) instead of stacking duplicates.
  const openConsolePip = (vm, user) => {
    const key = `${(vm && vm.vc) || ""}/${(vm && vm.ip) || ""}/${user || "ubuntu"}`;
    setConsolePips((p) => {
      if (p.some((c) => c.key === key)) return p.map((c) => (c.key === key ? { ...c, min: false } : c));
      return [...p, { key, vm: vm && vm.ip, name: vm && vm.name, vc: vm && vm.vc, user: user || "ubuntu", diskGb: vm && vm.disk_gb, min: false }];
    });
  };
  const setPipMin = (key, min) => setConsolePips((p) => p.map((c) => (c.key === key ? { ...c, min } : c)));
  const closePip = (key) => setConsolePips((p) => p.filter((x) => x.key !== key));
  const openNotify = (a) => {
    // Job events deep-link to the Events page and auto-expand that task's log
    // INLINE (no workspace navigation — the workflow stays on the Events page).
    if (a && a.task_id) { setTaskDeep(a.task_id); setNav("events"); return; }
    // Resource alerts deep-link to Inventory, focused on the object they point at:
    //   Host*  → that host row  ·  Datastore* → that vCenter card  ·  VM* → that VM row
    if (a && a.kind === "resource" && a.vc) {
      setNav("monitor");
      const label = a.label || "";
      const isHost = label.startsWith("Host ");
      const isDs = label.startsWith("Datastore");
      setMonitorFocus({ vc: a.vc, host: isHost ? (a.vm || "") : "", vm: !isHost && !isDs ? (a.vm || "") : "", ts: Date.now() });
      return;
    }
    setNav("events");
  };
  const openIpam = (vc, env) => openObject("ipam", { vc, env });
  const openEnvStatus = () => openObject("envstatus", {});
  const openSecure = (vc, rel) => {
    setSel({ vc, env: "", file: "", secure: rel });
    openObject("secure", { vc, rel });
  };

  const closeCard = (id) => setThread((t) => t.filter((c) => c.id !== id));

  const toggle = (key) => setTreeOpen((o) => ({ ...o, [key]: !o[key] }));

  // live power/status map: key = `${vc}/${env}/${file}` → { power, ip }
  const liveMap = useMemo(() => {
    const m = {};
    for (const vcSnap of monitor || []) {
      for (const en of vcSnap.envs || []) {
        for (const vm of en.vms || []) {
          if (vm.file) m[`${vcSnap.vcenter}/${en.env}/${vm.file}`] = vm;
        }
      }
    }
    return m;
  }, [monitor]);

  const powerOf = (vc, env, file) => {
    const lv = liveMap[`${vc}/${env}/${file}`];
    return lv ? lv.power : "notDeployed";
  };

  // event → VM config resolution: event rows carry only the VM name, so build a
  // vc+name → {vc, env, file} map from the catalog for the "→ config" cross-link.
  const resolveVm = useMemo(() => {
    const m = {};
    for (const vcSnap of catalog) {
      for (const en of vcSnap.envs || []) {
        for (const vm of en.vm_configs || []) {
          if (vm.name) m[`${vcSnap.vcenter}\u0000${vm.name}`] = { vc: vcSnap.vcenter, env: en.env, file: vm.file };
        }
      }
    }
    return (vc, vmName) => (vc && vmName ? m[`${vc}\u0000${vmName}`] : null) || null;
  }, [catalog]);

  const filtered = search
    ? catalog.map((vc) => ({
        ...vc,
        envs: vc.envs.map((en) => ({
          ...en,
          vm_configs: en.vm_configs.filter((vm) =>
            (vm.name || "").toLowerCase().includes(search.toLowerCase()) ||
            (vm.summary && vm.summary.ip || "").includes(search))
        })).filter((en) => en.vm_configs.length)
      })).filter((vc) => vc.envs.length)
    : catalog;

  const fleet = catalog.reduce((a, vc) => {
    vc.envs.forEach((en) => en.vm_configs.forEach((vm) => {
      const p = powerOf(vc.vcenter, en.env, vm.file);
      if (p === "poweredOn") a.on++;
      else if (p === "poweredOff") a.off++;
      else a.none++;
    }));
    return a;
  }, { on: 0, off: 0, none: 0 });

  async function doLogout() {
    try { await logout(); } catch {}
    setAuthed(false);
    if (onLogout) onLogout();
    else if (onAuthed) onAuthed(false);
  }

  function runNav(n) {
    setWizard(null);
    setNav(n);
    setCmdMode(false);
  }

  // ⌘ Terminal: open/restore the global terminal pip (floating, same PipWindow
  // chrome as the VM console). Clicking again restores if minimized.
  const openTerminalPip = () => {
    setTermPip((t) => (!t || t === "min" ? true : t));
  };

  return html`
    <div className="shell">
      <header className="shell-bar">
        <div className="shell-brand">
          <span className="logo-mark">VM</span>
          <div>
            <div className="shell-brand-name">VMPilot</div>
            <div className="shell-brand-sub">operator console</div>
          </div>
        </div>

        <div className="shell-search">
          <input value=${search} onChange=${(e) => setSearch(e.target.value)}
            placeholder="Search VMs / IPs in all vCenters… (Press /)" />
        </div>

        <div className="shell-top-right">
          ${envStatus && html`
<button className="ghost setup-chip" data-tip="Setup status — click to open"
            onClick=${() => openObject("envstatus", {})}>
            <span className="pill ${envStatus.age_key && envStatus.tools_present ? "ok" : "pending"}">● setup</span>
            <span className="muted">state: ${envStatus.state_backend}</span>
          </button>`}
          <span className="pill fleet">● ${fleet.on} on · ${fleet.off} off · ${fleet.none} none</span>
          <${NotifyBell} onOpen=${openNotify} onOpenAll=${() => runNav("events")} />
          <button className="ghost" onClick=${reload} data-tip="Refresh inventory + secure explorer">${reloading ? "⟳" : "↻"}</button>
          <${UserMenu} me=${meInfo} nav=${nav}
            onNav=${(n) => { runNav(n); }}
            onLogout=${doLogout} />
        </div>
      </header>

      <div className="shell-body">
        <aside className="shell-nav">
          <div className="shell-nav-view-icons">
            ${VIEWS.map((v) => html`
              <button key=${v.id} className=${nav === v.id ? "nav-icon active" : "nav-icon"}
                onClick=${() => (v.id === "terminal" ? openTerminalPip() : runNav(v.id))} data-tip=${v.label}>
                <span>${v.icon}</span><small>${v.label}</small>
              </button>`)}
          </div>

          <div className="shell-tree-head">
            <div className="explorer-tabs">
              <button className=${explorerTab === "config" ? "explorer-tab active" : "explorer-tab"}
                onClick=${() => setExplorerTab("config")}
                data-tip="Config Inventory — VM configs from deploy/ (vCenter → env → VM)">
                <span className="explorer-tab-ico">🗂</span><span>Configs</span>
              </button>
              <button className=${explorerTab === "secure" ? "explorer-tab active" : "explorer-tab"}
                onClick=${() => setExplorerTab("secure")}
                data-tip="Secure — vCenter inventory + per-env policies from secure/">
                <span className="explorer-tab-ico">🔐</span><span>Secure</span>
              </button>
            </div>
            <div className="explorer-actions">
              ${explorerTab === "config" && html`
                <button className="explorer-act primary-act" data-tip="${sel.vc ? (sel.env ? "New VM config in " + sel.vc + "/" + sel.env : "New VM config in " + sel.vc + " — pick an environment") : "New VM config — pick a vCenter/environment"}"
                  onClick=${() => setWizard({ kind: "vm", initial: { vc: sel.vc, env: sel.env } })}>✚</button>`}
              <button className="explorer-act" data-tip="Refresh explorer" onClick=${reload}>${reloading ? "⟳" : "↻"}</button>
            </div>
          </div>

          ${explorerTab === "config" ? html`
          <div className="tree">
            ${filtered.map((vc) => html`
              <div key=${vc.vcenter} className="tree-node">
                <div className=${sel.vc === vc.vcenter && !sel.env && !sel.file ? "tree-item active" : "tree-item"} onClick=${() => toggle(vc.vcenter)}>
                  <span className="caret">${treeOpen[vc.vcenter] ? "▾" : "▸"}</span>
                  <span className="tree-ico">🖥</span>
                  <span className="tree-label" onClick=${(e) => { e.stopPropagation(); setSel({ vc: vc.vcenter, env: "" }); openVc(vc.vcenter); }}>${vc.vcenter}</span>
                  ${vc.envs.some((en) => en.vm_configs.some((vm) => powerOf(vc.vcenter, en.env, vm.file) === "poweredOn")) && html`<span className="pill ok">●</span>`}
                </div>
                ${treeOpen[vc.vcenter] && vc.envs.map((en) => html`
                  <div key=${en.env} className="tree-node nested">
                    <div className=${sel.vc === vc.vcenter && sel.env === en.env && !sel.file ? "tree-item active" : "tree-item"} onClick=${() => toggle(vc.vcenter + "/" + en.env)}>
                      <span className="caret">${treeOpen[vc.vcenter + "/" + en.env] ? "▾" : "▸"}</span>
                      <span className="tree-ico">📁</span>
                      <span className="tree-label" onClick=${(e) => { e.stopPropagation(); setSel({ vc: vc.vcenter, env: en.env }); openEnv(vc.vcenter, en.env); }}>${en.env}</span>
                      <small>${en.vm_configs.length}</small>
                    </div>
                    ${treeOpen[vc.vcenter + "/" + en.env] && en.vm_configs.map((vm) => {
                      const p = powerOf(vc.vcenter, en.env, vm.file);
                      const lv = liveMap[`${vc.vcenter}/${en.env}/${vm.file}`];
                      return html`
                      <div key=${vm.file} className="tree-node nested2">
                        <div className=${sel.vc === vc.vcenter && sel.env === en.env && sel.file === vm.file ? "tree-item active" : "tree-item"} onClick=${() => { setSel({ vc: vc.vcenter, env: en.env, file: vm.file }); openVm(vc.vcenter, en.env, vm.file); }}>
                          <span className="caret" style=${{ visibility: "hidden" }}>▸</span>
                          <span className="tree-ico vm-ico">${p === "poweredOn" ? "🟢" : p === "poweredOff" ? "🔴" : "⚪"}</span>
                          <span className="tree-label">${vm.name}</span>
                          <span className="tree-status ${p === "poweredOn" ? "ok" : p === "poweredOff" ? "off" : "pending"}" data-tip=${p === "poweredOn" ? `live · ${lv && lv.ip || ""}` : p === "poweredOff" ? "deployed · powered off" : "not deployed"}>${p === "poweredOn" ? "live" : p === "poweredOff" ? "off" : "new"}</span>
                          <small>${lv && lv.ip || vm.summary && vm.summary.ip || ""}</small>
                        </div>
                      </div>`;
                    })}
                  </div>`)}
              </div>`)}
            ${filtered.length === 0 && html`<div className="muted tree-empty">No VM configs yet. Add a vCenter (Secure tab → + Add vCenter), then create VMs inside an environment.</div>`}
          </div>`
          : html`
          <div className="tree">
            ${secure.map((vc) => html`
              <div key=${"sec-" + vc.vcenter} className="tree-node">
                <div className="tree-item" onClick=${() => toggle("sec-" + vc.vcenter)}>
                  <span className="caret">${treeOpen["sec-" + vc.vcenter] ? "▾" : "▸"}</span>
                  <span className="tree-ico">🛡</span>
                  <span className="tree-label">${vc.vcenter}</span>
                  ${vc.files.some((f) => f.policy) && html`<span className="pill ok">●</span>`}
                </div>
                ${treeOpen["sec-" + vc.vcenter] && html`
                  <div className="tree-node nested">
                    ${vc.files.map((f) => html`
                      <div key=${f.name} className=${sel.secure === f.name ? "tree-item active" : "tree-item"}
                        data-tip=${f.editable ? "Click to view / edit" : f.encrypted ? "encrypted — read-only" : "click to view / edit"}
                        onClick=${() => openSecure(vc.vcenter, f.name)}>
                        <span className="caret" style=${{ visibility: "hidden" }}>▸</span>
                        <span className="tree-ico">${f.encrypted ? "🔒" : f.policy ? "🔐" : "📄"}</span>
                        <span className="tree-label">${f.name}</span>
                        ${!f.editable && html`<small>ro</small>`}
                      </div>`)}
                    ${vc.envs.map((en) => html`
                      <div key=${en.env} className="tree-node nested2">
                        <div className="tree-item" onClick=${() => toggle("sec-" + vc.vcenter + "/" + en.env)}>
                          <span className="caret">${treeOpen["sec-" + vc.vcenter + "/" + en.env] ? "▾" : "▸"}</span>
                          <span className="tree-ico">📁</span>
                          <span className="tree-label">${en.env}</span>
                        </div>
                        ${treeOpen["sec-" + vc.vcenter + "/" + en.env] && en.files.map((f) => html`
                          <div key=${f.name} className=${sel.secure === en.env + "/" + f.name ? "tree-item active" : "tree-item"}
                            data-tip=${f.editable ? "Click to view / edit" : "click to view / edit"}
                            onClick=${() => openSecure(vc.vcenter, en.env + "/" + f.name)}>
                            <span className="caret" style=${{ visibility: "hidden" }}>▸</span>
                            <span className="tree-ico">${f.encrypted ? "🔒" : f.policy ? "🔐" : "📄"}</span>
                            <span className="tree-label">${f.name}</span>
                          </div>`)}
                      </div>`)}
                  </div>`}
              </div>`)}
            ${secure.length === 0 && html`<div className="muted tree-empty">No secure/ configs yet. Add a vCenter to create its inventory + policy files.</div>`}
          </div>`}
        </aside>

        <main className="shell-main">
          <div className="shell-workspace" ref=${threadRef}>
            ${wizard ? (wizard.kind === "vc"
              ? html`<${VCenterWizard} initial=${wizard.initial}
                  onDone=${(vc) => { refresh(); setWizard(null); openVc(vc); }}
                  onCancel=${() => setWizard(null)} />`
              : html`<${VmConfigForm} initial=${wizard.initial} catalog=${catalog}
                  refresh=${refresh} onDone=${(s) => { refresh(); setWizard(null); openVm(s.vc, s.env, s.file); }}
                  onCancel=${() => setWizard(null)} />`)
            : nav === "thread" ? html`
                ${thread.length === 0 && html`
                  <div className="object-empty">
                    <h2>Workspace</h2>
                    <p className="muted">Select a vCenter, environment or VM from the left navigator — it opens here as a conversation.<br/>
                      Or use the command bar below: <b>help</b> lists everything.</p>
                  </div>`}
                ${thread.map((card) => html`<${ThreadCard} key=${card.id} card=${card} catalog=${catalog}
                    refresh=${refresh} refreshKey=${refreshKey} openVc=${openVc} openEnv=${openEnv} openVm=${openVm} openBackups=${openBackups}
                    openIpam=${openIpam} openEnvStatus=${openEnvStatus}
                    onClose=${() => closeCard(card.id)} setWizard=${setWizard} />`)}
              `
            : nav === "dashboard" ? renderViewOrFallback("dashboard", () => html`<${Dashboard} onOpen=${(s) => openVm(s.vc, s.env, s.file)} refresh=${refresh} />`)
            : nav === "monitor" ? renderViewOrFallback("monitor", () => html`<${MonitorView} onOpen=${(s) => openVm(s.vc, s.env, s.file)} onConsole=${openConsolePip} onJob=${(job) => setThread((t) => [...t, { id: nextId(), kind: "job", job }])} focus=${monitorFocus} />`)
            : nav === "events" ? renderViewOrFallback("events", () => html`<${EventsView} resolveVm=${resolveVm} onOpenVm=${openVm} onHost=${(vc, host) => { setNav("monitor"); setMonitorFocus({ vc, host, ts: Date.now() }); }} onVc=${(vc) => { setNav("monitor"); setMonitorFocus({ vc, host: "", vm: "", ts: Date.now() }); }} initial=${{ openTaskId: taskDeep }} />`)
            : nav === "backups" ? renderViewOrFallback("backups", () => html`<${BackupPanel} refresh=${refresh} />`)
            : nav === "settings" ? renderViewOrFallback("settings", () => html`<${SettingsView} me=${meInfo} />`)
            : renderViewOrFallback("dashboard", () => html`<${Dashboard} onOpen=${(s) => openVm(s.vc, s.env, s.file)} refresh=${refresh} />`) }
          </div>
        </main>
      </div>

      <${CommandBar}
        catalog=${catalog}
        onOpen=${(sel) => {
          if (sel && sel.kind === "backups") return openBackups();
          if (sel && sel.kind === "ipam") return openIpam(sel.vc, sel.env);
          if (sel && sel.kind === "envstatus") return openEnvStatus();
          return sel && sel.file ? openVm(sel.vc, sel.env, sel.file) : sel && sel.env ? openEnv(sel.vc, sel.env) : sel ? openVc(sel.vc) : null;
        }}
        onWizard=${setWizard}
        onNav=${runNav}
        pushJob=${(job) => setThread((t) => [...t, { id: nextId(), kind: "job", job }])}
        onCommand=${() => setNav("thread")} />

      ${consolePips.map((c, i) => html`<${ConsolePip} key=${c.key} vm=${c.vm} name=${c.name} vc=${c.vc} user=${c.user} diskGb=${c.diskGb} index=${i}
        minimized=${c.min} onMinimize=${(m) => setPipMin(c.key, m)}
        onClose=${() => closePip(c.key)}
        onMoveWorkspace=${() => { openObject("console", { vm: c.vm, name: c.name, vc: c.vc, user: c.user, diskGb: c.diskGb }); closePip(c.key); }} />`)}

      ${termPip && html`<${PipWindow} key="term-pip" icon="⌘" title="Terminal"
        w=${680} h=${480} minW=${420} minH=${300}
        minimized=${termPip === "min"} onMinimize=${(m) => setTermPip(m ? "min" : true)}
        onClose=${() => setTermPip(false)}>
        <${TerminalView} />
      </${PipWindow}>`}

      ${(consolePips.some((c) => c.min) || termPip === "min") && html`
        <div className="pip-ribbon">
          ${consolePips.filter((c) => c.min).map((c) => html`
            <button className="pip-ribbon-item" data-tip=${`${c.name || "VM"} · ${c.vm} — click to restore`}
              onClick=${() => setPipMin(c.key, false)}>
              <span>🖥</span><span className="pip-ribbon-name">${c.name || "VM"}</span>
              <span className="pip-ribbon-ip">${c.vm}</span>
              <span className="pip-ribbon-x" data-tip="Close console (ends session)"
                onClick=${(e) => { e.stopPropagation(); closePip(c.key); }}>✕</span>
            </button>`)}
          ${termPip === "min" && html`
            <button className="pip-ribbon-item" data-tip="Terminal — click to restore"
              onClick=${() => setTermPip(true)}>
              <span>⌘</span><span className="pip-ribbon-name">Terminal</span>
              <span className="pip-ribbon-x" data-tip="Close terminal" onClick=${(e) => { e.stopPropagation(); setTermPip(false); }}>✕</span>
            </button>`}
        </div>`}
    </div>`;
}

// ─── a chat-style card in the workspace thread ────────────────────────────
function ThreadCard({ card, catalog, refresh, refreshKey, openVc, openEnv, openVm, openBackups, openIpam, openEnvStatus, onClose, setWizard }) {
  const { icon, title, direct } = kindMeta(card);
  // breadcrumbs
  const crumbs = [];
  if (card.vc) crumbs.push(html`<span className="crumb" onClick=${() => openVc(card.vc)}>${card.vc}</span>`);
  if (card.env) crumbs.push(html`<span className="crumb-sep">›</span><span className="crumb" onClick=${() => openEnv(card.vc, card.env)}>${card.env}</span>`);
  if (card.file) crumbs.push(html`<span className="crumb-sep">›</span><span className="crumb disabled">${card.file}</span>`);

  return html`
    <div className="thread-card">
      <div className="thread-card-head">
        <div className="row">
          <span className="thread-card-ico">${icon}</span>
          <span className="thread-card-title">${title}</span>
          ${card.job && html`<${Pill} cls=${card.job.status === "success" ? "ok" : card.job.status === "failed" ? "off" : "pending"}>${actionLabel(card.job.action)} · ${card.job.status}</${Pill}>`}
        </div>
        <div className="row">
          ${card.vc && html`<span className="crumbs">${crumbs}</span>`}
          <button className="mini" onClick=${onClose} data-tip="Close card">✕</button>
        </div>
      </div>

      <div className="thread-card-body">
        ${card.kind === "job" ? html`<${JobThread} job=${card.job} />`
          : direct ? direct
          : card.kind === "vc" ? html`<${VcenterPanel} vc=${card.vc} refresh=${refresh}
              onWizard=${(s) => setWizard({ kind: "vc", initial: s })}
              onVmForm=${(s) => setWizard({ kind: "vm", initial: s })}
              onOpen=${(s) => { if (s.file) openVm(s.vc, s.env, s.file); else if (s.env) openEnv(s.vc, s.env); else openVc(s.vc); }} />`
          : card.kind === "env" ? html`<${EnvPanel} vc=${card.vc} env=${card.env} detail=${catalog.find((c) => c.vcenter === card.vc)}
              refresh=${refresh} onVmForm=${(s) => setWizard({ kind: "vm", initial: s })}
              onOpen=${(s) => { if (s.file) openVm(s.vc, s.env, s.file); else openEnv(s.vc, s.env); }} />`
          : card.kind === "secure" ? html`<${SecureFile} vc=${card.vc} rel=${card.rel} refresh=${refresh} refreshKey=${refreshKey} />`
          : card.kind === "task" ? html`<${TaskCard} id=${card.id} />`
          : card.kind === "console" ? html`<${ConsoleView} vm=${card.vm} name=${card.name} vc=${card.vc} user=${card.user} diskGb=${card.diskGb} onClose=${onClose} />`
          : html`<${VmPanel} vc=${card.vc} env=${card.env} file=${card.file} refresh=${refresh}
              onVmForm=${(s) => setWizard({ kind: "vm", initial: s })} />`}
      </div>
    </div>`;
}

function kindMeta(card) {
  switch (card.kind) {
    case "vc": return { icon: "🖥", title: card.vc, direct: null };
    case "env": return { icon: "📁", title: `${card.vc}/${card.env}`, direct: null };
    case "vm": return { icon: "🧱", title: `${card.vc}/${card.env}/${card.file}`, direct: null };
    case "backups": return { icon: "💾", title: "Backups", direct: html`<${BackupPanel} />` };
    case "ipam": return { icon: "🌐", title: `${card.vc}/${card.env} · IPAM`, direct: html`<${IpamPanel} vc=${card.vc} env=${card.env} />` };
    case "envstatus": return { icon: "🖧", title: "Setup status", direct: html`<${EnvStatus} />` };
    case "secure": return { icon: "🔐", title: `secure/${card.vc}/${card.rel}`, direct: html`<${SecureFile} vc=${card.vc} rel=${card.rel} refresh=${card.refresh} refreshKey=${card.refreshKey} />` };
    case "task": return { icon: "🧰", title: `Task ${card.id ? card.id.slice(-8) : ""}`, direct: html`<${TaskCard} id=${card.id} />` };
    case "console": return { icon: "🖥", title: `Console · ${card.name || card.vm} · ${card.vm || ""}`, direct: null };
    default: return { icon: "🧱", title: "Object", direct: null };
  }
}

// A task (job) opened from Events/Tasks or a notification deep-link. Loads the
// full task record and renders its live output console (JobThread) + meta.
function TaskCard({ id }) {
  const [task, setTask] = useState(null);
  const [err, setErr] = useState("");
  useEffect(() => {
    let alive = true;
    getTask(id).then((t) => { if (alive) setTask(t.task || t); }).catch((e) => { if (alive) setErr(e.message); });
    return () => { alive = false; };
  }, [id]);
  if (err) return html`<p className="error">${err}</p>`;
  if (!task) return html`<p className="muted"><${Spinner} inline /> loading task…</p>`;
  const statusCls = task.status === "success" ? "ok" : task.status === "failed" ? "off" : "pending";
  const dur = (a, b) => a && b ? Math.max(0, Math.round((b - a) / 1000)) + "s" : "—";
  return html`
    <div className="task-card">
      <div className="row" style=${{ gap: 8, flexWrap: "wrap", marginBottom: 8 }}>
        <code>${task.action}</code>
        <${Pill} cls=${statusCls}>${task.status}</${Pill}>
        <span className="muted">by ${task.user || "—"}</span>
        <span className="muted">· ${[task.target_vc, task.target_env, task.target_vm].filter(Boolean).join(" / ") || "no target"}</span>
        <span className="muted">· ${dur(task.started_at, task.finished_at)}</span>
      </div>
      <${JobThread} job=${task} />
    </div>`;
}

// vCenter-style user menu (top-right user pill → dropdown with Settings / Logout).
// Trigger is a .ghost button like the setup chip / notify bell; dropdown reuses
// the .notify-drop panel styling for visual consistency.
function UserMenu({ me, nav, onNav, onLogout }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return;
    const h = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const esc = (e) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", h);
    document.addEventListener("keydown", esc);
    return () => { document.removeEventListener("mousedown", h); document.removeEventListener("keydown", esc); };
  }, [open]);
  if (!me) return html`<span className="pill user-pill">…</span>`;
  const go = (n) => { setOpen(false); onNav(n); };
  return html`
    <div className="user-menu" ref=${ref}>
      <button className="ghost user-menu-trigger" onClick=${() => setOpen(!open)} data-tip="Account — ${me.user} (${me.role})">
        <span>👤</span>
        <span className="user-menu-name">${me.user}</span>
        <span className="user-menu-caret">▾</span>
      </button>
      ${open && html`
        <div className="user-drop">
          <div className="user-drop-head">
            <strong>${me.user}</strong>
            <span className="muted">signed in · ${me.role}</span>
          </div>
          <button className=${nav === "settings" ? "user-drop-item active" : "user-drop-item"}
            onClick=${() => go("settings")}>
            <span className="user-drop-ico">⚙</span>
            <span>Settings</span>
          </button>
          <button className="user-drop-item danger" onClick=${onLogout}>
            <span className="user-drop-ico">⏻</span>
            <span>Logout</span>
          </button>
        </div>`}
    </div>`;
}