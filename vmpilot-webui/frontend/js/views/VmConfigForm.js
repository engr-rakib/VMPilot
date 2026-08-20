// views/VmConfigForm.js — create / edit VM config (mirrors create-vm-config.sh).
// Shell passes `initial = { vc, env, file? }` (file present ⇒ edit), calls
// `onDone({ vc, env, file })` after save. Network + vCenter resource defaults
// auto-discover: gateway/dns from the effective inventory, datacenter/cluster/
// datastore/network/template from govc (dropdown when multiple, auto-filled
// when exactly one).
import { html, useState, useEffect } from "/js/core.js";
import { getVmConfig, getEnvOverride, createVmConfig, updateVmConfig, findFreeIp, getVcenterOptions, getProjectSshKey } from "/js/api.js";

const DEFAULT_PARTS = "/:10,/home:5,/var:15,/tmp:2";

// ─── IP helpers (mirror create-vm-config.sh ip_add / ip_last_usable) ─────
const ipToInt = (ip) => {
  const p = String(ip || "").split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isFinite(n))) return -1;
  return (((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]) >>> 0);
};
const intToIp = (n) => `${(n >>> 24) & 255}.${(n >>> 16) & 255}.${(n >>> 8) & 255}.${n & 255}`;
// Default IPAM range for a gateway: start = gateway+1, end = broadcast−1 (last
// usable host). Explicit network_subnets range_start/range_end always WIN.
const deriveRange = (gateway, netmask) => {
  const prefix = Number(netmask);
  const p = Number.isInteger(prefix) && prefix >= 0 && prefix <= 32 ? prefix : 24;
  const gw = ipToInt(gateway);
  if (gw < 0) return { start: "", end: "" };
  const hostmask = p >= 32 ? 0 : (1 << (32 - p)) - 1;
  const bcast = (gw | hostmask) >>> 0;
  return { start: intToIp(gw + 1), end: intToIp(bcast - 1) };
};

