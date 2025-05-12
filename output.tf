output "connect_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.public.name} --name ${azurerm_kubernetes_cluster.aks.name} --subscription ${data.azurerm_client_config.current.subscription_id}"
}
