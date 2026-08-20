// views/Inventory.js — object views for vCenter / environment / VM config.
import { html, useState, useEffect, useRef } from "/js/core.js";
import {
  getVcenter, getVmConfig, getLiveVms, setVmPower,
  addEnv, deleteEnv, deleteVcenter, getEnvOverride, saveEnvOverride, createJob
} from "/js/api.js";
import { Pill, PowerBadge, Spinner } from "/js/components.js";
import JobThread from "/js/views/JobThread.js";

// ─── vCenter object ──────────────────────────────────────────────────────
function VcenterPanel({ vc, refresh, onWizard, onVmForm, onOpen }) {
  const [detail, setDetail] = useState(null);
  const [live, setLive] = useState([]);
  const [err, setErr] = useState("");
  const [tab, setTab] = useState("summaries");
  const [envName, setEnvName] = useState("");
  const [busy, setBusy] = useState("");

  useEffect(() => {
    if (!vc) return;
    setErr("");
    getVcenter(vc).then(setDetail).catch((e) => setErr(e.message));
    getLiveVms(vc).then(setLive).catch(() => setLive([]));
  }, [vc, refresh]);

  const doAddEnv = async () => {
    setBusy("env"); setErr("");
    try { await addEnv(vc, envName); setEnvName(""); refresh(); }
    catch (e) { setErr(e.message); } finally { setBusy(""); }
  };

  const doDelEnv = async (env) => {
    if (!confirm(`Delete environment '${env}'? All its VM configs will be removed.`)) return;
    setErr("");
    try { await deleteEnv(vc, env); refresh(); } catch (e) { setErr(e.message); }
  };

  const doPower = async (name, action) => {
    setBusy(name + ":" + action); setErr("");
    try {
      await setVmPower(vc, name, action);
      await new Promise((r) => setTimeout(r, 1500));
      const lv = await getLiveVms(vc);
      setLive(lv); refresh();
    } catch (e) { setErr(e.message); } finally { setBusy(""); }
  };

  if (!detail) return html`<div className="object-empty">${err || "Loading…"}</div>`;
  const inv = detail.inventory || {};
  const invRows = [["Datacenter", inv.datacenter], ["Cluster", inv.cluster], ["Resource pool", inv.resource_pool],
    ["Datastore", inv.datastore], ["Network", inv.network], ["Template", inv.template],
    ["Domain", inv.domain], ["Gateway", inv.gateway], ["Netmask", inv.netmask],
    ["DNS", (inv.dns_servers || []).join(", ")], ["IPAM base", inv.ipam_base_ip]];
  const powerOf = (name) => live.find((v) => v.name === name);

  return html`
    <div className="object-view">
      <div className="object-head">
        <div>
          <h2>🖥 ${vc}</h2>
          <div className="muted">${detail.has_credentials ? "credentials encrypted ✔" : "⚠ no credentials — deploy will fail"}</div>
        </div>
        <div className="row">
          <button className="ghost" onClick=${() => onWizard({ vc, edit: true })}>Edit</button>
          <button className="ghost" onClick=${() => onVmForm({ vc })}>+ New VM</button>
          <button className="ghost danger" disabled=${busy === "del"} onClick=${async () => {
            if (!confirm(`Remove vCenter '${vc}' entirely (deploy/ + secure/)? This deletes credentials.`)) return;
            setBusy("del");
            try { await deleteVcenter(vc); refresh(); onOpen({ vc: "", env: "", file: "" }); }
            catch (e) { setErr(e.message); } finally { setBusy(""); }
          }}>Remove</button>
        </div>
      </div>

      ${err && html`<p className="error">${err}</p>`}

      <div className="tabs-row">
        <button className=${tab === "summaries" ? "tab active" : "tab"} onClick=${() => setTab("summaries")}>Inventories</button>
        <button className=${tab === "vms" ? "tab active" : "tab"} onClick=${() => setTab("vms")}>VMs</button>
        <button className=${tab === "envs" ? "tab active" : "tab"} onClick=${() => setTab("envs")}>Environments</button>
      </div>

      ${tab === "summaries" && html`
        <div className="kv-grid card">
          ${invRows.map(([k, val]) => html`<div className="kv" key=${k}><span className="kv-k">${k}</span><span className="kv-v">${val || "—"}</span></div>`)}
        </div>`}

      ${tab === "vms" && html`
        <div className="card">
          <table className="mini-table">
            <thead><tr><th>VM</th><th>Env</th><th>IP</th><th>vCPU</th><th>RAM</th><th>Disk</th><th>Power</th><th>Actions</th></tr></thead>
            <tbody>
              ${detail.envs.flatMap((e) => e.vm_configs.map((vm) => {
                const p = powerOf(vm.name);
                const power = p ? p.power : "poweredOff";
                return html`<tr key=${e.env + "-" + vm.file}>
                  <td><a href="#" onClick=${(ev) => { ev.preventDefault(); onOpen({ vc, env: e.env, file: vm.file }); }}>${vm.name}</a></td>
                  <td><${Pill} cls="env">${e.env}</${Pill}></td>
                  <td>${p ? (p.ip || vm.summary?.ip || "—") : (vm.summary?.ip || "—")}</td>
                  <td>${vm.summary?.cpu ?? p?.cpu ?? "—"}</td>
                  <td>${vm.summary?.memory_mb ? (vm.summary.memory_mb / 1024).toFixed(1) + " GB" : "—"}</td>
                  <td>${vm.summary?.disk_gb ? vm.summary.disk_gb + " GB" : "—"}</td>
                  <td><${PowerBadge} power=${power} /></td>
                  <td><div className="row">
                    ${power !== "poweredOn" && html`<button className="ghost" disabled=${!!busy} onClick=${() => doPower(vm.name, "on")}>On</button>`}
                    ${power === "poweredOn" && html`<button className="ghost danger" disabled=${!!busy} onClick=${() => doPower(vm.name, "off")}>Off</button>`}
                    <button className="ghost" disabled=${!!busy} onClick=${() => doPower(vm.name, "reset")}>Reset</button>
                  </div></td>
                </tr>`;
              }))}
            </tbody>
          </table>
        </div>`}

      ${tab === "envs" && html`
        <div className="card">
          <div className="row env-add">
            <input value=${envName} onChange=${(e) => setEnvName(e.target.value)} placeholder="new-env (e.g. qa)" />
            <button className="ghost" disabled=${busy === "env" || !envName} onClick=${doAddEnv}>+ Add env</button>
          </div>
          <table className="mini-table">
            <thead><tr><th>Environment</th><th>Configs</th><th>Actions</th></tr></thead>
            <tbody>
              ${detail.envs.map((e) => html`<tr key=${e.env}>
                <td><a href="#" onClick=${(ev) => { ev.preventDefault(); onOpen({ vc, env: e.env, file: "" }); }}>${e.env}</a></td>
                <td>${e.vm_configs.length}</td>
                <td><button className="ghost danger" onClick=${() => doDelEnv(e.env)}>Delete</button></td>
              </tr>`)}
            </tbody>
          </table>
        </div>`}
    </div>`;
}

