# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
locals {
  data_disks_with_unit = [
    for i, d in var.data_disks : {
      label            = d.label
      size             = d.size
      unit_number      = d.unit_number != null ? d.unit_number : i + 1
      thin_provisioned = d.thin_provisioned
      eagerly_scrub    = d.eagerly_scrub
    }
  ]

  os_partitions_with_lv = [
    for p in var.os_partitions : {
      mount_point = can(regex("^/", p.mount_point)) ? p.mount_point : p.mount_point == "swap" ? "swap" : "/${p.mount_point}"
      size        = p.size
      filesystem  = p.filesystem != null ? p.filesystem : "ext4"
      lv_name = p.lv_name != null ? p.lv_name : (
        p.mount_point == "/" ? "lv_root" : (
          p.mount_point == "swap" ? "lv_swap" : "lv_${replace(p.mount_point, "/", "")}"
        )
      )
    }
  ]

  lvm_config_with_abs = [
    for lv in var.lvm_config : {
      vg_name     = lv.vg_name
      lv_name     = lv.lv_name
      lv_size     = lv.lv_size
      mount_point = can(regex("^/", lv.mount_point)) ? lv.mount_point : "/${lv.mount_point}"
      filesystem  = lv.filesystem
      devices     = lv.devices
    }
  ]

  mount_points_with_abs = [
    for mp in var.mount_points : {
      device      = mp.device
      mount_point = can(regex("^/", mp.mount_point)) ? mp.mount_point : "/${mp.mount_point}"
      filesystem  = mp.filesystem
    }
  ]

  os_has_swap = length([for p in var.os_partitions : p if p.mount_point == "swap"]) > 0
}

locals {
  # Resolve each extra_user's group membership → union of os_groups + sudo
  # rules across ALL their groups + shell. A user can belong to MANY groups.
  #
  # Policy present (user_groups non-empty):
  #   - groups set   → union of each group's os_groups/sudo
  #   - no groups    → NO sudo, no extra OS groups (SSH-key only), default shell
  #   - unknown group → skipped (treated as no-op)
  # Policy MISSING (empty user_groups) → legacy full-sudo fallback so existing
  # configs keep working.
  group_attr = merge({
    admin = { os_groups = ["sudo", "adm"], sudo = "ALL=(ALL) NOPASSWD:ALL", shell = "/bin/bash", description = "Infra admin — full sudo" }
  }, var.user_groups)
  use_policy = length(var.user_groups) > 0

  # Fail-fast: when policy is present, every group a user references must exist
  # in the policy file. A typo'd group silently yielding "no access" is dangerous
  # (user locked out) or silently granting admin fallback (privilege leak).
  unknown_groups = local.use_policy ? distinct(flatten([for u in var.extra_users : [for g in u.groups : g if !contains(keys(var.user_groups), g)]])) : []

  # Policy fingerprint — recorded in the audit manifest so reviewers can tie a
  # VM's access to the exact policy state it was deployed with.
  policy_hash = length(var.user_groups) > 0 ? sha256(jsonencode(var.user_groups)) : "legacy-fallback"

  resolved_users = [for u in var.extra_users : {
    username = u.username
    password = u.password
    groups   = local.use_policy ? distinct(flatten([for g in u.groups : try(local.group_attr[g].os_groups, [])])) : (length(u.groups) > 0 ? distinct(flatten([for g in u.groups : try(local.group_attr[g].os_groups, local.group_attr["admin"].os_groups)])) : ["sudo", "adm"])
    sudo     = local.use_policy ? join(", ", [for g in u.groups : try(local.group_attr[g].sudo, "")]) : (length(u.groups) > 0 ? join(", ", [for g in u.groups : try(local.group_attr[g].sudo, local.group_attr["admin"].sudo)]) : "ALL=(ALL) NOPASSWD:ALL")
    shell    = local.use_policy && length(u.groups) > 0 ? try(local.group_attr[u.groups[0]].shell, "/bin/bash") : "/bin/bash"
    groups_desc = local.use_policy ? join(", ", [for g in u.groups : try(local.group_attr[g].description, "")]) : ""
  }]

  # Audit manifest — a Markdown record of who has access and WHY (group
  # descriptions), written to /etc/vmpilot-access.md by cloud-init.
  manifest_lines = concat(
    ["# VMPilot access manifest — ${var.hostname}",
     "",
     "- Deployed from policy: secure/<vcenter>/<env>/user-groups.tfvars",
     "- Policy fingerprint (sha256): ${local.policy_hash}",
     "",
     "| User | OS groups | sudo | shell | group purpose |",
     "|------|-----------|------|-------|---------------|"],
    [for u in local.resolved_users : "| ${u.username} | ${length(u.groups) > 0 ? join(", ", u.groups) : "(none)"} | ${u.sudo != "" ? u.sudo : "(none)"} | ${u.shell} | ${u.groups_desc} |"]
  )
  access_manifest = join("\n", local.manifest_lines)
}

