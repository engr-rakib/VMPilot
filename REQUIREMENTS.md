# VM Auto-Deploy Requirements

## Summary
An operator deploys a new VM by dropping a **new per-VM config file** into `deploy/<env>/`. The system reads the config's `hostname` and `ip_address`:

- If that hostname + IP is **already deployed** → **do nothing** (no redeploy, no destroy).
- If it's a **new hostname** → deploy it, and if the configured IP is **already in use** → assign the **next free IP** (scan upward from the configured IP), **update the config file** (`ip_address` + filename `vm-<hostname>_<newip>.tfvars`) and deploy with the new IP.

No manual key-renaming, no manual IP bookkeeping, no manual per-VM terraform invocation.

## Requirements

### R1 — Auto-deploy on new config
When a **new** per-VM config file (`deploy/<env>/vm-<name>_<ip>.tfvars`) appears whose hostname is **not** already tracked in the Terraform state, the system must automatically deploy that VM. The operator must not be required to run a per-VM command or edit the for_each key manually.

### R2 — No-op when hostname + IP identical
If a config file corresponds to an already-deployed VM and **both** the hostname **and** the IP address are unchanged, the system must **not** redeploy / must make no changes to that VM (no destroy, no replace).

### R3 — Next free IP on conflict + config/file update
If a config file has a **new hostname** (not in state) but its configured `ip_address` is **already in use**, the system must:
1. Assign the **next free IP** — scan upward from the configured IP, skipping every in-use / reserved address (running VMs, powered-off VMs, and previously assigned IPs).
2. **Update the config file** `ip_address` to the newly assigned IP.
3. **Rename the config file** to `vm-<hostname>_<newip>.tfvars`.
4. Deploy the VM with the newly assigned IP.

### R4 — Key auto-normalization
The `vm_configs` for_each **key** inside a per-VM config must always be forced to match the VM hostname before any plan/apply runs. A copied config whose key still points at the source VM must not cause `-target` mismatches ("No changes") or destroy the source VM.

### R5 — Never destroy tracked VMs
A VM that exists in the Terraform state must **never** be scheduled for destroy simply because its per-VM config file was deleted or renamed, or because it was deleted out-of-band. Deleted VMs are removed from state only when the operator explicitly asks (or confirms), and only after vCenter confirmation. Only an explicit destroy command may remove a VM.

### R6 — Idempotent
Running the deploy flow repeatedly must be safe: already-deployed, unchanged VMs are skipped; only new/changed VMs are acted upon.

## Out of scope (for now)
- Editing cloud-init content of an existing VM.
- Multi-cluster / multi-datacenter placement logic.

## Acceptance checks
- Drop `deploy/staging/vm-web-06_198.51.100.115.tfvars` (new hostname, `.115` in use by web-04) → `web-06` gets deployed with the **next free IP** (e.g. `.116`), and the config file + filename are updated to the new IP.
- Re-run with the same (now-updated) file → no changes reported for `web-06`.
- A VM deleted out-of-band (vCenter) but still in state → surfaced as a warning, never auto-destroyed; operator confirms removal from state.
