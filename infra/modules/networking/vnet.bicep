// Spoke / standalone VNet with segmented subnets and least-privilege NSGs.
// All workload subnets are private (defaultOutboundAccess=false); egress is explicit (NAT or UDR).

@description('VNet name.')
param name string
param location string
param tags object

@description('VNet address space.')
param addressPrefixes array

@description('Optional custom DNS servers (e.g. hub DNS resolver inbound endpoint). Empty = Azure-provided DNS.')
param dnsServers array = []

@description('Private endpoint subnet prefix (always created).')
param peSubnetPrefix string

@description('Agent subnet prefix (delegated to Microsoft.App/environments). Empty = not created.')
param agentSubnetPrefix string = ''

@description('Management (jumpbox) subnet prefix. Empty = not created.')
param managementSubnetPrefix string = ''

@description('AzureBastionSubnet prefix. Empty = not created.')
param bastionSubnetPrefix string = ''

@description('Optional application subnet prefix. Empty = not created.')
param appSubnetPrefix string = ''

@description('TCP port private apps in snet-app listen on (reachable from the VNet / peered hub only).')
param appPort int = 443

@description('Optional integration subnet prefix. Empty = not created.')
param integrationSubnetPrefix string = ''

@description('Source prefixes allowed to RDP to the management subnet (Bastion subnet or hub Bastion).')
param adminSourcePrefixes array = []

@description('Allow outbound HTTP/HTTPS (and KMS) to Internet from the management subnet. Required for Entra sign-in and the Foundry portal UI. Egress path is NAT (standalone) or hub firewall (UDR).')
param managementInternetEgress bool = false

@description('NAT gateway resource ID to attach to management and agent subnets. Empty = none.')
param natGatewayId string = ''

@description('Route table resource ID to attach to workload subnets (hub firewall). Empty = none.')
param routeTableId string = ''

var subnetNames = {
  pe: 'snet-private-endpoints'
  agent: 'snet-agent'
  mgmt: 'snet-management'
  bastion: 'AzureBastionSubnet'
  app: 'snet-app'
  integration: 'snet-integration'
}

var natRef = empty(natGatewayId) ? null : { id: natGatewayId }
var rtRef = empty(routeTableId) ? null : { id: routeTableId }

// ---------------------------------------------------------------------------
// NSG rule sets
// ---------------------------------------------------------------------------
var denyAllInbound = {
  name: 'DenyAllInbound'
  properties: {
    priority: 4096
    direction: 'Inbound'
    access: 'Deny'
    protocol: '*'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
  }
}

var denyInternetOutbound = {
  name: 'DenyInternetOutbound'
  properties: {
    priority: 4000
    direction: 'Outbound'
    access: 'Deny'
    protocol: '*'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: 'Internet'
    destinationPortRange: '*'
  }
}

var peRules = [
  {
    name: 'AllowHttpsFromVirtualNetwork'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: peSubnetPrefix
      destinationPortRange: '443'
    }
  }
  denyAllInbound
  denyInternetOutbound
]

// Outbound rules required by the injected Container Apps environment + Entra ID.
// https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks#limitations
var agentOutboundTags = [
  'AzureActiveDirectory'
  'AzureMonitor'
  'MicrosoftContainerRegistry'
  'AzureFrontDoor.FirstParty'
]
var agentTagRules = [
  for (tag, i) in agentOutboundTags: {
    name: 'AllowHttps-${replace(tag, '.', '-')}'
    properties: {
      priority: 110 + (i * 10)
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: agentSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: tag
      destinationPortRange: '443'
    }
  }
]

var agentRules = concat(
  [
    {
      name: 'AllowVirtualNetworkOutbound'
      properties: {
        priority: 100
        direction: 'Outbound'
        access: 'Allow'
        protocol: '*'
        sourceAddressPrefix: agentSubnetPrefix
        sourcePortRange: '*'
        destinationAddressPrefix: 'VirtualNetwork'
        destinationPortRange: '*'
      }
    }
  ],
  agentTagRules,
  [
    {
      name: 'AllowAzureLoadBalancerInbound'
      properties: {
        priority: 100
        direction: 'Inbound'
        access: 'Allow'
        protocol: '*'
        sourceAddressPrefix: 'AzureLoadBalancer'
        sourcePortRange: '*'
        destinationAddressPrefix: agentSubnetPrefix
        destinationPortRange: '*'
      }
    }
    {
      name: 'AllowVirtualNetworkInbound'
      properties: {
        priority: 110
        direction: 'Inbound'
        access: 'Allow'
        protocol: '*'
        sourceAddressPrefix: 'VirtualNetwork'
        sourcePortRange: '*'
        destinationAddressPrefix: agentSubnetPrefix
        destinationPortRange: '*'
      }
    }
    denyAllInbound
    denyInternetOutbound
  ]
)

