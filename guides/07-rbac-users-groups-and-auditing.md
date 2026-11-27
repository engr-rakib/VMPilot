# 07. RBAC, Users, Groups and Auditing

This guide covers managing system user roles, role unions, security boundaries, and command auditing across virtual machines.

---

## 📑 Table of Contents
- [What This Feature Does & Why It Matters](#what-this-feature-does--why-it-matters)
- [RBAC Architecture & Role Union Model](#rbac-architecture--role-union-model)
- [Standard RBAC Role Groups](#standard-rbac-role-groups)
- [Access Manifest (`/etc/vmpilot-access.md`)](#access-manifest-etcvmpilot-accessmd)
- [Command Auditing & Sudo Logging](#command-auditing--sudo-logging)
- [Step-by-Step Operator Usage](#step-by-step-operator-usage)
- [Real-Life Production Scenarios](#real-life-production-scenarios)
  - [Scenario A: Provisioning Full-Stack Engineer with Role Union Access](#scenario-a-provisioning-full-stack-engineer-with-role-union-access)
  - [Scenario B: Offboarding an Engineer & Auditing Past Actions](#scenario-b-offboarding-an-engineer--auditing-past-actions)
- [Guardrails & Common Mistakes](#guardrails--common-mistakes)

---

## What This Feature Does & Why It Matters

Managing SSH keys and sudo access directly on individual virtual machines creates compliance challenges, increases the risk of orphaned accounts, and leaves inadequate audit trails.

VMPilot provides:
1. **Centralized User Role Definition**: Define users, groups, and SSH keys in `user-groups.tfvars` per environment without touching individual VM configurations.
2. **Deterministic Role Unions**: Assign multiple roles (e.g., `["app", "db"]`) to a single user, merging permissions into appropriate system groups and sudoer rules.
3. **Immutable In-Guest Access Manifest**: Generates `/etc/vmpilot-access.md` on every guest, providing security teams with an inventory of authorized accounts and public keys.
4. **Complete Administrative Auditing**: Directs all `sudo` executions to `/var/log/sudo.log` with user identities, timestamps, and executed commands.

---

## RBAC Architecture & Role Union Model

VMPilot evaluates access rights at the environment level:

```text
┌────────────────────────────────────────────────────────────────────────┐
│ ENVIRONMENT USER DEFINITIONS                                           │
│ secure/<server>/<vcenter>/<env>/user-groups.tfvars                     │
│                                                                        │
│   users = {                                                            │
│     "jdoe" = {                                                         │
│       ssh_key = "ssh-ed25519 AAAAC3..."                                │
│       roles   = ["app", "db"]                                          │
│     }                                                                  │
│   }                                                                    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ IN-GUEST LINUX GROUP ASSIGNMENT & SUDO RIGHTS                          │
│                                                                        │
│   User: jdoe                                                           │
│   Primary Group: jdoe                                                  │
│   Secondary Groups: app-operators, db-operators                        │
│                                                                        │
│   Sudo Permissions:                                                    │
│   - Manage systemd services: systemctl restart app-* / postgresql      │
│   - Access application log directories: /var/log/app / /var/log/pg     │
│   - NO root shell escalation (wheel / su restricted)                   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ AUDIT EVIDENCE COLLECTION                                              │
│ ├── /etc/vmpilot-access.md (SHA-256 verified manifest)                 │
│ └── /var/log/sudo.log      (Command execution logs)                    │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Standard RBAC Role Groups

VMPilot defines four primary role groups:

| Role Group | Linux System Group | Sudo Privileges Granted | Target Persona |
| :--- | :--- | :--- | :--- |
| **`admin`** | `sudo`, `adm` | Full root access (`ALL=(ALL:ALL) NOPASSWD: ALL`). | Infrastructure & Systems Engineers |
| **`app`** | `app-operators` | Restart application services, manage app logs in `/var/log/app`. | Software & Application Developers |
| **`db`** | `db-operators` | Manage database engines, run database CLI tools, access `/data`. | Database Administrators |
| **`readonly`**| `auditors` | Read-only access to system logs, process lists, and status commands. | Security Auditors & Support Analysts |

---

## Access Manifest (`/etc/vmpilot-access.md`)

During deployment, VMPilot renders an access manifest on the guest filesystem at `/etc/vmpilot-access.md`:

```markdown
# VMPilot Access Manifest
Generated: 2026-11-22 14:00:00 UTC
Target Hostname: web-prod-01

## Authorized Accounts
| Username | Roles Assigned | Primary Group | SSH Key Fingerprint |
| :--- | :--- | :--- | :--- |
| ubuntu | admin | sudo | SHA256:7b42... |
| jdoe | app, db | app-operators | SHA256:88bc... |
| asmith | readonly | auditors | SHA256:12ef... |

This file is maintained by VMPilot automation. Manual edits will be overwritten.
```

---

## Command Auditing & Sudo Logging

All administrative commands executed through `sudo` are logged to `/var/log/sudo.log`:

```text
Nov 22 14:05:21 web-prod-01 sudo:    jdoe : TTY=pts/0 ; PWD=/home/jdoe ; USER=root ; COMMAND=/bin/systemctl restart myapp.service
Nov 22 14:08:12 web-prod-01 sudo:  asmith : TTY=pts/1 ; PWD=/var/log   ; USER=root ; COMMAND=/bin/journalctl -u myapp.service
```

This ensures full accountability for actions taken on production systems.

---

## Step-by-Step Operator Usage

### 1. Define an Environment User Configuration
Edit `secure/192.0.2.10/dc_pilot/prod/user-groups.tfvars`:
```hcl
users = {
  "rsmith" = {
    ssh_authorized_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... rsmith@example.com"
    groups             = ["app", "db"]
  }
}
```

### 2. Apply the Configuration
Run deploy on the target VM:
```bash
bash scripts/deploy-vm.sh dc_pilot_192.0.2.10 prod app-01
```

### 3. Verify Account Creation on the Guest
```bash
ssh ubuntu@198.51.100.31 "id rsmith && cat /etc/vmpilot-access.md"
```

---

## Real-Life Production Scenarios

### Scenario A: Provisioning Full-Stack Engineer with Role Union Access
A software engineer needs to manage application processes and inspect local database performance on staging instances.

**Action**:
Assign `["app", "db"]` in `user-groups.tfvars`.

**Result**:
The engineer can restart application containers and run database administrative queries, while administrative root escalation remains restricted.

---

### Scenario B: Offboarding an Engineer & Auditing Past Actions
An engineer leaves the team. You must revoke their access across the environment and export their recent command history for audit review.

**Action**:
1. Remove the engineer's entry from `secure/192.0.2.10/dc_pilot/prod/user-groups.tfvars`.
2. Re-run `bash scripts/deploy-sync.sh dc_pilot_192.0.2.10 prod`.
3. The sync script locks the Linux account, removes the authorized SSH key from `/home/<user>/.ssh/authorized_keys`, and updates `/etc/vmpilot-access.md`.
4. Review command history:
   ```bash
   ssh ubuntu@198.51.100.31 "sudo grep 'jdoe :' /var/log/sudo.log"
   ```

---

## Guardrails & Common Mistakes

| Problem | Root Cause | Solution |
| :--- | :--- | :--- |
| **`Unknown group role` error** | Typo in role name (e.g., `"adminn"`) | Valid roles are `admin`, `app`, `db`, and `readonly`. |
| **User cannot authenticate via SSH** | Public key formatted incorrectly or contains unsupported legacy RSA ciphers | Use modern Ed25519 (`ssh-ed25519 ...`) or ECDSA keys. |
| **User account retained after deletion** | Account was added manually outside of VMPilot | Manage users through `user-groups.tfvars` to ensure automated reconciliation. |

---

[◄ Back to 06. OS Hardening](06-os-hardening-and-compliance.md) | [Next: 08. Day-2 Sync, Resize & Safe Teardown ►](08-day2-sync-resize-and-safe-teardown.md)
