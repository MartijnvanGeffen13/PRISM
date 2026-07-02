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

@description('Which audit APIs to deploy. Each entry provisions the full stack for that workload: Function App, Event Hub, Stream Analytics job and role assignments. Valid values: exchange, sharepoint, dlp, general, azuread.')
param enabledWorkloads array = [
  'exchange'
  'sharepoint'
  'dlp'
  'general'
  'azuread'
]

// Full catalogue of supported audit workloads. Deployment is filtered down to
// the subset requested via enabledWorkloads so each API (and all of its
// dedicated infrastructure) can be turned on or off independently.
var allWorkloads = [
  { service: 'exchange', eventHubName: 'eh-exchange', contentType: 'Audit.Exchange', outputPrefix: 'exchange-json' }
  { service: 'sharepoint', eventHubName: 'eh-sharepoint', contentType: 'Audit.SharePoint', outputPrefix: 'sharepoint-json' }
  { service: 'dlp', eventHubName: 'eh-dlp', contentType: 'DLP.All', outputPrefix: 'dlp-json' }
  { service: 'general', eventHubName: 'eh-general', contentType: 'Audit.General', outputPrefix: 'general-json' }
  { service: 'azuread', eventHubName: 'eh-azuread', contentType: 'Audit.AzureActiveDirectory', outputPrefix: 'azuread-json' }
]
var workloads = filter(allWorkloads, w => contains(enabledWorkloads, w.service))
var enabledServices = map(workloads, w => w.service)

// Deterministic Stream Analytics job resource ids (jobs are created further
// below). Used as storage resource instance rules so the firewalled data lake
// trusts the ASA managed identities without joining the VNet.
var streamAnalyticsJobIds = [for w in workloads: resourceId('Microsoft.StreamAnalytics/streamingjobs', 'asa-${w.service}-${resourceToken}')]

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
    eventHubNames: map(workloads, w => w.eventHubName)
  }
}

// ---------------------------------------------------------------------------
// Function Apps
// ---------------------------------------------------------------------------

var kvRef = 'VaultName=${keyVault.outputs.name}'

// One Function App per enabled workload. Serialized (batchSize 1) to avoid
// ServiceAssociationLink lease conflicts when multiple apps integrate with the
// same functions subnet concurrently.
@batchSize(1)
module workloadFuncs './functionApp.bicep' = [for w in workloads: {
  name: 'func-${w.service}'
  params: {
    serviceName: w.service
    name: 'func-${w.service}-${resourceToken}'
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
      { name: 'CONTENT_TYPE', value: w.contentType }
      { name: 'EVENT_HUB_NAME', value: w.eventHubName }
      { name: 'EVENT_HUB_NAMESPACE_FQDN', value: '${eventHubs.outputs.namespaceName}.servicebus.windows.net' }
    ]
  }
}]

module entrausersFunc './functionApp.bicep' = {
  name: 'func-entrausers'
  dependsOn: [
    workloadFuncs
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
      { name: 'SNAPSHOT_SCHEDULE', value: '0 0 2 * * *' }
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
module workloadEventHubRoles './eventHubRole.bicep' = [for (w, i) in workloads: {
  name: '${w.service}-eventhub-role'
  params: {
    namespaceName: eventHubs.outputs.namespaceName
    eventHubName: w.eventHubName
    principalId: workloadFuncs[i].outputs.principalId
  }
}]

// ---------------------------------------------------------------------------
// Stream Analytics — one job per Event Hub. Each reads its hub and lands
// line-separated JSON in the data lake (Power BI reads these folders directly,
// no Avro decode). Replaces Event Hubs Avro Capture for all three workloads.
// ---------------------------------------------------------------------------

module streamAnalytics './streamanalytics.bicep' = [for w in workloads: {
  name: 'streamanalytics-${w.service}'
  params: {
    jobName: 'asa-${w.service}-${resourceToken}'
    location: location
    tags: tags
    namespaceName: eventHubs.outputs.namespaceName
    eventHubName: w.eventHubName
    consumerGroupName: 'asa-${w.service}'
    dataLakeName: dataLake.outputs.name
    containerName: 'auditlogs'
    outputPrefix: w.outputPrefix
  }
}]

// Grant each Stream Analytics identity write access to the data lake.
module streamAnalyticsDataLakeRole './datalakeRole.bicep' = [for (w, i) in workloads: {
  name: 'asa-datalake-role-${w.service}'
  params: {
    dataLakeName: dataLake.outputs.name
    principalId: streamAnalytics[i].outputs.principalId
  }
}]

output keyVaultName string = keyVault.outputs.name
output dataLakeName string = dataLake.outputs.name
output eventHubNamespaceName string = eventHubs.outputs.namespaceName
output exchangeFunctionUrl string = contains(enabledServices, 'exchange') ? 'https://${workloadFuncs[indexOf(enabledServices, 'exchange')].outputs.defaultHostName}/api/webhook' : ''
output sharepointFunctionUrl string = contains(enabledServices, 'sharepoint') ? 'https://${workloadFuncs[indexOf(enabledServices, 'sharepoint')].outputs.defaultHostName}/api/webhook' : ''
output dlpFunctionUrl string = contains(enabledServices, 'dlp') ? 'https://${workloadFuncs[indexOf(enabledServices, 'dlp')].outputs.defaultHostName}/api/webhook' : ''
output generalFunctionUrl string = contains(enabledServices, 'general') ? 'https://${workloadFuncs[indexOf(enabledServices, 'general')].outputs.defaultHostName}/api/webhook' : ''
output azureadFunctionUrl string = contains(enabledServices, 'azuread') ? 'https://${workloadFuncs[indexOf(enabledServices, 'azuread')].outputs.defaultHostName}/api/webhook' : ''
output entrausersFunctionName string = entrausersFunc.outputs.name
output streamAnalyticsJobNames array = [for (w, i) in workloads: streamAnalytics[i].outputs.jobName]
