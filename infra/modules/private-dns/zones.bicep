// Private DNS zones. Either creates the zones and links them to the given VNet(s), or passes
// through existing centrally-managed zone IDs (hub mode) without creating/linking anything.

param tags object

@description('Zone names required by the deployed private endpoints, e.g. privatelink.openai.azure.com')
param zoneNames array

@allowed(['create', 'existing'])
param mode string = 'create'

@description('VNet IDs to link the zones to (create mode only).')
param vnetIdsToLink array = []

@description('Map of zone name -> existing zone resource ID (existing mode only).')
param existingZoneIds object = {}

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in zoneNames: if (mode == 'create') {
    name: zone
    location: 'global'
    tags: tags
  }
]

module links 'zone-links.bicep' = [
  for (zone, i) in zoneNames: if (mode == 'create') {
    name: 'dnslinks-${uniqueString(zone)}'
    params: {
      zoneName: zone
      vnetIds: vnetIdsToLink
      tags: tags
    }
    dependsOn: [zones[i]]
  }
]

// Output: zone name -> resource ID, irrespective of mode.
output zoneIds object = toObject(
  zoneNames,
  z => z,
  z => mode == 'create' ? resourceId('Microsoft.Network/privateDnsZones', z) : existingZoneIds[z]
)
