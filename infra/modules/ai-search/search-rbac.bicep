// Least-privilege data-plane roles on the knowledge search service.
// Each item: { principalId, principalType, roleDefinitionId, purpose }

param searchName string
param assignments array

resource search 'Microsoft.Search/searchServices@2026-11-01' existing = {
  name: searchName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in assignments: {
    name: guid(search.id, a.principalId, a.roleDefinitionId)
    scope: search
    properties: {
      principalId: a.principalId
      principalType: a.principalType
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.roleDefinitionId)
      description: a.purpose
    }
  }
]
