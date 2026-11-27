<p align="center">
  <img src="https://img.shields.io/badge/🚀%20VMPilot-vSphere%20Automation-7B42BC?style=for-the-badge" />
</p>

<h1 align="center">🚀 VMPilot</h1>

<h3 align="center">VM Deployment &amp; Lifecycle Automation on VMware vSphere</h3>

<p align="center">
  <em>Drop one config file → a complete, production-ready Ubuntu VM is deployed in minutes.<br/>
  No manual cloning. No IP bookkeeping. No accidental overwrites.</em>
</p>

<p align="center">
  <a href="#-feature-overview"><img src="https://img.shields.io/badge/Terraform-%E2%89%A51.6-7B42BC" /></a>
  <a href="#-feature-overview"><img src="https://img.shields.io/badge/vSphere-7.x%2F8.x-00BFFF" /></a>
  <a href="#-feature-overview"><img src="https://img.shields.io/badge/SOPS-%2B%20Age-4B8BBE" /></a>
  <a href="#-feature-overview"><img src="https://img.shields.io/badge/Cloud--Init-%E2%9C%85-brightgreen" /></a>
  <a href="https://github.com/engr-rakib/VMPilot"><img src="https://img.shields.io/github/stars/engr-rakib/VMPilot?style=social" /></a>
  <a href="https://engr-rakib.github.io/web"><img src="https://img.shields.io/badge/Author-Engr.%20Rakib-181717?style=for-the-badge" /></a>
</p>

---

> **Infrastructure, fully automated.** Drop one config file → a complete, production-ready
> Ubuntu VM is deployed on vSphere in minutes. No manual cloning, no manual IP bookkeeping,
> no risk of overwriting your other VMs.

---

## 📌 Why VMPilot?

Most VM workflows are **manual, error-prone, and slow** — log into vCenter, clone a
template, configure networking, partition disks, remember which IPs are taken…

**VMPilot removes all of that.** You tell it *what* you want (a VM named `web-01`
in `prod`), and it handles *everything else* — picking the right cluster, datastore,
template, and network, finding a free IP, provisioning OS + LVM + swap, injecting SSH
keys, and even keeping your config file in sync with reality.

> 🎩 **The "magic" trick:** your config file is *live* — after a deploy it rewrites its own
> IP and renames itself, so what you see on disk is always the truth.

---

## 📑 Table of Contents

