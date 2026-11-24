# Private networking — known limitations and gaps

What may **not** work, or works only with caveats, when Foundry and its dependencies are fully
private. Sources: Microsoft Learn (linked) and our own live observations (dated). Check this list
before promising a feature to a customer; re-validate regularly — the platform changes often.

Legend: ❌ not supported privately · ⚠️ works with caveats / partially · 🔍 observed by us, cause unconfirmed · ℹ️ information

## Agents and tools

| Feature | Status | Detail | Source |
|---|---|---|---|
| Bing grounding, Web search, SharePoint grounding | ⚠️ | Work, but traffic goes over **public** Microsoft endpoints → excluded from the private profile. The new Foundry portal **adds `web_search` by default** to new agents — remove it | Learn: configure-private-link (tool table); observed 2026-11-18 |
| Browser automation, Computer use, Image generation, Logic Apps | ❌ | Not supported with network isolation | Learn: configure-private-link |
| Fabric Data Agent | ❌ | Needs Fabric public access | Learn |
| Fabric IQ | ⚠️ | Depends on Fabric item type and private link level | Learn |
| Work IQ | ❌ | Not supported in network-isolated projects | Learn: toolbox-network-isolation |
| Workflow agents | ⚠️ | Inbound private OK; outbound VNet injection not supported | Learn |
| Code Interpreter | ⚠️ | BYO VNet: no file upload/download via portal; files only via SDK-created container | Learn: virtual-networks |
| Agent tools reaching resources in your VNet (MCP, OpenAPI, Functions, A2A) | ⚠️ | Require a **project-level** capability host; otherwise `name or host unknown` | Learn |
| Azure AI Search tool | ⚠️ | Works privately; project MI needs **Search Index Data Contributor + Search Service Contributor** (Index Data Reader alone → 403 on `Indexes.Get`) | Learn: ai-search troubleshooting; observed 2026-11-18 |
| Classic Foundry portal agents with private AI Search | ❌ | Use the new Foundry portal | Learn |

## Knowledge, search and ingestion

| Feature | Status | Detail | Source |
|---|---|---|---|
| Search **indexers** pulling from private sources | ⚠️ | Must set `executionEnvironment: Private`; default multitenant execution can't traverse private endpoints → **silent failures / empty index** (incl. "Import data" wizard indexers) | Learn: configure-private-link, search-indexer-securing-resources |
| **Foundry IQ** knowledge sources with auto-generated indexers | ❌ / ⚠️ | Indexed knowledge sources and their auto-generated indexers **don't support** the private execution environment → ingestion from private data sources can fail. Knowledge base REST API is GA (`2026-10-01`); several features (Microsoft Retriever 1, knowledge graphs) are preview | Learn: configure-private-link; Ignite 2026 |
| Foundry IQ knowledge bases | ⚠️ | Require **semantic ranker** on the search service (portal blocks otherwise) | Observed 2026-11-18 |
| Agent citations that open the source document | ⚠️ | The Azure AI Search tool uses the index field named **`url`** as citation link only if that field is **searchable** (undocumented; `filepath` / `sourceUrl` are ignored). Without it the link points to the private search service root → 401. The link target must be reachable from the user's network (here: the RAG app `/docs/<id>` page). Foundry IQ citations are Search document-lookup URLs that need a token | Observed and fixed 2026-11-19 ([modules/agent-demo.md](modules/agent-demo.md)) |
| Integrated vectorization (Search → Foundry embeddings) | ⚠️ | Search MI must reach Foundry: trusted-service bypass (`AzureServices`) or shared private link | Learn |
| File search vector stores | ⚠️ | Recreate vector stores created before VNet was enabled (non-BYO) | Learn: toolbox-network-isolation |

## Platform and operations

