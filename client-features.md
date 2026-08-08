# 🚀 AccessPilot — VM Deployment & Lifecycle Automation

> **Infrastructure, fully automated.** Drop one config file → a complete, production-ready
> Ubuntu VM is deployed on vSphere in minutes. No manual cloning, no manual IP bookkeeping,
> no risk of overwriting your other VMs.

---

## 📌 Why AccessPilot?

Most VM workflows are **manual, error-prone, and slow** — log into vCenter, clone a
template, configure networking, partition disks, remember which IPs are taken…

**AccessPilot removes all of that.** You tell it *what* you want (a VM named `web-01`
in `prod`), and it handles *everything else* — picking the right cluster, datastore,
template, and network, finding a free IP, provisioning OS + LVM + swap, injecting SSH
keys, and even keeping your config file in sync with reality.

> 🎩 **The "magic" trick:** your config file is *live* — after a deploy it rewrites its own
> IP and renames itself, so what you see on disk is always the truth.

---

## 📑 Table of Contents

- [Feature Overview](#-feature-overview)
- [How It Works](#-how-it-works)
- [Feature Deep-Dives](#-feature-deep-dives)
  - [1. One-Command VM Deployment](#1-one-command-vm-deployment)
  - [2. Auto-Deploy Loop — drop & forget](#2-auto-deploy-loop--drop--forget)
  - [3. One-Click Environment Setup](#3-one-click-environment-setup)
  - [4. Config Guard & IP Auto-Sync](#4-config-guard--ip-auto-sync)
  - [5. Backup & Restore](#5-backup--restore)
  - [6. Security — encrypted by design](#6-security--encrypted-by-design)
  - [7. Monitoring & Observability](#7-monitoring--observability)
  - [8. Pre-Deploy Validation](#8-pre-deploy-validation)
  - [9. Safe Destroy — nothing disappears by accident](#9-safe-destroy--nothing-disappears-by-accident)
  - [10. Multi-VM & Scaling](#10-multi-vm--scaling)
  - [11. Multi-vCenter Support](#11-multi-vcenter-support)
  - [12. Customization Options](#12-customization-options)
- [Quick Start](#-quick-start)
- [Tech Stack](#-tech-stack)
- [Roadmap](#-roadmap)

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
| 💾 **Auto Backup** | Project backup / restore with rotation in 2 commands |
| 🛡️ **Safe Destroy** | `prevent_destroy` — a VM is never deleted by accident |
| 📈 **Monitoring Ready** | Optional node_exporter + cloud-init status tracking |
| 🚫 **Duplicate IP Guard** | Two VMs with the same IP → deployment is blocked |
| 🧪 **Pre-Deploy Validation** | Catches mistakes before they reach vSphere |
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
│   deploy/<dir>/<env>/vm-<name>_<ip>.tfvars   terraform apply    │
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
│                     🐧 CLOUD-INIT (inside the VM)                 │
│   1. Boot → network applied → static IP assigned                 │
│   2. OS partitions → LVM created (/, /var, swap…)                │
│   3. Data disks detected → VG → LV → mounted                     │
│   4. Users created → SSH key injected                            │
│   5. Auto-updates disabled (production)                          │
│   6. ✅ Ready in ~2–3 minutes                                    │
└───────────────────────────────────────────────────────────────────┘
```

---

## ⚡ Feature Deep-Dives

### 1. One-Command VM Deployment

```
bash scripts/create-vm-config.sh
```

Answer a few prompts (vCenter → environment → VM name), and the script does the rest:

- **Smart suggestions** — the moment you pick a vCenter + environment, it auto-loads
  `datacenter`, `cluster`, `datastore`, `resource_pool`, `network`, `template`,
  `domain`, `gateway`, `netmask`, `dns_servers`, and `ipam_base_ip`. Press Enter to
  accept, or type your own.
- **Free-IP discovery** — scans the network and picks the next available address.
- **Compliance warnings** — invalid names, missing credentials, or undersized disks are
  caught immediately, with the exact fix in the message.

```
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod web-01
```

One command → credentials decrypted → `terraform apply` **targeted to only that VM** →
cleanup. **Every other VM stays untouched.**

---

### 2. Auto-Deploy Loop — drop & forget

```
bash scripts/deploy-sync.sh <dir> <env>           # scan + auto-deploy new/changed
bash scripts/deploy-sync.sh <dir> <env> --plan    # dry-run first
bash scripts/deploy-sync.sh <dir> <env> --list    # show the diff table only
```

Drop a new per-VM config file into `deploy/<dir>/<env>/` and the system handles the rest:

| Rule | Behavior |
|------|----------|
| **R1** | New hostname → automatically deployed (next free IP assigned) |
| **R2** | Hostname + IP unchanged → skipped (no-op, idempotent) |
| **R3** | Hostname / IP changed → redeployed with a free IP; config file + filename auto-updated |
| **R4** | `for_each` key always forced to the hostname — no `-target` mismatch |
| **R5** | A tracked VM with a missing config is **never** auto-destroyed — surfaced as a warning |
| **R6** | Re-running is always safe — unchanged VMs are simply skipped |

```
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

Boot a brand-new Linux host and run one script — every dependency is installed automatically:

```
bash scripts/setup-deps.sh            # interactive
bash scripts/setup-deps.sh --yes      # fully automatic
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
  and the file is **renamed** (`vm-web-01_10.0.0.5.tfvars` → `vm-web-01_10.0.0.6.tfvars`)
  so the file on disk always matches reality.

---

### 5. Backup & Restore

```
bash scripts/backup.sh                    # interactive
bash scripts/backup.sh /project /backup-dir   # direct
```

- Excludes `.git`, `.terraform`, `node_modules` automatically
- Timestamped `.tar.gz` archives with rotation (keeps the last 5)
- Restore pre-saves your current state first — nothing is lost
- Remembers your paths — no need to type them twice

```
Menu:
  1) Create backup
  2) List backups (ID, Date, Size, Filename)
  3) Restore from backup
  4) Exit
```

---

### 6. Security — encrypted by design

| Security layer | Implementation |
|----------------|----------------|
| 🔑 **Credential encryption** | SOPS + Age — plaintext credentials never live in the repo |
| 🧹 **Auto cleanup** | Decrypted `*.auto.tfvars` are deleted after every apply (even on failure) |
| 🛡️ **VM protection** | `prevent_destroy = true` — a VM is never deleted by accident |
| 🔒 **SSH key only** | Password authentication disabled (cloud-init default) |
| 📋 **Audit** | Terraform state + backup history + validation messages |

> 💡 Only `credentials.tfvars` is encrypted — inventory (`datacenter`, `datastore`, …)
> stays in readable plaintext so the team can see *where* things live without secrets.

---

### 7. Monitoring & Observability

```
# Check cloud-init status per VM:
terraform output cloud_init_status
# → ssh ubuntu@<ip> sudo cloud-init status
```

**Optional node_exporter** — flip one flag in the VM config:

```hcl
enable_node_exporter = true
```

The VM auto-installs Prometheus `node_exporter`, ready to be scraped by Prometheus / Grafana.

---

### 8. Pre-Deploy Validation

Mistakes are caught **before** they reach vSphere:

- ✅ **Duplicate IP guard** — a built-in Terraform `check` refuses two VMs on the same IP:
  ```
  ERROR: Duplicate IPs: ["198.51.100.110","198.51.100.110"].
  Each VM must have a unique ip_address.
  ```
- ✅ **Config blending guard** — malformed per-VM files fail fast (§4)
- ✅ **R5 state reconciliation** — stale state entries are detected, never silently destroyed
- ✅ **Provider refresh** — templates, networks, and datastores are re-verified against vCenter

---

### 9. Safe Destroy — nothing disappears by accident

- **`prevent_destroy = true`** on every VM resource — even a bare `terraform destroy` can't take it down
- **R5 (deploy-sync)** — deleting a config file never deletes the VM; you get a warning and an explicit action
- No auto-destroy, ever — whether the config is missing or the VM vanished from vCenter

To remove a VM today (explicit, manual):

```bash
# 1. Remove it from state (the VM is orphaned in vCenter):
terraform -chdir=terraform state rm \
  -state=terraform/terraform.dc_pilot_192.0.2.10.dev.tfstate \
  'module.vm["<vm-name>"].vsphere_virtual_machine.this'

# 2. Delete the VM in vCenter:
govc vm.destroy "<vm-name>"
```

> 🚧 A polished `destroy.sh` wrapper (state backup + `type DESTROY to confirm`) is on the roadmap.

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

```
bash scripts/vcenter-setup.sh    # → "Create NEW" → server + datacenter
```

This single command creates everything:
- `deploy/<datacenter>_<server>/{dev,prod,staging}/` — config directories
- `secure/<datacenter>_<server>/credentials.tfvars` — encrypted credentials (SOPS)
- `secure/<datacenter>_<server>/vcenter.tfvars` — plaintext inventory
- `secure/<datacenter>_<server>/{dev,prod,staging}/vcenter.tfvars` — per-env override templates

**Per-environment overrides** — need a different datastore or network in prod only?

```hcl
# secure/dc_pilot_192.0.2.10/prod/vcenter.tfvars
datastore = "datastore99"   # ← prod only; everything else inherits the top-level default
```

- Load order: top-level `vcenter.tfvars` → per-env → **per-env wins per key**
- Commented/absent keys fall back to the top-level value
- Allowed keys: `datacenter`, `cluster`, `resource_pool`, `datastore`, `network`, `template`,
  `domain`, `gateway`, `netmask`, `dns_servers`, `ipam_base_ip`
- **Credentials are never per-env** — secrets live only in `secure/<dir>/credentials.tfvars`

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
| Extra users | Username + password | Optional |
| Auto-updates | Disable for prod | Optional |

---

## 🚀 Quick Start

```bash
# 0. Fresh host? Install every dependency:
bash scripts/setup-deps.sh --yes

# 1. Configure a vCenter (creates all dependency files automatically):
bash scripts/vcenter-setup.sh

# 2. Create a per-VM config:
bash scripts/create-vm-config.sh
# → deploy/dc_pilot_192.0.2.10/dev/vm-<hostname>_<ip>.tfvars

# 3. Deploy ONE VM (auto-decrypt, -target, auto-cleanup):
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-02

# 4. Or let the sync loop do it for you:
bash scripts/deploy-sync.sh dc_pilot_192.0.2.10 dev --list

# 5. Verify:
terraform -chdir=terraform output vms
terraform -chdir=terraform output cloud_init_status

# 6. Backup:
bash scripts/backup.sh /opt/terraform-lab/projects/project01 /backups
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

- [ ] Standalone `pre-apply-check.sh` with an 8-point pre-flight checklist
- [ ] `destroy.sh` wrapper with state backup + explicit confirmation
- [ ] Optional S3 remote-state backend (`backends/s3/bootstrap.sh`)
- [ ] Multi-cluster / multi-datacenter placement logic

---

## 📞 Support

- **Documentation:** [`docs/`](docs/)
- **Operator guide:** [`docs/operator-guide/operator-guide.md`](docs/operator-guide/operator-guide.md)
- **Requirements & installation:** [`REQUIREMENTS.md`](REQUIREMENTS.md)

> **"Our infrastructure should run itself — free from manual error."**
