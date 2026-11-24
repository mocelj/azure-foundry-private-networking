// Private Windows jumpbox: no public IP, Trusted Launch, Entra ID sign-in, auto-shutdown.
// The local admin password is random, never output and not needed for normal use
// (Entra ID sign-in via Bastion). Reset via ARM (VMAccess) for break-glass only.

param name string
param location string
param tags object
param subnetId string
param vmSize string = 'Standard_D2s_v5'
param adminUsername string = 'azlocaladmin'

@secure()
param adminPassword string

@description('Principals granted Entra sign-in to the VM.')
param loginPrincipals array = []

@description('Daily auto-shutdown time (HHmm, UTC). Empty = disabled.')
param autoShutdownTime string = '1900'

resource nic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: 'nic-${name}'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          // No publicIPAddress by design.
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
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: take(replace(name, '-', ''), 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
          enableHotpatching: true
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${name}'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true } // managed storage, no public storage account
    }
  }
}

resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
  }
}

// Virtual Machine User Login — Entra sign-in without local admin rights.
var vmUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
// Reader on the VM and its NIC — required by Azure Bastion to connect (Bastion FAQ: Reader on VM, NIC, Bastion).
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource vmReaderAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for p in loginPrincipals: {
    name: guid(vm.id, p.principalId, readerRoleId)
    scope: vm
    properties: {
      principalId: p.principalId
      principalType: p.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
      description: 'Azure Bastion connection requires Reader on the target VM'
    }
  }
]

resource nicReaderAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for p in loginPrincipals: {
    name: guid(nic.id, p.principalId, readerRoleId)
    scope: nic
    properties: {
      principalId: p.principalId
      principalType: p.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
      description: 'Azure Bastion connection requires Reader on the target VM NIC'
    }
  }
]

resource loginAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for p in loginPrincipals: {
    name: guid(vm.id, p.principalId, vmUserLoginRoleId)
    scope: vm
    properties: {
      principalId: p.principalId
      principalType: p.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmUserLoginRoleId)
      description: 'Entra ID sign-in to the private jumpbox via Bastion'
    }
  }
]

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
