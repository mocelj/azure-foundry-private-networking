// Joins workload monitoring resources to an EXISTING (central, hub-owned) AMPLS. Deployed at the
// AMPLS resource group scope. Creates no private endpoint and no DNS records.

param amplsName string

@description('Resource IDs to add to the scope.')
param scopedResourceIds array

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' existing = {
  name: amplsName
}

resource scoped 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = [
  for id in scopedResourceIds: {
    parent: ampls
    name: 'scoped-${last(split(id, '/'))}'
    properties: { linkedResourceId: id }
  }
]
