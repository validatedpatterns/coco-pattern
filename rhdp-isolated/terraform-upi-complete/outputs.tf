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

output "api_external_ip" {
  description = "External API load balancer public IP"
  value       = azurerm_public_ip.api_external.ip_address
}

output "api_internal_ip" {
  description = "Internal API load balancer private IP"
  value       = azurerm_lb.api_internal.frontend_ip_configuration[0].private_ip_address
}

output "cluster_name" {
  description = "OpenShift cluster name"
  value       = var.cluster_name
}

output "cluster_domain" {
  description = "Cluster domain"
  value       = var.cluster_domain
}

output "dns_zone_id" {
  description = "Private DNS zone ID"
  value       = azurerm_private_dns_zone.cluster.id
}

