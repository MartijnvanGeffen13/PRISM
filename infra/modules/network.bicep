targetScope = 'resourceGroup'

@description('Location for the virtual network and private DNS resources.')
param location string

@description('Tags applied to all resources.')
param tags object

@description('Short unique suffix for resource names.')
param resourceToken string

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.10.0.0/22'

@description('Subnet (delegated to Microsoft.App/environments) used for Function App VNet integration.')
param functionsSubnetPrefix string = '10.10.0.0/24'

@description('Subnet that hosts all private endpoints.')
param privateEndpointSubnetPrefix string = '10.10.1.0/24'

// Private DNS zones required so the VNet-integrated Function Apps resolve each
// private endpoint to its private IP. Order is referenced by the outputs below.
var dnsZoneNames = [
  'privatelink.blob.${environment().suffixes.storage}' // 0 - blob
  'privatelink.queue.${environment().suffixes.storage}' // 1 - queue
  'privatelink.table.${environment().suffixes.storage}' // 2 - table
  'privatelink.dfs.${environment().suffixes.storage}' // 3 - dfs (ADLS Gen2)
  'privatelink.vaultcore.azure.net' // 4 - Key Vault
  'privatelink.servicebus.windows.net' // 5 - Event Hubs
]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-prism-${resourceToken}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        // Flex Consumption VNet integration requires delegation to
        // Microsoft.App/environments and cannot be shared with private endpoints.
        name: 'snet-functions'
        properties: {
          addressPrefix: functionsSubnetPrefix
          delegations: [
            {
              name: 'flex'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-pep'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for name in dnsZoneNames: {
  name: name
  location: 'global'
  tags: tags
}]

resource dnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (name, i) in dnsZoneNames: {
  parent: dnsZones[i]
  name: 'link-${resourceToken}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]

output vnetId string = vnet.id
output functionsSubnetId string = '${vnet.id}/subnets/snet-functions'
output privateEndpointSubnetId string = '${vnet.id}/subnets/snet-pep'
output blobDnsZoneId string = dnsZones[0].id
output queueDnsZoneId string = dnsZones[1].id
output tableDnsZoneId string = dnsZones[2].id
output dfsDnsZoneId string = dnsZones[3].id
output keyVaultDnsZoneId string = dnsZones[4].id
output eventHubDnsZoneId string = dnsZones[5].id
