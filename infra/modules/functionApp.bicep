targetScope = 'resourceGroup'

@minLength(3)
@maxLength(11)
@description('azd service name (must match azure.yaml) — set as azd-service-name tag.')
param serviceName string

@description('Function App name (globally unique, <=60 chars).')
param name string

@description('Location for resources.')
param location string

@description('Base tags applied to resources.')
param tags object

@description('Short unique suffix for supporting resource names.')
param resourceToken string

@description('Log Analytics workspace resource id for Application Insights.')
param logAnalyticsId string

@description('Key Vault name the Function App reads secrets from.')
param keyVaultName string

@description('Service-specific app settings (TENANT_ID, CLIENT_ID, Key Vault references, etc.).')
param appSettings array

@description('Python runtime version for Flex Consumption.')
param pythonVersion string = '3.12'

@description('Resource id of the delegated subnet used for VNet integration.')
param functionsSubnetId string

@description('Resource id of the subnet that hosts the private endpoints.')
param privateEndpointSubnetId string

@description('Private DNS zone id for blob (privatelink.blob.*).')
param blobDnsZoneId string

@description('Private DNS zone id for queue (privatelink.queue.*).')
param queueDnsZoneId string

@description('Private DNS zone id for table (privatelink.table.*).')
param tableDnsZoneId string

@description('Optional public IP address allowed through the host storage firewall (e.g. the deployer machine). Empty disables the rule.')
param deployerIpAddress string = ''

var ipRules = empty(deployerIpAddress) ? [] : [
  {
    value: deployerIpAddress
    action: 'Allow'
  }
]

// Storage Blob Data Owner
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
// Key Vault Secrets User
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

var serviceTags = union(tags, { 'azd-service-name': serviceName })

resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${serviceName}${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    // Host storage is firewalled to default-deny. The Function App reaches it
    // over private endpoints via VNet integration. The optional deployer IP
    // lets azd upload the deployment package from outside the VNet.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: ipRules
      virtualNetworkRules: []
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: hostStorage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'deploymentpackage'
  properties: {
    publicAccess: 'None'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${serviceName}-${resourceToken}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsId
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-${serviceName}-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: serviceTags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // VNet integration so the app reaches host storage, Event Hubs, the data
    // lake and Key Vault over their private endpoints. Inbound stays public so
    // the M365 Management API can deliver webhook notifications.
    virtualNetworkSubnetId: functionsSubnetId
    vnetRouteAllEnabled: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${hostStorage.properties.primaryEndpoints.blob}deploymentpackage'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: pythonVersion
      }
    }
    siteConfig: {
      appSettings: concat(
        [
          {
            name: 'AzureWebJobsStorage__blobServiceUri'
            value: hostStorage.properties.primaryEndpoints.blob
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.properties.ConnectionString
          }
        ],
        appSettings
      )
    }
  }
}

// Function runtime access to its own host storage (deployment + state).
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: hostStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Allow the Function App to resolve Key Vault references at runtime.
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output name string = functionApp.name
output defaultHostName string = functionApp.properties.defaultHostName
output principalId string = functionApp.identity.principalId

module blobPrivateEndpoint './privateEndpoint.bicep' = {
  name: 'st${serviceName}${resourceToken}-blob-pe'
  params: {
    name: 'pe-st${serviceName}${resourceToken}-blob'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: hostStorage.id
    groupId: 'blob'
    dnsZoneId: blobDnsZoneId
  }
}

module queuePrivateEndpoint './privateEndpoint.bicep' = {
  name: 'st${serviceName}${resourceToken}-queue-pe'
  params: {
    name: 'pe-st${serviceName}${resourceToken}-queue'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: hostStorage.id
    groupId: 'queue'
    dnsZoneId: queueDnsZoneId
  }
}

module tablePrivateEndpoint './privateEndpoint.bicep' = {
  name: 'st${serviceName}${resourceToken}-table-pe'
  params: {
    name: 'pe-st${serviceName}${resourceToken}-table'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: hostStorage.id
    groupId: 'table'
    dnsZoneId: tableDnsZoneId
  }
}
