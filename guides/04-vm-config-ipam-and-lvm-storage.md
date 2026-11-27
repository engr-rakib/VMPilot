# 04. VM Config, IPAM and LVM Storage Architecture

This guide covers authoring virtual machine configurations using `create-vm-config.sh`, parallel IPAM address allocation (`next_free_ip.sh`), subnet boundary validation, and the dual Logical Volume Manager (LVM) storage model.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [VM Config Scaffolding Architecture](#vm-config-scaffolding-architecture)
- [Parallel IPAM & Address Reservation](#parallel-ipam--address-reservation)
- [Declared IP Subnet CIDR Validation](#declared-ip-subnet-cidr-validation)
- [Dual-LVM Storage Layout (`vg_os` and `vg_data`)](#dual-lvm-storage-layout-vg_os-and-vg_data)
- [Step-by-Step Operator Usage](#step-by-step-operator-usage)
- [Real-Life Production Scenarios](#real-life-production-scenarios)
  - [Scenario A: Standard Stateless Web Application VM](#scenario-a-standard-stateless-web-application-vm)
  - [Scenario B: PostgreSQL Database VM with Dedicated LVM Data Volume](#scenario-b-postgresql-database-vm-with-dedicated-lvm-data-volume)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

Manual virtual machine creation frequently results in configuration drift, duplicate IP address conflicts, and fragile disk layouts that require downtime to resize later. VMPilot eliminates these issues by providing:

1. **Interactive Config Scaffolding**: `scripts/create-vm-config.sh` dynamically queries vCenter for active compute resources and templates, validating memory, CPU, and disk sizing in real time.
2. **Automated Parallel IPAM**: Computes the next free IP address in the target subnet using parallel ICMP ping sweeps and existing state scans, respecting a 30-address reservation buffer (`RESERVE=30`).
3. **Enterprise Dual-LVM Partitioning**: Distinguishes between the operating system disk group (`vg_os`) and user data disk groups (`vg_data`), enabling online volume expansion without filesystem corruption risks.

---

## VM Config Scaffolding Architecture

The following diagram illustrates how `create-vm-config.sh` and `next_free_ip.sh` generate a valid VM configuration:

```text
┌─────────────────────────────────┐
│ Operator runs:                  │
│ bash create-vm-config.sh        │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Select vCenter & Environment    │
│ (e.g., dc_pilot / prod)         │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Query live inventory (govc):    │
│ clusters, datastores, networks  │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Run IPAM discovery:             │
│ next_free_ip.sh                 │
│  - Reads state ledgers          │
│  - Parallel ICMP sweeps         │
│  - Skips gateway + RESERVE=30   │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Prompt for CPU, RAM, OS Disk,   │
│ Data Disks & LVM mounts         │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│ Write & format file:            │
│ deploy/<server>/<vcenter>/      │
│   <env>/vm-<name>_<ip>.tfvars   │
└─────────────────────────────────┘
```

---

## Parallel IPAM & Address Reservation

VMPilot allocates IP addresses deterministically using `scripts/next_free_ip.sh`:

1. **State Scanning**: Inspects all active Terraform state files for the target vCenter to find previously provisioned IP addresses.
2. **Directory Scanning**: Scans all `.tfvars` files under `deploy/` to catch IPs allocated to pending configurations that have not yet been applied.
3. **Parallel ICMP Probing**: Runs concurrent background `ping -c 1 -W 1` sweeps across the subnet to verify that no untracked physical server or appliance is using the candidate IP.
4. **Reservation Buffer (`RESERVE=30`)**: Automatically reserves the first 30 host addresses of every subnet for network infrastructure (gateways, routers, firewalls, and management controllers).

```text
Subnet Range: 198.51.100.0/24
├── 198.51.100.1           -> Gateway
├── 198.51.100.2 - .30     -> RESERVED (Network Infrastructure Buffer)
├── 198.51.100.31          -> FIRST ELIGIBLE VMPILOT IP
└── 198.51.100.32 - .254   -> Dynamic Allocation Pool
```

---

## Declared IP Subnet CIDR Validation

If an operator manually enters an IP address instead of using auto-allocation, VMPilot runs a pre-flight CIDR check:

- The script compares the declared IP against the CIDR definition in `network_subnets` (e.g., `198.51.100.0/24`).
- If an operator accidentally assigns `192.0.2.55` to a port group configured for `198.51.100.0/24`, the deployment fails immediately before invoking Terraform.

---

## Dual-LVM Storage Layout (`vg_os` and `vg_data`)

VMPilot separates OS system directories from persistent application data disks:

```text
Disk 1: OS Disk (e.g., 40 GB)
├── /boot (1 GB, ext4)
└── Volume Group: vg_os
    ├── lv_root  -> /      (15 GB, xfs)
    ├── lv_var   -> /var   (10 GB, xfs)
    ├── lv_tmp   -> /tmp   (5 GB,  xfs, nodev/nosuid/noexec)
    ├── lv_home  -> /home  (5 GB,  xfs, nodev)
    └── lv_swap  -> swap   (4 GB,  swap)

Disk 2: Dedicated Data Disk (e.g., 100 GB)
└── Volume Group: vg_data
    └── lv_data  -> /data  (100 GB, xfs, mounted with custom flags)
```

**Benefits of this layout**:
- Application logs or large database tables filling up `/data` cannot crash the host OS kernel or prevent SSH root login.
- `/tmp` is mounted with hardening options (`nodev,nosuid,noexec`), preventing arbitrary binary execution from temporary directories.

---

## Step-by-Step Operator Usage

### 1. Scaffolding a VM Configuration Interactively
```bash
bash scripts/create-vm-config.sh dc_pilot_192.0.2.10 prod web-01
```

Follow the prompts:
1. **VM Name**: `web-01`
2. **IP Address**: Press Enter to accept the automatically discovered free IP (e.g., `198.51.100.31`).
3. **vCPU Count**: `4`
4. **Memory (MB)**: `8192` (8 GB)
5. **OS Disk Size (GB)**: `50`
6. **Additional Data Disk**: Select `y` or `n`.

### 2. Inspect the Generated Configuration File
```bash
cat deploy/192.0.2.10/dc_pilot/prod/vm-web-01_198.51.100.31.tfvars
```

---

## Real-Life Production Scenarios

### Scenario A: Standard Stateless Web Application VM
A front-end web server requiring 2 vCPUs, 4 GB RAM, and a single 40 GB boot disk.

**Configuration File (`vm-web-01_198.51.100.31.tfvars`)**:
```hcl
vm_configs = {
  web-01 = {
    hostname        = "web-01"
    ip_address      = "198.51.100.31"
    cpu             = 2
    memory          = 4096
    disk_size       = 40
    enable_node_exporter = true
  }
}
```

---

### Scenario B: PostgreSQL Database VM with Dedicated LVM Data Volume
A relational database requiring 8 vCPUs, 32 GB RAM, a 50 GB OS disk, and a secondary 200 GB disk dedicated to `/var/lib/postgresql` on `vg_data`.

**Configuration File (`vm-db-01_198.51.100.45.tfvars`)**:
```hcl
vm_configs = {
  db-01 = {
    hostname        = "db-01"
    ip_address      = "198.51.100.45"
    cpu             = 8
    memory          = 32768
    disk_size       = 50
    enable_node_exporter = true
    data_disks = [
      {
        size_gb     = 200
        mount_path  = "/var/lib/postgresql"
        filesystem  = "xfs"
        vg_name     = "vg_data"
        lv_name     = "lv_postgres"
      }
    ]
  }
}
```

**Outcome**:
During first boot, `cloud-init` partitions the second virtual disk (`/dev/sdb`), initializes the `vg_data` volume group, creates `lv_postgres`, formats it as XFS, mounts it to `/var/lib/postgresql`, and persists the mount configuration in `/etc/fstab`.

---

## Guardrails & Common Mistakes

| Problem | Root Cause | Solution |
| :--- | :--- | :--- |
| **`IP outside subnet CIDR` error** | The entered IP does not belong to the target network's CIDR block | Check `network_subnets` in `vcenter.tfvars` and ensure the IP matches the subnet range. |
| **Duplicate IP warning** | IP was manually assigned without checking running hosts | Allow `create-vm-config.sh` to auto-discover free IPs via ICMP and state checks. |
| **Data disk fails to mount** | Invalid filesystem type or overlapping mount paths | Ensure mount paths start with `/` (e.g., `/data`) and specify supported filesystems (`xfs` or `ext4`). |

---

[◄ Back to 03. Environments & Policies](03-environments-common-vars-and-policies.md) | [Next: 05. Test, Plan, Build & Deploy ►](05-test-plan-build-and-deploy.md)
