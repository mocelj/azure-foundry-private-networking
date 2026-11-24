// Project capability host for Agents — Standard setup (BYO Cosmos DB, Storage, AI Search).
// The account-level capability host is auto-created by the resource provider when the account is
// created with networkInjections (named '{account}@aml_aiagentservice'); do not create a second one.
// Order: project + connections + account-scope RBAC for the project MI  ->  this  ->  container RBAC.

param accountName string
param projectName string
param cosmosConnectionName string
param storageConnectionName string
param searchConnectionName string
param name string = 'caphost-agents'

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-01' existing = {
  parent: account
  name: projectName
}

resource capHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2026-09-01' = {
  parent: project
  name: name
  properties: {
    // Bicep types omit capabilityHostKind but the RP requires it (see Microsoft template 15).
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    threadStorageConnections: [cosmosConnectionName]
    storageConnections: [storageConnectionName]
    vectorStoreConnections: [searchConnectionName]
  }
}

output name string = capHost.name
