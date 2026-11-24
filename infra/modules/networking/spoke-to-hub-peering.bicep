// Spoke -> hub peering (spoke side). Created only when explicitly enabled.
// The hub -> spoke side is a separate module (hub-to-spoke-peering.bicep) that requires explicit opt-in
// because it modifies customer-owned networking.

param spokeVnetName string
param hubVnetId string

@description('Use the hub VPN/ExpressRoute gateway (requires gateway in hub and allowGatewayTransit on the hub side).')
param useRemoteGateways bool = false

resource spoke 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: spokeVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-05-01' = {
  parent: spoke
  name: 'peer-to-${last(split(hubVnetId, '/'))}'
  properties: {
    remoteVirtualNetwork: { id: hubVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: useRemoteGateways
  }
}

output peeringName string = peering.name
