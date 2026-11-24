// Generic role assignments on an Application Insights component and/or Log Analytics workspace.

param appInsightsName string
param workspaceName string

@description('Array of { principalId, principalType, roleDefinitionId, target: appInsights|workspace, purpose }.')
param assignments array

resource appi 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource law 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

resource raAppi 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in filter(assignments, x => x.target == 'appInsights'): {
    name: guid(appi.id, a.principalId, a.roleDefinitionId)
    scope: appi
    properties: {
      principalId: a.principalId
      principalType: a.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.roleDefinitionId)
      description: a.purpose
    }
  }
]

resource raLaw 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in filter(assignments, x => x.target == 'workspace'): {
    name: guid(law.id, a.principalId, a.roleDefinitionId)
    scope: law
    properties: {
      principalId: a.principalId
      principalType: a.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.roleDefinitionId)
      description: a.purpose
    }
  }
]
