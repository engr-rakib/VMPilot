# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
# ═══════════════════════════════════════════════════════════════════
# EXAMPLE / DEMO — DUMMY DATA (RFC 5737 TEST-NET). NOT a real vCenter.
#
# Mirrors the top-level inventory every deploy reads for this vCenter.
# Source of truth: per-env override files (dev/prod/staging) merge on
# top of this — commented keys there inherit these values.
# ═══════════════════════════════════════════════════════════════════
datacenter = "dc_example"
cluster    = "example_cluster"
resource_pool = "Resources"
datastore  = "datastore01"
network    = "VM Network"
template   = "ubuntu-24-template"

# Per-vCenter network defaults (used by create-vm-config.sh + terraform)
domain      = "example.local"
gateway     = "192.0.2.1"
netmask     = 24
dns_servers = ["192.0.2.2", "198.51.100.2"]

# IPAM — starting IP for new-VM free-IP scan
ipam_base_ip = "198.51.100.106"
