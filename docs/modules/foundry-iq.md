# Optional module 6 — Foundry IQ (knowledge base + agentic retrieval)

Enable (requires the AI Search module and `OUTBOUND_NETWORK_MODE=byoVnet`):

```powershell
azd env set ENABLE_AI_SEARCH true
azd env set ENABLE_FOUNDRY_IQ true
azd provision     # Bicep: MCP connection; postprovision: knowledge source + knowledge base + agent + smoke test
# optional A+ (LLM query planning, see below):
azd env set FOUNDRY_IQ_REASONING low   # minimal (default) | low | medium
```

## What Foundry IQ is

Azure AI Search is now branded **Foundry IQ**. On top of classic indexes it adds:

| Building block | What it is |
|---|---|
| Knowledge source | A content source: an existing search index, Blob/ADLS, SharePoint, OneLake, web. Indexed sources can get automatic chunking + embeddings |
| Knowledge base | Groups knowledge sources behind one **MCP endpoint** (`knowledge_base_retrieve`). Several agents can share it |
| Agentic retrieval | Optional LLM query planning (decompose, parallel sub-queries, iterate), semantic reranking, merged results with citations |

Module 4 (agent demo) already uses the classic **Foundry IQ (Azure AI Search) tool** against an index.
This module adds the **knowledge base / MCP** layer.

## Implemented: option A (fully private on Basic)

| Component | Configuration |
|---|---|
| Knowledge source `contoso-policies-kb-ks` | `kind: searchIndex` over the existing private `contoso-policies` index, semantic configuration `default` |
| Knowledge base `contoso-policies-kb` (`FOUNDRY_IQ_KB_NAME`) | `retrievalReasoningEffort: minimal`, `outputMode: extractiveData`, GA API `2026-10-01`. **No LLM**, so Search makes **no outbound call** at retrieval time |
| Project connection `knowledge-base-mcp` (Bicep) | `category: RemoteTool`, `authType: ProjectManagedIdentity`, `audience: https://search.azure.com/`, target `https://srch-kb-<token>.search.windows.net/knowledgebases/<kb>/mcp?api-version=2026-10-01` (GA) |
| Agent `contoso-iq-agent` | `src/agents/policy-agent-iq.json`: MCP tool, `allowed_tools: [knowledge_base_retrieve]`, `require_approval: never`, no other tools |
| RBAC | Reuses the project MI roles on the knowledge search (Search Index Data Contributor + Search Service Contributor ⊇ the documented Search Index Data Reader) |

Data-plane objects (knowledge source, knowledge base, agent) are created **from inside the network**
(VM Run Command on the jumpbox or `PRIVATE_CLIENT_VM_ID`, managed identity) by `Seed-KnowledgeIndex.ps1` and
`Deploy-DemoAgent.ps1 -Variant foundry-iq`, both called by the postprovision hook. Both are idempotent.

### Network paths (all private)

```text
agent runtime (snet-agent, VNet-injected)
  └─ MCP call knowledge_base_retrieve ─► srch-kb-<token>.search.windows.net (private endpoint, project MI token)
       └─ knowledge base (minimal) ─► knowledge source ─► contoso-policies index   (inside the Search service)
```

## Optional A+: LLM query planning (`FOUNDRY_IQ_REASONING=low|medium`)

With `low` or `medium` the knowledge base uses the model deployment (`gpt-5.4-mini`) to decompose the
question, run sub-queries and merge results. Search then calls the model **at query time**, an
**outbound** call from the knowledge search to the Foundry account ([network directions](../network-directions.md)).
It is kept private with a **shared private link** ([explained, incl. approval](../private-link-explained.md)):

| Component | Where | Configuration |
|---|---|---|
| Shared private link `spl-foundry-openai` | Bicep `modules/ai-search/shared-private-link.bicep` | Knowledge search → Foundry account, group ID `openai_account`, request message `Foundry IQ query planning from <search> (<env>)` |
| Approval | `scripts/ai-search/Approve-SharedPrivateLink.ps1` (called by the seed step) | Approves **only** a pending connection `spl-foundry-openai.<guid>` on this environment's account with the exact request message, and exactly one; otherwise fails. `FOUNDRY_IQ_AUTO_APPROVE=false` leaves approval to the account owner (separation of duties) |
| Model role | Bicep `modules/ai-search/search-model-rbac.bicep` | Knowledge search MI → **Cognitive Services OpenAI User** on the account (documented requirement) |
| Knowledge base | `Seed-KnowledgeIndex.ps1` | `retrievalReasoningEffort: low`, `models: [{ kind: azureOpenAI, resourceUri: https://aif-<token>.openai.azure.com, deploymentId, modelName }]` |

