// Azure Monitor Private Link Scope (AMPLS). Created only in standalone mode: an AMPLS private
// endpoint overrides DNS for the SHARED Azure Monitor endpoints, so there must be exactly one per
// DNS/network. In hub-spoke the spoke joins the central AMPLS instead (ampls-scoped-resources.bicep).

param name string
param tags object

@description('Resource IDs to add to the scope (Log Analytics workspace, Application Insights).')
param scopedResourceIds array

@allowed(['PrivateOnly', 'Open'])
param ingestionAccessMode string = 'PrivateOnly'

@allowed(['PrivateOnly', 'Open'])
param queryAccessMode string = 'PrivateOnly'

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: ingestionAccessMode
      queryAccessMode: queryAccessMode
    }
  }
}

resource scoped 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = [
  for id in scopedResourceIds: {
    parent: ampls
    name: 'scoped-${last(split(id, '/'))}'
    properties: { linkedResourceId: id }
  }
]

output id string = ampls.id
output name string = ampls.name
