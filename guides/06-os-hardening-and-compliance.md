# 06. OS Hardening and Compliance Probes

This guide details the two-phase OS hardening pipeline, Section 0 toggle switches, the 19 automated verification probes, and network recovery workflows for provisioned virtual machines.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [Two-Phase Hardening Lifecycle Architecture](#two-phase-hardening-lifecycle-architecture)
- [Section 0 Policy Switches](#section-0-policy-switches)
- [The 19 Automated Verification Probes](#the-19-automated-verification-probes)
- [The `--lan-up` Network Recovery Fallback](#the---lan-up-network-recovery-fallback)
- [Step-by-Step Operator Usage](#step-by-step-operator-usage)
- [Real-Life Production Scenarios](#real-life-production-scenarios)
  - [Scenario A: Enforcing Strict Production Compliance](#scenario-a-enforcing-strict-production-compliance)
  - [Scenario B: Disabling Hardening in a Fast Dev Sandbox](#scenario-b-disabling-hardening-in-a-fast-dev-sandbox)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

Deploying an operating system without security baselines leaves default services exposed, password authentication enabled, and core system tuning unapplied.

VMPilot provides:
1. **Automated Two-Phase Delivery**: Delivers hardening logic into the guest during first boot without relying on external configuration management servers.
2. **CIS-Aligned System Hardening**: Enforces root login restrictions, kernel panic behaviors, core dump limits, network routing protections, and time synchronization.
3. **Automated Verification Probes**: Runs 19 verification checks immediately after applying hardening rules, catching misconfigurations before the VM enters production service.

---

## Two-Phase Hardening Lifecycle Architecture

The hardening process runs in two distinct stages:

```text
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE 1: OFFLINE CLOUD-INIT DELIVERY (First Boot)                      │
│                                                                        │
│   vSphere GuestInfo Payload (Base64)                                   │
│            │                                                           │
│            ▼                                                           │
│   cloud-init user-data writes:                                         │
│   ├── /etc/vmpilot/hardening.sh                                        │
│   └── /etc/vmpilot/hardening.conf                                      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ VM power-on + IP online
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ PHASE 2: ONLINE SSH EXECUTION & VERIFICATION PROBES (Deploy Pipeline)  │
│                                                                        │
│   VMPilot host initiates SSH session:                                  │
│   bash /etc/vmpilot/hardening.sh                                       │
│            │                                                           │
│            ├─► 1. Apply kernel sysctl parameters                       │
│            ├─► 2. Reconfigure sshd_config.d/                           │
│            ├─► 3. Configure UFW & Fail2ban                             │
│            ├─► 4. Configure Chrony NTP & Timezone                      │
│            └─► 5. Execute 19 Automated CHECK Probes                    │
│                        │                                               │
│                        ▼                                               │
│                 Exit Code 0 or 3                                       │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Section 0 Policy Switches & 3-Tier Inheritance

Hardening policies follow a 3-tier hierarchy: Datacenter defaults in `vm-defaults.conf` (`DEFAULT_*`), global baseline in `secure/<srv>/<vc>/hardening.sh`, and environment specializations in `secure/<srv>/<vc>/<env>/hardening.sh`.

The hardening script is configured via Section 0 switches in `scripts/lib/hardening-template.sh` or per-environment variable files:

| Policy Switch | Legacy Alias | Default | Purpose / Options |
| :--- | :---: | :---: | :--- |
| `ENABLED` | — | `"true"` | Global master switch. Set `"false"` to bypass all hardening steps. |
| `SUDO_ADMIN_USERS` | `COMMON_USERS` | `""` | Sudo-privileged Server Team Administrators provisioned on the guest (space-separated). |
| `SUDO_ADMIN_PASSWORD` | `ADMIN_PASSWORD` | `""` | Initial password for `SUDO_ADMIN_USERS`; forces password change on 1st login (empty = SSH-key only). |
| `ROOT_PASSWORD` | — | `""` | Root account password; empty = untouched (locked). |
| `FIREWALL` | — | `"ufw"` | Host firewall engine (`"ufw"` or `"firewalld"`). |
| `PORTS` | — | `"80 443 8080 ..."` | Space-separated list of inbound ports permitted through the firewall (port 22 always kept). |
| `SSH_PORT` | — | `"22"` | Standard or custom OpenSSH listening port. |
| `NTP1` / `NTP2` | — | Chrony Pools | Primary and secondary network time protocol upstream servers. |
| `TIMEZONE` | — | `"Asia/Dhaka"` | Guest system timezone (e.g., `"America/New_York"`, `"Asia/Dhaka"`, `"UTC"`). |
| `NE_VERSION` | — | `"1.12.1"` | Prometheus node_exporter binary release version. |
| `NE_REPO` | — | Repo URL | Internal or public base URL for Prometheus node_exporter tarballs. |
| `CLAMAV` | — | `"false"` | Optional installation and background daemon configuration for ClamAV. |
| `SELINUX_TOOLS` | — | `"no"` | Opt-in SELinux userspace tools (Ubuntu default is AppArmor). |

---

## The 19 Automated Verification Probes

Following configuration, the script executes 19 verification checks. If any probe fails, the deployment script returns exit code `3`:

| # | Verification Probe | Target System Setting | Pass Requirement |
| :---: | :--- | :--- | :--- |
| **01** | `CHECK_SSH_ROOT` | `/etc/ssh/sshd_config.d/*` | `PermitRootLogin no` |
| **02** | `CHECK_SSH_PASS` | `/etc/ssh/sshd_config.d/*` | `PasswordAuthentication no` |
| **03** | `CHECK_SSH_EMPTY` | `/etc/ssh/sshd_config.d/*` | `PermitEmptyPasswords no` |
| **04** | `CHECK_SSH_ALGO` | Host key algorithms | No legacy SHA-1 or DSS ciphers permitted |
| **05** | `CHECK_CORE_DUMP` | `/etc/security/limits.conf` | `* hard core 0` (core dumps disabled) |
| **06** | `CHECK_SYSCTL_PANIC` | `kernel.panic` | Reboots automatically on kernel panic (`sysctl > 0`) |
| **07** | `CHECK_IP_FORWARD` | `net.ipv4.ip_forward` | Routing disabled (`0`) unless designated as router |
| **08** | `CHECK_SYN_COOKIES`| `net.ipv4.tcp_syncookies` | Enabled (`1`) to mitigate SYN flood attacks |
| **09** | `CHECK_ICMP_REDIRECT`| `net.ipv4.conf.all.accept_redirects` | Disabled (`0`) to prevent MITM spoofing |
| **10** | `CHECK_SOURCE_ROUTE`| `net.ipv4.conf.all.accept_source_route` | Disabled (`0`) to block source-routed packets |
| **11** | `CHECK_CHRONY_SYNC`| `chronyc tracking` | Active synchronization with upstream NTP |
| **12** | `CHECK_TIMEZONE` | `timedatectl` | System matches configured `TIMEZONE` |
| **13** | `CHECK_UFW_STATUS` | `ufw status` | Active and enforcing default-deny ingress |
| **14** | `CHECK_FAIL2BAN` | `fail2ban-client status` | Daemon running and monitoring sshd jail |
| **15** | `CHECK_TMP_OPTS` | `/etc/fstab` `/tmp` | Mounted with `nodev,nosuid,noexec` options |
| **16** | `CHECK_UMASK` | `/etc/profile` & `/etc/bash.bashrc` | System default umask set to `027` |
| **17** | `CHECK_SUDO_LOG` | `/etc/sudoers.d/audit` | `Defaults logfile="/var/log/sudo.log"` present |
| **18** | `CHECK_NODE_EXP` | `systemctl is-active node_exporter` | Active (if `enable_node_exporter = true`) |
| **19** | `CHECK_ACCESS_MD` | `/etc/vmpilot-access.md` | Manifest file present with valid SHA-256 |

---

## The `--lan-up` Network Recovery Fallback

In certain virtualization setups, operating system interfaces can remain unconfigured if link-state detection is delayed.

- When deploying with `--lan-up`, VMPilot generates fallback systemd units within the guest:
  ```bash
  bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod web-01 --lan-up
  ```
- This triggers a forced interface carrier bring-up on `ens192` or `ens160`, ensuring connectivity is established even under heavy host load.

---

## Step-by-Step Operator Usage

### 1. View Hardening Configuration Template
```bash
cat scripts/lib/hardening-template.sh | head -n 45
```

### 2. Inspect In-Guest Hardening Results
After deployment completes, log in to the virtual machine:
```bash
ssh ubuntu@198.51.100.31

# Check verification log output
sudo cat /var/log/vmpilot-hardening.log

# Verify UFW status and rules
sudo ufw status verbose
```

---

## Real-Life Production Scenarios

### Scenario A: Enforcing Strict Production Compliance
A company requires all production web nodes to run with strict firewalls, NTP timekeeping, and ports `80`, `443`, and `22` exposed.

**Configuration in VM `.tfvars`**:
```hcl
vm_configs = {
  web-prod-01 = {
    hostname        = "web-prod-01"
    ip_address      = "198.51.100.120"
    cpu             = 4
    memory          = 8192
    disk_size       = 50
    hardening_ports = "22/tcp,80/tcp,443/tcp"
  }
}
```

**Outcome**:
Upon deployment, UFW blocks all other incoming ports, Chrony synchronizes time, and all 19 verification checks report clean status.

---

### Scenario B: Disabling Hardening in a Fast Dev Sandbox
Developers require a temporary testing sandbox where local services bind to random ports, and standard CIS hardening is not required.

**Action**:
Pass the disable switch during creation:
```hcl
vm_configs = {
  dev-test-01 = {
    hostname          = "dev-test-01"
    ip_address        = "198.51.100.220"
    enable_hardening  = false
  }
}
```

**Outcome**:
The VM is provisioned with base network and storage settings. Phase 2 hardening is skipped, saving deployment time while keeping production environments hardened.

---

## Guardrails & Common Mistakes

| Problem | Root Cause | Solution |
| :--- | :--- | :--- |
| **Exit code 3 during deploy** | One of the 19 verification probes failed | Inspect `/var/log/vmpilot-hardening.log` to identify the failing check. |
| **SSH lockout after hardening** | Custom `PORTS` switch excluded `22/tcp` | Always include `22/tcp` in `hardening_ports` so SSH management traffic is permitted. |
| **NTP check fails** | Guest cannot reach upstream NTP pools on `123/UDP` | Verify UDP port 123 is allowed through perimeter firewalls to external time servers. |

---

[◄ Back to 05. Test, Plan & Deploy](05-test-plan-build-and-deploy.md) | [Next: 07. RBAC, Users, Groups & Auditing ►](07-rbac-users-groups-and-auditing.md)
