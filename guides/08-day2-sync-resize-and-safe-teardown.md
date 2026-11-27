# 08. Day-2 Sync, Resize and Safe Teardown

This guide covers operational lifecycle management, in-place compute and storage expansion, automated synchronization loops (`deploy-sync.sh`), state-guarded decommissioning (`destroy.sh`), and disaster recovery.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [Day-2 Operations Lifecycle Architecture](#day-2-operations-lifecycle-architecture)
- [In-Place Compute and Storage Resizing](#in-place-compute-and-storage-resizing)
- [Automated Sync Loop (`deploy-sync.sh`) & Rules R1–R6](#automated-sync-loop-deploy-syncsh--rules-r1r6)
- [Safe Decommissioning with `destroy.sh`](#safe-decommissioning-with-destroysh)
- [Recovering from Out-of-Band vCenter Deletions](#recovering-from-out-of-band-vcenter-deletions)
- [Full Project Backup & Recovery (`backup.sh`)](#full-project-backup--recovery-backupsh)
- [Step-by-Step Operator Usage](#step-by-step-operator-usage)
- [Real-Life Production Scenarios](#real-life-production-scenarios)
  - [Scenario A: In-Place CPU & RAM Scaling with Zero Downtime](#scenario-a-in-place-cpu--ram-scaling-with-zero-downtime)
  - [Scenario B: Recovering from Accidental GUI Deletion in vCenter](#scenario-b-recovering-from-accidental-gui-deletion-in-vcenter)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

Provisioning a virtual machine is only the first step. Over its operational lifecycle, teams must scale resources, handle configuration drift, synchronize large fleets, and safely decommission obsolete workloads.

VMPilot provides:
1. **In-Place Compute & Storage Scaling**: Modify vCPU count, RAM, or disk capacity directly in the `.tfvars` file and apply changes without rebuilding the VM.
2. **Automated Fleet Synchronization (`deploy-sync.sh`)**: Enforces rules R1 through R6 across entire directory trees, skipping unchanged machines and deploying new configurations.
3. **State-Protected Decommissioning (`destroy.sh`)**: Backs up the Terraform state ledger, safely removes the target resource using `terraform state rm`, and destroys the VM via `govc vm.destroy`.
4. **Complete Project Backup (`backup.sh`)**: Bundles configurations, inventory, and encrypted credentials into rotating `.tar.gz` archives with point-in-time restore capabilities.

---

## Day-2 Operations Lifecycle Architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│ DAY-2 OPERATIONAL WORKFLOWS                                            │
├───────────────────────────────────┬────────────────────────────────────┤
│ 1. COMPUTE & STORAGE RESIZING     │ In-place CPU/RAM hot-add           │
│                                   │ Online LVM volume expansion        │
├───────────────────────────────────┼────────────────────────────────────┤
│ 2. FLEET RECONCILIATION           │ bash scripts/deploy-sync.sh        │
│                                   │ Rules R1–R6 evaluation             │
├───────────────────────────────────┼────────────────────────────────────┤
│ 3. SAFE DECOMMISSIONING           │ bash scripts/destroy.sh            │
│                                   │ State backup -> state rm -> govc   │
├───────────────────────────────────┼────────────────────────────────────┤
│ 4. OUT-OF-BAND RECOVERY           │ Reconcile orphaned state entries   │
│                                   │ Re-deploy or remove without errors │
├───────────────────────────────────┼────────────────────────────────────┤
│ 5. DISASTER RECOVERY & BACKUPS    │ bash scripts/backup.sh             │
│                                   │ Rotating archives (keeps last 5)   │
└───────────────────────────────────┴────────────────────────────────────┘
```

---

## In-Place Compute and Storage Resizing

### 1. Scaling CPU and RAM
When hot-add is enabled on the virtual machine template, memory and CPU changes can be applied without downtime:
1. Edit the VM configuration file:
   ```hcl
   # deploy/192.0.2.10/dc_pilot/prod/vm-db-01_198.51.100.45.tfvars
   cpu    = 8     # previously 4
   memory = 16384 # previously 8192
   ```
2. Apply the change:
   ```bash
   bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod db-01
   ```
3. Terraform updates the virtual hardware definition via the vSphere API.

### 2. Expanding Storage Volumes
1. Increase `disk_size` in the configuration file (e.g., from `50` to `100` GB).
2. Apply the configuration.
3. In-guest LVM expansion:
   ```bash
   ssh ubuntu@198.51.100.45
   # Rescan the SCSI bus
   echo 1 | sudo tee /sys/class/block/sda/device/rescan
   # Grow partition and LVM physical volume
   sudo growpart /dev/sda 3
   sudo pvresize /dev/sda3
   # Expand logical volume and filesystem online
   sudo lvextend -r -l +100%FREE /dev/vg_os/lv_root
   ```

---

## Automated Sync Loop (`deploy-sync.sh`) & Rules R1–R6

The sync loop enables automated directory-driven provisioning:

```bash
bash scripts/deploy-sync.sh dc_pilot_192.0.2.10 prod
```

### The Synchronization Rules Engine:
- **Rule R1 (New Config)**: Detected config without matching state -> executes deployment.
- **Rule R2 (Unchanged)**: Hostname, IP, and parameters match -> skips deployment (no-op).
- **Rule R3 (Modified Parameters)**: Detected attribute diff -> re-applies targeted deployment.
- **Rule R4 (Key Normalization)**: Normalizes map key to match hostname before processing.
- **Rule R5 (Missing Config Protection)**: A VM present in state but missing its `.tfvars` file is **never** auto-destroyed. A warning is surfaced to the operator.
- **Rule R6 (Idempotent Execution)**: Re-running the sync loop multiple times produces identical results.

---

## Safe Decommissioning with `destroy.sh`

Because VMPilot applies `prevent_destroy = true` on virtual machine resources to prevent accidental destruction, standard `terraform destroy` commands are rejected.

Decommissioning is handled safely by `scripts/destroy.sh`:

```text
┌─────────────────────────┐
│ bash destroy.sh <vm>    │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Step W1: State Backup   │
│ Create .tfstate.bak     │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Step W2: Operator Check │
│ Prompt: type VM name    │
│ (or pass --yes)         │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Step W3: Power Off VM   │
│ govc vm.power -off      │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Step W4: State Removal  │
│ terraform state rm      │
│ module.vm["<name>"]     │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Step W5: vCenter Delete │
│ govc vm.destroy         │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Step W6: Config Archive │
│ Remove or keep .tfvars  │
└─────────────────────────┘
```

---

## Recovering from Out-of-Band vCenter Deletions

If a user deletes a VM directly from the vSphere Client GUI, Terraform's state becomes out of sync:

```text
Error: VirtualMachine with ID "vm-12345" was not found
```

### Recovery Procedure:
1. **Remove the Missing Resource from State**:
   ```bash
   terraform -chdir=terraform state rm \
     -state=terraform/terraform.dc_pilot_192.0.2.10.prod.tfstate \
     'module.vm["web-01"].vsphere_virtual_machine.this'
   ```
2. **Re-Deploy from Configuration**:
   ```bash
   bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod web-01
   ```
Terraform detects the missing instance and recreates it cleanly.

---

## Full Project Backup & Recovery (`backup.sh`)

`scripts/backup.sh` provides interactive and automated project archiving:

```bash
# Direct backup invocation
bash scripts/backup.sh /opt/terraform-lab/projects/VMPilot /backups

# Interactive menu
bash scripts/backup.sh
```

### Key Capabilities:
- Creates timestamped archives (e.g., `vmpilot-backup-20261122-143000.tar.gz`).
- Automatically excludes `.git/`, `.terraform/`, and transient files.
- Maintains a 5-archive rotation policy, automatically pruning older backups.
- Pre-saves active state before performing any restore operation.

---

## Step-by-Step Operator Usage

### 1. Run a Fleet Sync Dry-Run
```bash
bash scripts/deploy-sync.sh dc_pilot_192.0.2.10 prod --plan
```

### 2. Execute a Safe VM Decommission
```bash
bash scripts/destroy.sh dc_pilot_192.0.2.10 prod old-web-01
```

### 3. Generate a Project Backup
```bash
bash scripts/backup.sh /opt/terraform-lab/projects/VMPilot /var/backups/vmpilot
```

---

## Real-Life Production Scenarios

### Scenario A: In-Place CPU & RAM Scaling with Zero Downtime
A database server experiences high CPU load during month-end processing.

**Action**:
1. Edit `deploy/192.0.2.10/dc_pilot/prod/vm-db-01_198.51.100.45.tfvars` to increase `cpu = 8` and `memory = 32768`.
2. Run deploy:
   ```bash
   bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod db-01
   ```
3. VMware vSphere allocates the additional cores and RAM to the running guest without requiring a restart.

---

### Scenario B: Recovering from Accidental GUI Deletion in vCenter
A junior administrator accidentally deletes a staging API VM from the vCenter Web UI.

**Action**:
1. Run `destroy.sh` with `--keep-config` to clean up the state ledger:
   ```bash
   bash scripts/destroy.sh dc_pilot_192.0.2.10 staging api-stage-01 --yes --keep-config
   ```
2. Re-deploy the VM immediately from the preserved configuration file:
   ```bash
   bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 staging api-stage-01
   ```

**Outcome**:
The VM is restored with its original static IP, storage layout, hardening baseline, and RBAC roles within 2 to 3 minutes.

---

## Guardrails & Common Mistakes

| Problem | Root Cause | Solution |
| :--- | :--- | :--- |
| **`prevent_destroy` prevents teardown** | Running `terraform destroy` directly | Use `bash scripts/destroy.sh`, which safely performs state removal before deleting the VM. |
| **State lock error during sync** | Another deploy process is running or aborted abnormally | Verify no background Terraform processes exist, then clear the lock file if safe. |
| **Filesystem does not show resized disk** | Disk resized in vSphere but guest partition table not updated | Run `growpart` and `pvresize` inside the guest OS to expand the LVM volume. |

---

[◄ Back to 07. RBAC & Auditing](07-rbac-users-groups-and-auditing.md) | [Back to Guide Index ►](README.md)
