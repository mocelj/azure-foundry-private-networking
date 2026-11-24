// TEST-ONLY add-on to the hub fixture: a central Azure Monitor Private Link Scope, as the
// platform/network team would own it. Deployed into the hub resource group after sample-hub.bicep:
//   az deployment group create -g rg-<prefix>-sample-hub -f tests/integration/sample-hub/sample-hub-ampls.bicep
// One AMPLS per DNS: spokes add their workspace / App Insights as scoped resources
// (EXISTING_AMPLS_ID) and never create their own private endpoint or DNS records.

param location string = resourceGroup().location
param hubVnetName string = 'vnet-sample-hub'
param peSubnetPrefix string = '10.0.5.0/24'

var tags = { purpose: 'sample-hub-test-fixture' }
var zones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}' // already created by sample-hub.bicep
]

resource hub 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: hubVnetName
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' = {
  parent: hub
  name: 'snet-hub-pe'
  properties: {
    addressPrefix: peSubnetPrefix
    defaultOutboundAccess: false
    privateEndpointNetworkPolicies: 'Enabled'
  }
}

resource newZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for z in take(zones, 4): { name: z, location: 'global', tags: tags }
]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (z, i) in take(zones, 4): {
    parent: newZones[i]
    name: 'link-hub'
    location: 'global'
    properties: { registrationEnabled: false, virtualNetwork: { id: hub.id } }
  }
]

// Open access modes, typical for a shared central scope: resources that disable their own public
// access are reachable only through this private endpoint; other workloads keep working.
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: 'ampls-sample-hub'
  location: 'global'
  tags: tags
  properties: { accessModeSettings: { ingestionAccessMode: 'Open', queryAccessMode: 'Open' } }
}

resource pe 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: 'pe-ampls-sample-hub'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [{ name: 'ampls', properties: { privateLinkServiceId: ampls.id, groupIds: ['azuremonitor'] } }]
  }
}

resource peDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for z in zones: {
        name: replace(z, '.', '-')
        properties: { privateDnsZoneId: resourceId('Microsoft.Network/privateDnsZones', z) }
      }
    ]
  }
  dependsOn: [newZones]
}

output amplsId string = ampls.id
