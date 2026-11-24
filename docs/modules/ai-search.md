# Optional module 1 — Private Azure AI Search (knowledge)

Enable: `azd env set ENABLE_AI_SEARCH true && azd provision`
Sample profile: [`examples/private-rag/ai-search.env`](../../examples/private-rag/ai-search.env)

## What it deploys

| Resource | Configuration |
|---|---|
| Azure AI Search `srch-kb-<token>` | SKU `AI_SEARCH_SKU` (default `basic`; `free` rejected by preflight — no private endpoint / MI). Public network access **disabled**, `disableLocalAuth: true` (Entra RBAC only, no API keys), `networkRuleSet.bypass: None`, system-assigned MI, semantic ranker (free plan), diagnostics → Log Analytics |
| Private endpoint `pe-srch-kb-<token>` | group `searchService`, zone `privatelink.search.windows.net` (created, or central zone in hub mode) |
| Foundry project connection `knowledge-search` | category `CognitiveSearch`, `authType: AAD` — usable by agents (Azure AI Search tool) and apps without keys |
| Sample index `contoso-policies` + 8 synthetic documents | Seeded **from inside the VNet** by `scripts/ai-search/Seed-KnowledgeIndex.ps1` (postprovision hook, via jumpbox Run Command) |

It is a **separate** service from the Standard agent setup's vector store (`srch-agent-*`), which
Agent Service manages. Curated knowledge and agent-owned indexes don't share a blast radius or
RBAC scope.

## Identity

| Identity | Role on knowledge search | Why |
|---|---|---|
| Foundry project MI | Search Index Data Contributor + Search Service Contributor | Required by the agent Azure AI Search tool ([documented](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/ai-search#troubleshooting)); Index Data Reader alone fails with 403 on `Indexes.Get` (observed live). Admin keys unusable (`disableLocalAuth`); scoped to this service only |
| Demo user | Search Index Data Reader | Query from the jumpbox / portal |
| Jumpbox MI (validation client, `GRANT_JUMPBOX_VALIDATION_ROLES`) | Search Service Contributor + Search Index Data Contributor | Create the sample index and upload documents |

## Why seeding runs inside the network

With public network access disabled, the Search data plane (create index, upload, query) is only
reachable through the private endpoint. The deployment machine is usually outside the VNet, so
seeding uses `az vm run-command` (management plane) to execute the REST calls **on the jumpbox**,
authenticating with its managed identity. In hub-spoke mode pass `-ClientVmId` of a private
Windows client. No temporary public access is ever opened.

## Retrieval demo

From the jumpbox (PowerShell, signed in with Entra):

```powershell
$tok = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv
$body = '{"search":"Who may access highly confidential data from abroad?","queryType":"semantic","semanticConfiguration":"default","top":3,"select":"id,title"}'
Invoke-RestMethod -Method Post -Uri "https://<srch-kb>.search.windows.net/indexes/contoso-policies/docs/search?api-version=2024-07-01" `
  -Headers @{Authorization="Bearer $tok"} -ContentType application/json -Body $body
```

From the internet the same call returns `403 … publicNetworkAccess: Disabled`.

## Limitations

- Indexers pulling from private sources must use `executionEnvironment: Private`; the sample uses
  the push API instead. Integrated vectorization (Search → Foundry embeddings) requires the Search
  MI to reach Foundry (trusted bypass or shared private link); it is **not implemented** (the sample
  index has no vectors). See Foundry IQ option B in [foundry-iq.md](foundry-iq.md).
- Semantic ranker free plan: 1,000 requests/month.
