targetScope = 'resourceGroup'

@description('Primary location for all resources.')
param location string

@description('Tags applied to all resources.')
param tags object

@description('Short unique suffix for resource names.')
param resourceToken string

@description('Entra tenant id.')
param tenantId string

@description('Entra application (client) id.')
param clientId string

@secure()
@description('Entra app client secret.')
param entraClientSecret string

@description('Optional public IP address allowed through resource firewalls (e.g. the deployer machine). Empty disables the rule.')
param deployerIpAddress string = ''

@description('Client public IP addresses allowed to read the data lake (e.g. Power BI report authors / gateway).')
param dataLakeAllowedIpAddresses array = []

@description('Entra user/group object ids granted Storage Blob Data Contributor on the data lake (e.g. report authors using Storage Explorer / Power BI Desktop).')
param dataLakeUserPrincipalIds array = []

// Deterministic Stream Analytics job resource ids (jobs are created further
// below). Used as storage resource instance rules so the firewalled data lake
// trusts the ASA managed identities without joining the VNet.
var streamAnalyticsJobIds = [for job in streamJobs: resourceId('Microsoft.StreamAnalytics/streamingjobs', 'asa-${job.service}-${resourceToken}')]

// ---------------------------------------------------------------------------
// Private networking: VNet, subnets, private DNS zones
// ---------------------------------------------------------------------------

module network './network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
  }
}

// ---------------------------------------------------------------------------
// Shared platform: Key Vault, monitoring, data lake, Event Hubs
// ---------------------------------------------------------------------------

module keyVault './keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: 'kv-prism-${resourceToken}'
    location: location
    tags: tags
    entraClientSecret: entraClientSecret
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    keyVaultDnsZoneId: network.outputs.keyVaultDnsZoneId
    deployerIpAddress: deployerIpAddress
  }
}

module monitoring './monitoring.bicep' = {
  name: 'monitoring'
  params: {
    name: 'log-prism-${resourceToken}'
    location: location
    tags: tags
  }
}

module dataLake './datalake.bicep' = {
  name: 'datalake'
  params: {
    name: 'dlprism${resourceToken}'
    location: location
    tags: tags
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    dfsDnsZoneId: network.outputs.dfsDnsZoneId
    streamAnalyticsJobIds: streamAnalyticsJobIds
    deployerIpAddress: deployerIpAddress
    allowedIpAddresses: dataLakeAllowedIpAddresses
  }
}

module eventHubs './eventhubs.bicep' = {
  name: 'eventhubs'
  params: {
    namespaceName: 'ehns-prism-${resourceToken}'
    location: location
    tags: tags
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    eventHubDnsZoneId: network.outputs.eventHubDnsZoneId
    deployerIpAddress: deployerIpAddress
  }
}

// ---------------------------------------------------------------------------
// Function Apps
// ---------------------------------------------------------------------------

var kvRef = 'VaultName=${keyVault.outputs.name}'

module exchangeFunc './functionApp.bicep' = {
  name: 'func-exchange'
  params: {
    serviceName: 'exchange'
    name: 'func-exchange-${resourceToken}'
    location: location
    tags: tags
    resourceToken: resourceToken
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    keyVaultName: keyVault.outputs.name
    functionsSubnetId: network.outputs.functionsSubnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    queueDnsZoneId: network.outputs.queueDnsZoneId
    tableDnsZoneId: network.outputs.tableDnsZoneId
    deployerIpAddress: deployerIpAddress
    appSettings: [
      { name: 'TENANT_ID', value: tenantId }
      { name: 'CLIENT_ID', value: clientId }
      { name: 'CLIENT_SECRET', value: '@Microsoft.KeyVault(${kvRef};SecretName=client-secret)' }
      { name: 'CONTENT_TYPE', value: 'Audit.Exchange' }
      { name: 'EVENT_HUB_NAME', value: 'eh-exchange' }
      { name: 'EVENT_HUB_NAMESPACE_FQDN', value: '${eventHubs.outputs.namespaceName}.servicebus.windows.net' }
    ]
  }
}

