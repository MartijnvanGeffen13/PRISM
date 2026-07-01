targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment — used to name the resource group and derive a unique suffix.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Entra (Azure AD) tenant id for the shared app registration. Supply via: azd env set ENTRA_TENANT_ID <guid>.')
param tenantId string

@description('Entra (Azure AD) application (client) id for the shared app registration. Supply via: azd env set ENTRA_CLIENT_ID <guid>.')
param clientId string

@secure()
@description('Entra app client secret. Supply via: azd env set ENTRA_CLIENT_SECRET <value>. Never commit this value.')
param entraClientSecret string

@description('Optional public IP address allowed through resource firewalls so you can deploy from outside the VNet (e.g. your dev machine). Supply via: azd env set DEPLOYER_IP_ADDRESS <ip>. Leave empty for deny-all.')
param deployerIpAddress string = ''

@description('Client public IP addresses allowed to read the data lake over its public endpoint (e.g. Power BI report authors / gateway). Empty by default; supply via: azd env set DATA_LAKE_ALLOWED_IPS.')
param dataLakeAllowedIpAddresses array = []

@description('Entra user/group object ids granted Storage Blob Data Contributor on the data lake (e.g. report authors using Storage Explorer / Power BI Desktop). Empty by default.')
param dataLakeUserPrincipalIds array = []

var resourceToken = take(uniqueString(subscription().id, environmentName, location), 6)
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources './modules/resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    tenantId: tenantId
    clientId: clientId
    entraClientSecret: entraClientSecret
    deployerIpAddress: deployerIpAddress
    dataLakeAllowedIpAddresses: dataLakeAllowedIpAddresses
    dataLakeUserPrincipalIds: dataLakeUserPrincipalIds
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_KEY_VAULT_NAME string = resources.outputs.keyVaultName
output DATA_LAKE_ACCOUNT_NAME string = resources.outputs.dataLakeName
output EVENT_HUB_NAMESPACE string = resources.outputs.eventHubNamespaceName
output EXCHANGE_FUNCTION_URL string = resources.outputs.exchangeFunctionUrl
output SHAREPOINT_FUNCTION_URL string = resources.outputs.sharepointFunctionUrl
output DLP_FUNCTION_URL string = resources.outputs.dlpFunctionUrl
output ENTRAUSERS_FUNCTION_NAME string = resources.outputs.entrausersFunctionName
output STREAM_ANALYTICS_JOB_NAMES array = resources.outputs.streamAnalyticsJobNames
