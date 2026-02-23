locals {
  vnet_name        = "${var.name_prefix}-vnet"
  aks_subnet_name  = "${var.name_prefix}-snet-aks"
  pe_subnet_name   = "${var.name_prefix}-snet-pe"
  law_name         = "${var.name_prefix}-law"
  kv_name          = "${var.name_prefix}-kv"
  dns_kv_zone      = "privatelink.vaultcore.azure.net"
  dns_acr_zone     = "privatelink.azurecr.io"
  pe_kv_name       = "${var.name_prefix}-pe-kv"
  pe_acr_name      = "${var.name_prefix}-pe-acr"
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# --- Network ---
resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "aks" {
  name                 = local.aks_subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_aks_cidr]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = local.pe_subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_pe_cidr]

  # Required for private endpoints
  private_endpoint_network_policies = "Disabled"
}

# --- Log Analytics (for Container Insights) ---
resource "azurerm_log_analytics_workspace" "law" {
  name                = local.law_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# --- ACR (no admin user) ---
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Premium"
  admin_enabled       = false

network_rule_set {
  default_action = "Deny"
  virtual_network {
     action      = "Allow"
     subnet_id   =  azurerm_subnet.aks.id
   }
 }
}

  

# --- Key Vault (RBAC-based auth, private only) ---
resource "azurerm_key_vault" "kv" {
  name                       = local.kv_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  public_network_access_enabled = false

  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

data "azurerm_client_config" "current" {}

# --- Private DNS zones + VNet links ---
resource "azurerm_private_dns_zone" "kv" {
  name                = local.dns_kv_zone
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  name                  = "${var.name_prefix}-kv-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone" "acr" {
  name                = local.dns_acr_zone
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "${var.name_prefix}-acr-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

# --- Private Endpoints ---
resource "azurerm_private_endpoint" "kv" {
  name                = local.pe_kv_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${local.pe_kv_name}-psc"
    private_connection_resource_id = azurerm_key_vault.kv.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}

resource "azurerm_private_endpoint" "acr" {
  name                = local.pe_acr_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${local.pe_acr_name}-psc"
    private_connection_resource_id = azurerm_container_registry.acr.id
    is_manual_connection           = false
    subresource_names              = ["registry"]
  }

  private_dns_zone_group {
    name                 = "acr-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}

# --- AKS (private cluster + monitoring + workload identity) ---
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.aks_name

  private_cluster_enabled = false #setting to FALSE so kubectl can be run from home without a VPN

  identity {
    type = "SystemAssigned"
  }

  # enable OIDC issuer + workload identity
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Whitelist home IP to API server
  api_server_access_profile {
    authorized_ip_ranges = ["99.236.42.130"]
  }

  default_node_pool {
    name                = "system"
    vm_size             = "Standard_B2s" 
    vnet_subnet_id      = azurerm_subnet.aks.id
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 2
    os_disk_size_gb     = 32
    type                = "VirtualMachineScaleSets"
  }

  # Azure Monitor / Container Insights
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  }

  network_profile {
    network_plugin = "azure"
  }
}

# Let AKS pull from ACR (no creds)
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}
