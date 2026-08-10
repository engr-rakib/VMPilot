# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
#############################################################
# File Name : versions.tf
#
# Purpose
# -------
# Terraform and VMware vSphere Provider Definition
#
# Platform
# --------
# VMware vCenter 7.x / 8.x
#
#############################################################

terraform {

  required_version = ">= 1.6, < 2.0"


  required_providers {

    vsphere = {

      source = "vmware/vsphere"

      version = "~> 2.16.0"

    }

    external = {

      source = "hashicorp/external"

      version = "~> 2.3"

    }

    local = {

      source = "hashicorp/local"

      version = "~> 2.5"

    }

    null = {

      source = "hashicorp/null"

      version = "~> 3.2"

    }

  }



}