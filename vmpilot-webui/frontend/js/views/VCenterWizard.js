// views/VCenterWizard.js — add / edit vCenter (mirrors vcenter-setup.sh).
import { html, useState, useEffect } from "/js/core.js";
import { getVcenter, saveVcenter } from "/js/api.js";

const ENVS = ["dev", "prod", "staging"];
const hclStr = (s) => (s == null ? "" : `"${String(s).replace(/"/g, '\\"')}"`);

export default function VCenterWizard({ initial, onDone, onCancel }) {
  const edit = Boolean(initial?.vc && initial.edit);
  const [form, setForm] = useState({
    server: "", user: "", password: "",
    datacenter: "", cluster: "", resource_pool: "",
    datastore: "", network: "", template: "",
    domain: "", gateway: "", netmask: 24,
    dns_servers: "", ipam_base_ip: "", network_subnets_raw: "", network_hosts_raw: "",
    envs: [...ENVS]
  });
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");

  useEffect(() => {
    if (!edit || !initial.vc) return;
    setLoading(true);
    getVcenter(initial.vc)
      .then((d) => {
        const inv = d.inventory || {};
        const subnetsToHcl = (obj) =>
          Object.entries(obj || {})
            .map(([name, c]) => `  "${name}" = { gateway = ${hclStr(c.gateway)}, netmask = ${c.netmask ?? 24}, range_start = ${hclStr(c.range_start)}, range_end = ${hclStr(c.range_end)}, dns_servers = [${(c.dns_servers || []).map(hclStr).join(", ")}] }`)
            .join("\n");
        const hostsToHcl = (obj) =>
          Object.entries(obj || {})
            .map(([name, node]) => `  "${name}" = ${hclStr(node)}`)
            .join("\n");
        setForm({
          server: inv.server || "", user: inv.user || "", password: "",
          datacenter: inv.datacenter || "",
          cluster: inv.cluster || "", resource_pool: inv.resource_pool || "",
          datastore: inv.datastore || "", network: inv.network || "", template: inv.template || "",
          domain: inv.domain || "", gateway: inv.gateway || "", netmask: inv.netmask ?? 24,
          dns_servers: (inv.dns_servers || []).join(", "), ipam_base_ip: inv.ipam_base_ip || "",
          network_subnets_raw: subnetsToHcl(inv.network_subnets),
          network_hosts_raw: hostsToHcl(inv.network_hosts),
          envs: (d.envs || []).map((e) => (typeof e === "string" ? e : e.env))
        });
      })
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false));
  }, [edit, initial.vc]);

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const submit = async (e) => {
    e.preventDefault();
    setSaving(true); setErr(""); setMsg("");
    try {
      const payload = {
        server: form.server.trim(), user: form.user.trim(), password: form.password,
        datacenter: form.datacenter.trim(),
        cluster: form.cluster.trim(), resource_pool: form.resource_pool.trim(),
        datastore: form.datastore.trim(), network: form.network.trim(), template: form.template.trim(),
        domain: form.domain.trim(), gateway: form.gateway.trim(), netmask: Number(form.netmask) || 24,
        dns_servers: form.dns_servers.split(",").map((s) => s.trim()).filter(Boolean),
        ipam_base_ip: form.ipam_base_ip.trim(),
        network_subnets_raw: form.network_subnets_raw,
        network_hosts_raw: form.network_hosts_raw,
        envs: form.envs
      };
      const r = await saveVcenter(payload, edit ? initial.vc : "");
      setMsg((edit ? "Updated" : "Created") + " vCenter '" + r.vcenter + "'");
      setTimeout(() => onDone(r.vcenter), 800);
    } catch (err2) {
      setErr(err2.message);
    } finally {
      setSaving(false);
    }
  };

  const toggleEnv = (env) =>
    setForm((f) => ({ ...f, envs: f.envs.includes(env) ? f.envs.filter((x) => x !== env) : [...f.envs, env] }));

  if (loading) return html`<div className="page"><p className="muted"><span className="spinner inline" /> loading…</p></div>`;

  return html`
    <div className="page">
      <div className="page-head">
        <h2>${edit ? "Edit vCenter — " + initial.vc : "Add vCenter"}</h2>
        <button className="ghost" onClick=${onCancel}>Back</button>
      </div>

      <form className="wizard-form" onSubmit=${submit}>
        <div className="wizard-grid">
          <fieldset>
            <legend>vSphere connection</legend>
            <label>Server IP/FQDN *<input value=${form.server} onChange=${set("server")} placeholder="192.0.2.10" required /></label>
            <label>Username *<input value=${form.user} onChange=${set("user")} placeholder="administrator@vsphere.local" required /></label>
            <label>Password ${edit ? "(blank = keep current)" : "*"}<input type="password" value=${form.password} onChange=${set("password")} required=${!edit} /></label>
          </fieldset>

          <fieldset>
            <legend>Inventory</legend>
            <label>Datacenter *<input value=${form.datacenter} onChange=${set("datacenter")} placeholder="datacenter_pilot" required /></label>
            <p className="hint">Clusters, templates, datastores and networks are AUTO-DISCOVERED by govc when you create a VM — the fields below only CURATE those dropdown lists. Leave blank to show everything discovered.</p>
            <label>Cluster<input value=${form.cluster} onChange=${set("cluster")} placeholder="blank = auto-discover" /></label>
            <label>Resource pool<input value=${form.resource_pool} onChange=${set("resource_pool")} placeholder="blank = auto-discover (Resources)" /></label>
            <label>Datastore<input value=${form.datastore} onChange=${set("datastore")} placeholder="blank = auto-discover" /></label>
            <label>Network<input value=${form.network} onChange=${set("network")} placeholder="blank = auto-discover" /></label>
            <label>Template<input value=${form.template} onChange=${set("template")} placeholder="blank = auto-discover" /></label>
          </fieldset>

          <fieldset>
            <legend>Per-network IPAM (auto-fills gateway/netmask/IP range per VLAN)</legend>
            <label>network_subnets (HCL)
              <textarea rows="5" value=${form.network_subnets_raw} onChange=${set("network_subnets_raw")} placeholder={'  "VM Network" = { gateway = "192.0.2.1", netmask = 24, range_start = "198.51.100.106", range_end = "198.51.100.200", dns_servers = ["8.8.8.8"] }'} /></label>
            <p className="hint">One line per port group. When a VM is created on that network, gateway/netmask/IP-scan-range auto-fill. Keys must match the port-group names govc discovers.</p>
          </fieldset>

          <fieldset>
            <legend>Per-network host/node pinning</legend>
            <label>network_hosts (HCL)
              <textarea rows="4" value=${form.network_hosts_raw} onChange=${set("network_hosts_raw")} placeholder={'  "VM Network" = "esxi-node-01"'} /></label>
            <p className="hint">Maps each port group to the ESXi node it belongs to — selecting that network pins the new VM to that node (host_system_id). Leave blank = DRS auto-placement.</p>
          </fieldset>

          <fieldset>
            <legend>Network defaults (per-VM VLAN)</legend>
            <label>Domain *<input value=${form.domain} onChange=${set("domain")} placeholder="example.local" required /></label>
            <label>Gateway *<input value=${form.gateway} onChange=${set("gateway")} placeholder="192.0.2.1" required /></label>
            <label>Netmask (CIDR)<input type="number" value=${form.netmask} onChange=${set("netmask")} /></label>
            <label>DNS servers *<input value=${form.dns_servers} onChange=${set("dns_servers")} placeholder="8.8.8.8, 1.1.1.1" required /></label>
          </fieldset>

          <fieldset>
            <legend>IPAM</legend>
            <label>IPAM base IP *<input value=${form.ipam_base_ip} onChange=${set("ipam_base_ip")} placeholder="198.51.100.106" required /></label>
          </fieldset>
        </div>

        <fieldset>
          <legend>Auto-created environments</legend>
          <div className="env-toggles">
            ${ENVS.map((env) => html`
              <label key=${env} className="checkline">
                <input type="checkbox" checked=${form.envs.includes(env)} onChange=${() => toggleEnv(env)} /> ${env}
              </label>`)}
          </div>
        </fieldset>

        ${err && html`<p className="error">${err}</p>`}
        ${msg && html`<p className="ok">${msg}</p>`}

        <div className="row">
          <button className="primary" disabled=${saving}>${saving ? "Saving…" : edit ? "Save vCenter" : "Create vCenter"}</button>
          <button type="button" className="ghost" onClick=${onCancel}>Cancel</button>
        </div>
      </form>
    </div>`;
}