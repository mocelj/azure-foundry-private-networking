// Standard agent setup dependencies (BYO resources): agent state stays in the customer tenant.
//   Cosmos DB (NoSQL)  -> conversation/thread storage
//   Storage (blob)     -> file storage
//   Azure AI Search    -> vector store
// All: public network access disabled, key/local auth disabled (Entra ID only), diagnostics on.
// Private endpoints are created by the caller (main.bicep) with the shared PE module.

param location string
param tags object
param storageName string
param cosmosName string
param searchName string
param workspaceId string

@description('AI Search SKU. basic is the smallest SKU that supports private endpoints and managed identity.')
@allowed(['basic', 'standard', 'standard2', 'standard3'])
param searchSku string = 'basic'

@description('Storage replication. ZRS by default; use GRS/LRS in regions without ZRS.')
param storageSkuName string = 'Standard_ZRS'

@description('Trusted-service exception on the agent storage account. AzureServices matches Microsoft\'s Standard agent template; None validated live 2026-11-19 for all tested paths.')
@allowed(['AzureServices', 'None'])
param storageNetworkBypass string = 'AzureServices'

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: storageSkuName }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      // Default matches Microsoft's network-secured Standard agent template (trusted Azure services with
      // RBAC). No IP or VNet rules -> no public data-plane access. None = no exception (validated).
      bypass: storageNetworkBypass
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: true, days: 7 }
    containerDeleteRetentionPolicy: { enabled: true, days: 7 }
  }
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' = {
  name: cosmosName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    disableLocalAuth: true
    disableKeyBasedMetadataWriteAccess: true
    publicNetworkAccess: 'Disabled'
    isVirtualNetworkFilterEnabled: false
    ipRules: []
    minimalTlsVersion: 'Tls12'
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    enableFreeTier: false
  }
}

resource search 'Microsoft.Search/searchServices@2026-11-01' = {
  name: searchName
  location: location
  tags: tags
  sku: { name: searchSku }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'Default'
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true // Entra ID (RBAC) only; Foundry connections use authType AAD
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
    semanticSearch: 'disabled'
  }
}

// ----------------------------------------------------------------------------- diagnostics
resource blobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: blobService
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'Transaction', enabled: true }]
  }
}

resource cosmosDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: cosmos
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

resource searchDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: search
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output storageId string = storage.id
output storageName string = storage.name
output storageBlobEndpoint string = storage.properties.primaryEndpoints.blob
output cosmosId string = cosmos.id
output cosmosName string = cosmos.name
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output searchId string = search.id
output searchName string = search.name
