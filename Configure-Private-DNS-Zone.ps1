$AksNodeRg = $( terraform output -raw aks_node_rg )
$SubscriptionId = $( terraform output -raw subscription_id )
$SpokeRg = $( terraform output -raw spoke_rg )
$SpokeVnet = $( terraform output -raw spoke_vnet )

$DnsZoneName = az network private-dns zone list --resource-group "$aksNodeRG" `
    --query "[?contains(name, 'privatelink')].name | [0]" --output tsv

Write-Host "Dns Zone name: $DnsZoneName"

az network private-dns link vnet create `
--resource-group "$aksNodeRG" `
--zone-name "$DnsZoneName" `
--name "aks-dns-link" `
--virtual-network "/subscriptions/$SubscriptionId/resourceGroups/$SpokeRg/providers/Microsoft.Network/virtualNetworks/$SpokeVnet" `
--registration-enabled false
