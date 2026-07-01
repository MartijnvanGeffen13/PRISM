targetScope = 'resourceGroup'

@description('Private endpoint name.')
param name string

@description('Location for the private endpoint.')
param location string

@description('Tags applied to the private endpoint.')
param tags object

@description('Resource id of the subnet that hosts the private endpoint.')
param subnetId string

@description('Resource id of the target service (storage account, vault, namespace, ...).')
param serviceId string

@description('Sub-resource (groupId) to connect to, e.g. blob, queue, table, dfs, vault, namespace.')
param groupId string

@description('Resource id of the private DNS zone that resolves this groupId.')
param dnsZoneId string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: serviceId
          groupIds: [
            groupId
          ]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: groupId
        properties: {
          privateDnsZoneId: dnsZoneId
        }
      }
    ]
  }
}

output id string = privateEndpoint.id
