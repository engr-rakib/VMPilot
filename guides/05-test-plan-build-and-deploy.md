# 05. Test, Plan, Build and Deploy Pipeline

This guide details the complete 10-stage deployment lifecycle executed by `scripts/deploy-vm.sh`, dry-run planning options, targeted Terraform execution, the reboot-tolerant SSH verification gate, and standard operational exit codes.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [The 10-Stage Deployment Lifecycle](#the-10-stage-deployment-lifecycle)
- [Targeted Blast-Radius Containment](#targeted-blast-radius-containment)
- [The Reboot-Tolerant SSH Gate & Diagnostic](#the-reboot-tolerant-ssh-gate--diagnostic)
- [CLI Command Flags Reference](#cli-command-flags-reference)
- [Operational Exit Codes](#operational-exit-codes)
- [Step-by-Step Operator Usage](#step-by-step-operator-usage)
- [Real-Life Production Scenario: Targeted Zero-Downtime Deploy](#real-life-production-scenario-targeted-zero-downtime-deploy)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

Deploying virtual machines in production environments requires predictability. Traditional automation often risks modifying neighboring resources or failing silently during cloud-init execution.

VMPilot provides:
1. **Targeted Deployment Scoping**: Enforces `-target='module.vm["<name>"]'` during `terraform apply`. Ten existing production VMs in the same state file remain untouched while the eleventh VM is provisioned.
2. **Reboot-Tolerant SSH Gate**: A 300-second polling window (15 attempts × 20-second interval) accounts for cloud-init reboots. If the SSH key is rejected 5 consecutive times, it terminates early to avoid hanging. If unreachable, it executes an automated ICMP ping diagnostic to identify VLAN or routing failures.
3. **Automated Secret Lifecycle**: Decrypts SOPS credentials into temporary variable files before execution and deletes them immediately upon completion or failure using Bash traps.

---

## The 10-Stage Deployment Lifecycle

The diagram below maps the execution flow of `scripts/deploy-vm.sh`:

```text
┌────────────────────────────────────────────────────────────────────────┐
│ STAGE 1: Path & Directory Resolution                                   │
│          Locates deploy/ configs, secure/ inventory, and state ledger   │
├───────────────────────────────────┬────────────────────────────────────┤
│ STAGE 2: Pre-Flight Safety Checks │ Declared IP matches subnet CIDR    │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 3: Config Normalization (R4)│ Key matches hostname exactly       │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 4: Blending Guard           │ Validates all .tfvars syntax       │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 5: Synthesis & Merge        │ Assembles active VM definitions    │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 6: Credential Decryption    │ sops-decrypt -> transient RAM file │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 7: Targeted Terraform Apply │ -target='module.vm["<vm-name>"]'   │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 8: SSH Gate & Cloud-Init    │ 15x20s (300s) poll + ICMP check    │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 9: OS Hardening Execution   │ Executes /etc/vmpilot/hardening.sh │
├───────────────────────────────────┼────────────────────────────────────┤
│ STAGE 10: Cleanup & IP Auto-Sync  │ Deletes credentials & renames file │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Targeted Blast-Radius Containment

When multiple virtual machines share an environment state (e.g., `prod`), running a plain `terraform apply` risks modifying or refreshing all resources simultaneously.

VMPilot prevents this by running:
```bash
terraform apply \
  -target="module.vm[\"${VM_NAME}\"]" \
  -var-file="${VCENTER_VARS}" \
  -var-file="${TEMP_CREDENTIALS}" \
  -var-file="${MERGED_VARS}" \
  -state="${STATE_FILE}"
```
This guarantees that Terraform evaluates **only the resources belonging to the specified VM instance**.

---

## The Reboot-Tolerant SSH Gate & Diagnostic

After vSphere reports that the VM is powered on, guest provisioning continues via `cloud-init`. The deployment script polls port 22 on the guest:

```text
Attempt 1 (20s):  Connection refused (VM booting)
Attempt 2 (40s):  Connection timed out (Network initialising)
Attempt 3 (60s):  SSH banner received -> testing Ed25519 authentication
Attempt 4 (80s):  Authenticated -> polling /run/cloud-init/result.json
Attempt 5 (100s): Cloud-init status: "running"
Attempt 6 (120s): Cloud-init status: "done" -> Proceed to Hardening
```

### Safety Features of the Gate:
- **Key-Denied Bailout**: If the guest returns `Permission denied (publickey)` 5 consecutive times, VMPilot aborts immediately. This indicates an SSH key mismatch rather than a slow boot.
- **Automated ICMP VLAN Diagnostic**: If all 15 attempts expire without an SSH connection, the script sends 3 ICMP ping packets to the VM and to its gateway:
  - If the gateway responds but the VM does not, VMware Tools or guest networking failed.
  - If neither responds, a VLAN tagging or routing problem exists on the physical switch.

---

## CLI Command Flags Reference

`scripts/deploy-vm.sh` supports several operator flags:

| Flag | Purpose | Behavior |
| :--- | :--- | :--- |
| *(no flags)* | Standard Deploy | Full 10-stage provisioning pipeline with SSH gate and auto-cleanup. |
| `--plan` | Dry-Run Simulation | Runs `terraform plan -target=...` without modifying vCenter resources. |
| `--no-sync` | Skip File Rename | Deploys the VM but leaves `.tfvars` filenames unchanged on disk. |
| `--no-clean` | Debugging Mode | Preserves temporary `.auto.tfvars` files after execution for inspection. |
| `--lan-up` | Fallback Network Mode | Forces cloud-init to bring up physical NICs even if carrier detect is slow. |
| `--force` | Bypass Guardrails | Skips the duplicate IP pre-flight check (use with caution). |

---

## Operational Exit Codes

Automation tools and CI/CD pipelines can inspect process return codes to determine deployment results:

| Exit Code | Classification | Meaning | Recommended Action |
| :---: | :--- | :--- | :--- |
| **`0`** | `SUCCESS` | VM deployed, cloud-init finished, 19 hardening checks passed. | System is ready for production traffic. |
| **`1`** | `INFRASTRUCTURE ERROR` | Terraform apply failed, vCenter API rejected request, or syntax error. | Check vCenter capacity, storage, or HCL variables. |
| **`3`** | `HARDENING FAILED` | VM deployed, but guest hardening probes returned warnings. | Review SSH output; inspect `/var/log/vmpilot-hardening.log`. |
| **`124`** | `TIMEOUT` | SSH gate expired after 300 seconds without reaching the guest. | Check VLAN tagging, gateway connectivity, and firewall rules. |

---

## Step-by-Step Operator Usage

### 1. Execute a Dry-Run Plan
```bash
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod api-01 --plan
```
Review the proposed plan output to verify compute sizing, IP addressing, and datastore targets.

### 2. Execute Production Deployment
```bash
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod api-01
```

### 3. Review Real-Time Progress Steps
The console displays step indicators during execution:
```text
:: STEP deploy-vm:init SUCCESS ts=1774180001
:: STEP deploy-vm:plan SUCCESS ts=1774180015
:: STEP deploy-vm:apply SUCCESS ts=1774180055
:: STEP deploy-vm:ssh-gate SUCCESS ts=1774180120
:: STEP deploy-vm:hardening SUCCESS ts=1774180145
:: STEP deploy-vm:cleanup SUCCESS ts=1774180147
```

---

## Real-Life Production Scenario: Targeted Zero-Downtime Deploy

### Scenario
An enterprise runs 12 customer-facing microservices in the `prod` environment. You must deploy a new API instance (`api-01`) without causing configuration updates or reboots on the existing 12 microservices.

### Execution
```bash
# Verify active production instances
ls deploy/192.0.2.10/dc_pilot/prod/

# Deploy api-01 specifically
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod api-01
```

**Result**:
- Terraform restricts evaluation to `module.vm["api-01"]`.
- The 12 existing instances are marked as `(unchanged)` by Terraform.
- `api-01` is provisioned, boots up, passes the SSH gate, runs hardening scripts, and begins serving traffic.

---

## Guardrails & Common Mistakes

| Problem | Root Cause | Solution |
| :--- | :--- | :--- |
| **Terraform attempts to modify all VMs** | Missing `-target` parameter in custom script invocations | Always use `scripts/deploy-vm.sh` rather than running raw `terraform apply` commands. |
| **Exit code 124 on private VLANs** | VMPilot workstation does not have a route to the newly provisioned VM subnet | Ensure management routing is in place or run VMPilot on a multi-homed workstation. |
| **SSH key rejected repeatedly** | Template does not accept the public key defined in `~/.ssh/id_ed25519.pub` | Confirm the base VM template has `cloud-init` installed and guestinfo datasources enabled. |

---

[◄ Back to 04. VM Config & IPAM](04-vm-config-ipam-and-lvm-storage.md) | [Next: 06. OS Hardening & Compliance ►](06-os-hardening-and-compliance.md)
