# ═══════════════════════════════════════════════════════════════════
# EXAMPLE / DEMO — DUMMY DATA (RFC 5737 TEST-NET). NOT a real vCenter.
#
# Committed so the secure/ layout is visible on GitHub.
# A REAL credentials.tfvars is SOPS-encrypted (see secure/README.md §1);
# sops-decrypt.sh will NOT work against this dummy file.
# ═══════════════════════════════════════════════════════════════════
vsphere_server       = "192.0.2.10"
vsphere_user         = "administrator@vsphere.local"
vsphere_password     = "ChangeMe_DemoPassword_1"
allow_unverified_ssl = true
