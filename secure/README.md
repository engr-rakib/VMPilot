# secure/ — Encrypted vCenter Credentials & Inventory

This directory holds the **only secrets** in the project: vSphere credentials and the
vCenter inventory names every VM deployment depends on. Everything here is encrypted
with **SOPS (Mozilla) + age**, so it is **safe to commit to git**.

---

## 1. What's Inside

```text
secure/
├── README.md                <- you are here
└── <datacenter>_<server>/    <- one dir per vCenter (name = <datacenter>_<server>)
    ├── credentials.tfvars   <- ENCRYPTED: vsphere server / user / password
    ├── vcenter.tfvars       <- PLAINTEXT: datacenter / cluster / datastore / network / template
    └── {dev,prod,staging}/  <- OPTIONAL per-env overrides (see §3)
        └── vcenter.tfvars   <-   all-commented template; uncomment keys that differ per env
```

| File | Contents |
|------|----------|
| `credentials.tfvars` | `vsphere_server`, `vsphere_user`, `vsphere_password`, `allow_unverified_ssl` — **SOPS-encrypted** |
| `vcenter.tfvars`     | `datacenter`, `cluster`, `resource_pool`, `datastore`, `network`, `template`, `domain`, `gateway`, `netmask`, `dns_servers`, `ipam_base_ip` — **plaintext inventory** (readable, no secrets) |

> **Current state (2026-08-08):** one vCenter (`dc_pilot_192.0.2.10`,
> server `192.0.2.10`, datacenter `dc_pilot`). Legacy flat
> `secure/{dev,prod,staging}/` dirs are kept in parallel but no longer used.
> Adding a second vCenter creates its own `secure/<datacenter>_<server>/` automatically.

---

## 2. Quick Start (fastest path)

### Configure a new / different vCenter — one interactive command

```bash
bash scripts/vcenter-setup.sh
```

It shows a menu of existing vCenters, lets you pick one or create a new one (which
auto-creates `deploy/<datacenter>_<server>/{dev,prod,staging}/` +
`secure/<datacenter>_<server>/`), loads the current values as defaults, and asks
for everything it needs. `Enter` keeps a default; password is typed twice and
confirmed. Nothing is written until you approve the summary.

### Per-env override files (`secure/<datacenter>_<server>/<env>/vcenter.tfvars`)

Most inventory keys are the same across envs, so they live once in the top-level
`secure/<datacenter>_<server>/vcenter.tfvars`. When one env genuinely differs
(e.g. prod uses a different `datastore` or `network`), uncomment that key in the
per-env file:

```
# secure/dc_pilot_192.0.2.10/prod/vcenter.tfvars
datastore = "datastore99"
```

Merging rules (enforced by `sops-decrypt.sh` / `create-vm-config.sh`):

- Load order: top-level `vcenter.tfvars` first, then the per-env file — **per-env wins per key**.
- Only these keys may be overridden: `datacenter`, `cluster`, `resource_pool`, `datastore`, `network`, `template`, `domain`, `gateway`, `netmask`, `dns_servers`, `ipam_base_ip`.
- Commented/absent keys fall back to the top-level value.
- `credentials` are **never** per-env — secrets live only in `secure/<datacenter>_<server>/credentials.tfvars`.

### Deploy a VM afterwards

```bash
bash scripts/deploy-vm.sh <datacenter>_<server> <env> <vm-name>     # decrypts secure/<datacenter>_<server>/ automatically
```

### Full script cheat-sheet

| Task | Command |
|------|---------|
| Interactive vCenter setup (recommended) | `bash scripts/vcenter-setup.sh` |
| Encrypt existing plaintext dir | `bash scripts/sops-encrypt.sh <dir>` |
| Decrypt + auto-clean | `bash scripts/sops-decrypt.sh <dir> <env> --clean` |
| Decrypt, apply, auto-clean | `bash scripts/sops-decrypt.sh <dir> <env> --apply -- [flags]` |
| Clean up leftover plaintext | `bash scripts/sops-decrypt.sh <dir> <env> --clean` |
| Deploy a VM | `bash scripts/deploy-vm.sh <dir> <env> <vm-name>` |

---

