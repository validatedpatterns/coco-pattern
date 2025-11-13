# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0

variable "guid" {
  description = "GUID for the deployment"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the existing resource group"
  type        = string
}

variable "region" {
  description = "Azure region"
  type        = string
}

variable "cluster_name" {
  description = "OpenShift cluster name (infraID from metadata.json)"
  type        = string
}

variable "cluster_domain" {
  description = "Full cluster domain (e.g., coco.p54kj.azure.redhatworkshops.io)"
  type        = string
}

variable "vnet_name" {
  description = "Name of the existing virtual network"
  type        = string
}

variable "master_subnet_name" {
  description = "Name of the master subnet"
  type        = string
}

variable "worker_subnet_name" {
  description = "Name of the worker subnet"
  type        = string
}

variable "bootstrap_ip" {
  description = "Static IP address for bootstrap VM"
  type        = string
  default     = "10.0.10.4"
}

variable "master_ips" {
  description = "Static IP addresses for master VMs"
  type        = list(string)
  default     = ["10.0.10.5", "10.0.10.6", "10.0.10.7"]
}

variable "worker_ips" {
  description = "Static IP addresses for worker VMs (3 workers)"
  type        = list(string)
  default     = ["10.0.20.4", "10.0.20.5", "10.0.20.6"]
}

variable "bastion_ip" {
  description = "Bastion host IP address for ignition config delivery"
  type        = string
  default     = "10.0.1.4"
}

variable "local_ignition_dir" {
  description = "Local directory containing generated ignition configs (e.g., ./openshift-install-upi)"
  type        = string
  default     = ""
}

variable "api_internal_ip" {
  description = "Static IP address for internal load balancer"
  type        = string
  default     = "10.0.10.10"
}

variable "bootstrap_ignition_url" {
  description = "URL to bootstrap ignition config (with SAS token)"
  type        = string
}

variable "master_ignition_url" {
  description = "URL to master ignition config (with SAS token)"
  type        = string
}

variable "worker_ignition_url" {
  description = "URL to worker ignition config (with SAS token)"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

variable "rhcos_image_id" {
  description = "Azure managed image ID for RHCOS"
  type        = string
}

# Azure authentication
variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  default     = ""
}

variable "client_id" {
  description = "Azure client ID"
  type        = string
  default     = ""
}

variable "client_secret" {
  description = "Azure client secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure tenant ID"
  type        = string
  default     = ""
}

