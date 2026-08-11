# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
#############################################################
# VM config — db-01 (198.51.100.114)
# Env: staging   |   EXAMPLE / DEMO — DUMMY DATA (RFC 5737 TEST-NET)
#
# Deploy this VM only:
#   bash scripts/deploy-vm.sh dc_example_192.0.2.10 staging db-01
#
# vCenter inventory auto-loaded from secure/dc_example_192.0.2.10/.
#############################################################

# ─── SSH ────────────────────────────────────────────────────
ssh_public_key = "ssh-ed25519 AAAAC3...demo-key...never-real"

# ─── VM CONFIG (this VM) ────────────────────────────────────
vm_configs = {
  db-01 = {
    hostname              = "db-01"
    domain                = "example.local"
    annotation            = "Demo database server (dummy)"
    cpu                   = 4
    memory                = 8192
    disk_size             = 120
    firmware              = "efi"
    enable_cpu_hot_add    = true
    enable_memory_hot_add = true
    thin_provisioned      = false
    eagerly_scrub         = true
    ip_address            = "198.51.100.114"
    netmask               = 24
    gateway               = "192.0.2.1"
    dns_servers           = ["192.0.2.2", "198.51.100.2"]
    ipam_enabled          = false
    os_partitions = [
      { mount_point = "swap", size = "8G", lv_name = "lv_swap" },
      { mount_point = "/", size = "20G" },
      { mount_point = "/var", size = "30G", lv_name = "lv_var", filesystem = "ext4" },
      { mount_point = "/var/lib/mysql", size = "50G", lv_name = "lv_db", filesystem = "ext4" },
    ]
    data_disks           = []
    lvm_config           = []
    mount_points         = []
    extra_users          = []
    disable_auto_updates = true
  }
}