## 3. Features & Benefits

| Feature | Benefit |
|---------|---------|
| **SOPS + age encryption** | Secrets are readable only with the private key — safe in git, no `.gitignore` hacks for real data |
| **Plaintext never persists** | Decrypted files live a few seconds as `terraform/*.auto.tfvars`, then are deleted |
| **One directory per vCenter** | Each vCenter's secrets/inventory are isolated — a prod deploy can never use another vCenter's credentials |
| **Per-env overrides** | Env-specific inventory keys go in `secure/<dir>/<env>/vcenter.tfvars`; top-level file holds the shared defaults |
| **Interactive wizard** (`vcenter-setup.sh`) | No manual `sops` syntax; menu-driven, defaults pre-filled, confirmation before write |
| **Auto-clean on failure** | `deploy-vm.sh` traps errors and removes plaintext even when a deploy crashes |
| **Scripted/CI path** (`sops-encrypt.sh`) | Non-interactive encryption for automation or bulk changes |
| **Self-verifying** | After setup, `sops-decrypt.sh <dir> <env> --clean` proves the round-trip works |
| **vCenter-agnostic toolchain** | Adding a vCenter = run the wizard once; all deploy scripts follow `secure/<dir>/` |
| **Shared Terraform state stays safe** | Credentials are data, not logic — rotating them never triggers resource destroy |

---

## 4. How It Works (deploy-time flow)

Every deploy script takes a vCenter + env as its first arguments:

```bash
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 dev web-02
```

1. Reads the VM config from `deploy/dc_pilot_192.0.2.10/dev/vm-web-02_198.51.100.108.tfvars`
2. Decrypts `secure/dc_pilot_192.0.2.10/*.tfvars` → `terraform/*.auto.tfvars`
3. Runs `terraform apply` against `terraform/terraform.dc_pilot_192.0.2.10.dev.tfstate`
4. Deletes the decrypted `.auto.tfvars` files (even on failure)

The age **public key** is stored inside each encrypted file; the **private key** lives
at `$SOPS_AGE_KEY_FILE` (default `~/.config/sops/age/keys.txt`).

---

## 5. Manual Encrypt (when you don't want the wizard)

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

## 6. Case Analysis

### Case 1 — Deploy a new VM in dev
`deploy-vm.sh dc_pilot_192.0.2.10 dev web-02` decrypts `secure/dc_pilot_192.0.2.10/`,
builds a combined config so no VM is ever destroyed, applies
`-target=module.vm["web-02"]`, cleans up.
✅ VM gets `.108`, other VMs untouched.

### Case 2 — vCenter password rotates
Run `bash scripts/vcenter-setup.sh`, pick the vCenter, change password, save.
Only `secure/<dir>/credentials.tfvars` changes; other vCenters keep their valid secrets.

### Case 3 — Prod moves to a different cluster
Edit only `secure/<dir>/vcenter.tfvars` (via wizard). Other vCenters unaffected.
Shared state means nothing is destroyed — inventory names are just data.

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
`secure/` and `terraform/*.auto.tfvars` are git-ignored. If it ever happens: rotate the
password immediately, re-encrypt, and rotate the age key if it may have leaked.

---

## 7. Security Rules (non-negotiable)

1. **Never edit the encrypted files by hand.** Always encrypt from a plaintext copy.
2. **Never commit `terraform/*.auto.tfvars`.** Plaintext, auto-cleaned.
3. **Never print `vsphere_password`** in logs or scripts.
4. Keep the age **private key** off machines that are not the deploy host.
5. Leftover file? `bash scripts/sops-decrypt.sh <dir> <env> --clean`.

---

## 8. Files that make this work

| Path | Role |
|------|------|
| `.sops.yaml` | SOPS creation rules (which files encrypt with which age key) |
| `scripts/vcenter-setup.sh` | Interactive wizard (recommended) |
| `scripts/sops-encrypt.sh` | Encrypt plaintext dir → `secure/<dir>/` |
| `scripts/sops-decrypt.sh` | Decrypt → `terraform/*.auto.tfvars`, with `--clean`/`--apply` |
| `~/.config/sops/age/keys.txt` | age private key (never commit, never share) |
