# secure/ — Encrypted vCenter Credentials & Inventory

This directory holds the **only secrets** in the project: vSphere credentials and the
vCenter inventory names every VM deployment depends on. Everything here is encrypted
with **SOPS (Mozilla) + age**, so it is **safe to commit to git**.

This file is also the **operator's guide** — it explains how to plug your own vCenter
into the project, how the parent/per-env config model works, and how a config file you
write ends up as a deployed production-grade VM.

---

## 1. What's Inside

```text
secure/
├── README.md                <- you are here
└── <datacenter>_<server>/    <- one dir per vCenter (name = <datacenter>_<server>)
    ├── credentials.tfvars   <- ENCRYPTED: vsphere server / user / password
    ├── vcenter.tfvars       <- PLAINTEXT: datacenter / cluster / datastore / network / template
    └── {dev,prod,staging}/  <- OPTIONAL per-env overrides (see §2.2)
        └── vcenter.tfvars   <-   all-commented template; uncomment keys that differ per env
```

| File | Contents |
|------|----------|
| `credentials.tfvars` | `vsphere_server`, `vsphere_user`, `vsphere_password`, `allow_unverified_ssl` — **SOPS-encrypted** |
| `vcenter.tfvars`     | `datacenter`, `cluster`, `resource_pool`, `datastore`, `network`, `template`, `domain`, `gateway`, `netmask`, `dns_servers`, `ipam_base_ip` — **plaintext inventory** (readable, no secrets) |

> **📖 Committed demo:** `secure/dc_example_192.0.2.10/` is a committed **example
> vCenter** (100% dummy data — RFC 5737 TEST-NET) that mirrors the real layout:
> `credentials.tfvars` + `vcenter.tfvars` + `{dev,prod,staging}/vcenter.tfvars`
> overrides (prod shows `datastore99`). Deploy mirror:
> `deploy/dc_example_192.0.2.10/{dev,prod,staging}/vm-*.tfvars`. Never point the
> example name or its dummy values at real infrastructure.

---

## 2. Real-Life Integration — plug YOUR vCenter in 4 steps

### Step 0 — Prerequisites (once per machine)

```bash
bash install.sh          # installs sops, terraform, govc, age (creates age + ssh keys)
```
- age private key at `~/.config/sops/age/keys.txt` (SOPS uses it to decrypt)
- `scripts/vm-defaults.conf` optionally tweaks the defaults proposed by the wizard

### Step 1 — Onboard your vCenter (one command)

```bash
bash scripts/vcenter-setup.sh
```
Menu → **"Create NEW vCenter"** → enter your vCenter **server IP/FQDN**, then answer
the prompts: datacenter, cluster, resource pool, datastore, network, template, domain,
gateway, netmask, DNS, IPAM base IP. Password is typed twice (never echoed). Review the
summary and press **`y`** to save.

This **one command** does everything:
- **Encrypts** your credentials → `secure/<datacenter>_<server>/credentials.tfvars`
- **Writes** your inventory → `secure/<datacenter>_<server>/vcenter.tfvars`
- **Auto-creates the mirror** `deploy/<datacenter>_<server>/{dev,prod,staging}/`
  (the config directories your VM files will live in)
- **Auto-creates per-env override templates**
  → `secure/<datacenter>_<server>/{dev,prod,staging}/vcenter.tfvars`

> ⚠️ If the menu shows `Aborted. Nothing saved.` you pressed Enter at the confirm —
> default is **No**. Re-run and type `y`.

**Result:**
```text
secure/<datacenter>_<server>/credentials.tfvars        ← encrypted creds
secure/<datacenter>_<server>/vcenter.tfvars            ← inventory (source of truth)
secure/<datacenter>_<server>/{dev,prod,staging}/vcenter.tfvars
deploy/<datacenter>_<server>/{dev,prod,staging}/       ← mirror dirs, ready for VM files
```

### Step 2 — Per-environment customization (child overrides parent)

Every key lives **once** in the top-level `vcenter.tfvars`. When one environment really
differs, open **that env's child file** and uncomment + set the key:

```bash
# secure/<datacenter>_<server>/prod/vcenter.tfvars   ← PROD child
datastore = "datastore99"     # ← prod only; dev/staging keep datastore01
```

**The rule — child wins, parent is never modified:**
- Load order: **top-level** `vcenter.tfvars` → **per-env child** → **child wins per key**
- Keys left commented/absent in the child → **inherit** the parent value
- The parent file is **read-only at merge time** — editing a child **never overwrites** it
- `credentials` are **never** per-env — secrets stay only in `credentials.tfvars`

Allowed override keys: `datacenter`, `cluster`, `resource_pool`, `datastore`, `network`,
`template`, `domain`, `gateway`, `netmask`, `dns_servers`, `ipam_base_ip`.

