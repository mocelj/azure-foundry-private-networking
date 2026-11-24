// Generic private endpoint with DNS zone group.

param name string
param location string
param tags object
param subnetId string
param privateLinkResourceId string
param groupId string

@description('Private DNS zone resource IDs to register the endpoint in.')
param privateDnsZoneIds array

resource pe 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    customNetworkInterfaceName: 'nic-${name}'
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: privateLinkResourceId
          groupIds: [groupId]
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for zoneId in privateDnsZoneIds: {
        name: replace(last(split(zoneId, '/')), '.', '-')
        properties: { privateDnsZoneId: zoneId }
      }
    ]
  }
}

output id string = pe.id
output name string = pe.name
