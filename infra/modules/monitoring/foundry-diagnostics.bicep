// Diagnostic settings for the Foundry account. Azure OpenAI / Foundry resource logs record request
// metadata (operation, status, latency, caller IP, identity object ID) — not prompt or completion
// content.

param accountName string
param workspaceId string

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: account
  properties: {
    workspaceId: workspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}
