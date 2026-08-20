# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
#############################################################
# File Name : variables.tf
#############################################################

# ─── vCenter Authentication ──────────────────────────────────────────────
variable "vsphere_server" {
  description = "vCenter Server FQDN or IP"
  type        = string
}
variable "vsphere_user" {
  description = "vCenter Username"
  type        = string
  sensitive   = true
}
variable "vsphere_password" {
  description = "vCenter Password"
  type        = string
  sensitive   = true
}
variable "allow_unverified_ssl" {
  description = "Allow self signed SSL"
  type        = bool
  default     = true
}

# ─── VMware Inventory ────────────────────────────────────────────────────
variable "datacenter" {
  description = "VMware Datacenter Name"
  type        = string
}
variable "cluster" {
  description = "VMware Cluster Name"
  type        = string
}
variable "resource_pool" {
  description = "VMware Resource Pool"
  type        = string
  default     = "Resources"
}
variable "datastore" {
  description = "VMware Datastore Name"
  type        = string
}
variable "network" {
  description = "VM Network Port Group"
  type        = string
}
variable "template" {
  description = "VM Template Name"
  type        = string
}
variable "host" {
  description = "[DEPRECATED] ESXi host/node to pin the VM to (blank = DRS auto-placement)"
  type        = string
  default     = ""
}
variable "ssh_public_key" {
  description = "SSH Public Key"
  type        = string
}
variable "tags" {
  description = "VM Tags"
  type        = list(string)
  default     = []
}

# ─── VM Configs (Multi-VM mode) ─────────────────────────────────────────
variable "ipam_base_ip" {
  description = "IPAM fallback scan start (first IP tried when no config pin). Per-vCenter — set in each deploy/<vcenter>/<env>/ per-VM file."
  type        = string
  default     = "198.51.100.10"
}

variable "vm_configs" {
  description = "Map of VM configs. Each key = VM name."
  type = map(object({
    hostname   = string
    ip_address = string
    gateway    = string
    cpu        = number
    memory     = number
    disk_size  = number

    folder                     = optional(string, "")
    host                       = optional(string, "")
    annotation                 = optional(string, "Managed by Terraform")
    ipam_enabled               = optional(bool, true)
    netmask                    = optional(number, 24)
    dns_servers                = optional(list(string), [])
    domain                     = optional(string, "local")
    firmware                   = optional(string, "efi")
    enable_cpu_hot_add         = optional(bool, false)
    enable_memory_hot_add      = optional(bool, false)
    thin_provisioned           = optional(bool, true)
    eagerly_scrub              = optional(bool, false)
    wait_for_guest_net_timeout = optional(number, 0)
    disable_auto_updates       = optional(bool, false)
    enable_node_exporter       = optional(bool, false)
    extra_networks = optional(list(object({
      network_name = string
      dhcp         = optional(bool, true)
      match_name   = optional(string, "")
      match_mac    = optional(string, "")
      ip_address   = optional(string, "")
      netmask      = optional(number)
      gateway      = optional(string, "")
      dns_servers  = optional(list(string), [])
    })), [])
    data_disks = optional(list(object({
      label            = string
      size             = number
      unit_number      = optional(number)
      thin_provisioned = optional(bool, true)
      eagerly_scrub    = optional(bool, false)
    })), [])
    os_partitions = optional(list(object({
      mount_point = string
      size        = string
      lv_name     = optional(string)
      filesystem  = optional(string, "ext4")
    })), [])
    lvm_config = optional(list(object({
      vg_name     = string
      lv_name     = string
      lv_size     = optional(string, "100%FREE")
      mount_point = string
      filesystem  = optional(string, "ext4")
      devices     = list(string)
    })), [])
    mount_points = optional(list(object({
      device      = string
      mount_point = string
      filesystem  = optional(string, "ext4")
    })), [])
    extra_users = optional(list(object({
      username = string
      password = optional(string, "")
      groups   = optional(list(string), [])
    })), [])
  }))
  default = {}
}

# OS access each GROUP grants to extra_users (see secure/<vc>/<env>/user-groups.tfvars).
# Users are members of groups; permission lives on the group. Policy-loaded by
# deploy-vm.sh; empty = full-sudo fallback (legacy behaviour).
variable "user_groups" {
  description = "Group → OS access policy (os_groups/sudo/shell/description) applied to extra_users"
  type = map(object({
    os_groups   = list(string)
    sudo        = string
    shell       = string
    description = optional(string, "")
  }))
  default = {}
}

# ─── Legacy Single-VM variables ─────────────────────────────────────────
variable "vm_name" {
  description = "[DEPRECATED] Use vm_configs"
  type        = string
  default     = ""
}
variable "hostname" {
  description = "[DEPRECATED] Use vm_configs"
  type        = string
  default     = ""
}
variable "domain" {
  description = "[DEPRECATED] Use vm_configs"
  type        = string
  default     = "local"
}
variable "ip_address" {
  description = "[DEPRECATED] Use vm_configs"
  type        = string
  default     = ""
}
variable "gateway" {
  description = "[DEPRECATED] Use vm_configs"
  type        = string
  default     = ""
}
variable "cpu" {
  description = "[DEPRECATED] Use vm_configs"
  type        = number
  default     = 2
}
variable "memory" {
  description = "[DEPRECATED] Use vm_configs"
  type        = number
  default     = 2048
}
variable "disk_size" {
  description = "[DEPRECATED] Use vm_configs"
  type        = number
  default     = 40
}
variable "folder" {
  description = "[DEPRECATED]"
  type        = string
  default     = ""
}
variable "annotation" {
  description = "[DEPRECATED]"
  type        = string
  default     = "Managed by Terraform"
}
variable "ipam_enabled" {
  description = "[DEPRECATED]"
  type        = bool
  default     = true
}
variable "netmask" {
  description = "[DEPRECATED]"
  type        = number
  default     = 24
}
variable "dns_servers" {
  description = "[DEPRECATED]"
  type        = list(string)
  default     = []
}
variable "firmware" {
  description = "[DEPRECATED]"
  type        = string
  default     = "efi"
}
variable "enable_cpu_hot_add" {
  description = "[DEPRECATED]"
  type        = bool
  default     = false
}
variable "enable_memory_hot_add" {
  description = "[DEPRECATED]"
  type        = bool
  default     = false
}
variable "thin_provisioned" {
  description = "[DEPRECATED]"
  type        = bool
  default     = true
}
variable "eagerly_scrub" {
  description = "[DEPRECATED]"
  type        = bool
  default     = false
}
variable "wait_for_guest_net_timeout" {
  description = "[DEPRECATED]"
  type        = number
  default     = 0
}
variable "disable_auto_updates" {
  description = "[DEPRECATED]"
  type        = bool
  default     = false
}
variable "enable_node_exporter" {
  description = "[DEPRECATED]"
  type        = bool
  default     = false
}
variable "extra_networks" {
  description = "[DEPRECATED]"
  type        = any
  default     = []
}
variable "data_disks" {
  description = "[DEPRECATED]"
  type        = any
  default     = []
}
variable "os_partitions" {
  description = "[DEPRECATED]"
  type        = any
  default     = []
}
variable "lvm_config" {
  description = "[DEPRECATED]"
  type        = any
  default     = []
}
variable "mount_points" {
  description = "[DEPRECATED]"
  type        = any
  default     = []
}
variable "extra_users" {
  description = "[DEPRECATED]"
  type        = any
  default     = []
}
