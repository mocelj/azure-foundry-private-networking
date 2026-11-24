// Parameterised model deployment. No hard-coded model/version/capacity: all come from azd env.

param accountName string
param deploymentName string
param modelFormat string
param modelName string
param modelVersion string

@description('Deployment type / SKU, e.g. GlobalStandard, DataZoneStandard, Standard.')
param deploymentType string

@description('Capacity in thousands of tokens per minute.')
@minValue(1)
param capacity int

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2026-09-01' = {
  parent: account
  name: deploymentName
  sku: {
    name: deploymentType
    capacity: capacity
  }
  properties: {
    model: {
      format: modelFormat
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

output name string = deployment.name
