// Foundry project (child of the Foundry account) with system-assigned managed identity.
// When agentDependencies is supplied (Standard agent setup), Entra-authenticated (AAD)
// connections to Cosmos DB, Storage and AI Search are created on the project.

param accountName string
param name string
param location string
param tags object
param displayName string
param projectDescription string

@description('Standard setup BYO resources: { cosmosId, cosmosName, cosmosEndpoint, storageId, storageName, storageBlobEndpoint, searchId, searchName }. Empty object = no connections.')
param agentDependencies object = {}

var withDeps = !empty(agentDependencies)

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-01' = {
  parent: account
  name: name
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: displayName
    description: projectDescription
  }
}

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = if (withDeps) {
  parent: project
  name: withDeps ? agentDependencies.cosmosName : 'none-cosmos'
  properties: {
    category: 'CosmosDB'
    target: withDeps ? agentDependencies.cosmosEndpoint : ''
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: withDeps ? agentDependencies.cosmosId : ''
      location: location
    }
  }
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = if (withDeps) {
  parent: project
  name: withDeps ? agentDependencies.storageName : 'none-storage'
  properties: {
    category: 'AzureStorageAccount'
    target: withDeps ? agentDependencies.storageBlobEndpoint : ''
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: withDeps ? agentDependencies.storageId : ''
      location: location
    }
  }
  dependsOn: [cosmosConnection]
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = if (withDeps) {
  parent: project
  name: withDeps ? agentDependencies.searchName : 'none-search'
  properties: {
    category: 'CognitiveSearch'
    target: withDeps ? 'https://${agentDependencies.searchName}.search.windows.net' : ''
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: withDeps ? agentDependencies.searchId : ''
      location: location
    }
  }
  dependsOn: [storageConnection]
}

// internalId = project workspace GUID without dashes; Agent Service uses it in container names.
#disable-next-line BCP053
var internalId = string(project.properties.internalId)

output id string = project.id
output name string = project.name
output principalId string = project.identity.principalId
output endpoint string = project.properties.endpoints['AI Foundry API']
output workspaceIdGuid string = '${take(internalId, 8)}-${take(skip(internalId, 8), 4)}-${take(skip(internalId, 12), 4)}-${take(skip(internalId, 16), 4)}-${skip(internalId, 20)}'
output cosmosConnectionName string = withDeps ? cosmosConnection.name : ''
output storageConnectionName string = withDeps ? storageConnection.name : ''
output searchConnectionName string = withDeps ? searchConnection.name : ''