```text
agent runtime ─► MCP knowledge_base_retrieve ─► srch-kb (inbound private endpoint)
                                                 └─ query planning ─► shared private link ─► Foundry account (openai_account) ─► gpt-5.4-mini
```

**Live result (2026-11-19, standalone, Search Basic, Foundry trusted-service bypass `None`):**

| Step | Result |
|---|---|
| Knowledge base `low` + model, **no** shared private link | Retrieve **403**: "Could not complete model action. The model endpoint returned status code '403' … Public access is disabled. Please configure private endpoint." |
| Shared private link created, connection **Pending** | Still 403 |
| Connection **Approved** | Retrieve **200**, activity `modelQueryPlanning` (≈1,465 input / 83 output tokens) + 2 index searches; grounded answer |
| Bicep + hook from scratch, then forced re-deploy (`--no-state`) | Link created, approved by the hook, unchanged on re-deploy (idempotent) |
| `Test-Deployment.ps1` | **101/101** (one public check re-run after a local network error); new checks: link approved, search MI role, `modelQueryPlanning` from the private client |

This settles Learn's contradiction for this workload: "Knowledge bases calling Azure OpenAI: Basic and
higher" (shared private link prerequisites) is correct; the limits footnote ("on Basic services, private
connections to a Microsoft Foundry resource are unsupported") doesn't apply to it. No trusted-service
exception is involved.

Gotcha: a shared private link can't be re-requested once approved. Changing its properties (e.g. the
request message) fails with `PrivateLinkStatusChangeNotAllowed: Status change from 'Approved' to 'Pending'`;
delete the link and let the deployment recreate it.

Cost: model tokens per retrieval (roughly 1.5k input tokens per question here) and Private Link usage
billing for the shared private link.

## Validation

| Layer | Check |
|---|---|
| Static (`full-demo` profiles) | Exactly one `RemoteTool` connection, `ProjectManagedIdentity`, target = MCP endpoint of the **private** knowledge search; `full-demo-query-planning`: exactly one shared private link (`openai_account`); all other profiles: **no** shared private link; template: the search MI gets only Cognitive Services OpenAI User and only with query planning |
| Postprovision | Knowledge base `retrieve` returns *Expense reimbursement*; agent smoke: `mcp_call` succeeds and the answer mentions Bastion |
| Live `Test-Deployment.ps1` | Connection config; in-VNet: agent called `knowledge_base_retrieve` successfully and answered **220 EUR**; with A+: link approved, search MI role, `modelQueryPlanning` in a retrieve from the private client |

Live results: first run 2026-11-18; 2026-11-19 with the GA MCP API version: standalone 71/71 and hub-spoke 67/67 (network + in-VNet).

## Deferred option (documented, not implemented)

| Option | What it adds | Network implications | Why deferred / prerequisites |
|---|---|---|---|
| **B**: Full private agentic retrieval ([Microsoft tutorial](https://learn.microsoft.com/azure/foundry/agents/how-to/foundry-iq-tutorial-private-overview)) | Blob knowledge source with automatic chunking + `text-embedding-3-large` vectorization + scheduled indexer, query planning | Search → Storage and Search → Foundry via **shared private links** (target-side approvals, see [private-link-explained.md](../private-link-explained.md#4-what-this-means-for-foundry-iq-knowledge-sources)). Learn: the ingestion-time embedding call **still relies on the Foundry trusted-service bypass**. Private managed knowledge-source ingestion is documented for **S2+**; Basic doesn't support private connections to a Foundry resource | Cost: Search **S2** (~US$1,000/month) + embedding model. Worth it only when a customer needs document ingestion from Blob/ADLS rather than a curated index |

Also out of scope here: SharePoint / OneLake / web knowledge sources (web is public by definition),
per-user permission trimming (`x-ms-query-source-authorization`), and Copilot Studio integration.

## Gotchas

| Item | Note |
|---|---|
| MCP endpoint API version | The repo uses the GA version `2026-10-01` (parameter `mcpApiVersion`), verified live 2026-11-19 in both environments. Some Learn samples still show `2026-11-01-preview`, which also answers but is preview |
| Bicep schema | `authType: ProjectManagedIdentity` is accepted by the service on `2026-09-01` but not in the published types (`#disable-next-line BCP036`); `RemoteTool` and `audience` are typed since Bicep 0.49 |
| Agent instructions | As with module 4, tell the model to call the knowledge base for **every** question; otherwise it may answer "don't know" without retrieving |
| Stopped client VM | Seed / agent / RAG scripts now start the jumpbox or RAG VM if the daily auto-shutdown stopped it |
| Citation links | For search-index knowledge sources the agent cites the Search document-lookup URL (`…/indexes/<index>/docs/<id>?…`), documented fallback; opening it in a browser returns 401 (Entra-only). The classic Azure AI Search tool agent (module 4) links to the private document page instead |
