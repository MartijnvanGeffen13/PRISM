targetScope = 'resourceGroup'

@description('Stream Analytics job name.')
param jobName string

@description('Location for the streaming job.')
param location string

@description('Tags applied to resources.')
param tags object

@description('Event Hubs namespace name (input source).')
param namespaceName string

@description('Event Hub name to read from.')
param eventHubName string

@description('Dedicated consumer group name created for this job.')
param consumerGroupName string = 'asa-exchange'

@description('Data lake storage account name (JSON output destination).')
param dataLakeName string

@description('Blob container for JSON output.')
param containerName string = 'auditlogs'

@description('Prefix (folder) under the container where JSON files are written.')
param outputPrefix string = 'exchange-json'

@description('Number of streaming units allocated to the job.')
param streamingUnits int = 1

// Azure Event Hubs Data Receiver — lets the job's managed identity read events.
var eventHubsDataReceiverRoleId = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'

resource namespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: namespaceName

  resource eventHub 'eventhubs@2024-01-01' existing = {
    name: eventHubName
  }
}

// Dedicated consumer group so the job does not contend with other readers.
resource consumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: namespace::eventHub
  name: consumerGroupName
}

resource job 'Microsoft.StreamAnalytics/streamingjobs@2021-10-01-preview' = {
  name: jobName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Standard'
    }
    jobType: 'Cloud'
    outputErrorPolicy: 'Stop'
    eventsOutOfOrderPolicy: 'Adjust'
    eventsOutOfOrderMaxDelayInSeconds: 0
    eventsLateArrivalMaxDelayInSeconds: 5
    dataLocale: 'en-US'
    compatibilityLevel: '1.2'
  }
}

// Input — the Exchange Event Hub, authenticated with the job's managed identity
// (local SAS auth is disabled on the namespace). JSON deserialization.
resource ehInput 'Microsoft.StreamAnalytics/streamingjobs/inputs@2021-10-01-preview' = {
  parent: job
  name: 'exchange-input'
  properties: {
    type: 'Stream'
    datasource: {
      type: 'Microsoft.EventHub/EventHub'
      properties: {
        serviceBusNamespace: namespaceName
        eventHubName: eventHubName
        consumerGroupName: consumerGroup.name
        authenticationMode: 'Msi'
      }
    }
    serialization: {
      type: 'Json'
      properties: {
        encoding: 'UTF8'
      }
    }
  }
}

// Output — line-separated JSON written to the data lake, authenticated with the
// job's managed identity (shared key auth is disabled on the storage account).
resource adlsOutput 'Microsoft.StreamAnalytics/streamingjobs/outputs@2021-10-01-preview' = {
  parent: job
  name: 'datalake-output'
  properties: {
    datasource: {
      type: 'Microsoft.Storage/Blob'
      properties: {
        storageAccounts: [
          {
            accountName: dataLakeName
          }
        ]
        container: containerName
        pathPattern: '${outputPrefix}/{date}/{time}'
        dateFormat: 'yyyy/MM/dd'
        timeFormat: 'HH'
        authenticationMode: 'Msi'
      }
    }
    serialization: {
      type: 'Json'
      properties: {
        encoding: 'UTF8'
        format: 'LineSeparated'
      }
    }
  }
}

// Passthrough query — every audit record from the hub becomes a JSON line.
resource transformation 'Microsoft.StreamAnalytics/streamingjobs/transformations@2021-10-01-preview' = {
  parent: job
  name: 'Transformation'
  properties: {
    streamingUnits: streamingUnits
    query: 'SELECT * INTO [datalake-output] FROM [exchange-input]'
  }
  dependsOn: [
    ehInput
    adlsOutput
  ]
}

// Allow the job identity to read events from the Exchange Event Hub.
resource ehReceiverRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(namespace::eventHub.id, job.id, eventHubsDataReceiverRoleId)
  scope: namespace::eventHub
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output jobName string = job.name
output principalId string = job.identity.principalId
