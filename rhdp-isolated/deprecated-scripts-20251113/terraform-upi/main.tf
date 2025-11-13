# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0
#
# Terraform configuration for OpenShift UPI (User-Provisioned Infrastructure)
# This creates VMs with precise static IP control for disconnected environments

provider "azurerm" {
  features {}
  
  subscription_id = var.subscription_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
}

# Data sources for existing infrastructure
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "master" {
  name                 = var.master_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

data "azurerm_subnet" "worker" {
  name                 = var.worker_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

# ============================================================================
# BOOTSTRAP VM
# ============================================================================

resource "azurerm_public_ip" "bootstrap" {
  name                = "${var.cluster_name}-bootstrap-pip"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_network_interface" "bootstrap" {
  name                = "${var.cluster_name}-bootstrap-nic"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.master.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.bootstrap_ip
    public_ip_address_id          = azurerm_public_ip.bootstrap.id
  }

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_linux_virtual_machine" "bootstrap" {
  name                = "${var.cluster_name}-bootstrap"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  size                = "Standard_D4s_v3"
  admin_username      = "core"
  
  network_interface_ids = [
    azurerm_network_interface.bootstrap.id,
  ]

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${var.cluster_name}-bootstrap-os-disk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 120
  }

  source_image_id = var.rhcos_image_id

  # Ignition configuration via custom_data
  custom_data = base64encode(templatefile("${path.module}/ignition-shim.json.tpl", {
    ignition_url = var.bootstrap_ignition_url
  }))

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

# ============================================================================
# MASTER VMs
# ============================================================================

resource "azurerm_network_interface" "master" {
  count               = 3
  name                = "${var.cluster_name}-master-${count.index}-nic"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.master.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.master_ips[count.index]
  }

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_linux_virtual_machine" "master" {
  count               = 3
  name                = "${var.cluster_name}-master-${count.index}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  size                = "Standard_D8s_v3"
  admin_username      = "core"
  
  network_interface_ids = [
    azurerm_network_interface.master[count.index].id,
  ]

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${var.cluster_name}-master-${count.index}-os-disk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 120
  }

  source_image_id = var.rhcos_image_id

  # Ignition configuration via custom_data
  custom_data = base64encode(templatefile("${path.module}/ignition-shim.json.tpl", {
    ignition_url = var.master_ignition_url
  }))

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

# ============================================================================
# WORKER VMs
# ============================================================================

resource "azurerm_network_interface" "worker" {
  count               = 2
  name                = "${var.cluster_name}-worker-${count.index}-nic"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.worker.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.worker_ips[count.index]
  }

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_linux_virtual_machine" "worker" {
  count               = 2
  name                = "${var.cluster_name}-worker-${count.index}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  size                = "Standard_D4s_v3"
  admin_username      = "core"
  
  network_interface_ids = [
    azurerm_network_interface.worker[count.index].id,
  ]

  admin_ssh_key {
    username   = "core"
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "${var.cluster_name}-worker-${count.index}-os-disk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 120
  }

  source_image_id = var.rhcos_image_id

  # Ignition configuration via custom_data
  custom_data = base64encode(templatefile("${path.module}/ignition-shim.json.tpl", {
    ignition_url = var.worker_ignition_url
  }))

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

