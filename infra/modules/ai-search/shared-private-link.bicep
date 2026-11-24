// Outbound shared private link from the knowledge search to the Foundry account (Foundry IQ query
// planning, option A+). Creates a managed private endpoint in the search service's Microsoft-managed
// network; the connection is PENDING on the Foundry account until its owner approves it
// (scripts/ai-search/Approve-SharedPrivateLink.ps1). See docs/private-link-explained.md.
param searchName string
param name string
param privateLinkResourceId string
@allowed(['openai_account', 'foundry_account'])
param groupId string = 'openai_account'
param requestMessage string

resource search 'Microsoft.Search/searchServices@2026-11-01' existing = {
  name: searchName
}

resource spl 'Microsoft.Search/searchServices/sharedPrivateLinkResources@2026-11-01' = {
  parent: search
  name: name
  properties: {
    groupId: groupId
    privateLinkResourceId: privateLinkResourceId
    requestMessage: requestMessage
  }
}

output name string = spl.name
