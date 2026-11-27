# 02. vCenter Onboarding and Multi-Provider Setup

This guide details the process of connecting VMPilot to one or more VMware vCenter servers, encrypting management credentials using SOPS and Age, and operating multiple independent virtualization clusters with complete state isolation.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [Onboarding Architecture & State Isolation](#onboarding-architecture--state-isolation)
- [The vCenter Setup Workflow](#the-vcenter-setup-workflow)
- [SOPS-Age Secret Encryption Model](#sops-age-secret-encryption-model)
- [Step-by-Step How to Onboard a vCenter](#step-by-step-how-to-onboard-a-vcenter)
- [Real-Life Production Scenario: Multi-DC Disaster Recovery](#real-life-production-scenario-multi-dc-disaster-recovery)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

Enterprise organizations often manage multiple VMware clusters across different physical datacenters, cloud hosting providers, or isolated business units. VMPilot supports multiple vCenter environments through:

1. **Automated Discovery & Directory Scaffolding**: `scripts/vcenter-setup.sh` queries vCenter over HTTPS, discovers clusters, datastores, templates, and port groups, and populates baseline HCL configurations.
2. **Strict Cryptographic Credential Sealing**: Passwords and administrative credentials are encrypted using SOPS with Age recipient public keys. Secrets are decrypted only into transient in-memory files during Terraform execution.
3. **Independent State Ledgers**: Each vCenter and environment combination maintains its own isolated Terraform state file (`terraform.<vcenter>.<env>.tfstate`), preventing modifications in one datacenter from affecting another.

---

## Onboarding Architecture & State Isolation

When a new vCenter is onboarded, VMPilot establishes directory structures under `secure/` and `deploy/`:

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        VMPILOT PROJECT ROOT                            │
├───────────────────────────────────┬────────────────────────────────────┤
│   PRIMARY DATACENTER              │   DISASTER RECOVERY (DR) DC        │
│   (dc_pilot_192.0.2.10)           │   (dc_dr_192.0.2.20)               │
├───────────────────────────────────┼────────────────────────────────────┤
│ secure/                           │ secure/                            │
│  └── 192.0.2.10/                  │  └── 192.0.2.20/                   │
│       ├── credentials.tfvars      │       ├── credentials.tfvars       │
│       └── dc_pilot/               │       └── dc_dr/                   │
│            ├── vcenter.tfvars     │            ├── vcenter.tfvars      │
│            ├── dev/vcenter.tfvars │            ├── dev/vcenter.tfvars  │
│            └── prod/vcenter.tfvars│            └── prod/vcenter.tfvars │
│                                   │                                    │
│ deploy/                           │ deploy/                            │
│  └── 192.0.2.10/dc_pilot/         │  └── 192.0.2.20/dc_dr/             │
│       ├── dev/vm-*.tfvars         │       ├── dev/vm-*.tfvars          │
│       └── prod/vm-*.tfvars        │       └── prod/vm-*.tfvars         │
│                                   │                                    │
│ terraform/                        │ terraform/                         │
│  ├── terraform.dc_pilot.dev.state │  ├── terraform.dc_dr.dev.state     │
│  └── terraform.dc_pilot.prod.state│  └── terraform.dc_dr.prod.state    │
└───────────────────────────────────┴────────────────────────────────────┘
```

---

## The vCenter Setup Workflow

The following diagram illustrates how `scripts/vcenter-setup.sh` connects to vCenter, validates credentials, reads inventory, and encrypts secrets:

```text
┌─────────────────────────┐
│ Operator runs:          │
│ bash vcenter-setup.sh   │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Prompt for vCenter IP,  │
│ username, password, DC  │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Execute govc query:     │
│ verify 443/TCP login    │
└────────────┬────────────┘
             │
      ┌──────┴──────┐
      │ Success?    │
      └──────┬──────┘
             ├──────────────────────────┐
          YES│                        NO│
             ▼                          ▼
┌─────────────────────────┐    ┌─────────────────────────┐
│ Query live inventory:   │    │ Print exact error       │
│ clusters, datastores,   │    │ and exit with code 1    │
│ networks, templates     │    └─────────────────────────┘
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Generate vcenter.tfvars │
│ & prompt for IPAM pools │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Write credentials.tfvars│
│ & encrypt via SOPS-Age  │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Scaffolding complete:   │
│ Ready for VM creation   │
└─────────────────────────┘
```

---

## SOPS-Age Secret Encryption Model

VMPilot uses Age keys for asymmetric encryption:

- **Public Key (Recipient)**: Stored in `.sops.yaml` or provided during encryption. Files encrypted with this public key can be safely committed to source control.
- **Private Key (Identity)**: Located at `~/.config/sops/age/keys.txt`. This file remains on the VMPilot workstation and must never be committed to Git.
- **Path-Based Encryption Rules**: VMPilot encrypts any file matching `secure/*/credentials.tfvars`. Plaintext variables like cluster names, VLAN IDs, and datastores remain in `vcenter.tfvars` for easy inspection without decrypting secrets.

---

## Step-by-Step How to Onboard a vCenter

### 1. Run the Interactive Wizard
```bash
bash scripts/vcenter-setup.sh
```

### 2. Enter Connection Details
When prompted by the wizard:
1. Choose **1) Create NEW vCenter configuration**.
2. Enter the vCenter server IP or FQDN: `192.0.2.10`.
3. Enter the datacenter name: `dc_pilot`.
4. Enter the administrator username: `administrator@vsphere.local`.
5. Enter the password (input is masked).

### 3. Review Auto-Discovered Inventory
The wizard connects via `govc` and automatically selects or prompts for:
- Target Compute Cluster (e.g., `Cluster-01`)
- Default Datastore (e.g., `datastore-san-01`)
- Default Virtual Machine Network / Port Group (e.g., `VM-VLAN-100`)
- Base OS VM Template (e.g., `ubuntu-22.04-template`)
- Network Gateway, Netmask, and DNS servers
- Subnet IPAM allocation range (e.g., `198.51.100.100-200`)

### 4. Verify Generated Files
```bash
# Check plaintext inventory configuration
cat secure/192.0.2.10/dc_pilot/vcenter.tfvars

# Confirm credentials are encrypted with SOPS
head -n 10 secure/192.0.2.10/credentials.tfvars
```
The file should contain `sops_version`, `mac`, and encrypted ciphertext fields.

---

## Real-Life Production Scenario: Multi-DC Disaster Recovery

### Scenario
An enterprise runs its primary production workloads in `dc_pilot_192.0.2.10` and maintains a cold disaster recovery site in `dc_dr_192.0.2.20`. The DR site has different datastores (`san-dr-01`) and different network subnets (`198.51.200.0/24`).

### Execution
1. **Primary Onboarding**:
   ```bash
   # Already onboarded as dc_pilot_192.0.2.10
   ls secure/192.0.2.10/dc_pilot/
   ```
2. **DR Site Onboarding**:
   ```bash
   bash scripts/vcenter-setup.sh
   # Select "Create NEW", enter 192.0.2.20, datacenter dc_dr
   ```
3. **Deploy VM into Primary**:
   ```bash
   bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod app-primary-01
   ```
4. **Deploy Mirror VM into DR**:
   ```bash
   bash scripts/deploy-vm.sh dc_dr_192.0.2.20 prod app-dr-01
   ```

**Outcome**:
Both environments operate independently. Modifying or destroying resources in `dc_dr_192.0.2.20` cannot affect running workloads in `dc_pilot_192.0.2.10`.

---

## Guardrails & Common Mistakes

| Problem | Root Cause | Solution |
| :--- | :--- | :--- |
| **`govc: unauthorized`** | Incorrect SSO credentials or user lacks administrator privileges | Test authentication manually: `GOVC_INSECURE=1 govc about -u "user:password@host"`. Verify permissions in vCenter. |
| **Credentials file not encrypted** | Age key was not detected during wizard execution | Verify that `~/.config/sops/age/keys.txt` exists. Run `sops --encrypt --in-place secure/<server>/credentials.tfvars`. |
| **Port group name mismatch** | Distributed Virtual Switch (DVS) port group names containing special characters | Ensure the exact network name as seen in vCenter is enclosed in double quotes inside `vcenter.tfvars`. |

---

[◄ Back to 01. Architecture](01-architecture-and-connections.md) | [Next: 03. Environments, Common Vars & Policies ►](03-environments-common-vars-and-policies.md)
