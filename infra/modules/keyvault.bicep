targetScope = 'resourceGroup'

@description('Key Vault name (3-24 chars, alphanumeric and dashes).')
param name string

@description('Location for the vault.')
param location string

@description('Tags applied to the vault.')
param tags object

@secure()
@description('Entra app client secret stored as the client-secret secret.')
param entraClientSecret string

@description('Resource id of the subnet that hosts the private endpoint.')
param privateEndpointSubnetId string

@description('Private DNS zone id for Key Vault (privatelink.vaultcore.azure.net).')
param keyVaultDnsZoneId string

@description('Optional public IP address allowed through the firewall (e.g. the deployer machine). Empty disables the rule.')
param deployerIpAddress string = ''

var ipRules = empty(deployerIpAddress) ? [] : [
  {
    value: deployerIpAddress
  }
]

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    // Public endpoint is firewalled to default-deny. The Function Apps read
    // secrets over a private endpoint via their VNet integration.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: ipRules
      virtualNetworkRules: []
    }
  }
}

resource clientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'client-secret'
  properties: {
    value: entraClientSecret
  }
}

module privateEndpoint './privateEndpoint.bicep' = {
  name: '${name}-pe'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: keyVault.id
    groupId: 'vault'
    dnsZoneId: keyVaultDnsZoneId
  }
}

output name string = keyVault.name
output id string = keyVault.id
output uri string = keyVault.properties.vaultUri
