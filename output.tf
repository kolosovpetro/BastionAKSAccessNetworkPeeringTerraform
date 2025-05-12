output "connect_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.public.name} --name ${azurerm_kubernetes_cluster.aks.name} --subscription ${data.azurerm_client_config.current.subscription_id}"
}

output "aks_node_rg" {
  value = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}

output "spoke_rg" {
  value = azurerm_resource_group.spoke.name
}

output "spoke_vnet" {
  value = azurerm_virtual_network.spoke.name
}
