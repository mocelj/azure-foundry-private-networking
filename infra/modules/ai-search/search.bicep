// Optional module 1 — private Azure AI Search for curated knowledge (separate from the
// Agent Service vector-store search of the Standard setup).
// Public network access disabled, Entra ID only (local/key auth disabled), no trusted bypass.

param name string
param location string
param tags object
param workspaceId string

@description('basic is the smallest SKU that supports private endpoints, managed identity and semantic ranker (free plan).')
@allowed(['basic', 'standard', 'standard2', 'standard3', 'storage_optimized_l1', 'storage_optimized_l2'])
param sku string = 'basic'

@allowed(['disabled', 'free', 'standard'])
param semanticSearch string = 'free'

resource search 'Microsoft.Search/searchServices@2026-11-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: sku }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
    semanticSearch: semanticSearch
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: search
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output id string = search.id
output name string = search.name
output principalId string = search.identity.principalId