module sharepointFunc './functionApp.bicep' = {
  name: 'func-sharepoint'
  // Serialize VNet integration to avoid ServiceAssociationLink lease conflicts
  // when multiple apps integrate with the same subnet concurrently.
  dependsOn: [
    exchangeFunc
  ]
  params: {
    serviceName: 'sharepoint'
    name: 'func-sharepoint-${resourceToken}'
    location: location
    tags: tags
    resourceToken: resourceToken
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    keyVaultName: keyVault.outputs.name
    functionsSubnetId: network.outputs.functionsSubnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    queueDnsZoneId: network.outputs.queueDnsZoneId
    tableDnsZoneId: network.outputs.tableDnsZoneId
    deployerIpAddress: deployerIpAddress
    appSettings: [
      { name: 'TENANT_ID', value: tenantId }
      { name: 'CLIENT_ID', value: clientId }
      { name: 'CLIENT_SECRET', value: '@Microsoft.KeyVault(${kvRef};SecretName=client-secret)' }
      { name: 'CONTENT_TYPE', value: 'Audit.SharePoint' }
      { name: 'EVENT_HUB_NAME', value: 'eh-sharepoint' }
      { name: 'EVENT_HUB_NAMESPACE_FQDN', value: '${eventHubs.outputs.namespaceName}.servicebus.windows.net' }
    ]
  }
}

module dlpFunc './functionApp.bicep' = {
  name: 'func-dlp'
  dependsOn: [
    sharepointFunc
  ]
  params: {
    serviceName: 'dlp'
    name: 'func-dlp-${resourceToken}'
    location: location
    tags: tags
    resourceToken: resourceToken
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    keyVaultName: keyVault.outputs.name
    functionsSubnetId: network.outputs.functionsSubnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    queueDnsZoneId: network.outputs.queueDnsZoneId
    tableDnsZoneId: network.outputs.tableDnsZoneId
    deployerIpAddress: deployerIpAddress
    appSettings: [
      { name: 'TENANT_ID', value: tenantId }
      { name: 'CLIENT_ID', value: clientId }
      { name: 'CLIENT_SECRET', value: '@Microsoft.KeyVault(${kvRef};SecretName=client-secret)' }
      { name: 'CONTENT_TYPE', value: 'DLP.All' }
      { name: 'EVENT_HUB_NAME', value: 'eh-dlp' }
      { name: 'EVENT_HUB_NAMESPACE_FQDN', value: '${eventHubs.outputs.namespaceName}.servicebus.windows.net' }
    ]
  }
}

module entrausersFunc './functionApp.bicep' = {
  name: 'func-entrausers'
  dependsOn: [
    dlpFunc
  ]
  params: {
    serviceName: 'entrausers'
    name: 'func-entrausers-${resourceToken}'
    location: location
    tags: tags
    resourceToken: resourceToken
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    keyVaultName: keyVault.outputs.name
    functionsSubnetId: network.outputs.functionsSubnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    queueDnsZoneId: network.outputs.queueDnsZoneId
    tableDnsZoneId: network.outputs.tableDnsZoneId
    deployerIpAddress: deployerIpAddress
    appSettings: [
      { name: 'TENANT_ID', value: tenantId }
      { name: 'CLIENT_ID', value: clientId }
      { name: 'CLIENT_SECRET', value: '@Microsoft.KeyVault(${kvRef};SecretName=client-secret)' }
      { name: 'DATALAKE_BLOB_ENDPOINT', value: dataLake.outputs.blobEndpoint }
      { name: 'DATALAKE_CONTAINER', value: 'reference' }
      { name: 'DATALAKE_BLOB', value: 'entra/users.json' }
      { name: 'SNAPSHOT_SCHEDULE', value: '0 */10 * * * *' }
    ]
  }
}