### Step 3 — Create a VM config (auto-stored in the pre-structured dir)

```bash
bash scripts/create-vm-config.sh <datacenter>_<server> <env> <vm-name>
# e.g.  bash scripts/create-vm-config.sh dc_example_192.0.2.10 dev web-01
```

The script:
- Picks your vCenter + env (or auto-creates the env dir under `deploy/<vcenter>/`)
- **Auto-loads per-vCenter defaults** from `secure/<vcenter>/vcenter.tfvars`
- **Auto-assigns a free IP** (`next_free_ip.sh`)
- **Auto-stores** the config in the pre-structured location:
  `deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars`
- Every VM gets its **own file**; existing VMs are never touched

Review it (`vi deploy/<vcenter>/<env>/vm-<name>_<ip>.tfvars`), uncomment the blocks you
need (CPU, memory, disks, LVM, extra users…).

### Step 4 — Deploy a production-grade VM

```bash
bash scripts/deploy-vm.sh <datacenter>_<server> <env> <vm-name>
# e.g.  bash scripts/deploy-vm.sh dc_example_192.0.2.10 prod web-02
```

`deploy-vm.sh` automatically:
1. **Decrypts** that vCenter's credentials (`secure/<vcenter>/credentials.tfvars` via SOPS)
2. **Loads the inventory**, then **merges the env child on top** — a key you uncommented
   in `<env>` (e.g. prod `datastore99`) **overrides** the parent for that deploy
3. Assembles the **combined VM config** from every `deploy/<vcenter>/<env>/vm-*.tfvars`
4. Targets **only your VM** and applies against that env's **own state file**
   (`terraform/terraform.<vcenter>.<env>.tfstate`)
5. **Deletes the decrypted files** even on failure

> Result: the VM is built with **your vCenter's real credentials + that env's overridden
> inventory** — no manual wiring, no hardcoded paths, no cross-env leakage.

---

## 3. Script Cheat-Sheet

| Task | Command |
|------|---------|
| Onboard/change a vCenter | `bash scripts/vcenter-setup.sh` |
| Create a VM config | `bash scripts/create-vm-config.sh <vcenter> <env> <vm-name>` |
| Deploy a VM (targeted) | `bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>` |
| Decrypt + auto-clean | `bash scripts/sops-decrypt.sh <vcenter> <env> --clean` |
| Decrypt, apply, auto-clean | `bash scripts/sops-decrypt.sh <vcenter> <env> --apply -- [flags]` |
| Manual/scripted encrypt | `bash scripts/sops-encrypt.sh <dir>` |

---

## 4. Features & Benefits

| Feature | Benefit |
|---------|---------|
| **SOPS + age encryption** | Secrets are readable only with the private key — safe in git, no `.gitignore` hacks for real data |
| **Plaintext never persists** | Decrypted files live a few seconds as `terraform/*.auto.tfvars`, then are deleted |
| **One directory per vCenter** | Each vCenter's secrets/inventory are isolated — a prod deploy can never use another vCenter's credentials |
| **Per-env overrides** | Env-specific inventory keys go in `secure/<dir>/<env>/vcenter.tfvars`; top-level file holds the shared defaults |
| **Interactive wizard** (`vcenter-setup.sh`) | No manual `sops` syntax; menu-driven, defaults pre-filled, confirmation before write |
| **Auto mirror dirs** | Onboarding a vCenter auto-creates `deploy/<vcenter>/{dev,prod,staging}/` — config dirs are ready before you need them |
| **Auto-merged deploys** | `deploy-vm.sh` decrypts the right credentials, merges the env override, and targets only your VM |
| **Auto-clean on failure** | `deploy-vm.sh` traps errors and removes plaintext even when a deploy crashes |
| **Self-verifying** | After setup, `sops-decrypt.sh <dir> <env> --clean` proves the round-trip works |
| **vCenter-agnostic toolchain** | Adding a vCenter = run the wizard once; all deploy scripts follow `secure/<dir>/` |
| **Shared Terraform state stays safe** | Credentials are data, not logic — rotating them never triggers resource destroy |

---

## 5. How It Works (deploy-time flow)

Every deploy script takes a **vCenter + env** as its first arguments:

```bash
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-02
```

1. Reads the VM config from `deploy/dc_pilot_192.0.2.10/dev/vm-web-02_198.51.100.108.tfvars`
2. Decrypts `secure/dc_pilot_192.0.2.10/*.tfvars` → `terraform/*.auto.tfvars`
3. Merges `secure/dc_pilot_192.0.2.10/dev/vcenter.tfvars` **on top** of the top-level file
   (per-env keys win)
4. Runs `terraform apply` against `terraform/terraform.dc_pilot_192.0.2.10.dev.tfstate`
5. Deletes the decrypted `.auto.tfvars` files (even on failure)

