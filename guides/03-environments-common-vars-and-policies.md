# 03. Environments, Common Variables and Policies

This guide explains how VMPilot manages environments (`dev`, `staging`, `prod`), cascades common variables across infrastructure scopes, handles per-environment overrides, and applies policy re-synchronization at deployment time.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [Policy Inheritance Architecture](#policy-inheritance-architecture)
- [Policy-Driven vs VM-Owned Keys](#policy-driven-vs-vm-owned-keys)
- [The `network_subnets` Full-Replace Rule](#the-network_subnets-full-replace-rule)
- [Deploy-Time Policy Re-Sync](#deploy-time-policy-re-sync)
- [Step-by-Step Operator Usage](#step-by-step-operator-usage)
- [Real-Life Production Scenarios](#real-life-production-scenarios)
  - [Scenario A: Updating Corporate DNS Across Staging](#scenario-a-updating-corporate-dns-across-staging)
  - [Scenario B: Pinning Production to High-IOPS NVMe Storage](#scenario-b-pinning-production-to-high-iops-nvme-storage)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

In traditional infrastructure management, managing multiple environments often leads to duplicate configuration files where changes (such as DNS server rotations, gateway changes, or datastore migrations) must be manually copied across dozens of files.

VMPilot resolves this through **hierarchical policy inheritance**:
1. **Centralized Baseline Configuration**: Global settings (gateway, DNS, NTP, cluster definitions) are defined once in `secure/<server>/<vcenter>/vcenter.tfvars`.
2. **Selective Per-Environment Overrides**: Environments override only the specific keys they need (e.g., prod uses a dedicated datastore or isolated VLAN).
3. **Dynamic Re-Sync at Deploy Time**: Deploying an individual VM automatically merges the latest parent policies, preventing stale network or cluster variables from lingering in old VM configs.

---

## Policy Inheritance Architecture

VMPilot evaluates variables using a strict four-tier precedence hierarchy:

```text
┌────────────────────────────────────────────────────────────────────────┐
│ LEVEL 1: Datacenter Baseline Inventory                                │
│          secure/<server>/<vcenter>/vcenter.tfvars                      │
│          (Default clusters, datastores, networks, DNS, gateway)        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ inherits / overrides per key
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ LEVEL 2: Per-Environment Overrides                                     │
│          secure/<server>/<vcenter>/<env>/vcenter.tfvars                │
│          (e.g., prod datastore pinning, staging VLAN isolation)        │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ inherits / overrides per key
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ LEVEL 3: Base VM Sizing & Defaults                                     │
│          scripts/lib/vm-defaults.conf                                  │
│          (Default CPU count, RAM allocation, OS disk capacity)         │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ overrides per VM
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ LEVEL 4: Per-VM Specific Definition (Source of Truth)                  │
│          deploy/<server>/<vcenter>/<env>/vm-<hostname>_<ip>.tfvars     │
│          (Specific hostname, static IP, extra data disks, users)       │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Policy-Driven vs VM-Owned Keys

To maintain consistency across large fleets, VMPilot distinguishes between **Policy-Driven** attributes (inherited from datacenter/environment policies) and **VM-Owned** attributes (defined specifically for each VM):

| Variable Key | Scope | Owned By | Behavior on Policy Update |
| :--- | :--- | :--- | :--- |
| `datacenter` | Global / Env | Infrastructure Policy | Auto-synced during deploy; VM moves with DC policy |
| `cluster` | Global / Env | Infrastructure Policy | Auto-synced; pinned to environment compute pool |
| `datastore` | Global / Env | Infrastructure Policy / Env | Pinned per-env or overridden during VM scaffolding |
| `network` | Global / Env | Infrastructure Policy / Env | Inherited from selected environment VLAN |
| `gateway` | Global / Env | Infrastructure Policy | Inherited; updating policy updates all future deploys |
| `dns_servers` | Global / Env | Infrastructure Policy | Inherited; auto-synced across environment |
| `hostname` | Per-VM | VM Definition | Immutable identity of the virtual machine |
| `ip_address` | Per-VM | VM Definition | Static IP bound to VM (managed via IPAM) |
| `cpu` / `memory` | Per-VM | VM Definition | VM sizing; can be resized during Day-2 operations |
| `disk_size` | Per-VM | VM Definition | Boot disk size in GB |
| `data_disks` | Per-VM | VM Definition | Secondary LVM data volumes attached to the VM |

---

## The `network_subnets` Full-Replace Rule

> ⚠️ **Important Caveat**: In Terraform and HCL, map and list variables cannot be partially merged across variable files. 

If your root `vcenter.tfvars` defines:
```hcl
network_subnets = {
  "VM-VLAN-100" = "198.51.100.0/24"
  "VM-VLAN-200" = "198.51.200.0/24"
}
```
And you define an override in `prod/vcenter.tfvars`, the child definition **completely replaces** the parent map for that environment. Always declare all required networks in the child file when overriding map structures.

---

## Deploy-Time Policy Re-Sync

When `bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>` executes:

1. **Step 1: Inspects Environment Directory**: Reads `secure/<server>/<vcenter>/vcenter.tfvars`.
2. **Step 2: Inspects Child Overrides**: Checks if `secure/<server>/<vcenter>/<env>/vcenter.tfvars` exists.
3. **Step 3: Variable Layering**: Passes `-var-file` arguments to Terraform in order of precedence:
   ```bash
   terraform plan \
     -var-file="secure/<server>/<vcenter>/vcenter.tfvars" \
     -var-file="secure/<server>/<vcenter>/<env>/vcenter.tfvars" \
     -var-file="deploy/<server>/<vcenter>/<env>/vm-merged.auto.tfvars"
   ```
4. **Step 4: Config Sync Back**: Updates the individual `vm-*.tfvars` on disk so local files match deployed state.

---

## Step-by-Step Operator Usage

### 1. View Current Datacenter Defaults
```bash
cat secure/192.0.2.10/dc_pilot/vcenter.tfvars
```

### 2. View Environment Overrides
```bash
cat secure/192.0.2.10/dc_pilot/prod/vcenter.tfvars
```

### 3. Apply an Override for Production
To force all production VMs onto a dedicated cluster or datastore, edit `secure/<server>/<vcenter>/prod/vcenter.tfvars`:
```hcl
# secure/192.0.2.10/dc_pilot/prod/vcenter.tfvars
datastores = ["datastore-san-nvme-01"]
cluster    = "Gold-Cluster"
```

---

## Real-Life Production Scenarios

### Scenario A: Updating Corporate DNS Across Staging
A company deploys new internal DNS resolvers (`192.0.2.53` and `192.0.2.54`). You need all future staging deployments to use these new resolvers immediately without hand-editing 25 separate VM configuration files.

**Action**:
Edit `secure/192.0.2.10/dc_pilot/staging/vcenter.tfvars`:
```hcl
dns_servers = ["192.0.2.53", "192.0.2.54"]
```

**Verification**:
Run a dry run on a staging VM:
```bash
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 staging staging-api-01 --plan
```
Terraform detects the updated cloud-init user-data payload with the new DNS addresses while leaving all compute and storage configurations unchanged.

---

### Scenario B: Pinning Production to High-IOPS NVMe Storage
Your VMware administrator provisions a high-performance flash array named `datastore-nvme-gold` intended exclusively for production database workloads.

**Action**:
Update `secure/192.0.2.10/dc_pilot/prod/vcenter.tfvars`:
```hcl
datastores = ["datastore-nvme-gold"]
```

**Outcome**:
When developers run `bash scripts/create-vm-config.sh`, selecting `prod` automatically selects `datastore-nvme-gold` as the primary datastore, preventing accidental placement on slower spinning disks.

---

## Guardrails & Common Mistakes

| Problem | Root Cause | Solution |
| :--- | :--- | :--- |
| **VM deploys to unexpected datastore** | Stale datastore hardcoded inside `deploy/.../vm-*.tfvars` | Remove the `datastore = "..."` line from the per-VM file so it inherits the environment override. |
| **Network not found during deploy** | Map override in `prod/vcenter.tfvars` omitted standard VLANs | Ensure `network_subnets` in the child file contains all networks needed by that environment. |
| **Credentials placed in per-env file** | Attempting to define passwords inside `prod/vcenter.tfvars` | Keep credentials exclusively in `secure/<server>/credentials.tfvars`. Inventory files are plaintext and committed to Git. |

---

[◄ Back to 02. vCenter Onboarding](02-vcenter-onboarding-and-multi-provider.md) | [Next: 04. VM Config, IPAM & LVM Storage ►](04-vm-config-ipam-and-lvm-storage.md)
