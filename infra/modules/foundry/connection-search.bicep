// Entra-authenticated (AAD) project connection to the knowledge search service, so agents
// (Azure AI Search tool) and apps can use it without keys.

param accountName string
param projectName string
param searchName string
param searchId string
param location string
param connectionName string = 'knowledge-search'

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-01' existing = {
  parent: account
  name: projectName
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = {
  parent: project
  name: connectionName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${searchName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchId
      location: location
    }
  }
}

output name string = connection.name
output id string = connection.id
