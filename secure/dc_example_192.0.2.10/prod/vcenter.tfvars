# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
# Per-env override — secure/dc_example_192.0.2.10/prod/vcenter.tfvars
# EXAMPLE / DEMO — DUMMY DATA.
# `datastore` is UNCOMMENTED → PROD ONLY uses datastore99.
# Every other key is commented → inherits the top-level value.
# (credentials are NEVER per-env — secrets stay in credentials.tfvars)
#
datastore = "datastore99"
# datacenter    = "dc_example"
# cluster       = "example_cluster"
# resource_pool = "Resources"
# network       = "VM Network"
# template      = "ubuntu-24-template"
# domain        = "example.local"
# gateway       = "192.0.2.1"
# netmask       = 24
# dns_servers   = ["192.0.2.2", "198.51.100.2"]
# ipam_base_ip  = "198.51.100.106"
