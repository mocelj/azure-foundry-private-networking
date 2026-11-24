// Optional module 5 (advanced monitoring): workspace-based Application Insights for Foundry agent
// traces. Entra-only ingestion (local auth disabled -> instrumentation keys rejected).

param name string
param location string
param tags object
param workspaceId string

@allowed(['Enabled', 'Disabled'])
param publicNetworkAccessForIngestion string = 'Disabled'

@allowed(['Enabled', 'Disabled'])
param publicNetworkAccessForQuery string = 'Disabled'

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
    IngestionMode: 'LogAnalytics'
    DisableLocalAuth: true
    DisableIpMasking: false
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
  }
}

output id string = appi.id
output name string = appi.name
output appId string = appi.properties.AppId
