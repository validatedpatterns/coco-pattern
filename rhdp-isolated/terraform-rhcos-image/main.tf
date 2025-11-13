# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0
#
# Terraform module to prepare RHCOS Azure managed image
# This replaces shell script logic with declarative infrastructure

terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  
  subscription_id = var.subscription_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
}

# Get RHCOS image URL from openshift-install
data "external" "rhcos_url" {
  program = ["bash", "-c", <<-EOT
    openshift-install coreos print-stream-json | jq -r '{url: .architectures.x86_64.artifacts.azure.formats."vhd.gz".disk.location}'
  EOT
  ]
}

# Storage account for RHCOS VHD upload
resource "azurerm_storage_account" "rhcos_vhd" {
  name                     = "vhd${var.guid}"
  resource_group_name      = var.resource_group_name
  location                 = var.region
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  tags = {
    purpose = "rhcos-vhd-upload"
  }
}

# Container for VHD storage
resource "azurerm_storage_container" "vhds" {
  name                  = "vhds"
  storage_account_name  = azurerm_storage_account.rhcos_vhd.name
  container_access_type = "private"
}

# Download and upload RHCOS VHD
resource "null_resource" "rhcos_vhd_upload" {
  triggers = {
    rhcos_url = data.external.rhcos_url.result.url
    always_run = timestamp() # Comment out for caching
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      # Use data disk for large files (not /tmp which is only 2GB)
      WORK_DIR="/var/cache/oc-mirror/rhcos-prep"
      mkdir -p "$WORK_DIR"
      
      # Download RHCOS VHD
      RHCOS_URL="${data.external.rhcos_url.result.url}"
      VHD_GZ="$WORK_DIR/rhcos-${var.guid}.vhd.gz"
      VHD="$WORK_DIR/rhcos-${var.guid}.vhd"
      
      echo "Downloading RHCOS VHD from $RHCOS_URL to data disk..."
      curl -L "$RHCOS_URL" -o "$VHD_GZ"
      
      echo "Extracting VHD (this may take a few minutes)..."
      gunzip -f "$VHD_GZ"
      
      echo "Uploading VHD to Azure Storage (10-15 minutes)..."
      az storage blob upload \
        --account-name ${azurerm_storage_account.rhcos_vhd.name} \
        --account-key ${azurerm_storage_account.rhcos_vhd.primary_access_key} \
        --container-name ${azurerm_storage_container.vhds.name} \
        --name rhcos-${var.openshift_version}.vhd \
        --file "$VHD" \
        --type page \
        --overwrite
      
      echo "Cleaning up local VHD..."
      rm -rf "$WORK_DIR"
    EOT
  }

  depends_on = [
    azurerm_storage_container.vhds
  ]
}

# Create Azure managed image from uploaded VHD
resource "azurerm_image" "rhcos" {
  name                = "rhcos-${var.guid}-image"
  resource_group_name = var.resource_group_name
  location            = var.region
  os_disk {
    os_type      = "Linux"
    os_state     = "Generalized"
    storage_type = "Premium_LRS"
    blob_uri     = "https://${azurerm_storage_account.rhcos_vhd.name}.blob.core.windows.net/${azurerm_storage_container.vhds.name}/rhcos-${var.openshift_version}.vhd"
  }

  tags = {
    purpose           = "openshift-rhcos"
    openshift_version = var.openshift_version
  }

  depends_on = [
    null_resource.rhcos_vhd_upload
  ]
}

