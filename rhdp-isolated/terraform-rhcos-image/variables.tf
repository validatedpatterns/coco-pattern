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

variable "openshift_version" {
  description = "OpenShift version (e.g., 4.20)"
  type        = string
  default     = "4.20"
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

