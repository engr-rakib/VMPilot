# VMPilot — VM Auto-Deploy: Requirements, Installation & Beginner Guide

> **One command → a complete Ubuntu VM on vSphere in ~3 minutes.**
> This file is the single starting point for **anyone** — a total beginner or an
> existing operator — who wants to run this project on a **new machine / OS /
> environment**.

---

## Table of Contents

1. [What This Project Does](#1-what-this-project-does)
2. [What You Need — Any New OS / Environment](#2-what-you-need--any-new-os--environment)
3. [Install All Dependencies (one script)](#3-install-all-dependencies-one-script)
4. [Keys: SSH + Age (SOPS)](#4-keys-ssh--age-sops)
5. [First-Time Setup Flow](#5-first-time-setup-flow)
6. [Environment Checklist](#6-environment-checklist)
7. [System Behavior Requirements (R1–R6)](#7-system-behavior-requirements-r1r6)
8. [Acceptance Checks](#8-acceptance-checks)
9. [Beginner Guidelines (Step-by-Step)](#9-beginner-guidelines-step-by-step)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. What This Project Does

An operator deploys a new VM by dropping a **new per-VM config file** into
`deploy/<vcenter>/<env>/`. The system reads the config's `hostname` and `ip_address`:

- If that hostname + IP is **already deployed** → **do nothing** (no redeploy, no destroy).
- If it's a **new hostname** → deploy it, and if the configured IP is **already in use** →
  assign the **next free IP** (scan upward from the configured IP), **update the config file**
  (`ip_address` + filename `vm-<hostname>_<newip>.tfvars`) and deploy with the new IP.

No manual key-renaming, no manual IP bookkeeping, no manual per-VM terraform invocation.

---

## 2. What You Need — Any New OS / Environment

Before anything else, confirm these **platform-level** prerequisites. They are
the same on Ubuntu, Debian, RHEL/CentOS, or any other Linux distro.

### 2.1 The Deploy Host (the machine that runs the scripts)

| Requirement | Why |
|---|---|
| **Linux OS** (Ubuntu 22.04+ recommended) | Scripts are bash; Windows/macOS need WSL or a VM |
| **Network route to your vCenter** | `govc` / vSphere provider must reach vCenter (443) |
| **Network route to the VM subnet** | Free-IP scan (`ping`) must reach the target VLAN |
| **~2 GB free disk** | Terraform state, provider binaries, backups |
| **`git`** | Clone this repository |

> The exact CLI tools (Terraform, govc, SOPS, age, jq, …) are **not** something
> you install by hand — run the installer script in §3 and it does everything.

### 2.2 The vCenter (VMware side)

| Requirement | Why |
|---|---|
| **vCenter 7.x / 8.x** | vSphere provider targets these |
| **A user with API rights** | Read + create + delete VMs, clone templates, assign networks |
| **A golden template** | e.g. `ubuntu-24-template` (Ubuntu with cloud-init) — the base for clones |
| **A datacenter + cluster + resource pool** | Where VMs are placed |
| **A datastore** | With enough free space for OS + data disks |
| **A distributed/standard port group (network)** | The VLAN that VMs join (static IP) |
| **DNS servers + a gateway + a domain** | Static network config applied to every VM |
| **A block of free IPs** | `ipam_base_ip` = first IP the free-IP scanner tries |

### 2.3 Every New VM (inside the guest)

- Ubuntu **cloud-init** must be present in the template (used for OS partition, LVM,
  static IP, SSH keys, extra users).

---

## 3. Install All Dependencies (one script)

Run **one** script on a fresh Linux host and every tool this project needs gets
installed automatically (system packages + Terraform + govc + SOPS). It is
**idempotent** — safe to re-run any time; already-installed tools are skipped.

```bash
bash scripts/setup-deps.sh                # interactive (asks before each step)
bash scripts/setup-deps.sh --yes          # non-interactive: install everything
```

### Options

| Flag | What it does |
|------|--------------|
| `--yes` | No prompts — install everything |
| `--no-keys` | Skip SSH + age key generation |
| `--no-init` | Skip `terraform init` |
| `--latest` | Use the latest release versions (GitHub API) instead of pinned ones |
| `--help` | Show usage |

You can override a pinned version per tool:

```bash
TERRAFORM_VERSION=1.9.8 GOVC_VERSION=0.55.1 SOPS_VERSION=3.13.3 \
  bash scripts/setup-deps.sh --yes
```

### What it installs

- **System packages** via your package manager (`apt`/`dnf`/`yum`):
  `jq`, `git`, `curl`, `wget`, `unzip`, `openssl`, `age`, …
- **Terraform** (≥ 1.6) — official binary from `releases.hashicorp.com`
- **govc** — VMware vSphere CLI from GitHub releases
- **SOPS** — secrets encryption from GitHub releases
- **Optionally:** age key, SSH key, and `terraform init`

---

## 4. Keys: SSH + Age (SOPS)

`setup-deps.sh` can create these for you (interactive mode asks; `--yes` creates
them if missing). If you prefer to do it by hand:

### 4.1 SSH key (so you can log into deployed VMs)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
# copy this whole line — it goes into every VM config (ssh_public_key)
```

### 4.2 Age key (SOPS encryption backend)

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# Show the PUBLIC key — it must match the key in .sops.yaml
age-keygen -y ~/.config/sops/age/keys.txt
```

- **Public key** → go in `.sops.yaml` (`age: age1...`) so files can be encrypted.
- **Private key** stays at `~/.config/sops/age/keys.txt` (set `SOPS_AGE_KEY_FILE` to point
  here if you moved it). **Never commit/email this file.**

### 4.3 Clone the project

```bash
git clone <your-repo-url> /opt/terraform-lab/projects/project01
cd /opt/terraform-lab/projects/project01
```

---

## 5. First-Time Setup Flow

After installing tools + keys:

1. **Generate age key** (see §4) and make sure it matches `.sops.yaml`.
2. **Run the vCenter wizard** — it creates all dependency files automatically
   (`deploy/<datacenter>_<server>/{dev,prod,staging}/` + `secure/<datacenter>_<server>/`
   + per-env override templates):

   ```bash
   bash scripts/vcenter-setup.sh
   # → pick "Create NEW" → server IP → datacenter name → fill inventory
   ```

3. **Create your first VM config:**

   ```bash
   bash scripts/create-vm-config.sh
   # → pick vCenter → pick env → name the VM → accept suggestions → file written
   ```

4. **Deploy it** (auto-decrypts creds, plans, applies ONLY that VM, cleans up):

   ```bash
   bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev myvm
   ```

5. **Verify** in vCenter or with `govc find -type m`.

---

## 6. Environment Checklist

Before the first deploy, confirm all of these:

| Item | Check |
|------|-------|
| Terraform accessible | `terraform --version` |
| govc accessible | `govc version` |
| Age key present | `cat ~/.config/sops/age/keys.txt` |
| SOPS can decrypt | `bash scripts/sops-decrypt.sh <dir> dev --clean` |
| vCenter credentials | `secure/<dir>/credentials.tfvars` exists (encrypted) |
| vCenter inventory | `secure/<dir>/vcenter.tfvars` exists (plaintext) |
| SSH key generated | `cat ~/.ssh/id_ed25519.pub` shows a valid key |
| Network reachable | `ping` vCenter + the target VLAN gateway |
| Template exists | `ubuntu-24-template` present in vCenter |
| Datastore space | Enough free space for OS + data disks |

> A vCenter = `deploy/<dir>/` where `<dir>` = `<datacenter>_<server>` (e.g.
> `dc_pilot_192.0.2.10`). Envs live as subdirs (`dev`/`prod`/`staging`).

---

## 7. System Behavior Requirements (R1–R6)

These are the **behavioral contracts** every deploy must satisfy.

### R1 — Auto-deploy on new config
When a **new** per-VM config file (`deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars`)
appears whose hostname is **not** already tracked in the Terraform state, the system
must automatically deploy that VM. The operator must not be required to run a per-VM
command or edit the for_each key manually.

### R2 — No-op when hostname + IP identical
If a config file corresponds to an already-deployed VM and **both** the hostname
**and** the IP address are unchanged, the system must **not** redeploy / must make
no changes to that VM (no destroy, no replace).

### R3 — Next free IP on conflict + config/file update
If a config file has a **new hostname** (not in state) but its configured `ip_address`
is **already in use**, the system must:
1. Assign the **next free IP** — scan upward from the configured IP, skipping every
   in-use / reserved address (running VMs, powered-off VMs, previously assigned IPs).
2. **Update the config file** `ip_address` to the newly assigned IP.
3. **Rename the config file** to `vm-<hostname>_<newip>.tfvars`.
4. Deploy the VM with the newly assigned IP.

### R4 — Key auto-normalization
The `vm_configs` for_each **key** inside a per-VM config must always be forced to
match the VM hostname before any plan/apply runs. A copied config whose key still
points at the source VM must not cause `-target` mismatches ("No changes") or
destroy the source VM.

### R5 — Never destroy tracked VMs
A VM that exists in the Terraform state must **never** be scheduled for destroy
simply because its per-VM config file was deleted or renamed, or because it was
deleted out-of-band. Deleted VMs are removed from state only when the operator
explicitly asks (or confirms), and only after vCenter confirmation. Only an explicit
destroy command may remove a VM.

### R6 — Idempotent
Running the deploy flow repeatedly must be safe: already-deployed, unchanged VMs are
skipped; only new/changed VMs are acted upon.

---

## 8. Acceptance Checks

- Drop `deploy/dc_pilot_192.0.2.10/staging/vm-web-06_198.51.100.115.tfvars`
  (new hostname, `.115` in use by web-04) → `web-06` gets deployed with the
  **next free IP** (e.g. `.116`), and the config file + filename are updated to the new IP.
- Re-run with the same (now-updated) file → no changes reported for `web-06`.
- A VM deleted out-of-band (vCenter) but still in state → surfaced as a warning,
  never auto-destroyed; operator confirms removal from state.

---

## 9. Beginner Guidelines (Step-by-Step)

New to all of this? Follow exactly this order.

1. **Understand the folder layout.**

   ```
   deploy/<datacenter>_<server>/<env>/vm-<name>_<ip>.tfvars   ← per-VM config (edit this)
   secure/<datacenter>_<server>/credentials.tfvars             ← encrypted (never edit by hand)
   secure/<datacenter>_<server>/vcenter.tfvars                 ← plaintext inventory (wizard edits)
   secure/<datacenter>_<server>/<env>/vcenter.tfvars           ← per-env override (optional)
   terraform/terraform.<datacenter>_<server>.<env>.tfstate     ← per-vCenter+env state
   ```

2. **Never** edit `credentials.tfvars` directly — always use `vcenter-setup.sh`.
3. **Never** delete a VM via Terraform by removing its config file — use `destroy.sh`.
4. One VM = one file. To add a VM, run `create-vm-config.sh` again.
5. Changed an inventory value? Edit the per-env override file
   (`secure/<dir>/<env>/vcenter.tfvars`) — the key wins over the top-level default
   and reflects on the **next** deploy.
6. Left a decrypted file behind after a crash? `bash scripts/sops-decrypt.sh <dir> <env> --clean`.
7. Stuck on a message? Read it literally — the scripts tell you the exact fix command.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `setup-deps.sh: command not found` | Ran from the wrong directory | `cd /opt/terraform-lab/projects/project01` first |
| `no matching creation rules found` (sops) | Plaintext was outside the project | Put plaintext in `.tmp-sops-plain/` (project root) before encrypting |
| `Encrypted files not found` | `secure/<dir>/credentials.tfvars` missing | `bash scripts/vcenter-setup.sh` |
| `Could not auto-find free IP` | Port-group subnet unreachable / all IPs used | Widen `ipam_base_ip` or free an IP |
| `No vCenter configured yet` | No `deploy/*/` vCenter dirs | Run `vcenter-setup.sh` first |
| `Duplicate IPs` error | Two VMs configured with the same IP | Fix one config's `ip_address` |
| Terraform can't reach vCenter | Firewall / wrong creds | Test `govc ls` after `vcenter-setup.sh` |
| `OS disk must be at least N GB` | Disk smaller than template + partitions | Raise the disk size in the prompt |

---

## Out of scope (for now)

- Editing cloud-init content of an existing VM.
- Multi-cluster / multi-datacenter placement logic.

---

## Related documents

- [Requirements & installation](REQUIREMENTS.md)
- [Secure/ — encrypted credentials guide](secure/README.md)
