// Project managed identity -> data-plane roles scoped to the project's own agent containers,
// AFTER the capability host has provisioned them.
//   Storage Blob Data Owner, ABAC-conditioned to containers '<workspaceId>*-azureml-agent'
//   Cosmos DB Built-in Data Contributor, scoped to the enterprise_memory database

param projectPrincipalId string
param workspaceIdGuid string
param storageName string
param cosmosName string

var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' existing = {
  name: cosmosName
}

var blobCondition = '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/filter/action\'}) AND !(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write\'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase \'${workspaceIdGuid}\' AND @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringLikeIgnoreCase \'*-azureml-agent\'))'

resource blobOwnerRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, projectPrincipalId, storageBlobDataOwner, workspaceIdGuid)
  scope: storage
  properties: {
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwner)
    conditionVersion: '2.0'
    condition: blobCondition
    description: 'Foundry project MI: own blobs in this project agent containers only (ABAC)'
  }
}

resource cosmosDataRa 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: cosmos
  name: guid(cosmos.id, projectPrincipalId, workspaceIdGuid, 'data-contributor')
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: '${cosmos.id}/dbs/enterprise_memory'
  }
  dependsOn: [blobOwnerRa]
}
