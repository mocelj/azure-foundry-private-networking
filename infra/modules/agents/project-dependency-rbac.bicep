// Project managed identity -> Standard setup dependencies, BEFORE the capability host is created.
//   Storage Blob Data Contributor (account)  - provision agent containers
//   Cosmos DB Operator (account)             - provision the enterprise_memory database
//   Search Index Data Contributor + Search Service Contributor - vector store indexes

param projectPrincipalId string
param storageName string
param cosmosName string
param searchName string

var roles = {
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  cosmosDbOperator: '230815da-be43-4aae-9cb4-875f7bd000aa'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' existing = {
  name: cosmosName
}

resource search 'Microsoft.Search/searchServices@2026-11-01' existing = {
  name: searchName
}

resource storageRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, projectPrincipalId, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
    description: 'Foundry project MI: provision agent file storage'
  }
}

resource cosmosRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmos.id, projectPrincipalId, roles.cosmosDbOperator)
  scope: cosmos
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.cosmosDbOperator)
    description: 'Foundry project MI: provision agent thread storage'
  }
}

resource searchDataRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, projectPrincipalId, roles.searchIndexDataContributor)
  scope: search
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchIndexDataContributor)
    description: 'Foundry project MI: agent vector store data'
  }
}

resource searchSvcRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, projectPrincipalId, roles.searchServiceContributor)
  scope: search
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchServiceContributor)
    description: 'Foundry project MI: create/manage agent vector indexes'
  }
}
