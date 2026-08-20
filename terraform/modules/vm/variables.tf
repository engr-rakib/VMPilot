# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
variable "vm_name" {
  description = "Virtual Machine Name"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$", var.vm_name))
    error_message = "VM name must start/end with alphanumeric, contain only a-z A-Z 0-9 _ -"
  }
}


variable "folder" { type = string }
variable "annotation" { type = string }

variable "resource_pool_id" { type = string }
variable "datastore_id" { type = string }
variable "template_id" { type = string }
variable "template_guest_id" { type = string }
variable "template_scsi_type" { type = string }
variable "host_system_id" {
  description = "ESXi host to pin the VM to (null = DRS auto-placement)"
  type        = string
  default     = null
}

variable "wait_for_guest_net_timeout" {
  description = "Seconds to wait for VM IP. 0 = skip wait entirely."
  type        = number
  default     = 0
}

variable "networks" {
  description = "Network interfaces (ordered: unit 0, 1, 2...)"
  type = list(object({
    network_id   = string
    adapter_type = string
    match_name   = optional(string)
    match_mac    = optional(string)
    dhcp         = optional(bool, false)
    ip_address   = optional(string)
    netmask      = optional(number)
    gateway      = optional(string)
    dns_servers  = optional(list(string), [])
  }))
}

variable "cpu" {
  description = "Number of vCPU"
  type        = number
  validation {
    condition     = var.cpu >= 1 && var.cpu <= 256
    error_message = "CPU must be between 1 and 256."
  }
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  validation {
    condition     = var.memory >= 512 && var.memory <= 2097152
    error_message = "Memory must be between 512 MB and 2 TB (2097152 MB)."
  }
}

variable "firmware" { type = string }
variable "enable_cpu_hot_add" { type = bool }
variable "enable_memory_hot_add" { type = bool }

variable "disk_size" {
  description = "OS disk size in GB"
  type        = number
  validation {
    condition     = var.disk_size >= 10 && var.disk_size <= 10000
    error_message = "Disk size must be between 10 GB and 10 TB."
  }
}

variable "thin_provisioned" { type = bool }
variable "eagerly_scrub" {
  type    = bool
  default = false
}

variable "hostname" {
  description = "Guest OS hostname"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.hostname))
    error_message = "Hostname must be lowercase alphanumeric with hyphens."
  }
}

variable "domain" { type = string }
variable "ssh_public_key" { type = string }

variable "data_disks" {
  description = "Additional data disks (beyond OS disk)"
  type = list(object({
    label            = string
    size             = number
    unit_number      = optional(number)
    thin_provisioned = optional(bool, true)
    eagerly_scrub    = optional(bool, false)
  }))
  default = []
}

variable "lvm_config" {
  description = "LVM volume groups and mount points"
  type = list(object({
    vg_name     = string
    lv_name     = string
    lv_size     = optional(string, "100%FREE")
    mount_point = string
    filesystem  = optional(string, "ext4")
    devices     = list(string)
  }))
  default = []
}

variable "os_partitions" {
  description = "Partitions on OS disk vg_os. Extends lv_root and/or creates new LVs."
  type = list(object({
    mount_point = string
    size        = string
    lv_name     = optional(string)
    filesystem  = optional(string, "ext4")
  }))
  default = []
}

variable "mount_points" {
  description = "Direct disk mount points (format + mount, no LVM)"
  type = list(object({
    device      = string
    mount_point = string
    filesystem  = optional(string, "ext4")
  }))
  default = []
}

variable "extra_users" {
  description = "Additional OS users (created via cloud-init users module)"
  type = list(object({
    username = string
    password = optional(string, "")
    groups   = optional(list(string), [])
  }))
  default = []
}

variable "user_groups" {
  description = "Group → OS access policy (os_groups/sudo/shell/description). Loaded from secure/<vc>/<env>/user-groups.tfvars"
  type = map(object({
    os_groups   = list(string)
    sudo        = string
    shell       = string
    description = optional(string, "")
  }))
  default = {}
}

variable "disable_auto_updates" {
  description = "Disable apt-daily, apt-daily-upgrade, unattended-upgrades"
  type        = bool
  default     = false
}

variable "enable_node_exporter" {
  description = "Install Prometheus node_exporter for monitoring"
  type        = bool
  default     = false
}
