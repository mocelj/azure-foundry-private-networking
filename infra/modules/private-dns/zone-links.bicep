param zoneName string
param vnetIds array
param tags object

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetIds: {
    parent: zone
    name: 'link-${last(split(vnetId, '/'))}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      // Fail closed: never fall back to public resolution for privatelink names.
      resolutionPolicy: 'Default'
      virtualNetwork: { id: vnetId }
    }
  }
]
