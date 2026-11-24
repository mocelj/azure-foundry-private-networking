// Hub -> spoke peering. Deployed into the HUB resource group. Opt-in only (ENABLE_HUB_SIDE_PEERING),
// because it changes customer-owned networking and requires Network Contributor on the hub VNet.

param hubVnetName string
param spokeVnetId string

@description('Allow the spoke to use the hub gateway (VPN/ExpressRoute).')
param allowGatewayTransit bool = false

resource hub 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: hubVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-05-01' = {
  parent: hub
  name: 'peer-to-${last(split(spokeVnetId, '/'))}'
  properties: {
    remoteVirtualNetwork: { id: spokeVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: false
  }
}