// ─── Environment object ──────────────────────────────────────────────────
function EnvPanel({ vc, env, detail, refresh, onVmForm, onOpen }) {
  const [override, setOverride] = useState(null);
  const [overrideText, setOverrideText] = useState("");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");
  const [live, setLive] = useState([]);

  const envObj = detail?.envs?.find((e) => e.env === env);

  useEffect(() => {
    if (!vc || !env) return;
    getEnvOverride(vc, env).then((d) => { setOverride(d); setOverrideText(d.raw); }).catch((e) => setErr(e.message));
  }, [vc, env]);

  // live power for the VM table — monitor snapshot is authoritative, not
  // vm.summary.power (which is never populated). Refetch on refresh too.
  useEffect(() => {
    if (!vc) return;
    getLiveVms(vc).then(setLive).catch(() => setLive([]));
  }, [vc, refresh]);

  const saveOverride = async () => {
    setSaving(true); setErr(""); setMsg("");
    try {
      await saveEnvOverride(vc, env, overrideText);
      setMsg("Saved — per-env values now override the top-level inventory.");
      refresh();
    } catch (e) { setErr(e.message); } finally { setSaving(false); }
  };

  if (!envObj) return html`<div className="object-empty">Environment not found</div>`;

  return html`
    <div className="object-view">
      <div className="object-head">
        <div><h2>📁 ${env}</h2><div className="muted">${vc}</div></div>
        <div className="row">
          <button className="ghost" onClick=${() => onVmForm({ vc, env })}>+ New VM</button>
        </div>
      </div>

      <div className="card">
        <table className="mini-table">
          <thead><tr><th>VM</th><th>IP</th><th>vCPU</th><th>RAM</th><th>Disk</th><th>Power</th></tr></thead>
          <tbody>
            ${envObj.vm_configs.map((vm) => html`<tr key=${vm.file}>
              <td><a href="#" onClick=${(ev) => { ev.preventDefault(); onOpen({ vc, env, file: vm.file }); }}>${vm.name}</a></td>
              <td>${vm.summary?.ip || "—"}</td>
              <td>${vm.summary?.cpu ?? "—"}</td>
              <td>${vm.summary?.memory_mb ? (vm.summary.memory_mb / 1024).toFixed(1) + " GB" : "—"}</td>
              <td>${vm.summary?.disk_gb ? vm.summary.disk_gb + " GB" : "—"}</td>
              <td><${PowerBadge} power=${live.find((v) => v.name === vm.name)?.power || "notDeployed"} /></td>
            </tr>`)}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h3>Per-env overrides <span className="muted">(secure/${vc}/${env}/vcenter.tfvars)</span></h3>
        <p className="muted">Uncomment a key to make this environment use a different value than the top-level vCenter inventory.</p>
        ${err && html`<p className="error">${err}</p>`}
        ${msg && html`<p className="ok">${msg}</p>`}
        ${override !== null && html`
          <textarea className="code-edit" rows=${16} value=${overrideText} onChange=${(e) => setOverrideText(e.target.value)} spellCheck=${false} />
          <div className="row"><button className="ghost" disabled=${saving} onClick=${saveOverride}>${saving ? "Saving…" : "Save overrides"}</button></div>
        `}
      </div>
    </div>`;
}

