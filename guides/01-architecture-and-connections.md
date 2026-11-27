# 01. Architecture and Network Connections

This guide provides an overview of the VMPilot system architecture, network connectivity requirements, port topologies, and the distinction between the open-source CLI core and the commercial enterprise console.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [System Architecture & Layer Model](#system-architecture--layer-model)
- [Network & Port Connection Topology](#network--port-connection-topology)
- [Firewall Pre-Flight Checklist](#firewall-pre-flight-checklist)
- [Open-Source CLI vs Commercial Web Console](#open-source-cli-vs-commercial-web-console)
- [Step-by-Step Operator Verification](#step-by-step-operator-verification)
- [Real-Life Production Scenario](#real-life-production-scenario)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

VMPilot provides deterministic, repeatable infrastructure provisioning for VMware vSphere environments. Rather than requiring operator access to the vSphere Client GUI or running monolithic Terraform configurations that risk modifying unintended resources, VMPilot establishes:

1. **Layered Separation of Concerns**: Clear boundary between operator CLI commands, declarative configuration files, Terraform state orchestration, vSphere API calls, and in-guest cloud-init provisioning.
2. **Predictable Port Boundaries**: Clear network requirements between the control station, target vCenters, ESXi hosts, and newly provisioned guest VMs.
3. **Strict Blast-Radius Containment**: Terraform applies are targeted strictly to individual virtual machine modules (`-target='module.vm["<name>"]'`), protecting running production instances from unintended modification.

---

## System Architecture & Layer Model

VMPilot is structured into five functional layers:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ L1  OPERATOR CLI LAYER                                                     │
│     install.sh · vcenter-setup.sh · create-vm-config.sh · deploy-vm.sh     │
│     deploy-sync.sh · destroy.sh · backup.sh · next_free_ip.sh              │
├────────────────────────────────────────────────────────────────────────────┤
│ L2  DECLARATIVE CONFIGURATION LAYER (Source of Truth)                      │
│     deploy/<server>/<vcenter>/<env>/vm-<name>_<ip>.tfvars                  │
│     secure/<server>/<vcenter>/vcenter.tfvars (Plaintext Inventory)         │
│     secure/<server>/credentials.tfvars       (SOPS-Age Encrypted Secrets)  │
├────────────────────────────────────────────────────────────────────────────┤
│ L3  TERRAFORM ORCHESTRATION LAYER (Terraform >= 1.6)                       │
│     main.tf · module.vm · IPAM external data source · duplicate IP checks  │
│     Isolated per-vCenter and per-environment state ledgers                 │
├────────────────────────────────────────────────────────────────────────────┤
│ L4  VIRTUALIZATION CONTROL PLANE                                           │
│     vmware/vsphere provider (~> 2.16) · govc CLI (>= 0.30)                 │
│     Template cloning · OVF / cloud-init guestinfo injection · VM power-on  │
├────────────────────────────────────────────────────────────────────────────┤
│ L5  IN-GUEST CONFIGURATION & HARDENING PLANE                               │
│     Cloud-init user-data / network-config · /etc/vmpilot/hardening.sh       │
│     CIS-aligned sysctl tuning · SSH Ed25519 gate · 19 automated CHECKs     │
└────────────────────────────────────────────────────────────────────────────┘
```

- **L1 to L2**: Interactive CLI utilities generate valid HCL `.tfvars` files. Operators can also review, edit, or commit these files directly to Git.
- **L2 to L3**: The deployment engine aggregates environment variables, decrypts credentials into transient RAM-backed files, and executes targeted Terraform plans.
- **L3 to L4**: Terraform connects over HTTPS (`443/TCP`) to VMware vCenter to clone templates, attach networks, allocate disks, and inject guest configuration via VMware Tools `guestinfo`.
- **L4 to L5**: Upon power-on, `cloud-init` configures static IP networking, formats LVM storage, provisions system users, and executes hardening scripts.

---

## Network & Port Connection Topology

The diagram below illustrates the exact ports and communication paths between VMPilot and the target infrastructure:

```text
┌──────────────────────────┐
│      VMPilot Station     │
│  (Terraform / govc host) │
└─────────────┬────────────┘
              │
              ├────── 443/TCP (HTTPS) ──────────────────► ┌──────────────────────────┐
              │                                           │  VMware vCenter Server   │
              │                                           │  (e.g., 192.0.2.10)      │
              │                                           └──────────────────────────┘
              │
              ├────── ICMP (Echo Request/Reply) ────────► ┌──────────────────────────┐
              │                                           │  Provisioned Guest VM    │
              ├────── 22/TCP (SSH Handshake & Hardening)─►│  (e.g., 198.51.100.121)  │
              │                                           └────────────┬─────────────┘
              │                                                        │
              └────── 9100/TCP (Prometheus Metrics - Optional) ◄───────┘
```

### Connection Port Matrix

| Source | Destination | Protocol / Port | Purpose | Criticality |
| :--- | :--- | :--- | :--- | :--- |
| VMPilot Host | vCenter Server | `443/TCP` | vSphere REST & SOAP API authentication, inventory discovery, VM cloning | **Mandatory** |
| VMPilot Host | Guest VM Subnet | `ICMP` (ping) | Pre-flight free IP detection (`next_free_ip.sh`) and post-deploy diagnostic | **Mandatory** |
| VMPilot Host | Guest VM | `22/TCP` | Reboot-tolerant SSH gate (300s window) and in-guest hardening execution | **Mandatory** |
| Prometheus | Guest VM | `9100/TCP` | Prometheus node_exporter metrics scrape (enabled when `enable_node_exporter = true`) | Optional |
| Guest VM | NTP Server / DNS | `123/UDP`, `53/UDP` | Chrony time synchronization and recursive domain name resolution | **Mandatory** |
| Guest VM | Package Mirrors | `80/TCP`, `443/TCP` | OS package updates and security patches | Optional (for updates) |

---

## Firewall Pre-Flight Checklist

Before deploying your first virtual machine from a newly installed VMPilot workstation, verify network paths using standard system utilities:

```bash
# 1. Test HTTPS connectivity to vCenter
curl -k -s -o /dev/null -w "%{http_code}\n" https://192.0.2.10/sdk

# 2. Verify govc API authentication
export GOVC_URL="https://192.0.2.10"
export GOVC_INSECURE="true"
govc about

# 3. Test ICMP reachability to the target VM gateway
ping -c 2 198.51.100.1

# 4. Verify local port binding permissions
nc -zv 192.0.2.10 443
```

---

## Open-Source CLI vs Commercial Web Console

VMPilot provides two operational tiers:

```text
┌───────────────────────────────────────────┬───────────────────────────────────────────┐
│       OPEN-SOURCE CLI CORE (Free)         │       ENTERPRISE WEB CONSOLE (Paid)       │
├───────────────────────────────────────────┼───────────────────────────────────────────┤
│ • Native Linux CLI & Bash wizards         │ • Web GUI with responsive dark mode       │
│ • Targeted Terraform deployment engine    │ • 38-privilege vCenter-grade RBAC         │
│ • SOPS-Age credential encryption          │ • Real-time SSE pipeline log streaming    │
│ • Two-phase OS hardening (19 CHECK probes)│ • 30-second live fleet metrics polling    │
│ • Linux guest RBAC (/var/log/sudo.log)    │ • Alert routing (Telegram, Email, Bell)   │
│ • Safe destroy via scripts/destroy.sh     │ • Veeam-grade delta BDR hot restore       │
│ • MIT License (Public GitHub)             │ • Proprietary LICENSE-COMMERCIAL          │
└───────────────────────────────────────────┴───────────────────────────────────────────┘
```

Both tiers share identical configuration files under `deploy/`, identical encrypted credentials under `secure/`, and identical state files under `terraform/`. Adopting the commercial console requires no modifications to existing configurations.

---

## Step-by-Step Operator Verification

Follow these steps to confirm your host environment is operational:

1. **Verify Binary Dependencies**:
   ```bash
   terraform -version
   govc version
   sops --version
   age --version
   jq --version
   ```
2. **Inspect Local Keys**:
   ```bash
   ls -la ~/.config/sops/age/keys.txt
   ls -la ~/.ssh/id_ed25519.pub
   ```
3. **Verify Git Repository Status**:
   ```bash
   git status
   ```

---

## Real-Life Production Scenario

### Scenario: Isolated Bastion Workstation in a Segmented Datacenter
An infrastructure team operates VMPilot from a management bastion (`192.0.2.50`). The production vCenter resides in a core services VLAN (`192.0.2.10`), and the VM workloads will be provisioned into a DMZ subnet (`198.51.100.0/24`).

**Firewall Policy Applied on Perimeter Gateways:**
- Allow `192.0.2.50` -> `192.0.2.10` on port `443/TCP`.
- Allow `192.0.2.50` -> `198.51.100.0/24` on port `22/TCP` and `ICMP`.
- Allow `198.51.100.0/24` -> `192.0.2.1` on port `53/UDP` (DNS) and `123/UDP` (NTP).

**Outcome**:
When the operator runs `bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod app-01`, Terraform communicates with vCenter to clone the VM, and the deploy script polls SSH on port 22 until cloud-init and hardening scripts report completion.

---

## Guardrails & Common Mistakes

| Risk / Symptom | Root Cause | Prevention / Solution |
| :--- | :--- | :--- |
| **`connection refused` on port 443** | Firewall blocking HTTPS to vCenter or invalid vCenter hostname | Check routing, verify `curl -k https://<vcenter-ip>`, and check gateway security groups. |
| **SSH Gate timeout after 300s** | VM network VLAN lacks route to VMPilot host, or guest IP conflict | Check VMPilot deploy output for the automatic ICMP diagnostic. Verify gateway and VLAN IDs in `vcenter.tfvars`. |
| **Age key missing error** | `SOPS_AGE_KEY_FILE` environment variable unset or key file missing | Ensure `~/.config/sops/age/keys.txt` exists or run `bash install.sh` to generate a fresh key pair. |

---

[◄ Back to Guide Index](README.md) | [Next: 02. vCenter Onboarding & Multi-Provider ►](02-vcenter-onboarding-and-multi-provider.md)
