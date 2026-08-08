#############################################################
# File Name : main.tf
# Purpose    : Multi-VM or Single-VM deployment
#############################################################

locals {
  use_multi = length(var.vm_configs) > 0

  # Duplicate IP check
  vm_ip_list = [for k, v in local.all_configs : v.ip_address]
  has_dup_ip = length(local.vm_ip_list) != length(toset(local.vm_ip_list))

  adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]

  # Normalize single VM config into vm_configs format for unified handling
  single_vm_config = {
    (var.vm_name != "" ? var.vm_name : "default") = {
      hostname                   = var.hostname
      ip_address                 = var.ip_address
      gateway                    = var.gateway
      cpu                        = var.cpu
      memory                     = var.memory
      disk_size                  = var.disk_size
      ipam_enabled               = var.ipam_enabled
      netmask                    = var.netmask
      dns_servers                = var.dns_servers
      domain                     = var.domain
      folder                     = var.folder
      annotation                 = var.annotation
      firmware                   = var.firmware
      enable_cpu_hot_add         = var.enable_cpu_hot_add
      enable_memory_hot_add      = var.enable_memory_hot_add
      thin_provisioned           = var.thin_provisioned
      eagerly_scrub              = var.eagerly_scrub
      wait_for_guest_net_timeout = var.wait_for_guest_net_timeout
      disable_auto_updates       = var.disable_auto_updates
      enable_node_exporter       = var.enable_node_exporter
      extra_networks             = var.extra_networks
      data_disks                 = var.data_disks
      os_partitions              = var.os_partitions
      lvm_config                 = var.lvm_config
      mount_points               = var.mount_points
      extra_users                = var.extra_users
    }
  }

  all_configs = local.use_multi ? var.vm_configs : local.single_vm_config
}

# ─── IPAM: per-VM IP resolution ──────────────────────────────────────────
# The source of truth for in-use IPs is the per-VM config files themselves
# (deploy/*/vm-*.tfvars). next_free_ip.sh reads their ip_address values as
# "reserved", so no separate .<vm>_ip persist file / state tracking is needed.
locals {
  effective_ips = {
    for k, v in local.all_configs : k => (
      v.ipam_enabled && (v.ip_address != "" && v.ip_address != "0.0.0.0")
      ? v.ip_address
      : data.external.next_free_ip[k].result.free_ip
    )
  }
}

# Only resolve a free IP when the config didn't pin a real one; otherwise the
# config's own ip_address is used directly (it's already the source of truth).
data "external" "next_free_ip" {
  for_each = {
    for k, v in local.all_configs : k => v if(
      v.ipam_enabled && (v.ip_address == "" || v.ip_address == "0.0.0.0")
    )
  }

  program = ["bash", "${path.module}/../scripts/next_free_ip.sh"]
  query = {
    base_ip = var.ipam_base_ip
  }
}

# ─── Per-VM network config ──────────────────────────────────────────────
locals {
  vm_networks = {
    for k, v in local.all_configs : k => {
      all = concat(
        [{
          network_id   = data.vsphere_network.network.id
          adapter_type = local.adapter_type
          dhcp         = false
          ip_address   = local.effective_ips[k]
          netmask      = v.netmask
          gateway      = v.gateway
          dns_servers  = v.dns_servers
          match_name   = ""
          match_mac    = ""
        }],
        [for net in v.extra_networks : {
          network_id   = data.vsphere_network.extra[net.network_name].id
          adapter_type = local.adapter_type
          dhcp         = net.dhcp
          ip_address   = net.ip_address
          netmask      = net.netmask
          gateway      = net.gateway
          dns_servers  = net.dns_servers
          match_name   = net.match_name
          match_mac    = net.match_mac
        }]
      )
    }
  }
}

# ─── VMs ────────────────────────────────────────────────────────────────
module "vm" {
  for_each  = local.all_configs
  source    = "./modules/vm"
  providers = { vsphere = vsphere }

  vm_name    = each.key
  hostname   = each.value.hostname
  domain     = each.value.domain
  folder     = each.value.folder
  annotation = each.value.annotation

  resource_pool_id   = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id       = data.vsphere_datastore.datastore.id
  template_id        = data.vsphere_virtual_machine.template.id
  template_guest_id  = data.vsphere_virtual_machine.template.guest_id
  template_scsi_type = data.vsphere_virtual_machine.template.scsi_type

  networks = local.vm_networks[each.key].all

  cpu                   = each.value.cpu
  memory                = each.value.memory
  firmware              = each.value.firmware
  enable_cpu_hot_add    = each.value.enable_cpu_hot_add
  enable_memory_hot_add = each.value.enable_memory_hot_add

  disk_size        = each.value.disk_size
  thin_provisioned = each.value.thin_provisioned
  eagerly_scrub    = each.value.eagerly_scrub

  ssh_public_key             = var.ssh_public_key
  wait_for_guest_net_timeout = each.value.wait_for_guest_net_timeout

  data_disks    = each.value.data_disks
  os_partitions = each.value.os_partitions
  lvm_config    = each.value.lvm_config
  mount_points  = each.value.mount_points
  extra_users   = each.value.extra_users

  disable_auto_updates = each.value.disable_auto_updates
  enable_node_exporter = each.value.enable_node_exporter
}

# ─── Validation: no duplicate IPs ──────────────────────────────────────
check "duplicate_ips" {
  assert {
    condition     = !local.has_dup_ip
    error_message = "ERROR: Duplicate IPs: ${jsonencode(local.vm_ip_list)}. Each VM must have a unique ip_address."
  }
}

# ─── Wait for cloud-init (per VM) ───────────────────────────────────────
resource "null_resource" "wait_for_cloud_init" {
  for_each = { for k, v in local.all_configs : k => v if v.wait_for_guest_net_timeout > 0 }

  depends_on = [module.vm]

  provisioner "local-exec" {
    command = <<EOT
      echo "Waiting for cloud-init on ${each.key} (${module.vm[each.key].default_ip_address})..."
      for i in $(seq 1 30); do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${module.vm[each.key].default_ip_address} \
          "cloud-init status | grep -q done" && { echo "${each.key}: cloud-init completed"; exit 0; }
        sleep 10
      done
      echo "WARNING: ${each.key}: cloud-init did not complete in 5 minutes"
      exit 1
    EOT
  }
}
