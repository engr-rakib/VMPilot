# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
#############################################################
# VM config — web-02 (198.51.100.113)
# Env: prod   |   EXAMPLE / DEMO — DUMMY DATA (RFC 5737 TEST-NET)
#
# Deploy this VM only:
#   bash scripts/deploy-vm.sh dc_example_192.0.2.10 prod web-02
#
# NOTE: prod env uses datastore99 — set in
# secure/dc_example_192.0.2.10/prod/vcenter.tfvars (per-env override).
# Everything else inherits the top-level vcenter.tfvars.
#############################################################

# ─── SSH ────────────────────────────────────────────────────
ssh_public_key = "ssh-ed25519 AAAAC3...demo-key...never-real"

# ─── VM CONFIG (this VM) ────────────────────────────────────
vm_configs = {
  web-02 = {
    hostname              = "web-02"
    domain                = "example.local"
    annotation            = "Demo production web server (dummy)"
    cpu                   = 4
    memory                = 8192
    disk_size             = 80
    firmware              = "efi"
    enable_cpu_hot_add    = true
    enable_memory_hot_add = true
    thin_provisioned      = true
    eagerly_scrub         = false
    ip_address            = "198.51.100.113"
    netmask               = 24
    gateway               = "192.0.2.1"
    dns_servers           = ["192.0.2.2", "198.51.100.2"]
    ipam_enabled          = false
    os_partitions = [
      { mount_point = "swap", size = "8G", lv_name = "lv_swap" },
      { mount_point = "/", size = "20G" },
      { mount_point = "/var", size = "30G", lv_name = "lv_var", filesystem = "ext4" },
      { mount_point = "/home", size = "10G", lv_name = "lv_home", filesystem = "ext4" },
    ]
    data_disks           = []
    lvm_config           = []
    mount_points         = []
    extra_users          = []
    disable_auto_updates = true
  }
}
