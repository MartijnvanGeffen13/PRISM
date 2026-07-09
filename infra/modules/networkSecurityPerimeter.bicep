targetScope = 'resourceGroup'

@description('Network Security Perimeter name.')
param name string

@description('Location for the perimeter and its profile/rules.')
param location string

@description('Tags applied to the perimeter.')
param tags object

@description('Resource id of the Data Lake storage account to associate with the perimeter.')
param dataLakeId string

@description('Subscription id whose in-subscription Azure services (e.g. the Stream Analytics job authenticating with its managed identity) are allowed inbound to the data lake. Defaults to the current subscription.')
param allowedSubscriptionId string = subscription().subscriptionId

@description('Association access mode. Enforced denies all public traffic except the rules below. Use Learning first to observe traffic without blocking, then switch to Enforced.')
@allowed([
  'Learning'
  'Enforced'
  'Audit'
])
param accessMode string = 'Enforced'

// NOTE: The inbound IP access rule (report authors / Power BI Desktop) is NOT
// declared here. The NSP resource provider rejects an IP-based rule and a
// subscription-based rule being written in the same ARM deployment with
// "Address Prefixes can't be overlapping", even though a standalone PUT of the
// IP rule succeeds. The IP rule is therefore managed by the azd postprovision
// hook (scripts/set-datalake-nsp-ip-rule.ps1) from DATA_LAKE_ALLOWED_IPS.

resource perimeter 'Microsoft.Network/networkSecurityPerimeters@2023-08-01-preview' = {
  name: name
  location: location
  tags: tags
}

resource profile 'Microsoft.Network/networkSecurityPerimeters/profiles@2023-08-01-preview' = {
  parent: perimeter
  name: 'prism-profile'
  location: location
}

// Inbound rule so in-subscription Azure services reach the lake. The Standard
// Stream Analytics job cannot join the VNet and authenticates with its managed
// identity over the public endpoint; a subscription-based rule authorises it
// (subscription rules use Azure AD auth, not SAS).
resource subscriptionInboundRule 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2023-08-01-preview' = {
  parent: profile
  name: 'allow-inbound-subscription'
  location: location
  properties: {
    direction: 'Inbound'
    subscriptions: [
      {
        id: '/subscriptions/${allowedSubscriptionId}'
      }
    ]
  }
}

// Associate the Data Lake with the perimeter. In Enforced mode all public
// traffic is denied except the inbound rules and private endpoint traffic
// (which is always allowed without an explicit rule).
resource dataLakeAssociation 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2023-08-01-preview' = {
  parent: perimeter
  name: 'assoc-datalake'
  location: location
  properties: {
    accessMode: accessMode
    privateLinkResource: {
      id: dataLakeId
    }
    profile: {
      id: profile.id
    }
  }
  dependsOn: [
    subscriptionInboundRule
  ]
}

output perimeterId string = perimeter.id
output perimeterName string = perimeter.name
