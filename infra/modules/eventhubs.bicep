targetScope = 'resourceGroup'

@description('Event Hubs namespace name.')
param namespaceName string

@description('Location for the namespace.')
param location string

@description('Tags applied to resources.')
param tags object

@description('Resource id of the subnet that hosts the private endpoint.')
param privateEndpointSubnetId string

@description('Private DNS zone id for Event Hubs (privatelink.servicebus.windows.net).')
param eventHubDnsZoneId string

@description('Optional public IP address allowed through the firewall (e.g. the deployer machine). Empty disables the rule.')
param deployerIpAddress string = ''

var ipRules = empty(deployerIpAddress) ? [] : [
  {
    ipMask: deployerIpAddress
    action: 'Allow'
  }
]

var hubs = [
  { name: 'eh-exchange', prefix: 'exchange' }
  { name: 'eh-sharepoint', prefix: 'sharepoint' }
  { name: 'eh-dlp', prefix: 'dlp' }
]

resource namespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    // Local (SAS) auth is disabled; producers authenticate with Azure AD
    // (managed identity) and the Azure Event Hubs Data Sender role.
    disableLocalAuth: true
    // Public endpoint stays enabled but is firewalled to default-deny. The
    // webhook functions reach it over a private endpoint; Stream Analytics
    // reaches it as a trusted service (MSI). Disabling public access entirely
    // would block Stream Analytics, which cannot join the VNet.
    publicNetworkAccess: 'Enabled'
  }
}

resource networkRuleSet 'Microsoft.EventHub/namespaces/networkRuleSets@2024-01-01' = {
  parent: namespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Enabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: true
    ipRules: ipRules
    virtualNetworkRules: []
  }
}

// Avro Capture is disabled. Each hub is drained by a dedicated Stream Analytics
// job that writes line-separated JSON to the data lake instead.
resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = [for h in hubs: {
  parent: namespace
  name: h.name
  properties: {
    partitionCount: 4
    messageRetentionInDays: 1
  }
}]

module namespacePrivateEndpoint './privateEndpoint.bicep' = {
  name: '${namespaceName}-pe'
  params: {
    name: 'pe-${namespaceName}'
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    serviceId: namespace.id
    groupId: 'namespace'
    dnsZoneId: eventHubDnsZoneId
  }
}

output namespaceName string = namespace.name
