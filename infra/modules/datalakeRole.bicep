targetScope = 'resourceGroup'

@description('Data lake storage account name to grant access on.')
param dataLakeName string

@description('Principal id to grant Storage Blob Data Contributor.')
param principalId string

@description('Type of the principal being granted access (ServicePrincipal for managed identities, User for interactive sign-ins such as Storage Explorer).')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'ServicePrincipal'

// Storage Blob Data Contributor
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource dataLake 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: dataLakeName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataLake.id, principalId, storageBlobDataContributorRoleId)
  scope: dataLake
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: principalId
    principalType: principalType
  }
}