export default function VmConfigForm({ initial, catalog, refresh, onDone, onCancel }) {
  const vc = (initial && initial.vc) || "";
  const env = (initial && initial.env) || "";
  const file = (initial && initial.file) || "";
  const edit = Boolean(vc && env && file);

  const [form, setForm] = useState({
    vm_name: "", hostname: "", domain: "", annotation: "", os: "ubuntu-24.04",
    ip: "", netmask: 24, gateway: "", dns_servers: "", ipam_base_ip: "",
    ipam_range_end: "",
    memory: 4, vcpu: 2, disk_size: 40, disk_type: "thin",
    firmware: "efi", cpu_hot: true, mem_hot: true, resource_pool: "Resources",
    boot_size: "500M", os_parts: "/:10,/home:5,/var:15,/tmp:2",
    data_disk_gb: "", data_disk_type: "thin",
    public_key: "", extra_users: "", disable_auto_updates: true,
    datacenter: "", cluster: "", datastore: "", vlan: "", host: ""
  });
  // ─── vCenter inventory = CACHED file (secure/<vc>/vcenter.tfvars) ─────
  // No live govc discovery at VM-create time: the CLI and Web UI read the same
  // file (written once by vcenter-setup.sh), so both always agree.
  const [pick, setPick] = useState({ vc, env });   // chosen target when creating from the global button
  const [disc, setDisc] = useState(null);          // { dcs, dc, items, loading, error }
  const [opts, setOpts] = useState(null);          // curated file options (inventoryOptions)
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const [msg, setMsg] = useState("");

  const chosenVc = pick.vc || vc;
  const chosenEnv = pick.env || env;

  // curated file options (secure/<vc>/vcenter.tfvars lists + legacy singles).
  // Populates the dropdowns directly — items come from the cached inventory.
  useEffect(() => {
    if (!chosenVc) return;
    let alive = true;
    setDisc((d) => ({ ...(d || {}), loading: true, error: "" }));
    getVcenterOptions(chosenVc)
      .then((o) => {
        if (!alive) return;
        const inv = o || {};
        setOpts(inv);
        setDisc({
          dcs: inv.datacenters || [],
          dc: inv.datacenter || (inv.datacenters && inv.datacenters[0]) || "",
          items: inv.items || {},
          loading: false,
          error: ""
        });
        setForm((f) => ({ ...f, datacenter: f.datacenter || inv.datacenter || "" }));
      })
      .catch((e) => { if (alive) setDisc((d) => ({ ...(d || {}), loading: false, error: e.message })); });
    return () => { alive = false; };
  }, [chosenVc]);

  // project's shared SSH public key → auto-fill in create mode when empty
  useEffect(() => {
    if (edit) return;
    let alive = true;
    getProjectSshKey()
      .then((d) => {
        if (!alive || !d.ssh_public_key) return;
        setForm((f) => ({ ...f, public_key: f.public_key || d.ssh_public_key }));
      })
      .catch(() => {});
    return () => { alive = false; };
  }, [edit]);

  // single-option cached inventory → auto-fill (mirrors create-vm-config.sh)
  useEffect(() => {
    if (edit || !opts || !disc || !disc.items) return;
    const first = (arr, cur) => arr && arr.length === 1 ? arr[0] : (cur || (arr && arr[0]) || "");
    setForm((f) => ({
      ...f,
      cluster: first(disc.items.clusters, f.cluster),
      datastore: first(disc.items.datastores, f.datastore),
      vlan: first(disc.items.networks, f.vlan),
      os: first(disc.items.templates, f.os),
      resource_pool: first(disc.items.resource_pools, f.resource_pool || "Resources")
    }));
  }, [edit, disc && disc.items, opts]);

  // network defaults from effective inventory (top-level + per-env override)
  useEffect(() => {
    let alive = true;
    if (!chosenVc) return;
    getEnvOverride(chosenVc, chosenEnv)
      .then((d) => {
        const eff = (d && d.effective) || {};
        setForm((f) => ({
          ...f,
          gateway: f.gateway || eff.gateway || "",
          dns_servers: f.dns_servers || (eff.dns_servers && eff.dns_servers.join ? eff.dns_servers.join(", ") : ""),
          netmask: f.netmask || eff.netmask || 24,
          ipam_base_ip: f.ipam_base_ip || eff.ipam_base_ip || "",
          vlan: f.vlan || eff.network || "",
          cluster: f.cluster || eff.cluster || "",
          datastore: f.datastore || eff.datastore || "",
          datacenter: f.datacenter || eff.datacenter || "",
          resource_pool: f.resource_pool || eff.resource_pool || "Resources",
          domain: f.domain || eff.domain || ""
        }));
      })
      .catch(() => {});
    return () => { alive = false; };
  }, [chosenVc, chosenEnv]);

  useEffect(() => {
    if (!edit) return;
    setLoading(true);
    getVmConfig(vc, env, file)
      .then((d) => {
        const v = Object.values(d.vm_configs || {})[0] || {};
        const t = d.top || {};
        setForm({
          vm_name: Object.keys(d.vm_configs || {})[0] || d.summary?.name || "",
          hostname: v.hostname || "",
          domain: v.domain || t.domain || "",
          annotation: v.annotation || "",
          os: v.template || t.template || "ubuntu-24.04",
          ip: v.ip_address || d.summary?.ip || "",
          netmask: v.netmask ?? 24,
          gateway: v.gateway || "",
          dns_servers: (v.dns_servers || []).join(", "),
          ipam_base_ip: t.ipam_base_ip || "",
          memory: v.memory ? Math.round((v.memory || 0) / 1024) : 4,
          vcpu: v.cpu ?? 2,
          disk_size: v.disk_size ?? 40,
          disk_type: v.eagerly_scrub ? "eager" : (v.thin_provisioned ? "thin" : "thick"),
          firmware: v.firmware || "efi",
          cpu_hot: v.enable_cpu_hot_add !== false,
          mem_hot: v.enable_memory_hot_add !== false,
          resource_pool: t.resource_pool || "Resources",
          boot_size: (v.boot_size ? String(v.boot_size).toUpperCase() : "500M"),
          os_parts: (v.os_partitions || []).map((p) => `${p.mount_point}:${(p.size || "").replace(/G$/i, "")}`).join(","),
          data_disk_gb: ((v.data_disks || [])[0] && (v.data_disks[0].size || "")) || "",
          data_disk_type: (v.data_disks || [])[0] ? ((v.data_disks[0].eagerly_scrub ? "eager" : (v.data_disks[0].thin_provisioned ? "thin" : "thick"))) : "thin",
          public_key: t.ssh_public_key || "",
          extra_users: (v.extra_users || []).map((u) => u.username).join(", "),
          disable_auto_updates: v.disable_auto_updates !== false,
          datacenter: t.datacenter || v.datacenter || "",
          cluster: t.cluster || v.cluster || "",
          datastore: t.datastore || v.datastore || "",
          vlan: v.network || t.network || "",
          host: v.host || ""
        });
        setDisc((d) => ({ ...(d || {}), dc: t.datacenter || "" }));
      })
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false));
  }, [edit, vc, env, file]);

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const setBool = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.checked }));

  // When a network/port group is selected, pull that network's IPAM block
  // (gateway/netmask/scan base/DNS) from the configured network_subnets map and
  // auto-fill. Mirrors create-vm-config.sh §2: a port-group entry WINS over the
  // vCenter-wide defaults. If the network has NO entry (brand-new, added since
  // the file was written) the range is DERIVED from the gateway: start = gw+1,
  // end = broadcast−1. Missing range_start/range_end in an entry are defaulted
  // the same way; an explicit range and any operator-typed value are kept.
  const onNetworkChange = (e) => {
    const net = e.target.value;
    const subs = (opts && opts.network_subnets) || {};
    const cfg = subs[net] || {};
    const old = subs[form.vlan] || {};
    // Gateway + netmask: per-network entry wins, else vCenter-wide defaults.
    const gateway = cfg.gateway || ((opts && opts.gateway) || "");
    const netmask = cfg.netmask != null ? cfg.netmask : (opts && opts.netmask != null ? opts.netmask : 24);
    const derived = deriveRange(gateway, netmask);
    const rangeStart = cfg.ipam_base || cfg.range_start || cfg.ipam_base_ip || derived.start;
    const rangeEnd = cfg.range_end || derived.end;
    const dnsCfg = Array.isArray(cfg.dns_servers) ? cfg.dns_servers.join(", ") : cfg.dns_servers;
    const dnsFile = Array.isArray((opts || {}).dns_servers) ? opts.dns_servers.join(", ") : ((opts || {}).dns_servers || "");
    const defs = {
      gateway,
      netmask,
      ipam_base_ip: rangeStart,
      ipam_range_end: rangeEnd,
      dns_servers: dnsCfg || dnsFile
    };
    const val = (src, k) => { const x = src[k]; return Array.isArray(x) ? x.join(", ") : x; };
    const tracked = (src, k) => val(src, k) != null && String(val(src, k)) !== "";
    const fallback = (k) => (tracked(cfg, k) ? val(cfg, k) : defs[k]);
    const knownAuto = (k) => {
      const chain = [defs[k]];
      if (k === "ipam_base_ip" && (opts || {}).ipam_base_ip) chain.push(opts.ipam_base_ip);
      if (k === "ipam_range_end" && (opts || {}).ipam_range_end) chain.push(opts.ipam_range_end);
      return chain;
    };
    const next = (k, cur) => {
      const oldV = val(old, k);
      const curIsOldAuto = cur === oldV || knownAuto(k).includes(cur) || (oldV == null && cur === "");
      return curIsOldAuto ? fallback(k) : cur;
    };
    setForm((f) => ({
      ...f,
      vlan: net,
      gateway: next("gateway", f.gateway),
      netmask: typeof f.netmask === "number" ? next("netmask", f.netmask) : next("netmask", Number(f.netmask) || 24),
      ipam_base_ip: next("ipam_base_ip", f.ipam_base_ip),
      ipam_range_end: next("ipam_range_end", f.ipam_range_end),
      dns_servers: next("dns_servers", f.dns_servers),
      // per-network node pinning (network_hosts map) — auto-fills the host
      host: f.host === "" || f.host === (opts.network_hosts && opts.network_hosts[f.vlan]) ? ((opts.network_hosts && opts.network_hosts[net]) || "") : f.host
    }));
  };

  const pickFreeIp = async () => {
    const base = form.ipam_base_ip || form.ip || form.gateway;
    if (!base) { setErr("Select a network or set a scan base IP first"); return; }
    setErr("");
    try {
      const d = await findFreeIp(base, "", form.ipam_range_end);
      setForm((f) => ({ ...f, ip: d.free_ip || "" }));
    } catch (e2) {
      setErr(e2.message);
    }
  };

  const submit = async (e) => {
    e.preventDefault();
    if (!form.vm_name) { setErr("vm_name is required"); return; }
    if (!chosenVc || !chosenEnv) { setErr("Select a vCenter and environment"); return; }
    if (!form.ip) { setErr("IP address is required (use Pick free IP)"); return; }
    setSaving(true); setErr(""); setMsg("");
    try {
      const payload = {
        vm_name: form.vm_name.trim(), ip_address: form.ip.trim(),
        hostname: form.hostname.trim(), domain: form.domain.trim(), annotation: form.annotation.trim(),
        datacenter: form.datacenter.trim(), cluster: form.cluster.trim(),
        datastore: form.datastore.trim(), network: form.vlan.trim(),
        template: form.os.trim(), resource_pool: form.resource_pool.trim(),
        host: form.host.trim(),
        memory_mb: (Number(form.memory) || 4) * 1024, cpu: Number(form.vcpu) || 2,
        os_disk_gb: Number(form.disk_size) || 40, provisioning: form.disk_type,
        firmware: form.firmware, cpu_hot: form.cpu_hot, mem_hot: form.mem_hot,
        netmask: Number(form.netmask) || 24,
        ssh_public_key: form.public_key.trim(),
        gateway: form.gateway.trim(),
        ipam_base_ip: form.ipam_base_ip.trim(),
        ipam_range_end: form.ipam_range_end.trim(),
        dns_servers: form.dns_servers.split(",").map((s) => s.trim()).filter(Boolean),
        boot_size: form.boot_size.trim() || "500M",
        os_partitions: form.os_parts.split(",").map((s) => s.trim()).filter(Boolean).map((entry) => {
          const [mp, sz] = entry.split(":");
          const mount = mp === "/" ? "/" : mp.startsWith("/") ? mp : "/" + mp;
          const size = (sz || "10").toUpperCase().endsWith("G") || (sz || "10").toUpperCase().endsWith("M") ? sz : sz + "G";
          return { mount_point: mount, size, lv_name: mount === "/" ? "lv_root" : "lv_" + mount.replace(/^\//, "").replace(/\//g, "_") };
        }),
        data_disks: form.data_disk_gb ? [{
          label: "lvm", size: Number(form.data_disk_gb) || 120, unit_number: 1,
          thin_provisioned: form.data_disk_type === "thin",
          eagerly_scrub: form.data_disk_type === "eager"
        }] : [],
        disable_auto_updates: form.disable_auto_updates,
        extra_users: form.extra_users.split(",").map((s) => s.trim()).filter(Boolean).map((username) => ({ username, password: "" }))
      };
      let result;
      if (edit) {
        result = await updateVmConfig(vc, env, file, payload);
      } else {
        result = await createVmConfig({ vcenter: chosenVc, env: chosenEnv, ...payload });
      }
      const savedFile = result.file || file;
      setMsg((edit ? "Updated" : "Created") + " VM config '" + savedFile + "'");
      refresh && refresh();
      setTimeout(() => onDone && onDone({ vc: chosenVc, env: chosenEnv, file: savedFile }), 600);
    } catch (err2) {
      setErr(err2.message);
    } finally {
      setSaving(false);
    }
  };

  if (loading) return html`<div className="page"><p className="muted"><span className="spinner inline" /> loading…</p></div>`;

  const discSel = (label, key, options, cur, onSel) => html`
    <label>${label}
      <select value=${cur || ""} onChange=${onSel || set(key)}>
        <option value="">${disc && disc.loading ? "discovering…" : "— select —"}</option>
        ${(options || []).map((o) => html`<option key=${o} value=${o}>${o}</option>`)}
        ${(options || []).length === 0 && !(disc && disc.loading) && html`<option value="${cur || ""}">${cur || "— none —"}</option>`}
      </select>
    </label>`;

  const merged = {
    clusters: [...new Set([...(opts && opts.clusters || []), ...(disc && disc.items && disc.items.clusters || [])])],
    datastores: [...new Set([...(opts && opts.datastores || []), ...(disc && disc.items && disc.items.datastores || [])])],
    networks: [...new Set([...(opts && opts.networks || []), ...(disc && disc.items && disc.items.networks || [])])],
    templates: [...new Set([...(opts && opts.templates || []), ...(disc && disc.items && disc.items.templates || [])])],
    resource_pools: [...new Set([...(opts && opts.resource_pools || []), ...(disc && disc.items && disc.items.resource_pools || [])])],
    hosts: [...new Set([...(opts && opts.network_hosts ? Object.values(opts.network_hosts) : []), ...(opts && opts.hosts ? opts.hosts.map((h) => h.name) : []), ...(disc && disc.items && disc.items.hosts || [])])],
    datacenters: [...new Set([...(opts && opts.datacenter ? [opts.datacenter] : []), ...(disc && disc.dcs || [])])]
  };

  return html`
    <div className="page">
      <div className="page-head">
        <h2>${edit ? "Edit VM — " + file : "New VM config"}</h2>
        <button className="ghost" onClick=${onCancel}>Back</button>
      </div>

      ${!edit && (vc || env) && html`
        <div className="target-hint">
          <span className="pill ok">● target</span>
          <span className="muted">will be created as</span>
          <code>deploy/${chosenVc}/${chosenEnv}/${"vm-<name>_<ip>.tfvars"}</code>
        </div>`}

      <form className="wizard-form" onSubmit=${submit}>
        <div className="wizard-grid">
          ${!edit && (!(vc && env)) && html`
            <fieldset className="target-fieldset">
              <legend>Target (vCenter / environment)</legend>
              ${!vc && html`<label>vCenter
                <select value=${chosenVc} onChange=${(e) => setPick((p) => ({ ...p, vc: e.target.value, env: "" }))}>
                  <option value="">— select vCenter —</option>
                  ${(catalog || []).map((v) => html`<option key=${v.vcenter} value=${v.vcenter}>${v.vcenter}</option>`)}
                </select>
              </label>`}
              <label>Environment
                <select value=${chosenEnv} onChange=${(e) => setPick((p) => ({ ...p, env: e.target.value }))} disabled=${!chosenVc}>
                  <option value="">— select environment —</option>
                  ${(() => {
                    const v = (catalog || []).find((x) => x.vcenter === chosenVc);
                    return (v ? v.envs.map((en) => (typeof en === "string" ? en : en.env)) : []).map((en) => html`<option key=${en} value=${en}>${en}</option>`);
                  })()}
                </select>
              </label>
            </fieldset>`}

          <fieldset>
            <legend>vCenter resources (auto-discovered)</legend>
            ${discSel("Datacenter", "datacenter", merged.datacenters, form.datacenter)}
            ${discSel("Cluster", "cluster", merged.clusters, form.cluster)}
            ${discSel("Datastore", "datastore", merged.datastores, form.datastore)}
            ${discSel("Network / port group", "vlan", merged.networks, form.vlan, onNetworkChange)}
            ${discSel("Template (VM)", "os", merged.templates, form.os)}
            ${discSel("Host (node)", "host", merged.hosts, form.host)}
            <label>Resource pool
              <select value=${form.resource_pool} onChange=${set("resource_pool")}>
                <option value="">${disc && disc.loading ? "discovering…" : "— select —"}</option>
                ${merged.resource_pools.map((o) => html`<option key=${o} value=${o}>${o}</option>`)}
                ${merged.resource_pools.length === 0 && html`<option value="${form.resource_pool}">${form.resource_pool || "Resources"}</option>`}
              </select>
            </label>
            <label>IPAM scan base<input value=${form.ipam_base_ip} onChange=${set("ipam_base_ip")} placeholder=${opts && opts.ipam_base_ip || "198.51.100.106"} />
              ${form.ipam_range_end && html`<span className="muted" style=${{ fontSize: 11 }}>range: ${form.ipam_base_ip} – ${form.ipam_range_end}</span>`}
            </label>
            ${disc && disc.error && html`<p className="muted" style=${{ fontSize: 11 }}>discovery: ${disc.error}</p>`}
          </fieldset>

          <fieldset>
            <legend>Identity</legend>
            <label>VM name *<input value=${form.vm_name} onChange=${set("vm_name")} placeholder="app-01" required=${!edit} /></label>
            <label>Hostname<input value=${form.hostname} onChange=${set("hostname")} placeholder="app-01" /></label>
            <label>Domain<input value=${form.domain} onChange=${set("domain")} placeholder="example.local" /></label>
            <label>Description / annotation<input value=${form.annotation} onChange=${set("annotation")} placeholder="app-01 Server" /></label>
          </fieldset>

          <fieldset>
            <legend>Network</legend>
            <label>IP address *
              <div className="iprow">
                <input value=${form.ip} onChange=${set("ip")} required />
                <button type="button" className="ghost" onClick=${pickFreeIp}>Pick free IP</button>
              </div>
            </label>
            <label>Netmask<input value=${form.netmask} onChange=${set("netmask")} placeholder="24" /></label>
            <label>Gateway<input value=${form.gateway} onChange=${set("gateway")} placeholder="198.51.100.1" /></label>
            <label>DNS servers<input value=${form.dns_servers} onChange=${set("dns_servers")} placeholder="8.8.8.8, 1.1.1.1" /></label>
          </fieldset>

          <fieldset>
            <legend>Compute</legend>
            <div className="pair">
              <label>Memory (GB)<input type="number" value=${form.memory} onChange=${set("memory")} min="1" /></label>
              <label>vCPU<input type="number" value=${form.vcpu} onChange=${set("vcpu")} min="1" /></label>
            </div>
            <div className="pair">
              <label>Disk size (GB)<input type="number" value=${form.disk_size} onChange=${set("disk_size")} min="1" /></label>
              <label>Firmware
                <select value=${form.firmware} onChange=${set("firmware")}>
                  <option value="efi">efi</option>
                  <option value="bios">bios</option>
                </select>
              </label>
            </div>
            <div className="pair">
              <label>Disk type
                <select value=${form.disk_type} onChange=${set("disk_type")}>
                  <option value="thin">thin</option>
                  <option value="thick">thick lazy</option>
                  <option value="eager">thick eager (DB/secure)</option>
                </select>
              </label>
            </div>
            <div className="pair">
              <label className="checkline"><input type="checkbox" checked=${form.cpu_hot} onChange=${setBool("cpu_hot")} /> CPU hot-add</label>
              <label className="checkline"><input type="checkbox" checked=${form.mem_hot} onChange=${setBool("mem_hot")} /> RAM hot-add</label>
            </div>
            <div className="pair">
              <label>Boot (sda1)<input value=${form.boot_size} onChange=${set("boot_size")} placeholder="500M" /></label>
              <label>Data disk GB<input type="number" value=${form.data_disk_gb} onChange=${set("data_disk_gb")} min="0" placeholder="none" /></label>
            </div>
            <label>OS partitions (mount:size, comma-separated)
              <input value=${form.os_parts} onChange=${set("os_parts")} placeholder="/:10,/home:5,/var:15,/tmp:2" />
            </label>
            <label>Data disk type
              <select value=${form.data_disk_type} onChange=${set("data_disk_type")}>
                <option value="thin">thin</option>
                <option value="thick">thick lazy</option>
                <option value="eager">thick eager (DB/secure)</option>
              </select>
            </label>
          </fieldset>

          <fieldset>
            <legend>Customization</legend>
            <label>SSH public key<textarea value=${form.public_key} onChange=${set("public_key")} rows="4" placeholder="ssh-rsa AAAA… (kept in top-level ssh_public_key)" /></label>
            <label>Additional users (comma-separated)<input value=${form.extra_users} onChange=${set("extra_users")} placeholder="rakib, devops" /></label>
            <label className="checkline"><input type="checkbox" checked=${form.disable_auto_updates} onChange=${setBool("disable_auto_updates")} /> Disable auto-updates (recommended for prod/DB)</label>
          </fieldset>
        </div>

        ${err && html`<p className="error">${err}</p>`}
        ${msg && html`<p className="ok">${msg}</p>`}

        <div className="row">
          <button className="primary" disabled=${saving}>${saving ? "Saving…" : edit ? "Save VM" : "Create VM"}</button>
          <button type="button" className="ghost" onClick=${onCancel}>Cancel</button>
        </div>
      </form>
    </div>`;
}
