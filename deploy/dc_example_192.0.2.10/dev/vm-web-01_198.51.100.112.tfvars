#############################################################
# VM config — web-01 (198.51.100.112)
# Env: dev    |   EXAMPLE / DEMO — DUMMY DATA (RFC 5737 TEST-NET)
#
# Deploy this VM only (other VMs untouched):
#   bash scripts/deploy-vm.sh dc_example_192.0.2.10 dev web-01
#
# vCenter inventory (datacenter/cluster/datastore/network/template)
# is auto-loaded from secure/dc_example_192.0.2.10/vcenter.tfvars at
# deploy time — this file only holds per-VM settings.
#############################################################

# ─── SSH ────────────────────────────────────────────────────
ssh_public_key = "ssh-ed25519 AAAAC3...demo-key...never-real"

# ─── VM CONFIG (this VM) ────────────────────────────────────
vm_configs = {
  web-01 = {
    hostname   = "web-01"
    domain     = "example.local"
    annotation = "Demo web server (dummy)"
    cpu        = 2
    memory     = 4096
    disk_size  = 40
    firmware   = "efi"
    enable_cpu_hot_add    = true
    enable_memory_hot_add = true
    thin_provisioned      = true
    eagerly_scrub         = false
    ip_address   = "198.51.100.112"
    netmask      = 24
    gateway      = "192.0.2.1"
    dns_servers  = ["192.0.2.2", "198.51.100.2"]
    ipam_enabled = false
    os_partitions = [
      { mount_point = "swap", size = "4G",  lv_name = "lv_swap" },
      { mount_point = "/",    size = "10G" },
      { mount_point = "/var", size = "15G", lv_name = "lv_var", filesystem = "ext4" },
    ]
    data_disks          = []
    lvm_config          = []
    mount_points        = []
    extra_users         = []
    disable_auto_updates = true
  }
}
