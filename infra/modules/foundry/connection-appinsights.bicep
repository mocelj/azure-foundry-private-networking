// Project connection to Application Insights for server-side agent tracing. Entra auth: the
// Foundry project managed identity ingests traces (needs Monitoring Metrics Publisher).
// A project allows exactly one AppInsights connection.

param accountName string
param projectName string
param appInsightsName string
param connectionName string = 'agent-traces'

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
  resource project 'projects' existing = {
    name: projectName
  }
}

// The service requires the connection string in metadata even for managed-identity auth. Its
// instrumentation key is an identifier, not a credential: local auth is disabled on the component.
resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = {
  parent: account::project
  name: connectionName
  properties: {
    category: 'AppInsights'
    target: appi.id
    // The service accepts only ProjectManagedIdentity (or ApiKey) for AppInsights connections; the
    // value is not yet in the published Bicep type schema.
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: appi.id
      ApplicationInsightsConnectionString: appi.properties.ConnectionString
    }
  }
}

output name string = connection.name
