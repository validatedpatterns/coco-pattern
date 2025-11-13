# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0

output "image_id" {
  description = "Azure managed image ID for RHCOS"
  value       = azurerm_image.rhcos.id
}

output "image_name" {
  description = "Azure managed image name"
  value       = azurerm_image.rhcos.name
}

output "vhd_storage_account" {
  description = "Storage account used for VHD upload"
  value       = azurerm_storage_account.rhcos_vhd.name
}