var mgmtRdpRules = empty(adminSourcePrefixes)
  ? []
  : [
      {
        name: 'AllowRdpFromAdminSources'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefixes: adminSourcePrefixes
          sourcePortRange: '*'
          destinationAddressPrefix: managementSubnetPrefix
          destinationPortRange: '3389'
        }
      }
    ]

var mgmtEgressRules = managementInternetEgress
  ? [
      {
        name: 'AllowWebOutboundToInternet'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: managementSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: ['443', '80']
        }
      }
      {
        name: 'AllowWindowsKmsActivation'
        properties: {
          priority: 210
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: managementSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '1688'
        }
      }
    ]
  : []

var mgmtRules = concat(
  mgmtRdpRules,
  [
    {
      name: 'AllowHttpsToPrivateEndpoints'
      properties: {
        priority: 100
        direction: 'Outbound'
        access: 'Allow'
        protocol: 'Tcp'
        sourceAddressPrefix: managementSubnetPrefix
        sourcePortRange: '*'
        destinationAddressPrefix: peSubnetPrefix
        destinationPortRange: '443'
      }
    }
  ],
  empty(appSubnetPrefix)
    ? []
    : [
        {
          name: 'AllowAppPortToAppSubnet'
          properties: {
            priority: 110
            direction: 'Outbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: managementSubnetPrefix
            sourcePortRange: '*'
            destinationAddressPrefix: appSubnetPrefix
            destinationPortRange: string(appPort)
          }
        }
      ],
  mgmtEgressRules,
  [
    denyAllInbound
    denyInternetOutbound
    {
      // Prevent lateral movement from the jumpbox to other subnets (only PEs allowed above).
      name: 'DenyVirtualNetworkOutbound'
      properties: {
        priority: 4010
        direction: 'Outbound'
        access: 'Deny'
        protocol: '*'
        sourceAddressPrefix: '*'
        sourcePortRange: '*'
        destinationAddressPrefix: 'VirtualNetwork'
        destinationPortRange: '*'
      }
    }
  ]
)

