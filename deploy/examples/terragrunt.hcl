# Terragrunt Example — Multi-VM Setup (ALTERNATIVE to built-in for_each)
#
# NOTE: The root module already supports unlimited VMs via for_each in
#       deploy/<vcenter>/<env>/vm-*.tfvars. Terragrunt is OPTIONAL — use only if
#       you want per-VM isolated state or parallel apply.
#
# Usage:
#   1. Install terragrunt: https://terragrunt.gruntwork.io/docs/getting-started/install/
#   2. For each VM, create a directory with:
#      - terragrunt.hcl  (source pointing to ../../terraform//modules/vm)
#      - env.yaml        (or use input vars directly)
#   3. Run: terragrunt run-all apply
#
# Architecture:
#   deploy/
#   ├── terragrunt.hcl          ← root config (providers, backend)
#   ├── vm-vmpilot/
#   │   └── terragrunt.hcl      ← VM-specific inputs
#   └── vm-webapp/
#       └── terragrunt.hcl      ← another VM, parallel apply

# ─────────────────────────────────────────────────────────────────────────
# deploy/terragrunt.hcl  (root — shared across all VMs)
# ─────────────────────────────────────────────────────────────────────────
# generate "provider" {
#   path      = "provider.tf"
#   if_exists = "overwrite_terragrunt"
#   contents  = <<EOF
# provider "vsphere" {
#   vsphere_server       = var.vsphere_server
#   user                 = var.vsphere_user
#   password             = var.vsphere_password
#   allow_unverified_ssl = var.allow_unverified_ssl
# }
# EOF
# }
#
# remote_state {
#   backend = "s3"
#   config = {
#     bucket         = "terraform-state-vmpilot"
#     key            = "${path_relative_to_include()}/terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "terraform-state-lock"
#   }
# }

# ─────────────────────────────────────────────────────────────────────────
# deploy/vm-vmpilot/terragrunt.hcl
# ─────────────────────────────────────────────────────────────────────────
# terraform {
#   source = "../../terraform//modules/vm"
# }
#
# include "root" {
#   path = find_in_parent_folders()
# }
#
# inputs = {
#   vm_name    = "prod_app"
#   hostname   = "vmpilot-prod"
#   domain     = "example.local"
#   cpu        = 4
#   memory     = 8192
#   disk_size  = 80
#
#   folder     = "/vmpilot/vm/prod"
#   annotation = "Production VMPilot VM"
#
#   ip_address = "198.51.100.110"
#   netmask    = 24
#   gateway    = "192.0.2.1"
#   dns_servers = ["198.51.100.10", "8.8.8.8"]
#
#   os_partitions = [
#     { mount_point = "/",     size = "8G" },
#     { mount_point = "/var",  size = "10G" },
#     { mount_point = "swap",  size = "4G" },
#   ]
#
#   extra_users = [
#     { username = "devops", password = "$(sops -d ../../secure/<vcenter>/passwords.tfvars | grep devops | cut -d= -f2)" }
#   ]
#
#   disable_auto_updates = true
# }