| Feature | Status | Detail | Source |
|---|---|---|---|
| Changing outbound mode / agent subnet after creation | ❌ | Not supported; no upgrade BYO VNet → Managed VNet. Redeploy Foundry | Learn |
| Agent subnet reuse after delete | ⚠️ | Account must be **deleted and purged**; subnet link (`legionservicelink`) clears after ~20 min | Learn; observed |
| Re-creating an account with the **same name** shortly after purge | 🔍 | Private calls fail with "Traffic is not from an approved private endpoint"; a new name works | Observed; use a new environment name |
| Hosted agents in private networks | ✅ (validated live 2026-11-23) | Validated in standalone, hub-spoke and managed VNet (preview): private invoke, Foundry IQ via a project toolbox (data proxy), guardrails, Internet 403. Deployed from an in-network runner by `scripts/agents/Deploy-HostedAgentAzd.ps1` (`src/hosted-agents`); packaged as optional module 7. Managed VNet needs the managed PE rule `pe-foundry-account`; the agent identity needs Monitoring Metrics Publisher for code traces. Egress controls and shared subnet IPs GA since Ignite 2026; agent-level guardrails preview | [ADR 0003](adr/0003-hosted-agents.md), [validation summary](security/validation-summary.md) |
| `azd down` with VNet injection | ✅ (hook) | Fails on the VNet without ordering; the `predown` hook (`scripts/cleanup/predown.ps1`) deletes + purges the account and waits for the subnet link first | Observed 2026-11-17; hook added 2026-11-19 |
| Foundry portal (`ai.azure.com`) | ⚠️ | Public web app; project content only from a network that resolves the private endpoints. Not every portal feature has been validated over Private Link | Learn; observed |
| Hosted agents with private ACR | ⚠️ | Only projects created after 2026-06-25 | Learn |
| AI Gateway (APIM) created from Foundry portal | ⚠️ | Created **public**; must be network-isolated separately | Learn |
| Evaluations / tracing with Application Insights | ⚠️ | Needs AMPLS or firewall FQDNs (`*.in.applicationinsights.azure.com`, …) | Learn |
| Fine-tuning curated sample datasets | ⚠️ | Needs `raw.githubusercontent.com` | Learn |
| Managed VNet (`AllowOnlyApprovedOutbound`) | ⚠️ | Implemented as preview option and validated live; preview API only; irreversible; region subset; no customer firewall / outbound logging; on-premises only via Application Gateway | [modules/managed-vnet.md](modules/managed-vnet.md) |
| Data-plane operations from outside the network (seeding indexes, smoke tests, CI) | ⚠️ | Need a private execution path (jumpbox / hub client via Run Command, self-hosted runners) | By design |
| Deploying application code from outside the network (registry push, zip deploy) | ⚠️ | Private ACR / SCM endpoints are unreachable from a notebook or GitHub-hosted runner | By design — the RAG module pushes code over the management plane (VM Run Command); see [modules/rag-demo.md](modules/rag-demo.md). Production: self-hosted CI agents inside the network |
| Agent Azure AI Search tool with a private search service on **Basic** agent setup (no VNet injection) | ❌ | Documented: the tool can't reach a private search service without VNet injection; enabling public access doesn't guarantee it either | `ENABLE_AGENT_DEMO` requires `byoVnet` (preflight enforces) |
| Azure Monitor Private Link Scope in a **spoke** with shared hub DNS | ❌ (by design) | AMPLS registers *shared* Azure Monitor endpoints; a spoke AMPLS would redirect every workload's monitoring traffic | Standalone creates its own AMPLS; hub-spoke joins the central AMPLS (`EXISTING_AMPLS_ID`) |
| Server-side agent traces with App Insights ingestion **private-only** | ✅ (validated live) | Platform-emitted traces arrive although public ingestion is disabled — **only if the AMPLS private endpoint and DNS exist before the Foundry account is created**. Otherwise the injected agent runtime keeps using the public ingestion path, which is blocked (no traces for 12 h observed) | Default; `MONITOR_PUBLIC_INGESTION` stays `Disabled`; Bicep enforces the order (account `dependsOn` the AMPLS PE). See [modules/monitoring.md](modules/monitoring.md) |
| Viewing traces / KQL from outside the network | ❌ (by design) | Query is private-only (`PrivateLinkValidationFailedError`) | Use the jumpbox / hub workstation |
| Foundry IQ knowledge base with **LLM query planning** (`low`/`medium`) on Basic | ✅ (validated live 2026-11-19, optional) | Search → Foundry model call at query time over an approved shared private link (`openai_account`); without it 403. Needs the link approval step ([private-link-explained.md](private-link-explained.md)) | `FOUNDRY_IQ_REASONING=low` adds the shared private link + approval; default `minimal` has no outbound call. [modules/foundry-iq.md](modules/foundry-iq.md) |
| Foundry IQ private ingestion (Blob/ADLS knowledge sources with embeddings) | ⚠️ | Shared private links; documented for S2+; ingestion-time embedding still uses the Foundry trusted-service bypass (Learn) | Deferred option B |