// Required Azure Bastion NSG rules: https://learn.microsoft.com/azure/bastion/bastion-nsg
var bastionRules = [
  {
    name: 'AllowHttpsInbound'
    properties: {
      priority: 120
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowGatewayManagerInbound'
    properties: {
      priority: 130
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'GatewayManager'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowAzureLoadBalancerInbound'
    properties: {
      priority: 140
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowBastionHostCommunicationInbound'
    properties: {
      priority: 150
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: ['8080', '5701']
    }
  }
  denyAllInbound
  {
    // Platform-mandated rule (Bastion compliance check requires destination VirtualNetwork, 22+3389).
    // Reachability is enforced by the target subnet NSGs: only snet-management allows RDP, and only
    // from AzureBastionSubnet; all other subnets deny inbound except HTTPS from the VNet.
    name: 'AllowSshRdpOutbound'
    properties: {
      priority: 100
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: ['22', '3389']
    }
  }
  {
    name: 'AllowAzureCloudOutbound'
    properties: {
      priority: 110
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureCloud'
      destinationPortRange: '443'
    }
  }
  {
    name: 'AllowBastionCommunicationOutbound'
    properties: {
      priority: 120
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: ['8080', '5701']
    }
  }
  {
    name: 'AllowGetSessionInformationOutbound'
    properties: {
      priority: 130
      direction: 'Outbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '80'
    }
  }
  {
    name: 'DenyAllOutbound'
    properties: {
      priority: 4096
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
]

func workloadRules(prefix string, port string) array => [
  {
    name: 'AllowAppPortFromVirtualNetwork'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: prefix
      destinationPortRange: port
    }
  }
  {
    name: 'DenyAllInbound'
    properties: {
      priority: 4096
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'DenyInternetOutbound'
    properties: {
      priority: 4000
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '*'
    }
  }
]

// ---------------------------------------------------------------------------
// NSGs
// ---------------------------------------------------------------------------
resource nsgPe 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: 'nsg-${name}-pe'
  location: location
  tags: tags
  properties: { securityRules: peRules }
}

resource nsgAgent 'Microsoft.Network/networkSecurityGroups@2025-05-01' = if (!empty(agentSubnetPrefix)) {
  name: 'nsg-${name}-agent'
  location: location
  tags: tags
  properties: { securityRules: agentRules }
}

resource nsgMgmt 'Microsoft.Network/networkSecurityGroups@2025-05-01' = if (!empty(managementSubnetPrefix)) {
  name: 'nsg-${name}-mgmt'
  location: location
  tags: tags
  properties: { securityRules: mgmtRules }
}

resource nsgBastion 'Microsoft.Network/networkSecurityGroups@2025-05-01' = if (!empty(bastionSubnetPrefix)) {
  name: 'nsg-${name}-bastion'
  location: location
  tags: tags
  properties: { securityRules: bastionRules }
}

resource nsgApp 'Microsoft.Network/networkSecurityGroups@2025-05-01' = if (!empty(appSubnetPrefix)) {
  name: 'nsg-${name}-app'
  location: location
  tags: tags
  properties: { securityRules: workloadRules(appSubnetPrefix, string(appPort)) }
}

resource nsgIntegration 'Microsoft.Network/networkSecurityGroups@2025-05-01' = if (!empty(integrationSubnetPrefix)) {
  name: 'nsg-${name}-integration'
  location: location
  tags: tags
  properties: { securityRules: workloadRules(integrationSubnetPrefix, '443') }
}

// ---------------------------------------------------------------------------
// Subnets
// ---------------------------------------------------------------------------
var peSubnet = [
  {
    name: subnetNames.pe
    properties: {
      addressPrefix: peSubnetPrefix
      networkSecurityGroup: { id: nsgPe.id }
      privateEndpointNetworkPolicies: 'Enabled'
      defaultOutboundAccess: false
    }
  }
]

var agentSubnet = empty(agentSubnetPrefix)
  ? []
  : [
      {
        name: subnetNames.agent
        properties: {
          addressPrefix: agentSubnetPrefix
          networkSecurityGroup: { id: nsgAgent.id }
          natGateway: natRef
          routeTable: rtRef
          defaultOutboundAccess: false
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]

var mgmtSubnet = empty(managementSubnetPrefix)
  ? []
  : [
      {
        name: subnetNames.mgmt
        properties: {
          addressPrefix: managementSubnetPrefix
          networkSecurityGroup: { id: nsgMgmt.id }
          natGateway: natRef
          routeTable: rtRef
          defaultOutboundAccess: false
        }
      }
    ]

var bastionSubnet = empty(bastionSubnetPrefix)
  ? []
  : [
      {
        name: subnetNames.bastion
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: { id: nsgBastion.id }
        }
      }
    ]

var appSubnet = empty(appSubnetPrefix)
  ? []
  : [
      {
        name: subnetNames.app
        properties: {
          addressPrefix: appSubnetPrefix
          networkSecurityGroup: { id: nsgApp.id }
          routeTable: rtRef
          defaultOutboundAccess: false
        }
      }
    ]

var integrationSubnet = empty(integrationSubnetPrefix)
  ? []
  : [
      {
        name: subnetNames.integration
        properties: {
          addressPrefix: integrationSubnetPrefix
          networkSecurityGroup: { id: nsgIntegration.id }
          routeTable: rtRef
          defaultOutboundAccess: false
        }
      }
    ]

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: addressPrefixes }
    dhcpOptions: empty(dnsServers) ? null : { dnsServers: dnsServers }
    subnets: concat(peSubnet, agentSubnet, mgmtSubnet, bastionSubnet, appSubnet, integrationSubnet)
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output peSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetNames.pe)
output agentSubnetId string = empty(agentSubnetPrefix) ? '' : resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetNames.agent)
output managementSubnetId string = empty(managementSubnetPrefix) ? '' : resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetNames.mgmt)
output bastionSubnetId string = empty(bastionSubnetPrefix) ? '' : resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetNames.bastion)
output appSubnetId string = empty(appSubnetPrefix) ? '' : resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetNames.app)
output integrationSubnetId string = empty(integrationSubnetPrefix) ? '' : resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetNames.integration)
