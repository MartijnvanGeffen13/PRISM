targetScope = 'resourceGroup'

@description('Stream Analytics job name.')
param jobName string

@description('Location for the streaming job.')
param location string

@description('Tags applied to resources.')
param tags object

@description('Event Hubs namespace name (input source).')
param namespaceName string

@description('Data lake storage account name (JSON output destination).')
param dataLakeName string

@description('Blob container for JSON output.')
param containerName string = 'auditlogs'

@description('Workloads processed by this job. Each item: { service, eventHubName, outputPrefix }. One Event Hub input and one data lake output folder are created per entry.')
param workloads array

@description('Number of streaming units allocated to the job (shared across all workloads).')
param streamingUnits int = 1

// Azure Event Hubs Data Receiver — lets the job's managed identity read events.
var eventHubsDataReceiverRoleId = 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'

// Combined query: one independent passthrough statement per workload. Streams
// never mix — each Event Hub input lands in its own data lake output/folder.
var query = join(map(workloads, w => 'SELECT * INTO [${w.service}-output] FROM [${w.service}-input]'), ';\n')

resource namespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: namespaceName
}

// Existing per-workload Event Hubs (created by the eventhubs module) — used to
// scope the Data Receiver role assignment for the job identity.
resource eventHubs 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = [for w in workloads: {
  parent: namespace
  name: w.eventHubName
}]

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

// Dedicated consumer group per workload so the job does not contend with other readers.
resource consumerGroups 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = [for (w, i) in workloads: {
  parent: eventHubs[i]
  name: 'asa-${w.service}'
}]

// One Event Hub input per workload (managed identity auth; local SAS auth is
// disabled on the namespace). JSON deserialization.
resource inputs 'Microsoft.StreamAnalytics/streamingjobs/inputs@2021-10-01-preview' = [for (w, i) in workloads: {
  parent: job
  name: '${w.service}-input'
  properties: {
    type: 'Stream'
    datasource: {
      type: 'Microsoft.EventHub/EventHub'
      properties: {
        serviceBusNamespace: namespaceName
        eventHubName: w.eventHubName
        consumerGroupName: 'asa-${w.service}'
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
  dependsOn: [
    consumerGroups
  ]
}]

// One data lake output per workload — line-separated JSON under its own folder,
// authenticated with the job's managed identity (shared key auth is disabled).
resource outputs 'Microsoft.StreamAnalytics/streamingjobs/outputs@2021-10-01-preview' = [for w in workloads: {
  parent: job
  name: '${w.service}-output'
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
        pathPattern: '${w.outputPrefix}/{date}/{time}'
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
}]

// Single transformation with one passthrough statement per workload.
resource transformation 'Microsoft.StreamAnalytics/streamingjobs/transformations@2021-10-01-preview' = {
  parent: job
  name: 'Transformation'
  properties: {
    streamingUnits: streamingUnits
    query: query
  }
  dependsOn: [
    inputs
    outputs
  ]
}

// Allow the job identity to read events from each workload's Event Hub.
resource ehReceiverRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (w, i) in workloads: {
  name: guid(eventHubs[i].id, job.id, eventHubsDataReceiverRoleId)
  scope: eventHubs[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataReceiverRoleId)
    principalId: job.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

output jobName string = job.name
output principalId string = job.identity.principalId