// ─── VM config object ────────────────────────────────────────────────────
function VmPanel({ vc, env, file, refresh, onVmForm }) {
  const [cfg, setCfg] = useState(null);
  const [live, setLive] = useState([]);
  const [err, setErr] = useState("");
  const [tab, setTab] = useState("summary");
  const [deploying, setDeploying] = useState(false);
  const [jobMsg, setJobMsg] = useState("");
  const [destroyName, setDestroyName] = useState("");
  const [redeployName, setRedeployName] = useState("");  // typed-name to arm re-deploy of a deployed VM
  const [activeJob, setActiveJob] = useState(null);   // inline JobThread for deploy/plan/sync
  const [powerMsg, setPowerMsg] = useState("");       // transient power-op feedback
  const [powerBusy, setPowerBusy] = useState(false);  // spinner while govc call runs

  useEffect(() => {
    if (!vc || !env || !file) return;
    setErr("");
    getVmConfig(vc, env, file).then(setCfg).catch((e) => setErr(e.message));
    getLiveVms(vc).then(setLive).catch(() => setLive([]));
  }, [vc, env, file, refresh]);

  const nameFromFile = file.replace(/^vm-/, "").replace(/_\d+\.\d+\.\d+\.\d+\.tfvars$/, "");
  const power = live.find((v) => v.name === nameFromFile)?.power || cfg?.summary?.power;
  const alreadyDeployed = power === "poweredOn" || power === "poweredOff";

  if (!cfg) return html`<div className="object-empty">${err || "Loading…"}</div>`;
  const vm = Object.values(cfg.vm_configs || {})[0] || {};
  const key = Object.keys(cfg.vm_configs || {})[0] || cfg.summary?.name || file;

  const startJob = async (action) => {
    setDeploying(true); setErr(""); setJobMsg("");
    if (action === "deploy" && alreadyDeployed && redeployName !== key) {
      setErr(`"${key}" is already deployed (${power}). Type its name below to arm re-deploy.`);
      setDeploying(false);
      return;
    }
    try {
      const job = await createJob({ action, vcenter: vc, env, vm_name: key });
      setJobMsg("");
      setActiveJob(job);
      setRedeployName("");
      if (action !== "deploy-plan") {
        // plan is quick; apply/sync change VM state → refresh live power when done
        setTimeout(() => { refresh(); getLiveVms(vc).then(setLive).catch(() => {}); }, 1500);
      }
    } catch (e) { setErr(e.message); }
    finally { setDeploying(false); refresh(); }
  };

  const startDestroy = async () => {
    if (destroyName !== key) { setErr(`Type "${key}" to confirm destroy — this is permanent.`); return; }
    setErr(""); setDeploying(true); setJobMsg("");
    try {
      // The job runs scripts/destroy.sh --yes (guarded on the CLI too); the
      // state is backed up to backups/pre-destroy-* before anything changes.
      const job = await createJob({ action: "destroy", vcenter: vc, env, vm_name: key });
      setJobMsg("Destroy job " + job.id.slice(0, 8) + "… started → Jobs tab for live output. State is backed up first.");
      setDestroyName("");
    } catch (e) { setErr(e.message); }
    finally { setDeploying(false); refresh(); }
  };

  const powerNow = async (action) => {
    setErr(""); setPowerMsg(""); setPowerBusy(true);
    const target = action === "on" ? "poweredOn" : "poweredOff";
    const human = action === "on" ? "powered on" : "powered off";
    try {
      const res = await setVmPower(vc, key, action);
      if (res && res.already) {
        setPowerMsg(`VM is already ${human}.`);
        setPowerBusy(false);
        return;
      }
      setPowerMsg(`Power ${action} requested — waiting for VM to be ${human}…`);
      // Poll the live state until the VM actually reaches the target power.
      // The inventory script keeps a ~11s cache, so a poll right after a change
      // can still return the old value; keep going until it flips (or timeout).
      const deadline = Date.now() + 90000;
      const check = async () => {
        try {
          const vms = await getLiveVms(vc);
          setLive(vms);
          const cur = vms.find((v) => v.name === nameFromFile)?.power;
          if (cur === target) {
            setPowerMsg(`VM is ${human}.`);
            setPowerBusy(false);
            refresh();
            return;
          }
          if (Date.now() > deadline) {
            setPowerMsg(`Power ${action} command sent — VM state update pending (${human}).`);
            setPowerBusy(false);
            refresh();
            return;
          }
          setTimeout(check, 4000);
        } catch {
          setTimeout(check, 4000);
        }
      };
      setTimeout(check, 4000);
    } catch (e) { setErr(e.message); setPowerBusy(false); }
  };

  return html`
    <div className="object-view">
      <div className="object-head">
        <div>
          <h2>🧱 ${key}</h2>
          <div className="muted">${vc} · ${env} · ${file}
            <span className="pill ${power === "poweredOn" ? "ok" : power === "poweredOff" ? "off" : "pending"}">${power === "poweredOn" ? "live" : power === "poweredOff" ? "off" : "not deployed"}</span>
          </div>
        </div>
        <div className="row">
          ${powerMsg && html`<span className="pill ok">${powerMsg}</span>`}
          ${powerBusy && html`<${Spinner} inline />`}
          ${power !== "poweredOn" && html`<button className="ghost" disabled=${powerBusy} onClick=${() => powerNow("on")}>${powerBusy ? "…" : "Power on"}</button>`}
          ${power === "poweredOn" && html`<button className="ghost danger" disabled=${powerBusy} onClick=${() => powerNow("off")}>${powerBusy ? "…" : "Power off"}</button>`}
          <button className="ghost primary-ghost" onClick=${() => onVmForm({ vc, env, file })}>Edit config</button>
        </div>
      </div>

      ${err && html`<p className="error">${err}</p>`}

      <div className="tabs-row">
        ${[["summary", "Summary"], ["config", "Configuration"], ["deploy", "Deploy / Ops"], ["raw", "Raw config"]].map(([id, label]) =>
          html`<button key=${id} className=${tab === id ? "tab active" : "tab"} onClick=${() => setTab(id)}>${label}</button>`)}
      </div>

      ${tab === "summary" && html`
        <div className="kv-grid card">
          ${[["Hostname", vm.hostname], ["Domain", vm.domain], ["IP", vm.ip_address || cfg.summary?.ip || "—"],
            ["Gateway", vm.gateway], ["Netmask", vm.netmask], ["DNS", (vm.dns_servers || []).join(", ")],
            ["vCPU", vm.cpu], ["Memory", vm.memory ? (vm.memory / 1024).toFixed(1) + " GB" : "—"],
            ["OS disk", vm.disk_size ? vm.disk_size + " GB" : "—"], ["Firmware", vm.firmware],
            ["Thin / eager", (vm.thin_provisioned ? "thin" : "thick") + (vm.eagerly_scrub ? " (eager)" : "")],
            ["CPU hot-add", vm.enable_cpu_hot_add ? "yes" : "no"], ["RAM hot-add", vm.enable_memory_hot_add ? "yes" : "no"],
            ["Auto-updates", vm.disable_auto_updates ? "disabled" : "enabled"],
            ["node_exporter", vm.enable_node_exporter ? "enabled" : "off"]]
            .map(([k, val]) => html`<div className="kv" key=${k}><span className="kv-k">${k}</span><span className="kv-v">${String(val)}</span></div>`)}
        </div>
        <div className="dash-columns">
          <div className="card dash-panel">
            <h3>OS partitions (${Array.isArray(vm.os_partitions) ? vm.os_partitions.length : 0})</h3>
            <table className="mini-table">
              <thead><tr><th>Mount</th><th>Size</th><th>LV</th><th>FS</th></tr></thead>
              <tbody>
                ${(vm.os_partitions || []).map((p, i) => html`<tr key=${i}><td>${p.mount_point === "swap" ? "swap" : p.mount_point}</td><td>${p.size}</td><td>${p.lv_name || "—"}</td><td>${p.filesystem || "xfs"}</td></tr>`)}
                ${!(vm.os_partitions || []).length && html`<tr><td colSpan="4" className="muted">None</td></tr>`}
              </tbody>
            </table>
          </div>
          <div className="card dash-panel">
            <h3>Data disks &amp; LVM</h3>
            ${(vm.data_disks || []).map((d, i) => html`<div className="kv" key=${i}><span className="kv-k">${d.label} disk</span><span className="kv-v">${d.size} GB ${d.thin_provisioned ? "thin" : "thick"}</span></div>`)}
            ${(vm.lvm_config || []).map((l, i) => html`<div className="kv" key=${i}><span className="kv-k">${l.lv_name}</span><span className="kv-v">${l.lv_size} → ${l.mount_point} (${l.filesystem})</span></div>`)}
            ${!(vm.data_disks || []).length && !(vm.lvm_config || []).length && html`<p className="muted">No data disks configured.</p>`}
          </div>
        </div>`}

      ${tab === "config" && html`<pre className="code-block">${JSON.stringify(vm, null, 2)}</pre>`}

      ${tab === "deploy" && html`
        <div className="card">
          <div className="row" style=${{ alignItems: "center", gap: 10, marginBottom: 8 }}>
            <h3 style=${{ margin: 0 }}>Deploy / Ops</h3>
            <${PowerBadge} power=${alreadyDeployed ? power : "notDeployed"} />
            ${alreadyDeployed && html`<span className="muted">already deployed — re-deploy is guarded</span>`}
          </div>
          <p className="muted">Run the VMPilot CLI scripts against this VM — only <b>${key}</b> is targeted, other VMs in the state are never touched.</p>
          ${err && html`<p className="error">${err}</p>`}

          ${alreadyDeployed && html`
            <div className="redeploy-warn">
              <b>⚠ This VM is already deployed (${power === "poweredOn" ? "currently live" : "powered off"}).</b><br/>
              Re-running <b>Deploy (apply)</b> will re-apply Terraform against the existing VM — it can re-provision disks,
              rewrite cloud-init and disrupt the running workload. If you only want to fix config, prefer
              <b>Plan only</b> first, then re-deploy only if the plan shows the intended change.<br/>
              To arm re-deploy, type the VM name <b>${key}</b> below:
              <div className="row restore-row">
                <input value=${redeployName} onChange=${(e) => setRedeployName(e.target.value)}
                  placeholder="type ${key} to enable re-deploy" />
                <span className="pill ${redeployName === key ? "ok" : "pending"}">${redeployName === key ? "armed" : "locked"}</span>
              </div>
            </div>`}

          <div className="row">
            <button className="ghost primary-ghost" disabled=${deploying || (alreadyDeployed && redeployName !== key)}
              data-tip=${alreadyDeployed && redeployName !== key ? "type the VM name to arm re-deploy" : "deploy (apply)"}
              onClick=${() => startJob("deploy")}>${deploying ? "…" : "Deploy (apply)"}</button>
            <button className="ghost" disabled=${deploying} onClick=${() => startJob("deploy-plan")}>Plan only</button>
            <button className="ghost" disabled=${deploying} onClick=${() => startJob("sync")}>Sync env</button>
          </div>
        </div>

        ${activeJob && html`<div className="card"><${JobThread} job=${activeJob} /></div>`}

        <div className="card destroy-card">
          <h3>Destroy <span className="pill off">protected</span></h3>
          <p className="muted"><b>Safe destroy</b> (README §9): removes the VM from Terraform state and deletes it in vCenter via <code>scripts/destroy.sh</code>. The state file is backed up to <code>backups/pre-destroy-*</code> first. Type the VM name to arm the button — the CLI additionally requires DESTROY confirmation.</p>
          ${destroyName === key ? html`
            <div className="row restore-row">
              <input value=${destroyName} onChange=${(e) => setDestroyName(e.target.value)} placeholder="type ${key} to confirm" />
              <button className="ghost danger" disabled=${deploying} onClick=${() => startDestroy()}>Confirm destroy ${key}</button>
              <button className="ghost" onClick=${() => setDestroyName("")}>✕</button>
            </div>`
          : html`<button className="ghost danger" onClick=${() => { setDestroyName(key); setErr(""); }}>Destroy this VM…</button>`}
        </div>`}

      ${tab === "raw" && html`<pre className="code-block">${cfg.raw}</pre>`}
    </div>`;
}

// ─── Router ──────────────────────────────────────────────────────────────
export { VcenterPanel, EnvPanel, VmPanel };