// alerts-util.js — shared resource-alert helpers used by EventsView + NotifyBell
// so both surfaces stay in sync. A "resource" event (Host/VM CPU/RAM, datastore,
// failed services, VM DOWN...) carries only {label, value, at}; these helpers
// turn that into two meaningful extras:
//   highFor(e)     — how long this alert has been active ("25m", "1h05m")
//   alertSuggest(e)— an actionable next step based on the label + severity.
import { html } from "/js/core.js";

export const highFor = (e) => {
  if (!e || e.kind !== "resource" || !e.at) return "";
  const s = Math.max(0, Math.floor((Date.now() - Number(e.at)) / 1000));
  const m = Math.floor(s / 60);
  return s < 60 ? `${s}s` : m < 60 ? `${m}m` : `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}m`;
};

export const alertSuggest = (e) => {
  if (!e || e.kind !== "resource") return "";
  const l = (e.label || "").toLowerCase();
  const crit = e.severity === "critical";
  if (l.startsWith("host down")) return "Host is down — check power/network. VMs on it are unreachable. See Inventory → Infrastructure for host state.";
  if (l.startsWith("host cpu")) return crit ? "Host CPU critical — vMotion busy VMs off this host or reduce overcommit." : "Host CPU high — review top VMs by CPU and balance them across hosts.";
  if (l.startsWith("host ram")) return crit ? "Host RAM critical — vMotion VMs off this host or add memory; check overcommit." : "Host RAM high — check running VMs and memory overcommit, or add memory to the host.";
  if (l.startsWith("datastore")) return crit ? "Datastore critical — free space or expand storage before writes fail." : "Datastore filling — clean snapshots/logs or move VMs to another datastore.";
  if (l.startsWith("vm cpu")) return "VM CPU high — check guest processes, or resize vCPU in the VM config.";
  if (l.startsWith("vm ram")) return "VM RAM high — check the guest workload, or resize memory in the VM config.";
  if (l.startsWith("vm down")) return "VM powered off unexpectedly — verify intentional power-off, and check host/network state.";
  if (l.includes("failed services")) return "Services failed in the guest — open guest troubleshoot, check service logs, restart the service.";
  if (l.startsWith("guest")) return "Guest root disk filling — expand via Inventory → Grow, or clean up guest files/logs.";
  return "";
};

// Suggested one-liner for a resource alert: "suggestion — high for 25m".
export const suggestLine = (e) => {
  if (!e || e.kind !== "resource") return "";
  const s = alertSuggest(e);
  const h = highFor(e);
  if (!s && !h) return "";
  return html`${s}${h ? ` — alerting for ${h}` : ""}`;
};