check "unknown_user_group" {
  assert {
    condition     = length(local.unknown_groups) == 0
    error_message = "extra_users references group(s) not defined in the user-groups policy: ${join(", ", local.unknown_groups)}. Fix the group name in the per-VM config or add the group to secure/<vcenter>/<env>/user-groups.tfvars."
  }
}

resource "vsphere_virtual_machine" "this" {

  name       = var.vm_name
  folder     = var.folder
  annotation = var.annotation

  resource_pool_id = var.resource_pool_id
  datastore_id     = var.datastore_id
  host_system_id   = var.host_system_id

  num_cpus = var.cpu
  memory   = var.memory
  firmware = var.firmware

  cpu_hot_add_enabled    = var.enable_cpu_hot_add
  memory_hot_add_enabled = var.enable_memory_hot_add

  guest_id  = var.template_guest_id
  scsi_type = var.template_scsi_type

  dynamic "network_interface" {
    for_each = var.networks
    content {
      network_id   = network_interface.value.network_id
      adapter_type = network_interface.value.adapter_type
    }
  }

  disk {
    label            = "os-disk"
    size             = var.disk_size
    thin_provisioned = var.thin_provisioned
    eagerly_scrub    = var.eagerly_scrub
  }

  dynamic "disk" {
    for_each = local.data_disks_with_unit
    content {
      label            = disk.value.label
      size             = disk.value.size
      unit_number      = disk.value.unit_number
      thin_provisioned = disk.value.thin_provisioned
      eagerly_scrub    = disk.value.eagerly_scrub
    }
  }

  clone {
    template_uuid = var.template_id
  }

  extra_config = {
    "guestinfo.metadata" = base64encode(
      templatefile("${path.module}/cloud-init/metadata.yaml", {
        vm_name  = var.vm_name
        hostname = var.hostname
      })
    )

    "guestinfo.metadata.encoding" = "base64"

    "guestinfo.userdata" = base64encode(
      templatefile("${path.module}/cloud-init/userdata.yaml", {
        hostname             = var.hostname
        domain               = var.domain
        ssh_public_key       = var.ssh_public_key
        data_disks           = local.data_disks_with_unit
        os_partitions        = local.os_partitions_with_lv
        lvm_config           = local.lvm_config_with_abs
        mount_points         = local.mount_points_with_abs
        networks             = var.networks
        memory_mb            = var.memory
        os_has_swap          = local.os_has_swap
        extra_users          = local.resolved_users
        access_manifest      = local.access_manifest
        disable_auto_updates = var.disable_auto_updates
        enable_node_exporter = var.enable_node_exporter
      })
    )

    "guestinfo.userdata.encoding" = "base64"
  }

  wait_for_guest_net_timeout = var.wait_for_guest_net_timeout

  lifecycle {
    # Hardcoded true: Terraform doesn't allow variables in lifecycle blocks.
    # Use scripts/destroy.sh for safe destroy flow.
    prevent_destroy = true
    ignore_changes  = [datastore_id]
  }

}
