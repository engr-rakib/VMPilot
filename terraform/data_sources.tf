#############################################################
# Shared vSphere Inventory Data Sources
#
# These are discovered once and shared by all VMs.
#############################################################

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Extra networks from all VM configs
locals {
  all_extra_network_names = distinct(flatten([
    for k, v in local.all_configs : [
      for net in v.extra_networks : net.network_name
    ]
  ]))
}

data "vsphere_network" "extra" {
  for_each      = toset(local.all_extra_network_names)
  name          = each.key
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template
  datacenter_id = data.vsphere_datacenter.dc.id
}
