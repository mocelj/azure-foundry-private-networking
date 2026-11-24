param name string
param location string
param tags object

@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@allowed(['Enabled', 'Disabled'])
param publicNetworkAccessForIngestion string = 'Enabled'

@allowed(['Enabled', 'Disabled'])
param publicNetworkAccessForQuery string = 'Enabled'

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
    features: {
      // Workspace-scoped RBAC only; no shared keys needed by this deployment.
      enableLogAccessUsingOnlyResourcePermissions: true
      disableLocalAuth: true
    }
  }
}

output id string = workspace.id
output name string = workspace.name