The age **public key** is stored inside each encrypted file; the **private key** lives
at `$SOPS_AGE_KEY_FILE` (default `~/.config/sops/age/keys.txt`).

---

## 6. Manual Encrypt (when you don't want the wizard)

`vcenter-setup.sh` is the recommended path. If you need the manual/scripted route:

```bash
# 1. staging dir inside the project (sops matches rules by input path)
mkdir -p .tmp-sops-plain/dc_pilot_192.0.2.10

# 2. write plaintext files
vim .tmp-sops-plain/dc_pilot_192.0.2.10/credentials.tfvars
vim .tmp-sops-plain/dc_pilot_192.0.2.10/vcenter.tfvars

# 3. encrypt
bash scripts/sops-encrypt.sh dc_pilot_192.0.2.10

# 4. verify round-trip, then clean up
bash scripts/sops-decrypt.sh dc_pilot_192.0.2.10 dev --clean
rm -rf .tmp-sops-plain/dc_pilot_192.0.2.10
```

> **Important:** `sops --encrypt` matches `.sops.yaml` creation rules against the
> **input file path**, so plaintext must live inside the project (`.tmp-sops-plain/`),
> **not** `/tmp` — otherwise you get `no matching creation rules found`.

---

## 7. Case Analysis

### Case 1 — Deploy a new VM in dev
`deploy-vm.sh dc_pilot_192.0.2.10 dev web-02` decrypts `secure/dc_pilot_192.0.2.10/`,
builds a combined config so no VM is ever destroyed, applies
`-target=module.vm["web-02"]`, cleans up.
✅ VM gets its free IP, other VMs untouched.

### Case 2 — vCenter password rotates
Run `bash scripts/vcenter-setup.sh`, pick the vCenter, change password, save.
Only `secure/<dir>/credentials.tfvars` changes; other vCenters keep their valid secrets.

### Case 3 — Prod moves to a different cluster / datastore
Edit only `secure/<dir>/prod/vcenter.tfvars` (via wizard) — uncomment the key.
Dev and staging are unaffected; the parent file is never overwritten.

### Case 4 — Decrypted files left behind (crash)
`terraform/credentials.auto.tfvars` (plaintext) may remain. Remove with:
`bash scripts/sops-decrypt.sh dc_pilot_192.0.2.10 dev --clean`. `deploy-vm.sh` already cleans on failure.

### Case 5 — New vCenter `10.50.0.1` (datacenter `dc_north`)
`bash scripts/vcenter-setup.sh` → select "Create NEW" → enter `10.50.0.1` as the server,
then `dc_north` as the datacenter. The toolchain auto-creates
`deploy/dc_north_10.50.0.1/{dev,prod,staging}/` + `secure/dc_north_10.50.0.1/`
(dir name = `<datacenter>_<server>`); deploy scripts just read `secure/dc_north_10.50.0.1/`
and `deploy/dc_north_10.50.0.1/<env>/`.

### Case 6 — Someone commits a plaintext secret
`secure/` (except the committed demo + README) and `terraform/*.auto.tfvars` are git-ignored.
If it ever happens: rotate the password immediately, re-encrypt, and rotate the age key if
it may have leaked.

---

## 8. Security Rules (non-negotiable)

1. **Never edit the encrypted files by hand.** Always encrypt from a plaintext copy.
2. **Never commit `terraform/*.auto.tfvars`.** Plaintext, auto-cleaned.
3. **Never print `vsphere_password`** in logs or scripts.
4. Keep the age **private key** off machines that are not the deploy host.
5. Leftover file? `bash scripts/sops-decrypt.sh <dir> <env> --clean`.
6. **Never reuse `dc_example_192.0.2.10`** (the committed demo) or its dummy values for real infra.

---

## 9. Files that make this work

| Path | Role |
|------|------|
| `.sops.yaml` | SOPS creation rules (which files encrypt with which age key) |
| `scripts/vcenter-setup.sh` | Interactive wizard — onboard a vCenter (creds + inventory + mirror dirs) |
| `scripts/create-vm-config.sh` | Scaffold a per-VM config into `deploy/<vcenter>/<env>/` |
| `scripts/deploy-vm.sh` | Deploy a VM — decrypt creds, merge env override, apply, clean up |
| `scripts/sops-encrypt.sh` | Encrypt plaintext dir → `secure/<dir>/` |
| `scripts/sops-decrypt.sh` | Decrypt → `terraform/*.auto.tfvars`, with `--clean`/`--apply` |
| `~/.config/sops/age/keys.txt` | age private key (never commit, never share) |

---

*© 2026 [Rakibuzzaman (Engr. Rakib)](https://engr-rakib.github.io/web) — VMPilot. Part of the VMPilot project (see [`AUTHORS.md`](../AUTHORS.md) & [`LICENSE`](../LICENSE)).*
