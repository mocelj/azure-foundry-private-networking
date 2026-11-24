// Explicit egress resources. Exactly one (or none) of NAT gateway / route table is deployed.
// NAT gateway: outbound-only SNAT; it cannot accept inbound connections.

param namePrefix string
param location string
param tags object

@allowed(['none', 'natGateway', 'hubFirewall'])
param egressMode string

@description('Private IP of the hub firewall / NVA (required when egressMode = hubFirewall).')
param hubFirewallPrivateIp string = ''

resource pip 'Microsoft.Network/publicIPAddresses@2025-05-01' = if (egressMode == 'natGateway') {
  name: 'pip-${namePrefix}-nat'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nat 'Microsoft.Network/natGateways@2025-05-01' = if (egressMode == 'natGateway') {
  name: 'ng-${namePrefix}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [{ id: pip.id }]
  }
}

resource rt 'Microsoft.Network/routeTables@2025-05-01' = if (egressMode == 'hubFirewall') {
  name: 'rt-${namePrefix}-to-hub'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-hub-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: hubFirewallPrivateIp
        }
      }
    ]
  }
}

output natGatewayId string = egressMode == 'natGateway' ? nat.id : ''
output routeTableId string = egressMode == 'hubFirewall' ? rt.id : ''
