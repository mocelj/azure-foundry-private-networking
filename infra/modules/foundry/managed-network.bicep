// Foundry managed virtual network (OUTBOUND_NETWORK_MODE=managedVnet, PREVIEW).
// The agent runtime runs in a Microsoft-managed VNet in the Microsoft tenant; isolation mode
// AllowOnlyApprovedOutbound. No FQDN rules -> no managed Azure Firewall is created (no firewall cost).
// Irreversible per account (can't be disabled; no switch to/from BYO VNet).
// Learn: https://learn.microsoft.com/azure/foundry/how-to/managed-virtual-network
//
// Order (Learn): account with networkInjections[useMicrosoftManagedNetwork=true] -> account MI gets
// "Azure AI Enterprise Network Connection Approver" (auto-approves managed private endpoints on the
// targets in this resource group) -> managedNetworks/default -> outbound rules.
// Required rules (Cosmos DB, Storage, agent Search, AzureActiveDirectory tag) are created by the
// service; this module adds private endpoint rules for the account itself (required by hosted agents)
// and optional targets (knowledge search, AMPLS).

param accountName string
param accountPrincipalId string

@description('Additional managed private endpoint outbound rules: [{ name, resourceId, subresource }].')
param privateEndpointRules array = []

@description('Preview API version of accounts/managedNetworks (no GA version is registered).')
param apiVersion string = '2026-09-15-preview'

var networkConnectionApprover = 'b556d68e-0be0-4f35-a333-ad7ee1ce17ea'

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource approver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, accountPrincipalId, networkConnectionApprover)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkConnectionApprover)
    principalId: accountPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Foundry managed VNet: account MI creates and approves managed private endpoints to targets in this resource group'
  }
}

#disable-next-line BCP081
resource managedNetwork 'Microsoft.CognitiveServices/accounts/managedNetworks@2026-09-15-preview' = {
  parent: account
  name: 'default'
  properties: {
    managedNetwork: {
      isolationMode: 'AllowOnlyApprovedOutbound'
      firewallSku: 'Basic'
    }
  }
  dependsOn: [approver]
}

#disable-next-line BCP081
@batchSize(1)
resource rules 'Microsoft.CognitiveServices/accounts/managedNetworks/outboundRules@2026-09-15-preview' = [
  for r in privateEndpointRules: {
    parent: managedNetwork
    name: r.name
    properties: {
      type: 'PrivateEndpoint'
      category: 'UserDefined'
      destination: {
        serviceResourceId: r.resourceId
        subresourceTarget: r.subresource
      }
    }
  }
]

output isolationMode string = 'AllowOnlyApprovedOutbound'
output apiVersion string = apiVersion
