# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0

output "bootstrap_public_ip" {
  description = "Public IP of the bootstrap VM"
  value       = azurerm_public_ip.bootstrap.ip_address
}

output "bootstrap_private_ip" {
  description = "Private IP of the bootstrap VM"
  value       = var.bootstrap_ip
}

output "master_private_ips" {
  description = "Private IPs of master VMs"
  value       = var.master_ips
}

output "worker_private_ips" {
  description = "Private IPs of worker VMs"
  value       = var.worker_ips
}

output "cluster_name" {
  description = "OpenShift cluster name"
  value       = var.cluster_name
}

