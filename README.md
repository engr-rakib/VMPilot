<div align="center">

# 🚀 AccessPilot

**VM Deployment & Lifecycle Automation on VMware vSphere**

> Drop one config file → a complete, production-ready Ubuntu VM is deployed in minutes.
> No manual cloning. No IP bookkeeping. No accidental overwrites.

![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A51.6-7B42BC)
![vSphere](https://img.shields.io/badge/vSphere-7.x%2F8.x-00BFFF)
![SOPS](https://img.shields.io/badge/SOPS-%2B%20Age-4B8BBE)
![Cloud-Init](https://img.shields.io/badge/Cloud--Init-%E2%9C%85-brightgreen)

</div>

---

## ✨ What is AccessPilot?

A fully automated toolkit that turns a **single per-VM config file** into a deployed,
configured Ubuntu VM — OS partitions, LVM, swap, static IP, DNS, SSH keys and users all
handled automatically.

The most surprising part: **your config file is alive.** After every deploy it rewrites
its own IP and renames itself, so what you see on disk is always the truth. VMs are
**never** destroyed by accident, and dev / prod / staging can run on entirely different
vCenters without conflict.

## ✨ Features

| | |
|---|---|
| 🤖 **Zero-Touch VM Deploy** | 1 command → VM created, OS set up, LVM + network configured |
| 📦 **Full Stack Ready** | OS partitions, swap, data-disk LVM, static IP, DNS — all automatic |
| 🔄 **Auto-Deploy Loop** | Drop a config file → the system deploys it for you (R1–R6) |
| ⚙️ **One-Click Setup** | Fresh host → all tools installed with a single script |
| 🧩 **Per-Env Overrides** | One key per environment — no more copy-pasting configs |
| 🌐 **Multi-vCenter** | dev / prod / staging on *different* vCenters, zero conflicts |
| 🛡️ **Config Guard** | Broken configs fail fast; keys auto-fix; IPs auto-sync |
| 🔐 **Security First** | Credentials encrypted with SOPS + Age; plaintext never persists |
| 💾 **Auto Backup** | Project backup / restore with rotation in 2 commands |
| 🛡️ **Safe Destroy** | `prevent_destroy` — a VM is never deleted by accident |
| 🚫 **Duplicate IP Guard** | Two VMs with the same IP → deployment is blocked |
| 🧪 **Pre-Deploy Validation** | Catches mistakes before they reach vSphere |
| 📈 **Monitoring Ready** | Optional node_exporter + cloud-init status tracking |
| 📜 **Audit Trail** | Full Terraform state + backup history + deploy logs |

**The auto-deploy loop** (drop a per-VM config into `deploy/<dir>/<env>/` and walk away):

| Rule | Behavior |
|------|----------|
| **R1** | New hostname → automatically deployed (next free IP assigned) |
| **R2** | Hostname + IP unchanged → skipped (no-op, idempotent) |
| **R3** | Hostname / IP changed → redeployed with a free IP; config + filename auto-updated |
| **R4** | `for_each` key always forced to the hostname — no `-target` mismatch |
| **R5** | A tracked VM with a missing config is **never** auto-destroyed — surfaced as a warning |
| **R6** | Re-running is always safe — unchanged VMs are simply skipped |

## 🚀 60-second feel

```bash
bash scripts/setup-deps.sh --yes                       # 1. install everything
bash scripts/vcenter-setup.sh                          # 2. configure a vCenter (auto-creates all dirs)
bash scripts/create-vm-config.sh                       # 3. answer a few prompts → config file written
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-01   # 4. deployed!
```

## 📚 Documentation

Read them in this order:

1. **[client-features.md](client-features.md)** — the full deep-dive: how it works, feature deep-dives, quick start
2. **[REQUIREMENTS.md](REQUIREMENTS.md)** — what you need on any new OS, installation, beginner guide, R1–R6 contracts
3. **[PROJECT_STATUS.md](PROJECT_STATUS.md)** — what's changed, how the new per-VM model works, file map

Additional guides live in [`docs/`](docs/): operator guide, project structure, security (SOPS), and more.

## 🧰 Tech stack

Terraform ≥ 1.6 · VMware vSphere provider · govc · SOPS + Age · Cloud-Init · Bash

---

> **"Our infrastructure should run itself — free from manual error."**
