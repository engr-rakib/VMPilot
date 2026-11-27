# 📖 VMPilot Public Feature & Operator Guide Suite

Welcome to the **VMPilot Feature & Operator Guide Suite**. This documentation series covers every feature, workflow, and lifecycle operation within VMPilot, complete with architectural diagrams, production scenarios, step-by-step CLI commands, guardrails, and troubleshooting recipes.

---

## 📑 Guide Directory

| Guide | Focus Area | Key Concepts Covered |
| :--- | :--- | :--- |
| **[01. Architecture & Connections](01-architecture-and-connections.md)** | Network & Topology | 5-layer model, port matrix (`443`, `22`, `9100`), ICMP diagnostic, CLI vs Web Console |
| **[02. vCenter Onboarding & Multi-Provider](02-vcenter-onboarding-and-multi-provider.md)** | Infrastructure Setup | `vcenter-setup.sh`, SOPS-Age sealing, multi-vCenter/multi-datacenter isolation, DR onboarding |
| **[03. Environments, Common Vars & Policies](03-environments-common-vars-and-policies.md)** | Policy Inheritance | `dev`/`staging`/`prod`, `vcenter.tfvars`, `vm-defaults.conf`, policy re-sync, datastore pinning |
| **[04. VM Config, IPAM & LVM Storage](04-vm-config-ipam-and-lvm-storage.md)** | VM Scaffolding | `create-vm-config.sh`, parallel IPAM (`next_free_ip.sh`, `RESERVE=30`), dual LVM (`vg_os`, `vg_data`) |
| **[05. Test, Plan, Build & Deploy](05-test-plan-build-and-deploy.md)** | Core Pipeline | 10-stage deploy pipeline, 300s reboot-tolerant SSH gate, `-target` isolation, CLI flags & exit codes |
| **[06. OS Hardening & Compliance](06-os-hardening-and-compliance.md)** | Guest Security | Two-phase hardening, 19 automated `CHECK` probes, Section 0 switches, `--lan-up` recovery |
| **[07. RBAC, Users, Groups & Auditing](07-rbac-users-groups-and-auditing.md)** | Access Control | `user-groups.tfvars`, role unions (`admin`/`app`/`db`/`readonly`), `/etc/vmpilot-access.md`, `sudo.log` |
| **[08. Day-2 Sync, Resize & Safe Teardown](08-day2-sync-resize-and-safe-teardown.md)** | Day-2 Operations | In-place CPU/RAM hot-add, LVM expansion, `deploy-sync.sh` R1–R6, `destroy.sh` safe teardown |

---

## 🚀 Quick-Start Execution Path

If you are new to VMPilot, follow this sequential path:

```text
┌────────────────────────┐      ┌────────────────────────┐      ┌────────────────────────┐
│ 1. Bootstrap Host      │ ───► │ 2. Onboard vCenter     │ ───► │ 3. Scaffolding Config  │
│    bash install.sh     │      │    vcenter-setup.sh    │      │    create-vm-config.sh │
└────────────────────────┘      └────────────────────────┘      └────────────────────────┘
                                                                             │
                                                                             ▼
┌────────────────────────┐      ┌────────────────────────┐      ┌────────────────────────┐
│ 6. Day-2 & Lifecycle   │ ◄─── │ 5. OS Hardening & RBAC │ ◄─── │ 4. Deploy One VM       │
│    deploy-sync/destroy │      │    19-point audit      │      │    deploy-vm.sh        │
└────────────────────────┘      └────────────────────────┘      └────────────────────────┘
```

1. **Host Setup**: Run `bash install.sh --yes` to install Terraform, govc, SOPS, age, and generate local keys (see [01. Architecture](01-architecture-and-connections.md)).
2. **vCenter Connection**: Run `bash scripts/vcenter-setup.sh` to register and encrypt your vCenter credentials (see [02. Onboarding](02-vcenter-onboarding-and-multi-provider.md)).
3. **Environment Tuning**: Verify your network subnets, IPAM pools, and datastore allocations in `secure/<server>/<vcenter>/` (see [03. Environments & Policies](03-environments-common-vars-and-policies.md)).
4. **Generate VM Specification**: Run `bash scripts/create-vm-config.sh` to allocate a static IP and configure compute/storage (see [04. VM Config & IPAM](04-vm-config-ipam-and-lvm-storage.md)).
5. **Execute Deployment**: Run `bash scripts/deploy-vm.sh <vcenter> <env> <vm-name>` to deploy with surgical `-target` precision (see [05. Test, Plan & Deploy](05-test-plan-build-and-deploy.md)).
6. **Verify Security**: Inspect automated hardening probes and access manifests (see [06. Hardening](06-os-hardening-and-compliance.md) and [07. RBAC](07-rbac-users-groups-and-auditing.md)).
7. **Manage Lifecycle**: Scale resources, synchronize state, or safely decommission machines with `destroy.sh` (see [08. Day-2 Operations](08-day2-sync-resize-and-safe-teardown.md)).

---

## 🔒 Public Safety & Licensing

- **Open-Source CLI Core**: All tools and scripts detailed in these guides are freely available under the **MIT License** in the [engr-rakib/VMPilot](https://github.com/engr-rakib/VMPilot) public repository.
- **Enterprise Web Console Add-On**: A turnkey browser console (`vmpilot-webui/`) is available as a commercial add-on under proprietary license. See [01. Architecture](01-architecture-and-connections.md) for architectural comparisons.
- **RFC-5737 Example Addresses**: Throughout these guides, example IP addresses utilize documentation subnets (`192.0.2.0/24`, `198.51.100.0/24`) and dummy datacenter keys (`dc_pilot_192.0.2.10`, `dc_dr_192.0.2.20`). Replace these values with your actual network settings.

---

[Next: 01. Architecture & Connections ►](01-architecture-and-connections.md)
