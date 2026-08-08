<p align="center">
  <img src="https://img.shields.io/badge/🚀%20AccessPilot-vSphere%20Automation-7B42BC?style=for-the-badge" />
</p>

<h1 align="center">🚀 AccessPilot</h1>

<h3 align="center">VM Deployment &amp; Lifecycle Automation on VMware vSphere</h3>

<p align="center">
  <em>Drop one config file → a complete, production-ready Ubuntu VM is deployed in minutes.<br/>
  No manual cloning. No IP bookkeeping. No accidental overwrites.</em>
</p>

<p align="center">
  <a href="#-features"><img src="https://img.shields.io/badge/Terraform-%E2%89%A51.6-7B42BC" /></a>
  <a href="#-features"><img src="https://img.shields.io/badge/vSphere-7.x%2F8.x-00BFFF" /></a>
  <a href="#-features"><img src="https://img.shields.io/badge/SOPS-%2B%20Age-4B8BBE" /></a>
  <a href="#-features"><img src="https://img.shields.io/badge/Cloud--Init-%E2%9C%85-brightgreen" /></a>
  <a href="https://github.com/engr-rakib/terraform-lab"><img src="https://img.shields.io/github/stars/engr-rakib/terraform-lab?style=social" /></a>
</p>

---

## 📖 What is AccessPilot?

AccessPilot is a **fully automated toolkit** that turns a **single per-VM config file** into a
deployed, configured Ubuntu VM — OS partitions, LVM, swap, static IP, DNS, SSH keys and users
all handled automatically.

> 🎩 **The "magic" trick:** your config file is *alive*. After every deploy it rewrites its own IP
> and renames itself — so what you see on disk is always the truth. VMs are **never** destroyed by
> accident, and dev / prod / staging can run on entirely different vCenters without conflict.

| 😫 **Without AccessPilot** | ✅ **With AccessPilot** |
|---|---|
| Log into vCenter, clone a template by hand | `bash scripts/deploy-vm.sh <dir> dev web-01` |
| Manually partition disks & configure LVM | OS partitions, swap, LVM — all automatic |
| Maintain a mental map of free IPs | Next free IP discovered for you |
| Copy-paste configs per environment | One key per env — per-env overrides |
| Pray you don't overwrite a running VM | `prevent_destroy` — a VM is never deleted |

---

## ✨ Features

<table>
<tr>
<td width="50%"><b>🤖 Zero-Touch VM Deploy</b><br/>1 command → VM created, OS set up, LVM + network configured</td>
<td width="50%"><b>📦 Full Stack Ready</b><br/>OS partitions, swap, data-disk LVM, static IP, DNS — all automatic</td>
</tr>
<tr>
<td width="50%"><b>🔄 Auto-Deploy Loop</b><br/>Drop a config file → the system deploys it (R1–R6)</td>
<td width="50%"><b>⚙️ One-Click Setup</b><br/>Fresh host → all tools installed with a single script</td>
</tr>
<tr>
<td width="50%"><b>🧩 Per-Env Overrides</b><br/>One key per environment — no copy-pasting configs</td>
<td width="50%"><b>🌐 Multi-vCenter</b><br/>dev / prod / staging on different vCenters, zero conflicts</td>
</tr>
<tr>
<td width="50%"><b>🛡️ Config Guard</b><br/>Broken configs fail fast; keys auto-fix; IPs auto-sync</td>
<td width="50%"><b>🔐 Security First</b><br/>Credentials encrypted with SOPS + Age; plaintext never persists</td>
</tr>
<tr>
<td width="50%"><b>💾 Auto Backup</b><br/>Project backup / restore with rotation in 2 commands</td>
<td width="50%"><b>🛡️ Safe Destroy</b><br/>`prevent_destroy` — never deleted by accident</td>
</tr>
<tr>
<td width="50%"><b>🚫 Duplicate IP Guard</b><br/>Two VMs on the same IP → deployment is blocked</td>
<td width="50%"><b>🧪 Pre-Deploy Validation</b><br/>Catches mistakes before they reach vSphere</td>
</tr>
<tr>
<td width="50%"><b>📈 Monitoring Ready</b><br/>Optional node_exporter + cloud-init status tracking</td>
<td width="50%"><b>📜 Audit Trail</b><br/>Full Terraform state + backup history + deploy logs</td>
</tr>
</table>

### 🔄 The auto-deploy loop — drop & forget

Drop a per-VM config into `deploy/<dir>/<env>/` and walk away:

| Rule | Behavior |
|------|----------|
| **R1** | New hostname → automatically deployed (next free IP assigned) |
| **R2** | Hostname + IP unchanged → skipped (no-op, idempotent) |
| **R3** | Hostname / IP changed → redeployed with a free IP; config + filename auto-updated |
| **R4** | `for_each` key always forced to the hostname — no `-target` mismatch |
| **R5** | A tracked VM with a missing config is **never** auto-destroyed — surfaced as a warning |
| **R6** | Re-running is always safe — unchanged VMs are simply skipped |

---

## 🏗️ How it works

```
  👨‍💻 You              🖥️ Terraform server               🌐 vSphere                🐧 Cloud-Init
 ┌─────────┐   config   ┌──────────────┐   plan/apply   ┌────────────┐   boots    ┌────────────┐
 │ create- │ ─────────▶ │  create-vm-  │ ─────────────▶ │  new VM    │ ─────────▶ │ static IP  │
 │ vm-config│  .tfvars  │  config.sh + │   vSphere API  │ (cloned)   │            │ LVM, swap  │
 └─────────┘            │  next-free-  │                └────────────┘            │ SSH keys   │
                        │  ip          │                                          └────────────┘
                        └──────────────┘   ✅ ready in ~2–3 minutes
```

---

## 🚀 60-second feel

```bash
bash scripts/setup-deps.sh --yes                       # 1. install everything
bash scripts/vcenter-setup.sh                          # 2. configure a vCenter (auto-creates all dirs)
bash scripts/create-vm-config.sh                       # 3. answer a few prompts → config file written
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-01   # 4. deployed!
```

---

## 📚 Documentation

| Guide | What it covers |
|---|---|
| **[client-features.md](client-features.md)** | Full deep-dive: how it works, feature deep-dives, quick start |
| **[REQUIREMENTS.md](REQUIREMENTS.md)** | What you need on any new OS, installation, beginner guide, R1–R6 contracts |
| **[PROJECT_STATUS.md](PROJECT_STATUS.md)** | What's changed, how the new per-VM model works, file map |
| **[`docs/`](docs/)** | Operator guide, project structure, security (SOPS), and more |

---

## 🧰 Tech stack

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | ≥ 1.6 | Infrastructure as Code |
| VMware vSphere Provider | ~> 2.16 | VMware API integration |
| govc | ≥ 0.30 | vSphere CLI for resource selection |
| SOPS + Age | ≥ 3.8 | Credential encryption |
| Cloud-Init | Built-in | VM bootstrap & configuration |
| Bash | ≥ 5 | Orchestration scripts |

---

## 🗺️ Roadmap

- [x] One-command per-VM deploy with per-env state
- [x] Auto-deploy loop (R1–R6) — drop & forget
- [x] SOPS + Age credential encryption
- [ ] `destroy.sh` wrapper with state backup + explicit confirmation
- [ ] Optional S3 remote-state backend (`backends/s3/bootstrap.sh`)
- [ ] Multi-cluster / multi-datacenter placement logic

---

<p align="center">
  <b>AccessPilot</b> — *"Our infrastructure should run itself — free from manual error."*<br/>
  <sub>Made with ❤️ using Terraform · vSphere · SOPS</sub>
</p>
