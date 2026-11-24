// Least-privilege role assignments on the Foundry account and project.
// Each item: { principalId, principalType, roleDefinitionId, scope: 'account' | 'project', purpose }

param accountName string
param projectName string
param assignments array

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-01' existing = {
  parent: account
  name: projectName
}

resource accountAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in filter(assignments, x => x.scope == 'account'): {
    name: guid(account.id, a.principalId, a.roleDefinitionId)
    scope: account
    properties: {
      principalId: a.principalId
      principalType: a.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.roleDefinitionId)
      description: a.purpose
    }
  }
]

resource projectAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in filter(assignments, x => x.scope == 'project'): {
    name: guid(project.id, a.principalId, a.roleDefinitionId)
    scope: project
    properties: {
      principalId: a.principalId
      principalType: a.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.roleDefinitionId)
      description: a.purpose
    }
  }
]
