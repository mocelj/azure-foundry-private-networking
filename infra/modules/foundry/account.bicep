// Microsoft Foundry account (Microsoft.CognitiveServices/accounts, kind AIServices).
// Inbound: public network access disabled, deny-by-default ACLs, Entra-only auth.
// Outbound: BYO VNet injection or Microsoft-managed VNet for agents (set at creation, immutable afterwards).

param name string
param location string
param tags object

@description('Agent subnet resource ID for BYO VNet injection. Empty = no injection (models only).')
param agentSubnetId string = ''

@description('Managed VNet (preview): inject the agent runtime into a Microsoft-managed network instead of a customer subnet.')
param managedNetwork bool = false

@description('Public network mode (NETWORK_MODE=public, quick demos): accept traffic from public networks. Entra-only auth stays.')
param publicAccess bool = false

@description('Public mode: client IPv4 addresses/CIDRs allowed through the account firewall. Empty = open to the internet (still Entra-only).')
param allowedIps array = []

@description('Trusted Azure services bypass. AzureServices = Foundry Tools, AI Search, Azure ML with MI + RBAC only. None = no bypass.')
@allowed(['AzureServices', 'None'])
param networkAclsBypass string = 'AzureServices'

var ipRules = [for ip in allowedIps: { value: ip }]

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: name
    allowProjectManagement: true
    publicNetworkAccess: publicAccess ? 'Enabled' : 'Disabled'
    disableLocalAuth: true
    networkAcls: {
      // Private: deny everything except private endpoints. Public: allow-list, or Allow when no IPs are given.
      defaultAction: (publicAccess && empty(allowedIps)) ? 'Allow' : 'Deny'
      bypass: networkAclsBypass
      ipRules: publicAccess ? ipRules : []
      virtualNetworkRules: []
    }
    networkInjections: managedNetwork
      ? [
          {
            scenario: 'agent'
            subnetArmId: ''
            useMicrosoftManagedNetwork: true
          }
        ]
      : (empty(agentSubnetId)
          ? null
          : [
              {
                scenario: 'agent'
                subnetArmId: agentSubnetId
                useMicrosoftManagedNetwork: false
              }
            ])
  }
}

output id string = account.id
output name string = account.name
output endpoint string = account.properties.endpoint
output principalId string = account.identity.principalId
