// Alerts + saved queries for the private Foundry deployment.
//  - Security drift: activity-log alert on writes/deletes of network-relevant configuration
//    (Foundry account, Search, Storage, Cosmos DB, private endpoints, NSG rules). This includes
//    someone enabling public network access. azd provision also triggers it (expected).
//  - Reliability: Foundry ServerErrors; Responsible AI: content-filter rejections.
//  - Query pack: KQL for agent traces (server-side tracing -> workspace-based Application Insights).

param namePrefix string
param location string
param tags object
param accountId string

@description('Optional e-mail for alert notifications. Empty = alerts fire and are visible in Azure Monitor only.')
param alertEmail string = ''

resource actionGroup 'Microsoft.Insights/actionGroups@2024-10-01-preview' = if (!empty(alertEmail)) {
  name: 'ag-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take('fdpriv${uniqueString(namePrefix)}', 12)
    enabled: true
    emailReceivers: [
      { name: 'owner', emailAddress: alertEmail, useCommonAlertSchema: true }
    ]
  }
}

var actions = empty(alertEmail) ? [] : [{ actionGroupId: actionGroup.id }]

var watchedOperations = [
  'Microsoft.CognitiveServices/accounts/write'
  'Microsoft.CognitiveServices/accounts/delete'
  'Microsoft.CognitiveServices/accounts/privateEndpointConnections/delete'
  'Microsoft.Search/searchServices/write'
  'Microsoft.Storage/storageAccounts/write'
  'Microsoft.DocumentDB/databaseAccounts/write'
  'Microsoft.Network/privateEndpoints/delete'
  'Microsoft.Network/networkSecurityGroups/securityRules/write'
  'Microsoft.Network/networkSecurityGroups/securityRules/delete'
  'Microsoft.Insights/privateLinkScopes/write'
]

resource driftAlert 'Microsoft.Insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'alert-${namePrefix}-network-config-change'
  location: 'global'
  tags: tags
  properties: {
    description: 'Network-relevant configuration of the private Foundry deployment changed (e.g. public network access, private endpoints, NSG rules). Verify the change was approved.'
    enabled: true
    scopes: [resourceGroup().id]
    condition: {
      allOf: [
        { field: 'category', equals: 'Administrative' }
        { field: 'status', equals: 'Succeeded' }
        { anyOf: [for op in watchedOperations: { field: 'operationName', equals: op }] }
      ]
    }
    actions: { actionGroups: actions }
  }
}

resource serverErrors 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${namePrefix}-foundry-server-errors'
  location: 'global'
  tags: tags
  properties: {
    description: 'Foundry model server errors (5xx) in the last 15 minutes.'
    severity: 2
    enabled: true
    scopes: [accountId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        { criterionType: 'StaticThresholdCriterion', name: 'ServerErrors', metricName: 'ServerErrors', metricNamespace: 'Microsoft.CognitiveServices/accounts', operator: 'GreaterThan', threshold: 5, timeAggregation: 'Total' }
      ]
    }
    actions: actions
  }
}

resource raiRejected 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${namePrefix}-foundry-content-filter'
  location: 'global'
  tags: tags
  properties: {
    description: 'Requests rejected by the Responsible AI content filter in the last 15 minutes.'
    severity: 3
    enabled: true
    scopes: [accountId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        { criterionType: 'StaticThresholdCriterion', name: 'RAIRejectedRequests', metricName: 'RAIRejectedRequests', metricNamespace: 'Microsoft.CognitiveServices/accounts', operator: 'GreaterThan', threshold: 0, timeAggregation: 'Total' }
      ]
    }
    actions: actions
  }
}

var queries = [
  {
    name: 'Agent runs (server-side traces)'
    body: 'AppDependencies\n| where TimeGenerated > ago(24h)\n| extend agent = tostring(Properties["gen_ai.agent.name"]), op = tostring(Properties["gen_ai.operation.name"])\n| where isnotempty(agent) or isnotempty(op)\n| project TimeGenerated, OperationId, agent, op, Name, DurationMs, Success\n| order by TimeGenerated desc'
  }
  {
    name: 'Agent tool calls'
    body: 'AppDependencies\n| where TimeGenerated > ago(24h)\n| extend op = tostring(Properties["gen_ai.operation.name"]), tool = tostring(Properties["gen_ai.tool.name"])\n| where op == "execute_tool" or isnotempty(tool)\n| summarize calls = count(), failures = countif(Success == false), p95ms = percentile(DurationMs, 95) by tool, bin(TimeGenerated, 1h)'
  }
  {
    name: 'Token usage by model'
    body: 'AppDependencies\n| where TimeGenerated > ago(7d)\n| extend model = tostring(Properties["gen_ai.request.model"]), inTok = toint(Properties["gen_ai.usage.input_tokens"]), outTok = toint(Properties["gen_ai.usage.output_tokens"])\n| where isnotempty(model)\n| summarize input = sum(inTok), output = sum(outTok) by model, bin(TimeGenerated, 1d)'
  }
  {
    name: 'Failed agent operations'
    body: 'AppDependencies\n| where TimeGenerated > ago(24h) and Success == false\n| where Properties has "gen_ai"\n| project TimeGenerated, OperationId, Name, ResultCode, DurationMs, Properties'
  }
  {
    name: 'Foundry account: blocked / failed requests (resource logs)'
    body: 'AzureDiagnostics\n| where TimeGenerated > ago(24h) and ResourceProvider == "MICROSOFT.COGNITIVESERVICES"\n| where toint(ResultSignature) >= 400\n| summarize count() by ResultSignature, OperationName, CallerIPAddress, bin(TimeGenerated, 1h)'
  }
]

resource queryPack 'Microsoft.OperationalInsights/queryPacks@2025-07-01' = {
  name: 'qp-${namePrefix}'
  location: location
  tags: tags
  properties: {}
}

resource packQueries 'Microsoft.OperationalInsights/queryPacks/queries@2025-07-01' = [
  for q in queries: {
    parent: queryPack
    name: guid(queryPack.id, q.name)
    properties: {
      displayName: q.name
      body: q.body
      related: { categories: ['monitor'] }
      tags: { labels: ['foundry-private-demo'] }
    }
  }
]

output driftAlertName string = driftAlert.name
output queryPackName string = queryPack.name
