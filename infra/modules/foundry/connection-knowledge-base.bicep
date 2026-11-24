// Optional module 6 (Foundry IQ): project connection to a Foundry IQ knowledge base MCP endpoint.
// RemoteTool + project managed identity (no secrets). The knowledge source / knowledge base are
// Search data-plane objects created from inside the network by scripts/ai-search/Seed-KnowledgeIndex.ps1.

param accountName string
param projectName string
param searchName string
param knowledgeBaseName string
param connectionName string = 'knowledge-base-mcp'

@description('API version of the knowledge base MCP endpoint. GA 2026-10-01 verified live 2026-11-19 (Learn samples still show 2026-11-01-preview).')
param mcpApiVersion string = '2026-10-01'

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
  resource project 'projects' existing = {
    name: projectName
  }
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = {
  parent: account::project
  name: connectionName
  properties: {
    category: 'RemoteTool'
    target: 'https://${searchName}.search.windows.net/knowledgebases/${knowledgeBaseName}/mcp?api-version=${mcpApiVersion}'
    // ProjectManagedIdentity is accepted by the service but not yet in the published Bicep type schema
    // (RemoteTool and audience are typed since Bicep 0.49.2).
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: 'https://search.azure.com/'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
    }
  }
}

output name string = connection.name
output target string = connection.properties.target
