// Optional module 3 — private RAG demo host.
// Ubuntu VM in snet-app: no public IP, no internet egress (stdlib-only Python app, nothing to
// download), Trusted Launch, system-assigned MI. App code is delivered by
// scripts/rag/Deploy-RagApp.ps1 via VM Run Command (management plane), so nothing is exposed.

param name string
param location string
param tags object
param subnetId string
param vmSize string = 'Standard_D2s_v5'
param adminUsername string = 'azlocaladmin'

@secure()
param adminPassword string

@description('Daily auto-shutdown (HHmm UTC). Empty = disabled.')
param autoShutdownTime string = '1900'

resource nic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    osProfile: {
      computerName: take(replace(name, '-', ''), 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false // no SSH path exists (NSG); password is random and never output
        provisionVMAgent: true
        patchSettings: { patchMode: 'ImageDefault', assessmentMode: 'ImageDefault' }
      }
    }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: {
        name: 'osdisk-${name}'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (!empty(autoShutdownTime)) {
  name: 'shutdown-computevm-${name}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: autoShutdownTime }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
    notificationSettings: { status: 'Disabled' }
  }
}

output id string = vm.id
output name string = vm.name
output principalId string = vm.identity.principalId
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
