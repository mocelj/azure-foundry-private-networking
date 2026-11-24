// Knowledge search managed identity -> Foundry account: Cognitive Services OpenAI User.
// Required for knowledge base LLM query planning with managed identity (Learn: assign on the parent
// Foundry resource that hosts the deployment, not on the project or the deployment).
param accountName string
param searchPrincipalId string

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

var openAiUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, searchPrincipalId, openAiUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUser)
    principalId: searchPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Foundry IQ query planning: knowledge search MI calls the model deployment'
  }
}