- [Feature Overview](#-feature-overview)
- [How It Works](#-how-it-works)
- [Technology & Architecture](#-technology--architecture)
- [Internal Workflow](#-internal-workflow)
- [Feature Deep-Dives](#-feature-deep-dives)
  - [1. One-Command VM Deployment](#1-one-command-vm-deployment)
  - [2. Auto-Deploy Loop — drop & forget](#2-auto-deploy-loop--drop--forget)
  - [3. One-Click Environment Setup](#3-one-click-environment-setup)
  - [4. Config Guard & IP Auto-Sync](#4-config-guard--ip-auto-sync)
  - [5. Two-Phase OS Hardening & Verification](#5-two-phase-os-hardening--verification)
  - [6. Linux Guest RBAC & Auditing](#6-linux-guest-rbac--auditing)
  - [7. Security — encrypted by design](#7-security--encrypted-by-design)
  - [8. Pre-Deploy Validation & Safety Gates](#8-pre-deploy-validation--safety-gates)
  - [9. Safe Destroy — state-protected lifecycle](#9-safe-destroy--state-protected-lifecycle)
  - [10. Multi-VM & Scaling](#10-multi-vm--scaling)
  - [11. Multi-vCenter Support](#11-multi-vcenter-support)
  - [12. Customization Options](#12-customization-options)
  - [13. S3 Remote-State Backend](#13-s3-remote-state-backend)
- [From Zero to a Production-Grade VM](#-from-zero-to-a-production-grade-vm)
- [Quick Start](#-quick-start)
- [Tech Stack](#-tech-stack)
- [Roadmap](#-roadmap)
- [Support & Documentation](#-support--documentation)
- [Enterprise Web Console (Commercial Add-On)](#-enterprise-web-console-commercial-add-on)
- [Author & License](#-author--license)

---

## ✨ Feature Overview

| Feature | What it gives you |
|---------|-------------------|
| 🤖 **Zero-Touch VM Deploy** | 1 command → VM created, OS set up, LVM + network configured |
| 📦 **Full Stack Ready** | OS partitions, swap, data-disk LVM, static IP, DNS — all automatic |
| 🔄 **Auto-Deploy Loop** | Drop a config file → the system deploys it for you (R1–R6) |
| ⚙️ **One-Click Setup** | Fresh host → all tools installed with a single script |
| 🧩 **Per-Env Overrides** | One key per environment — no more copy-pasting configs |
| 🌐 **Multi-vCenter Support** | dev / prod / staging on *different* vCenters, zero conflicts |
| 🛡️ **Config Guard** | Broken configs fail fast; keys auto-fix; IPs auto-sync |
| 🔐 **Security First** | Credentials encrypted with SOPS + Age; plaintext never persists |
| 🔒 **Two-Phase OS Hardening** | Cloud-init delivery + live SSH run + 19 automated `CHECK` probes |
| 👥 **Linux Guest RBAC** | Per-environment role union (`admin`/`app`/`db`/`readonly`) + `/var/log/sudo.log` |
| 💾 **Auto Backup** | Project backup / restore with rotation in 2 commands |
| 🛡️ **Safe Destroy** | `destroy.sh` with state backup, W4 state removal, and W5 `govc vm.destroy` |
| 📈 **Monitoring Ready** | Optional node_exporter + cloud-init status tracking |
| 🚫 **Duplicate IP Guard** | Two VMs with the same IP → deployment is blocked |
| 🧪 **Pre-Flight Safety Gates** | Declared IP subnet CIDR validation + 300s reboot-tolerant SSH gate |
| 📜 **Audit Trail** | Full Terraform state + backup history + deploy logs |

---

## 🏗️ How It Works

```
┌───────────────────────────────────────────────────────────────────┐
│                    👨‍💻 YOU (Operator)                              │
│        bash scripts/create-vm-config.sh                          │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌───────────────────────────────────────────────────────────────────┐
│                     🖥️ TERRAFORM SERVER                           │
│                                                                   │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐   │
│   │  1. Config   │───▶│  2. IP Auto  │───▶│  3. Terraform    │   │
│   │  Generator   │    │   Discovery  │    │   Plan + Apply   │   │
│   │  (prompts)   │    │  (free-IP)   │    │  (vSphere API)   │   │
│   └──────┬───────┘    └──────┬───────┘    └────────┬─────────┘   │
│          │                   │                     │              │
│          ▼                   ▼                     ▼              │
│   deploy/<server>/<vcenter>/<env>/vm-*.tfvars   terraform apply  │
└───────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌───────────────────────────────────────────────────────────────────┐
│                      🌐 vSPHERE VIRTUALIZATION                    │
│   NEW VM (cloned from template)                                   │
│     OS disk · data disks · vCPU · RAM · static IP + DNS + gateway │
└───────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌───────────────────────────────────────────────────────────────────┐
│                     🐧 CLOUD-INIT & HARDENING (inside the VM)     │
│   1. Boot → network applied → static IP assigned                 │
│   2. OS partitions → LVM created (/, /var, swap…)                │
│   3. Data disks detected → VG → LV → mounted                     │
│   4. Users created → SSH key injected → RBAC applied             │
│   5. Two-phase hardening script executed + 19 CHECK probes       │
│   6. Auto-updates disabled (production stability)                │
│   7. ✅ Ready in ~2–3 minutes                                    │
└───────────────────────────────────────────────────────────────────┘
```

---

## 🧩 Technology & Architecture

Five layers, one config file. You only ever touch **L1** — everything below is automated.

```
┌────────────────────────────────────────────────────────────────────┐
│ L1  OPERATOR - the CLI you use                                     │
│ install.sh · vcenter-setup.sh · create-vm-config.sh                │
│ deploy-vm.sh · deploy-sync.sh · destroy.sh · backup.sh             │
│ sops-encrypt.sh · sops-decrypt.sh · next_free_ip.sh                │
├────────────────────────────────────────────────────────────────────┤
│ L2  CONFIG - source of truth                                       │
│ deploy/<server>/<vcenter>/<env>/vm-<name>_<ip>.tfvars              │
│ secure/<server>/<vcenter>/vcenter.tfvars (plaintext inventory)     │
│ secure/<server>/credentials.tfvars       (SOPS + Age secret)       │
├────────────────────────────────────────────────────────────────────┤
│ L3  ORCHESTRATION - Terraform >= 1.6                               │
│ main.tf for_each · module.vm · IPAM (external data source)         │
│ check{ duplicate IP } · per-vCenter+env isolated state files       │
├────────────────────────────────────────────────────────────────────┤
│ L4  VSPHERE - vmware/vsphere provider + govc                       │
│ clone template · datastore/LVM · network · guestinfo injection     │
├────────────────────────────────────────────────────────────────────┤
│ L5  GUEST - cloud-init + OS hardening inside the VM                │
│ network · partition/LVM · data disks · users & RBAC · SSH gate     │
└────────────────────────────────────────────────────────────────────┘
```

**L1 → L2:** interactive scripts write real, reviewable config files — the same
files you can hand-edit. **L2 → L3:** Terraform merges one environment's configs
into a single `vm_configs` map (never across vCenters). **L3 → L4:** the vSphere
provider clones, provisions, and injects cloud-init via guestinfo.
**L4 → L5:** cloud-init and hardening scripts turn a blank clone into a configured server.

---

## ⚙️ Internal Workflow

What actually happens inside when you deploy **one** VM:

```
bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>
│
├─ 1  Resolve paths + the per-vCenter+env state file (isolated state)
├─ 2  Validate declared IP subnet CIDR match (fails fast before Terraform)
├─ 3  Auto-normalize the vm_configs key → VM name           (R4)
├─ 4  Blending guard — validate every per-VM config file    (fails fast)
├─ 5  Merge this env's configs → a single -var-file
├─ 6  sops-decrypt credentials → *.auto.tfvars              (transient)
├─ 7  terraform apply -target='module.vm["<vm-name>"]'
│      │
│      ├─ IPAM      next_free_ip.sh → first free address
│      ├─ CLONE     from hardened template (prevent_destroy = true)
│      ├─ GUESTINFO inject cloud-init payload (base64, via vApp)
│      └─ GATE      SSH poll (15 x 20s = 300s) + auto ICMP diagnostic
├─ 8  Execute OS hardening script (/etc/vmpilot/hardening.sh) + 19 CHECKs
├─ 9  Cleanup — decrypted creds removed, even on failure     (trap)
├─ 10 IP auto-sync — rewrite config ip_address + filename    (R3)
└─ 11 Report the assigned IP
```

The pipeline is **idempotent** — run it again and nothing changes (R2) unless the
config is new (R1) or actually changed (R3). The sync loop
(`deploy-sync.sh`) runs this pipeline for every new/changed config file
automatically.

---

## ⚡ Feature Deep-Dives

### 1. One-Command VM Deployment

```bash
bash scripts/create-vm-config.sh
```

Answer a few prompts (vCenter → environment → VM name), and the script does the rest:

- **Smart suggestions** — the moment you pick a vCenter + environment, it auto-loads
  `datacenter`, `cluster`, `datastore`, `resource_pool`, `network`, `template`,
  `domain`, `gateway`, `netmask`, `dns_servers`, and the per-network IPAM map.
  Press Enter to accept, or type your own.
- **Free-IP discovery** — scans the network and picks the next available address.
- **Compliance warnings** — invalid names, missing credentials, or undersized disks are
  caught immediately, with the exact fix in the message.

```bash
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod web-01
```

One command → credentials decrypted → `terraform apply` **targeted to only that VM** →
SSH gate verification → hardening run → cleanup. **Every other VM stays untouched.**

---

### 2. Auto-Deploy Loop — drop & forget

```bash
bash scripts/deploy-sync.sh <dir> <env>           # scan + auto-deploy new/changed
bash scripts/deploy-sync.sh <dir> <env> --plan    # dry-run first
bash scripts/deploy-sync.sh <dir> <env> --list    # show the diff table only
```

Drop a new per-VM config file into `deploy/<server>/<vcenter>/<env>/` and the system handles the rest:

| Rule | Behavior |
|------|----------|
| **R1** | New hostname → automatically deployed (next free IP assigned) |
| **R2** | Hostname + IP unchanged → skipped (no-op, idempotent) |
| **R3** | Hostname / IP changed → redeployed with a free IP; config file + filename auto-updated |
| **R4** | `for_each` key always forced to the hostname — no `-target` mismatch |
| **R5** | A tracked VM with a missing config is **never** auto-destroyed — surfaced as a warning |
| **R6** | Re-running is always safe — unchanged VMs are simply skipped |

```text
==========================================================
  Sync scan: deploy/dc_pilot_192.0.2.10/dev/
==========================================================
:: R2 skip: web-02  (ip 198.51.100.108 unchanged)
:: R2 skip: web-03  (ip 198.51.100.109 unchanged)
:: R2 skip: web-01  (ip 198.51.100.107 unchanged)
==========================================================
  Sync done: 0 changed, 3 unchanged, 0 missing-config warning(s)
==========================================================
```

---

### 3. One-Click Environment Setup

Boot a brand-new Linux host and run one script — it detects the environment and installs everything automatically (deps, keys, terraform init). One command, no extra scripts:

```bash
bash install.sh               # same detection, may ask before installing
bash install.sh --yes         # fully automatic (no prompts)
```

- System packages (`jq`, `git`, `curl`, `wget`, `unzip`, `openssl`, `age`, …)
- **Terraform** (≥ 1.6) + **govc** + **SOPS** binaries
- Optionally: an age key, an SSH key, and `terraform init`
- **Idempotent** — already-installed tools are skipped; override versions with
  `TERRAFORM_VERSION=1.9.8 GOVC_VERSION=0.55.1 SOPS_VERSION=3.13.3`

---

### 4. Config Guard & IP Auto-Sync

Your config files are **self-healing**:

- **Blending guard** — before combining per-VM configs, each file is validated. A
  malformed `vm_configs` block fails fast with a clear message, so a broken file can
  **never** corrupt another VM's deployment.
- **Key auto-normalization (R4)** — copied a config and forgot to rename it? The key,
  annotation, and hostname are fixed automatically.
- **IP auto-sync (R3)** — after every apply, the config file's `ip_address` is updated
  and the file is **renamed** (`vm-web-01_198.51.100.107.tfvars` → `vm-web-01_198.51.100.108.tfvars`)
  so the file on disk always matches reality.

---

### 5. Two-Phase OS Hardening & Verification

VMPilot applies a resilient two-phase hardening model:

1. **Phase 1 (Offline Cloud-Init Delivery)**: Cloud-init writes the hardening script into `/etc/vmpilot/hardening.sh` during first boot.
2. **Phase 2 (Online SSH Execution)**: The deployment pipeline triggers execution over SSH, running CIS-aligned kernel sysctl tuning, SSH daemon hardening, firewall policies, and panic dump configurations.
3. **19 Automated Verification Probes**: The script runs 19 granular `CHECK` probes (SSH root disable, password auth disable, core dump restrictions, IPv4 forwarding, `/tmp` mount options, and system auditing). If network interface issues occur, `--lan-up` fallback recovery prevents lockouts.

---

### 6. Linux Guest RBAC & Auditing

User and group access is decoupled from individual VM definitions:

- **Per-Environment User Roles**: Managed via `user-groups.tfvars` with role unions for `admin`, `app`, `db`, and `readonly` groups.
- **Access Manifest**: Every VM receives `/etc/vmpilot-access.md` detailing provisioned accounts, public keys, and role assignments.
- **Command Auditing**: All administrative actions are routed through `sudo` with full command logging written to `/var/log/sudo.log`.

---

### 7. Security — encrypted by design

| Security layer | Implementation |
|----------------|----------------|
| 🔑 **Credential encryption** | SOPS + Age — plaintext credentials never live in the repo |
| 🧹 **Auto cleanup** | Decrypted `*.auto.tfvars` are deleted after every apply (even on failure) |
| 🛡️ **VM protection** | `prevent_destroy = true` — a VM is never deleted by accident |
| 🔒 **SSH key only** | Password authentication disabled (cloud-init default) |
| 📋 **Audit trail** | Terraform state + backup history + guest `/var/log/sudo.log` |

> 💡 Only `credentials.tfvars` is encrypted — inventory (`datacenter`, `datastore`, …)
> stays in readable plaintext so the team can see *where* things live without secrets.

---

### 8. Pre-Deploy Validation & Safety Gates

Mistakes are caught **before** they reach vSphere:

- ✅ **Declared IP Subnet CIDR Validation**: The CLI verifies that the target VM's static IP falls strictly within the network's defined subnet CIDR before generating Terraform resources.
- ✅ **Duplicate IP Guard**: A built-in Terraform `check` block refuses two VMs on the same IP.
- ✅ **Reboot-Tolerant SSH Gate**: A polling gate (15 attempts × 20s interval = 300s window) waits for cloud-init completion. If 5 consecutive attempts yield key-denied, it bails out early; on timeout, an automated ICMP VLAN diagnostic checks reachability.
- ✅ **Config Blending Guard**: Malformed per-VM files fail fast before synthesis.
- ✅ **R5 State Reconciliation**: Stale state entries are flagged with warnings, never silently destroyed.

---

### 9. Safe Destroy — state-protected lifecycle

VMPilot provides explicit, safety-guarded VM decommissioning via `scripts/destroy.sh`:

- **Automatic Pre-Destroy State Backup**: Creates an immutable timestamped backup of the target environment's state file before making any changes.
- **Step W4 (Safe State Removal)**: Cleans the VM resource (`module.vm["<vm>"]`) from the Terraform state using `terraform state rm`.
- **Step W5 (vSphere Deletion)**: Deletes the virtual machine in vSphere via `govc vm.destroy`.
- **Operator Safety Flags**: Supports `--plan` (dry-run review), `--yes` (scripted confirmation), and `--keep-config` (retains the `.tfvars` file for quick redeployment).

```bash
# Decommission a VM safely:
bash scripts/destroy.sh dc_pilot_192.0.2.10 dev web-01

# Dry-run check:
bash scripts/destroy.sh dc_pilot_192.0.2.10 dev web-01 --plan
```

---

### 10. Multi-VM & Scaling

Unlimited VMs in one environment's state — each VM in its **own config file**, orchestrated
with Terraform `for_each`. No more "one big file to rule them all":

```hcl
# deploy/dc_pilot_192.0.2.10/dev/vm-web-01_198.51.100.112.tfvars
# deploy/dc_pilot_192.0.2.10/dev/vm-web-02_198.51.100.113.tfvars
vm_configs = {
  web-02 = {
    hostname   = "web-02"
    ip_address = "198.51.100.113"
    cpu        = 2
    memory     = 4096
    disk_size  = 40
  }
}
```

```bash
# Deploy ONE VM — everyone else stays untouched:
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-02
```

**Benefits:**
- ✅ Add VMs freely — old ones are never touched
- ✅ Duplicate IPs are rejected outright
- ✅ Per-VM outputs (`vms`, `vm_ip_addresses`, `cloud_init_status`, …)
- ✅ Terragrunt is *optional* — built-in `for_each` covers unlimited VMs

---

### 11. Multi-vCenter Support

Every environment gets its **own Terraform state**, so dev, prod, and staging can live on
entirely different vCenters:

```bash
terraform/terraform.dc_pilot_192.0.2.10.dev.tfstate
terraform/terraform.dc_pilot_192.0.2.10.prod.tfstate
terraform/terraform.dc_pilot_192.0.2.10.staging.tfstate
```

**Onboarding a new vCenter is automatic:**

```bash
bash scripts/vcenter-setup.sh    # → "Create NEW" → server + datacenter
```

This single command creates everything:
- `deploy/<server>/<vcenter>/{dev,prod,staging}/` — config directories
- `secure/<server>/credentials.tfvars` — encrypted credentials (SOPS)
- `secure/<server>/<vcenter>/vcenter.tfvars` — plaintext inventory
- `secure/<server>/<vcenter>/{dev,prod,staging}/vcenter.tfvars` — per-env override templates

**Per-environment overrides** — need a different datastore/network/resource_pool in prod only?

```hcl
# secure/192.0.2.10/dc_pilot/prod/vcenter.tfvars
datastores = ["datastore99"]   # ← prod only; dev/staging inherit the top-level default
```

- Load order: top-level `vcenter.tfvars` → per-env → **per-env wins per key**
- Commented/absent keys fall back to the top-level value
- Allowed keys: `datacenter`, `clusters`, `templates`, `datastores`, `networks`,
  `resource_pools` (optional per-env pinning — default is govc auto-discovery at
  VM-create time), plus network/IPAM: `domain`, `gateway`, `netmask`, `dns_servers`,
  `network_subnets`, `network_hosts`
- **Credentials are never per-env** — secrets live only in `secure/<server>/credentials.tfvars`

---

### 12. Customization Options

| Parameter | Options | Default |
|-----------|---------|---------|
| OS partitions | `/`, `/var`, `/tmp`, `/home`, swap | Auto-suggested |
| Data disks | LVM with custom VG / LV | Commented template |
| Filesystem | ext4, xfs, btrfs | xfs |
| CPU | 1–256 | Prompt |
| Memory | 512 MB – 2 TB | Prompt |
| Network | DHCP / Static | Static |
| Extra users | Username + password + group role | Optional |
| Auto-updates | Disable for prod | Optional |

---

### 13. S3 Remote-State Backend

Running several machines off the same repo means they must share one Terraform state — the optional S3 backend keeps it locked and versioned in your AWS account instead of a local file.

- Full setup & walkthrough: [`backends/s3/README.md`](backends/s3/README.md)
- One-shot bootstrap: [`backends/s3/bootstrap.sh`](backends/s3/bootstrap.sh)

---

## 🛣️ From Zero to a Production-Grade VM

The complete journey — from an empty server to a hardened, production-ready VM:

| Phase | Step | What happens | Where |
|-------|------|--------------|-------|
| 0 | **Bootstrap the host** | Detect + install every dependency: Terraform, govc, SOPS, age, jq… plus keys & `terraform init` (idempotent) | `install.sh --yes` |
| 1 | **Onboard vCenter** | Register server + datacenter → auto-creates `deploy/` + `secure/` dirs, per-env overrides, and encrypts credentials | `vcenter-setup.sh` |
| 2 | **Prepare the template** | One-time per vCenter: Ubuntu with `open-vm-tools` + cloud-init + VMware GuestInfo, LVM-friendly partitioning | manual |
| 3 | **Create the config** | Answer prompts → free IP auto-assigned, LVM layout, SSH key, RBAC groups | `create-vm-config.sh` |
| 4 | **Deploy** | One VM targeted, others untouched — or drop the file and let the loop do it | `deploy-vm.sh` / `deploy-sync.sh` |
| 5 | **Verify & Harden** | Confirm SSH gate, run OS hardening script, verify 19 CHECK probes | automated during deploy |
| 6 | **Production hardening** | Auto-updates off (default), optional Prometheus `node_exporter` — baked into the deploy | config flags |
| 7 | **Backup & lifecycle** | Rotating backups, safe destroy (`destroy.sh` with state protection) | `backup.sh` / `destroy.sh` |

**The result** — in about **2–3 minutes** a production-grade VM lands:

- ✅ Cloned from a hardened template
- ✅ Static IP + DNS + gateway, no IP conflicts (guarded)
- ✅ LVM + swap provisioned with a sensible partition layout
- ✅ SSH-key-only access (no passwords)
- ✅ 19-point CIS-aligned OS hardening verified
- ✅ Per-environment Linux RBAC and sudo command logging active
- ✅ Auto-updates disabled for stable, predictable behavior
- ✅ Optional `node_exporter` running, ready for Prometheus / Grafana
- ✅ Your config file stayed in sync — the truth is on disk
- ✅ Every other VM untouched, and the VM itself is destroy-protected

---

## 🚀 Quick Start

### 🆕 Fresh Setup — run this repo as YOUR project (GitHub reader)

The one-line installer gives you a **fully working copy** — dependencies, keys,
and Terraform are installed automatically. You do **one** manual configuration
(your vCenter), and then the app starts working.

```bash
# 1. Install (clones repo → ~/VMPilot, installs terraform/govc/sops/age,
#    generates your own age + SSH keys, runs terraform init — everything auto)
curl -fsSL https://raw.githubusercontent.com/engr-rakib/VMPilot/main/install.sh | bash

# 2. THE ONLY CONFIG — onboard YOUR vCenter (interactive wizard):
cd ~/VMPilot
bash scripts/vcenter-setup.sh
#    → "Create NEW vCenter" → your server + inventory → press y
#    (dc_example_192.0.2.10 is a committed DUMMY example — always pick "Create NEW")

# 3. From here the app just works — create a VM config:
bash scripts/create-vm-config.sh <vcenter> <env> <vm-name>

# 4. Deploy it:
bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>
```

**Why no other setup is needed:**
- Your **age key is generated automatically** and encryption works out of the box
  (SOPS creation rules are *path-based*; the wizard encrypts with *your* key —
  no `.sops.yaml` edits required)
- `vcenter-setup.sh` creates everything: encrypted `secure/<server>/credentials.tfvars`,
  inventory `vcenter.tfvars`, per-env overrides, and the mirrored
  `deploy/<server>/<vcenter>/{dev,prod,staging}/` directories
- Every deploy auto-decrypts *your* vCenter's credentials, merges per-env
  overrides, and targets only the VM you asked for

> ⚠️ **First time on this host?** Manual alternative to the one-liner:
> `bash install.sh --yes` (same thing — installs repo + deps + keys + terraform init).

### Already installed — daily use

```bash
# 0. Fresh host? Detect + install every dependency (idempotent, skips what's done):
bash install.sh --yes

# 1. Configure a vCenter (creates all dependency files automatically):
bash scripts/vcenter-setup.sh

# 2. Create a per-VM config:
bash scripts/create-vm-config.sh
# → deploy/dc_pilot_192.0.2.10/dev/vm-<hostname>_<ip>.tfvars

# 3. Deploy ONE VM (auto-decrypt, -target, SSH gate, hardening, auto-cleanup):
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-02

# 4. Or let the sync loop do it for you:
bash scripts/deploy-sync.sh dc_pilot_192.0.2.10 dev --list

# 5. Verify:
terraform -chdir=terraform output vms
terraform -chdir=terraform output cloud_init_status

# 6. Backup:
bash scripts/backup.sh <project-root> /backups
```

---

## 🧰 Tech Stack

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | ≥ 1.6 | Infrastructure as Code |
| vSphere Provider | ~> 2.16 | VMware API integration |
| govc | ≥ 0.30 | vSphere CLI for resource selection |
| SOPS + Age | ≥ 3.8 | Credential encryption |
| Cloud-Init | Built-in | VM bootstrap & configuration |
| Terragrunt | ≥ 0.55 (optional) | Multi-VM orchestration |
| Prometheus | opt-in | Monitoring with node_exporter |

---

## 🗺️ Roadmap

- [x] Pre-flight safety checks (declared IP subnet CIDR validation + reboot-tolerant SSH gate)
- [x] Decommission wrapper (`scripts/destroy.sh` with state backup + `govc vm.destroy`)
- [x] Multi-cluster & multi-datacenter placement logic with per-env overrides
- [x] Optional S3 remote-state backend ([`backends/s3/bootstrap.sh`](backends/s3/bootstrap.sh) · [docs](backends/s3/README.md))
- [ ] Automated CIS OS benchmark compliance reporting export

---

## 📞 Support & Documentation

- **Feature-Wise User & Operator Guides:** [`guides/README.md`](guides/README.md)
- **Requirements & installation:** [`REQUIREMENTS.md`](REQUIREMENTS.md)
- **Encrypted credentials guide:** [`secure/README.md`](secure/README.md)
- **S3 remote-state backend:** [`backends/s3/README.md`](backends/s3/README.md)

---

## 🖥️ Enterprise Web Console (Commercial Add-On)

VMPilot provides an optional **commercial Enterprise Web Console (`vmpilot-webui/`)** designed for platform engineering teams and enterprise operations that require a web-based operations cockpit alongside the open-source CLI.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        VMPILOT ARCHITECTURE                            │
├───────────────────────────────────┬────────────────────────────────────┤
│   OPEN-SOURCE CLI CORE (Free)     │   ENTERPRISE WEB CONSOLE (Paid)    │
│   • Multi-vCenter Terraform IaC   │   • Full Browser Operations UI     │
│   • Interactive Shell Wizards     │   • 38-Privilege Granular RBAC     │
│   • Parallel IPAM & Free-IP Calc  │   • Live SSE Pipeline Streaming    │
│   • SOPS-Age Secret Encryption    │   • Fleet Inventory & 30s Metrics  │
│   • Two-Phase OS Hardening (19)   │   • Multi-Channel Alert Routing    │
│   • Linux Guest RBAC & Auditing   │   • Veeam-Grade Delta BDR Chains   │
│   • Safe Destroy & State Guards   │   • DBeaver-Style SQL Console      │
│   • MIT License (Zero Lock-In)    │   • Proprietary Enterprise License │
└───────────────────────────────────┴────────────────────────────────────┘
```

### ⚖️ Side-by-Side Feature Comparison

| Capability | Open-Source CLI Core | Enterprise Web Console |
| :--- | :---: | :---: |
| **Licensing** | **Free & Open-Source (MIT)** | **Commercial (Proprietary)** |
| **Interface** | Terminal CLI / Bash Scripts | Responsive Browser Cockpit |
| **Multi-vCenter IaC Engine** | Yes | Yes (Underlying Engine) |
| **SOPS + Age Encryption** | Yes | Yes (Managed via Vault) |
| **Two-Phase OS Hardening (19 Probes)** | Yes | Yes |
| **Linux Guest RBAC (`/etc/vmpilot-access.md`)** | Yes | Yes |
| **Safe Decommission (`destroy.sh`)** | Yes | Yes |
| **Granular UI RBAC (38 Privileges)** | — | Yes (Admin, App, DB, Readonly) |
| **Real-Time Job Streaming (SSE)** | — | Yes (Live Steps & ANSI Logs) |
| **Fleet Inventory & Telemetry** | — | Yes (30s Background Polling) |
| **Enterprise Alert Routing** | — | Yes (Telegram, Email, WhatsApp, Bell) |
| **Delta BDR & Hot Restore** | Simple `.tar.gz` | Yes (Delta Chains & SQLite WAL) |
| **Read-Only SQL Explorer & Query Console** | — | Yes (500-Row Cap & Redaction) |
| **AI Incident RCA Diagnostics** | — | Yes (Interactive RCA Engine) |

### 🚀 Zero-Friction Upgrade Path

The Enterprise Web Console sits directly on top of the open-source CLI. It requires **zero state migration** and introduces **zero vendor lock-in**:

1. Obtain the licensed `vmpilot-webui/` package from the author.
2. Drop `vmpilot-webui/` into your existing VMPilot project root.
3. Deploy the containerized appliance:
   ```bash
   bash install.sh --webui
   ```
4. Access your HTTPS operations cockpit at `https://<your-host>:8443`.

> Both the CLI and Web Console share the exact same configuration files (`deploy/`), encrypted credentials (`secure/`), and Terraform state files (`terraform/`). You can switch between CLI and Web Console at any time.

### 💼 Commercial Licensing & Inquiries

For commercial licensing, enterprise support tiers, or private appliance bundles:
- **Author:** [Rakibuzzaman (Engr. Rakib)](https://engr-rakib.github.io/web)
- **Email:** [rakibcse47@gmail.com](mailto:rakibcse47@gmail.com)
- **Website:** [engr-rakib.github.io/web](https://engr-rakib.github.io/web)

---

## 👤 Author & License

**VMPilot** is the original work of **Rakibuzzaman (Engr. Rakib)** — Server Administrator
at Walton Hi-Tech Industries PLC, with an M.Sc. in Computer Science (Jahangirnagar
University) and B.Sc. Eng. in CSE (Daffodil International University).

| | |
|---|---|
| **GitHub** | [github.com/engr-rakib](https://github.com/engr-rakib) |
| **Website** | [engr-rakib.github.io/web](https://engr-rakib.github.io/web) |
| **Email** | [rakibcse47@gmail.com](mailto:rakibcse47@gmail.com) |
| **License** | © 2026 Rakibuzzaman — see [`LICENSE`](LICENSE) & [`AUTHORS.md`](AUTHORS.md) |

> All source files carry the author's attribution header. Removing it violates the
> license terms. Reusing this project? Credit the author and keep the notices intact.

---

<p align="center">
  <b>VMPilot</b> — *"Our infrastructure should run itself — free from manual error."*<br/>
  <sub>Made with ❤️ using Terraform · vSphere · SOPS</sub><br/>
  <b>© 2026 <a href="https://engr-rakib.github.io/web">Rakibuzzaman (Engr. Rakib)</a></b> — all rights reserved.
</p>
