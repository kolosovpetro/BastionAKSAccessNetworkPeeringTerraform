data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

#################################################################################################################
# LOCALS
#################################################################################################################

locals {
  vnet_aks_cidr = ["10.10.0.0/24"]

  ask_nodes_subnet_cidr = ["10.10.0.0/25"]


  vnet_spoke_cidr     = ["10.11.0.0/24"]
  vm_subnet_cidr      = ["10.11.0.0/26"]
  bastion_subnet_cidr = ["10.11.0.64/26"]
}

#################################################################################################################
# RESOURCE GROUP
#################################################################################################################

resource "azurerm_resource_group" "public" {
  location = var.location
  name     = "rg-bastion-peering-${var.prefix}"
  tags     = var.tags
}

resource "azurerm_resource_group" "spoke" {
  location = var.location
  name     = "rg-spoke-${var.prefix}"
  tags     = var.tags
}

#################################################################################################################
# VNET HUB
#################################################################################################################

resource "azurerm_virtual_network" "aks" {
  name                = "vnet-aks-${var.prefix}"
  address_space       = local.vnet_aks_cidr
  location            = azurerm_resource_group.public.location
  resource_group_name = azurerm_resource_group.public.name
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes-${var.prefix}"
  resource_group_name  = azurerm_resource_group.public.name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = local.ask_nodes_subnet_cidr
}

#################################################################################################################
# VNET SPOKE
#################################################################################################################

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-spoke-${var.prefix}"
  address_space       = local.vnet_spoke_cidr
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm-${var.prefix}"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = local.vm_subnet_cidr
}

resource "azurerm_subnet" "bastion_snet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = local.bastion_subnet_cidr
}

#################################################################################################################
# NETWORK PEERING
#################################################################################################################

resource "azurerm_virtual_network_peering" "aks_vm" {
  name                      = "peer-aks-vm-${var.prefix}"
  resource_group_name       = azurerm_resource_group.public.name
  virtual_network_name      = azurerm_virtual_network.aks.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
}

resource "azurerm_virtual_network_peering" "vm_aks" {
  name                      = "peer-vm-aks-${var.prefix}"
  resource_group_name       = azurerm_resource_group.spoke.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.aks.id
}

#################################################################################################################
# AKS
#################################################################################################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-${var.prefix}"
  kubernetes_version  = "1.31.2"
  location            = azurerm_resource_group.public.location
  resource_group_name = azurerm_resource_group.public.name
  dns_prefix          = "aks-${var.prefix}"
  node_resource_group = "rg-node-aks-${var.prefix}"
  private_dns_zone_id = "System"

  default_node_pool {
    name           = "systempool"
    node_count     = 2
    vm_size        = "Standard_DS2_v2"
    os_sku         = "AzureLinux"
    vnet_subnet_id = azurerm_subnet.aks_nodes.id
  }

  private_cluster_enabled = true

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  web_app_routing {
    dns_zone_ids = []
  }


  lifecycle {
    ignore_changes = [
      key_vault_secrets_provider,
      default_node_pool.0.upgrade_settings
    ]
  }
}

#################################################################################################################
# PRIVATE LINK AKS TO SPOKE VNET
#################################################################################################################

# data "azapi_resource_list" "private_dns_zones" {
#   type                   = "Microsoft.Network/privateDnsZones@2020-06-01"
#   parent_id              = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${azurerm_kubernetes_cluster.aks.node_resource_group}"
#   response_export_values = ["name"]
#
#   depends_on = [azurerm_kubernetes_cluster.aks]
# }
#
# locals {
#   private_dns_zone_names = [
#     for zone in data.azapi_resource_list.private_dns_zones.output : zone.name
#     if can(regex(".*\\.privatelink\\.northeurope\\.azmk8s\\.io", zone.name))
#   ]
# }
#
# resource "azurerm_private_dns_zone_virtual_network_link" "aks" {
#   name                  = "link-spoke-${var.prefix}"
#   resource_group_name   = azurerm_kubernetes_cluster.aks.node_resource_group
#   private_dns_zone_name = local.private_dns_zone_names[0]
#   virtual_network_id    = azurerm_virtual_network.spoke.id
#   registration_enabled  = false
#
#   depends_on = [
#     data.azapi_resource_list.private_dns_zones,
#     azurerm_kubernetes_cluster.aks
#   ]
# }

#################################################################################################################
# VIRTUAL MACHINES
#################################################################################################################

module "linux_vm" {
  source                           = "./modules/jumpbox-vm"
  ip_configuration_name            = "pip-vm2-${var.prefix}"
  network_interface_name           = "nic-vm2-${var.prefix}"
  os_profile_admin_password        = trimspace(file("${path.root}/password.txt"))
  os_profile_admin_username        = "razumovsky_r"
  os_profile_computer_name         = "vm2-${var.prefix}"
  resource_group_name              = azurerm_resource_group.spoke.name
  resource_group_location          = azurerm_resource_group.spoke.location
  storage_os_disk_name             = "osdisk-vm2-${var.prefix}"
  subnet_id                        = azurerm_subnet.vm.id
  vm_name                          = "vm2-${var.prefix}"
  network_security_group_id        = azurerm_network_security_group.spoke.id
  custom_image_resource_group_name = "rg-packer-images-linux"
  custom_image_sku                 = "azure-ubuntu-v6"
}

# Assign RBAC role so the VM can get AKS credentials
resource "azurerm_role_assignment" "vm_mi_to_aks" {
  principal_id         = module.linux_vm.user_assigned_identity_principal_id
  role_definition_name = "Contributor"
  scope                = data.azurerm_subscription.current.id
}

#################################################################################################################
# BASTION
#################################################################################################################

resource "azurerm_public_ip" "bastion_pip" {
  name                = "bastion-pip-${var.prefix}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "public" {
  name                = "bastion-${var.prefix}"
  copy_paste_enabled  = true
  file_copy_enabled   = true
  ip_connect_enabled  = false
  tunneling_enabled   = true
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  sku                 = "Standard"

  ip_configuration {
    name                 = "bastion-ipc-${var.prefix}"
    subnet_id            = azurerm_subnet.bastion_snet.id
    public_ip_address_id = azurerm_public_ip.bastion_pip.id
  }
}
