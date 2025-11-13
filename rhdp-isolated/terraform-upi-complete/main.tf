# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0
#
# Complete OpenShift UPI Infrastructure for Azure
# Includes: DNS, Load Balancers, VMs with static IPs

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
# PRIVATE DNS ZONE
# ============================================================================

resource "azurerm_private_dns_zone" "cluster" {
  name                = "${var.cluster_domain}"
  resource_group_name = data.azurerm_resource_group.main.name

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "cluster" {
  name                  = "${var.cluster_name}-dns-link"
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.cluster.name
  virtual_network_id    = data.azurerm_virtual_network.main.id
  registration_enabled  = false

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

# ============================================================================
# LOAD BALANCERS
# ============================================================================

# Public IP for external API load balancer
resource "azurerm_public_ip" "api_external" {
  name                = "${var.cluster_name}-api-pip"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

# External Load Balancer for API (6443)
resource "azurerm_lb" "api_external" {
  name                = "${var.cluster_name}-api-external-lb"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "api-frontend"
    public_ip_address_id = azurerm_public_ip.api_external.id
  }

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_lb_backend_address_pool" "api_external" {
  name            = "api-backend-pool"
  loadbalancer_id = azurerm_lb.api_external.id
}

resource "azurerm_lb_probe" "api_external" {
  name            = "api-probe"
  loadbalancer_id = azurerm_lb.api_external.id
  protocol        = "Https"
  port            = 6443
  request_path    = "/readyz"
}

resource "azurerm_lb_rule" "api_external" {
  name                           = "api-rule"
  loadbalancer_id                = azurerm_lb.api_external.id
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "api-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.api_external.id]
  probe_id                       = azurerm_lb_probe.api_external.id
  enable_floating_ip             = false
  idle_timeout_in_minutes        = 30
}

# Internal Load Balancer for Machine Config Server (22623) and internal API
resource "azurerm_lb" "api_internal" {
  name                = "${var.cluster_name}-api-internal-lb"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "api-internal-frontend"
    subnet_id                     = data.azurerm_subnet.master.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.api_internal_ip
  }

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_lb_backend_address_pool" "api_internal" {
  name            = "api-internal-backend-pool"
  loadbalancer_id = azurerm_lb.api_internal.id
}

# Machine Config Server (22623) - only bootstrap and masters
resource "azurerm_lb_probe" "machine_config" {
  name            = "machine-config-probe"
  loadbalancer_id = azurerm_lb.api_internal.id
  protocol        = "Https"
  port            = 22623
  request_path    = "/healthz"
}

resource "azurerm_lb_rule" "machine_config" {
  name                           = "machine-config-rule"
  loadbalancer_id                = azurerm_lb.api_internal.id
  protocol                       = "Tcp"
  frontend_port                  = 22623
  backend_port                   = 22623
  frontend_ip_configuration_name = "api-internal-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.api_internal.id]
  probe_id                       = azurerm_lb_probe.machine_config.id
  enable_floating_ip             = false
  idle_timeout_in_minutes        = 30
}

# Internal API (6443)
resource "azurerm_lb_probe" "api_internal" {
  name            = "api-internal-probe"
  loadbalancer_id = azurerm_lb.api_internal.id
  protocol        = "Https"
  port            = 6443
  request_path    = "/readyz"
}

resource "azurerm_lb_rule" "api_internal" {
  name                           = "api-internal-rule"
  loadbalancer_id                = azurerm_lb.api_internal.id
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "api-internal-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.api_internal.id]
  probe_id                       = azurerm_lb_probe.api_internal.id
  enable_floating_ip             = false
  idle_timeout_in_minutes        = 30
}

# DNS A Records
resource "azurerm_private_dns_a_record" "api" {
  name                = "api"
  zone_name           = azurerm_private_dns_zone.cluster.name
  resource_group_name = data.azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_lb.api_internal.frontend_ip_configuration[0].private_ip_address]

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

resource "azurerm_private_dns_a_record" "api_int" {
  name                = "api-int"
  zone_name           = azurerm_private_dns_zone.cluster.name
  resource_group_name = data.azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_lb.api_internal.frontend_ip_configuration[0].private_ip_address]

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
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

# Associate bootstrap with internal LB backend pool
resource "azurerm_network_interface_backend_address_pool_association" "bootstrap" {
  network_interface_id    = azurerm_network_interface.bootstrap.id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.api_internal.id
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

# Associate masters with BOTH external and internal LB backend pools
resource "azurerm_network_interface_backend_address_pool_association" "master_external" {
  count                   = 3
  network_interface_id    = azurerm_network_interface.master[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.api_external.id
}

resource "azurerm_network_interface_backend_address_pool_association" "master_internal" {
  count                   = 3
  network_interface_id    = azurerm_network_interface.master[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.api_internal.id
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

  custom_data = base64encode(templatefile("${path.module}/ignition-shim.json.tpl", {
    ignition_url = var.master_ignition_url
  }))

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

# ============================================================================
# WORKER VMs (3 workers as requested)
# ============================================================================

resource "azurerm_network_interface" "worker" {
  count               = 3
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
  count               = 3
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

  custom_data = base64encode(templatefile("${path.module}/ignition-shim.json.tpl", {
    ignition_url = var.worker_ignition_url
  }))

  tags = {
    "kubernetes.io_cluster.${var.cluster_name}" = "owned"
  }
}

