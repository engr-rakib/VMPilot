# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
#############################################################
# File Name : provider.tf
#
# Purpose
# -------
# VMware vCenter Authentication
#
# Credential Source:
# secure/<env>/credentials.tfvars (encrypted via sops/age)
# Decrypted automatically by sops-decrypt.sh before terraform runs.
# Decrypted files: terraform/credentials.auto.tfvars + vcenter.auto.tfvars
#
#############################################################


provider "vsphere" {


  vsphere_server = var.vsphere_server


  user = var.vsphere_user


  password = var.vsphere_password


  allow_unverified_ssl = var.allow_unverified_ssl


}