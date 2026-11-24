// TEST FIXTURE ONLY — sample hub for testing hub-spoke without a production hub. Not part of the product.
// Deploy:  az deployment group create -g <rg> -f tests/integration/sample-hub/sample-hub.bicep -p adminPrincipalId=<objectId>
// Contents:
//   - hub VNet, Azure Firewall Basic (documented agent egress allow-list + web egress for the
//     corporate workstation subnet only), logs to Log Analytics
//   - DNS Private Resolver inbound endpoint + 6 central private DNS zones linked to the hub
//   - Azure Bastion (Standard) = the customer's existing admin/remote access
//   - Windows "corporate workstation" VM: no public IP, Entra ID sign-in, managed identity,
//     egress via firewall (UDR). Used for interactive Foundry portal access and automated probes.

param location string = resourceGroup().location
param hubPrefix string = '10.0.0.0/16'
param spokePrefix string = '10.81.0.0/16'

@description('Object ID of the user/group allowed to sign in to the workstation (Virtual Machine User Login).')
param adminPrincipalId string

@allowed(['User', 'Group'])
param adminPrincipalType string = 'User'

@description('Workstation VM size (test only). Choose a size with capacity in the region.')
param clientVmSize string = 'Standard_D2s_v5'

@secure()
param clientAdminPassword string = '${toUpper(take(newGuid(), 8))}#${newGuid()}'

var zones = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.documents.azure.com'
  'privatelink.search.windows.net'
]
var tags = { purpose: 'sample-hub-test-fixture' }
var clientsPrefix = cidrSubnet(hubPrefix, 24, 3) // 10.0.3.0/24
var bastionPrefix = cidrSubnet(hubPrefix, 26, 16) // 10.0.4.0/26
var fwPrivateIp = cidrHost(cidrSubnet(hubPrefix, 26, 4), 3) // 10.0.1.4 (first usable in AzureFirewallSubnet)

resource law 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: 'log-sample-hub-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource clientNsg 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: 'nsg-sample-hub-clients'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromHubBastion'
        properties: { priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourceAddressPrefix: bastionPrefix, sourcePortRange: '*', destinationAddressPrefix: clientsPrefix, destinationPortRange: '3389' }
      }
      {
        name: 'DenyAllInbound'
        properties: { priority: 4096, direction: 'Inbound', access: 'Deny', protocol: '*', sourceAddressPrefix: '*', sourcePortRange: '*', destinationAddressPrefix: '*', destinationPortRange: '*' }
      }
    ]
  }
}

resource clientRt 'Microsoft.Network/routeTables@2025-05-01' = {
  name: 'rt-sample-hub-clients-to-fw'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [{ name: 'default-to-firewall', properties: { addressPrefix: '0.0.0.0/0', nextHopType: 'VirtualAppliance', nextHopIpAddress: fwPrivateIp } }]
  }
}

resource hub 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: 'vnet-sample-hub'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [hubPrefix] }
    subnets: [
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: cidrSubnet(hubPrefix, 26, 4) } }
      { name: 'AzureFirewallManagementSubnet', properties: { addressPrefix: cidrSubnet(hubPrefix, 26, 5) } }
      {
        name: 'snet-dns-inbound'
        properties: {
          addressPrefix: cidrSubnet(hubPrefix, 28, 32)
          defaultOutboundAccess: false
          delegations: [{ name: 'dnsResolvers', properties: { serviceName: 'Microsoft.Network/dnsResolvers' } }]
        }
      }
      {
        name: 'snet-clients'
        properties: {
          addressPrefix: clientsPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: { id: clientNsg.id }
          routeTable: { id: clientRt.id }
        }
      }
      { name: 'AzureBastionSubnet', properties: { addressPrefix: bastionPrefix } }
    ]
  }
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = [for z in zones: { name: z, location: 'global', tags: tags }]

resource zoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (z, i) in zones: {
    parent: zone[i]
    name: 'link-hub'
    location: 'global'
    properties: { registrationEnabled: false, virtualNetwork: { id: hub.id } }
  }
]

resource resolver 'Microsoft.Network/dnsResolvers@2025-05-01' = {
  name: 'dnspr-sample-hub'
  location: location
  tags: tags
  properties: { virtualNetwork: { id: hub.id } }
}

resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2025-05-01' = {
  parent: resolver
  name: 'inbound'
  location: location
  properties: {
    ipConfigurations: [{ privateIpAllocationMethod: 'Dynamic', subnet: { id: '${hub.id}/subnets/snet-dns-inbound' } }]
  }
}

resource fwPip 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: 'pip-fw-sample-hub'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource fwMgmtPip 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: 'pip-fwmgmt-sample-hub'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource policy 'Microsoft.Network/firewallPolicies@2025-05-01' = {
  name: 'afwp-sample-hub'
  location: location
  tags: tags
  properties: { sku: { tier: 'Basic' } }
}

resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-05-01' = {
  parent: policy
  name: 'foundry-agent-egress'
  properties: {
    priority: 200
    ruleCollections: [
      {
        // Documented allow-list for the BYO VNet agent runtime (docs/hub-integration.md section 3).
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'net-service-tags'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'agent-platform-tags'
            ipProtocols: ['TCP']
            sourceAddresses: [spokePrefix]
            destinationAddresses: ['AzureActiveDirectory', 'AzureMonitor', 'MicrosoftContainerRegistry', 'AzureFrontDoor.FirstParty']
            destinationPorts: ['443']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'app-identity-fqdns'
        priority: 300
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'entra-and-managed-identity'
            sourceAddresses: [spokePrefix]
            protocols: [{ protocolType: 'Https', port: 443 }]
            #disable-next-line no-hardcoded-env-urls
            targetFqdns: ['login.microsoftonline.com', '*.login.microsoftonline.com', '*.login.microsoft.com', '*.identity.azure.net']
          }
        ]
      }
      {
        // Sample corporate web proxy: the workstation subnet (not the spoke) may browse the web
        // (Entra sign-in, Azure / Foundry portal UI, Windows activation).
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'workstation-web'
        priority: 400
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'workstation-https-http'
            sourceAddresses: [clientsPrefix]
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
            targetFqdns: ['*']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'workstation-kms'
        priority: 410
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'workstation-kms'
            ipProtocols: ['TCP']
            sourceAddresses: [clientsPrefix]
            destinationAddresses: ['*']
            destinationPorts: ['1688']
          }
        ]
      }
    ]
  }
}

resource fw 'Microsoft.Network/azureFirewalls@2025-05-01' = {
  name: 'afw-sample-hub'
  location: location
  tags: tags
  properties: {
    sku: { name: 'AZFW_VNet', tier: 'Basic' }
    firewallPolicy: { id: policy.id }
    ipConfigurations: [
      { name: 'ipconfig', properties: { subnet: { id: '${hub.id}/subnets/AzureFirewallSubnet' }, publicIPAddress: { id: fwPip.id } } }
    ]
    managementIpConfiguration: {
      name: 'mgmt'
      properties: { subnet: { id: '${hub.id}/subnets/AzureFirewallManagementSubnet' }, publicIPAddress: { id: fwMgmtPip.id } }
    }
  }
  dependsOn: [rules]
}

resource fwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag'
  scope: fw
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

resource basPip 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: 'pip-bas-sample-hub'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-05-01' = {
  name: 'bas-sample-hub'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    ipConfigurations: [
      { name: 'ipconfig', properties: { subnet: { id: '${hub.id}/subnets/AzureBastionSubnet' }, publicIPAddress: { id: basPip.id } } }
    ]
  }
}

resource clientNic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: 'nic-vm-hub-workstation'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [{ name: 'ipconfig1', properties: { subnet: { id: '${hub.id}/subnets/snet-clients' }, privateIPAllocationMethod: 'Dynamic' } }]
  }
}

resource client 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: 'vm-hub-workstation'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: clientVmSize }
    securityProfile: { securityType: 'TrustedLaunch', uefiSettings: { secureBootEnabled: true, vTpmEnabled: true } }
    osProfile: {
      computerName: 'hubworkstation'
      #disable-next-line adminusername-should-not-be-literal
      adminUsername: 'azlocaladmin'
      adminPassword: clientAdminPassword
      windowsConfiguration: { enableAutomaticUpdates: true, provisionVMAgent: true }
    }
    storageProfile: {
      imageReference: { publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2025-datacenter-azure-edition', version: 'latest' }
      osDisk: { createOption: 'FromImage', deleteOption: 'Delete', managedDisk: { storageAccountType: 'StandardSSD_LRS' } }
    }
    networkProfile: { networkInterfaces: [{ id: clientNic.id, properties: { deleteOption: 'Delete' } }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
  dependsOn: [fw] // egress (Entra) must exist before the AAD login extension runs
}

resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = {
  parent: client
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
  }
}

resource userLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(client.id, adminPrincipalId, 'fb879df8-f326-4884-b1cf-06f3ad86be52')
  scope: client
  properties: {
    principalId: adminPrincipalId
    principalType: adminPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')
    description: 'Sample hub (test fixture): Entra sign-in to the workstation'
  }
}

// Reader on the workstation VM, its NIC and the hub Bastion: required by Azure Bastion to connect (Bastion FAQ).
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
resource vmReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(client.id, adminPrincipalId, readerRoleId)
  scope: client
  properties: {
    principalId: adminPrincipalId
    principalType: adminPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    description: 'Sample hub (test fixture):  Bastion connection requires Reader on the workstation VM'
  }
}
resource nicReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(clientNic.id, adminPrincipalId, readerRoleId)
  scope: clientNic
  properties: {
    principalId: adminPrincipalId
    principalType: adminPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    description: 'Sample hub (test fixture):  Bastion connection requires Reader on the workstation NIC'
  }
}
resource bastionReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bastion.id, adminPrincipalId, readerRoleId)
  scope: bastion
  properties: {
    principalId: adminPrincipalId
    principalType: adminPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    description: 'Sample hub (test fixture):  Bastion connection requires Reader on the hub Bastion'
  }
}

output hubVnetId string = hub.id
output firewallPrivateIp string = fw.properties.ipConfigurations[0].properties.privateIPAddress
output resolverInboundIp string = inbound.properties.ipConfigurations[0].privateIpAddress
output zoneIdsJson string = string(toObject(zones, z => z, z => resourceId('Microsoft.Network/privateDnsZones', z)))
output bastionSubnetPrefix string = bastionPrefix
output clientVmName string = client.name
output clientVmId string = client.id
output clientPrincipalId string = client.identity.principalId
output firewallWorkspaceId string = law.id
