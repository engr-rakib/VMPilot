# ============================================================
# VMPilot  (c) 2026 Rakibuzzaman (Engr. Rakib)
# Original author - do not remove this attribution.
# GitHub: https://github.com/engr-rakib
# Web:    https://engr-rakib.github.io/web
# ============================================================
output "id" {
  value = vsphere_virtual_machine.this.id
}

output "name" {
  value = vsphere_virtual_machine.this.name
}

output "default_ip_address" {
  value = vsphere_virtual_machine.this.default_ip_address
}

output "guest_id" {
  value = vsphere_virtual_machine.this.guest_id
}

output "num_cpus" {
  value = vsphere_virtual_machine.this.num_cpus
}

output "memory" {
  value = vsphere_virtual_machine.this.memory
}
