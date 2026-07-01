targetScope = 'resourceGroup'

@description('Event Hubs namespace name.')
param namespaceName string

@description('Event Hub name to grant send access on.')
param eventHubName string

@description('Principal id (managed identity) to grant Azure Event Hubs Data Sender.')
param principalId string

// Azure Event Hubs Data Sender
var eventHubsDataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'

resource namespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: namespaceName

  resource eventHub 'eventhubs@2024-01-01' existing = {
    name: eventHubName
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(namespace::eventHub.id, principalId, eventHubsDataSenderRoleId)
  scope: namespace::eventHub
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataSenderRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
