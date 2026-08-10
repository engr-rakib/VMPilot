# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
#############################################################
# File Name : outputs.tf
# Purpose    : Terraform Deployment Outputs
#############################################################

output "vms" {
  description = "All deployed VMs"
  value = {
    for k, vm in module.vm : k => {
      name       = vm.name
      uuid       = vm.id
      ip_address = vm.default_ip_address
      guest_os   = vm.guest_id
      cpu        = vm.num_cpus
      memory     = vm.memory
    }
  }
}

output "vm_names" {
  description = "VM Names"
  value       = [for k, vm in module.vm : vm.name]
}

output "vm_ip_addresses" {
  description = "VM IP Addresses"
  value       = { for k, vm in module.vm : k => vm.default_ip_address }
}

output "datacenter" { value = data.vsphere_datacenter.dc.name }
output "cluster" { value = data.vsphere_compute_cluster.cluster.name }
output "datastore" { value = data.vsphere_datastore.datastore.name }
output "network" { value = data.vsphere_network.network.name }
output "disk_sizes" { value = { for k, v in local.all_configs : k => v.disk_size } }

output "cloud_init_status" {
  description = "Commands to check cloud-init completion per VM"
  value = {
    for k, vm in module.vm : k => vm.default_ip_address != null ? "ssh ubuntu@${vm.default_ip_address} sudo cloud-init status" : "IP not yet assigned — run later: terraform output cloud_init_status"
  }
}
