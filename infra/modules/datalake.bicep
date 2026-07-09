targetScope = 'resourceGroup'

@description('ADLS Gen2 storage account name (3-24 lowercase alphanumeric).')
param name string

@description('Location for the storage account.')
param location string

@description('Tags applied to the storage account.')
param tags object

@description('Resource id of the subnet that hosts the private endpoints.')
param privateEndpointSubnetId string

@description('Private DNS zone id for blob (privatelink.blob.*).')
param blobDnsZoneId string

@description('Private DNS zone id for dfs (privatelink.dfs.*).')
param dfsDnsZoneId string

@description('Resource ids of the Stream Analytics jobs allowed through the firewall (resource instance rules).')
param streamAnalyticsJobIds array = []

resource dataLake 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Access is via managed identity only; shared key auth is disabled. The
    // entrausers function and Stream Analytics jobs authenticate with Azure AD.
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    // Public network access is governed by the associated Network Security
    // Perimeter (see networkSecurityPerimeter.bicep). The perimeter denies all
    // public traffic by default and allows only:
    //  - the entrausers function (over its private endpoint / VNet — private
    //    endpoint traffic is always allowed without an explicit rule)
    //  - report authors / Power BI Desktop (inbound IP rule on the perimeter)
    //  - in-subscription Azure services such as the Stream Analytics job
    //    (inbound subscription rule on the perimeter; MSI/Azure AD auth).
    // The Stream Analytics resource instance rules are kept as a defence-in-depth
    // fallback for MSI access; they have no effect while SecuredByPerimeter.
    publicNetworkAccess: 'SecuredByPerimeter'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
      resourceAccessRules: [for jobId in streamAnalyticsJobIds: {
        tenantId: tenant().tenantId
        resourceId: jobId
      }]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: dataLake
  name: 'default'
}

resource auditlogsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'auditlogs'
  properties: {
    publicAccess: 'None'
  }
}

resource referenceContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'reference'
  properties: {
    publicAccess: 'None'
  }
}

module blobPrivateEndpoint './privateEndpoint.bicep' = {
  name: '${name}-blob-pe'
  params: {
    name: 'pe-${name}-blob'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: dataLake.id
    groupId: 'blob'
    dnsZoneId: blobDnsZoneId
  }
}

module dfsPrivateEndpoint './privateEndpoint.bicep' = {
  name: '${name}-dfs-pe'
  params: {
    name: 'pe-${name}-dfs'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: dataLake.id
    groupId: 'dfs'
    dnsZoneId: dfsDnsZoneId
  }
}

output id string = dataLake.id
output name string = dataLake.name
output blobEndpoint string = dataLake.properties.primaryEndpoints.blob