// Grant the entrausers function identity write access to the data lake via
// managed identity (shared key auth is disabled on the data lake).
module entrausersDataLakeRole './datalakeRole.bicep' = {
  name: 'entrausers-datalake-role'
  params: {
    dataLakeName: dataLake.outputs.name
    principalId: entrausersFunc.outputs.principalId
  }
}

// Grant interactive users (report authors) read/write access to the data lake
// via their Entra identity so they can browse it in Storage Explorer / Power BI
// Desktop (shared key auth is disabled, so a data-plane role is required).
module dataLakeUserRoles './datalakeRole.bicep' = [for principalId in dataLakeUserPrincipalIds: {
  name: 'datalake-user-role-${uniqueString(principalId)}'
  params: {
    dataLakeName: dataLake.outputs.name
    principalId: principalId
    principalType: 'User'
  }
}]

// Grant each webhook function identity Send access on its Event Hub via
// managed identity (local SAS auth is disabled on the namespace).
module exchangeEventHubRole './eventHubRole.bicep' = {
  name: 'exchange-eventhub-role'
  params: {
    namespaceName: eventHubs.outputs.namespaceName
    eventHubName: 'eh-exchange'
    principalId: exchangeFunc.outputs.principalId
  }
}

module sharepointEventHubRole './eventHubRole.bicep' = {
  name: 'sharepoint-eventhub-role'
  params: {
    namespaceName: eventHubs.outputs.namespaceName
    eventHubName: 'eh-sharepoint'
    principalId: sharepointFunc.outputs.principalId
  }
}

module dlpEventHubRole './eventHubRole.bicep' = {
  name: 'dlp-eventhub-role'
  params: {
    namespaceName: eventHubs.outputs.namespaceName
    eventHubName: 'eh-dlp'
    principalId: dlpFunc.outputs.principalId
  }
}

// ---------------------------------------------------------------------------
// Stream Analytics — one job per Event Hub. Each reads its hub and lands
// line-separated JSON in the data lake (Power BI reads these folders directly,
// no Avro decode). Replaces Event Hubs Avro Capture for all three workloads.
// ---------------------------------------------------------------------------

var streamJobs = [
  { service: 'exchange', eventHubName: 'eh-exchange', prefix: 'exchange-json' }
  { service: 'sharepoint', eventHubName: 'eh-sharepoint', prefix: 'sharepoint-json' }
  { service: 'dlp', eventHubName: 'eh-dlp', prefix: 'dlp-json' }
]

module streamAnalytics './streamanalytics.bicep' = [for job in streamJobs: {
  name: 'streamanalytics-${job.service}'
  params: {
    jobName: 'asa-${job.service}-${resourceToken}'
    location: location
    tags: tags
    namespaceName: eventHubs.outputs.namespaceName
    eventHubName: job.eventHubName
    consumerGroupName: 'asa-${job.service}'
    dataLakeName: dataLake.outputs.name
    containerName: 'auditlogs'
    outputPrefix: job.prefix
  }
}]

// Grant each Stream Analytics identity write access to the data lake.
module streamAnalyticsDataLakeRole './datalakeRole.bicep' = [for (job, i) in streamJobs: {
  name: 'asa-datalake-role-${job.service}'
  params: {
    dataLakeName: dataLake.outputs.name
    principalId: streamAnalytics[i].outputs.principalId
  }
}]

output keyVaultName string = keyVault.outputs.name
output dataLakeName string = dataLake.outputs.name
output eventHubNamespaceName string = eventHubs.outputs.namespaceName
output exchangeFunctionUrl string = 'https://${exchangeFunc.outputs.defaultHostName}/api/webhook'
output sharepointFunctionUrl string = 'https://${sharepointFunc.outputs.defaultHostName}/api/webhook'
output dlpFunctionUrl string = 'https://${dlpFunc.outputs.defaultHostName}/api/webhook'
output entrausersFunctionName string = entrausersFunc.outputs.name
output streamAnalyticsJobNames array = [for (job, i) in streamJobs: streamAnalytics[i].outputs.jobName]
