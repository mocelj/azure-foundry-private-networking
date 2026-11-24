// Azure Bastion (Standard). The Standard public IP is Bastion's managed HTTPS ingress only;
// RDP/SSH to workloads are never exposed publicly.

param name string
param location string
param tags object
param subnetId string
param workspaceId string

@description('Principals that connect through Bastion (get Reader on the Bastion resource).')
param readerPrincipals array = []

resource pip 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: 'pip-${name}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-05-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    scaleUnits: 2
    enableTunneling: true // native client (az network bastion rdp --enable-mfa)
    enableIpConnect: false
    enableShareableLink: false
    enableFileCopy: false
    disableCopyPaste: false
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: subnetId }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: bastion
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

// Reader on the Bastion resource — required to connect through it (Bastion FAQ: Reader on VM, NIC, Bastion;
// VM and NIC are granted in the jumpbox module). Same VNet as the jumpbox, so no VNet Reader is needed.
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource readerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for p in readerPrincipals: {
    name: guid(bastion.id, p.principalId, readerRoleId)
    scope: bastion
    properties: {
      principalId: p.principalId
      principalType: p.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
      description: 'Azure Bastion connection requires Reader on the Bastion resource'
    }
  }
]

output id string = bastion.id
output name string = bastion.name
