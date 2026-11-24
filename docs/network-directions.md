# Network directions: inbound vs. outbound and private connectivity

Conceptual background for the private networking in this repo. For the mechanics of private
endpoints, shared private links and approvals see [private-link-explained.md](private-link-explained.md)
(with diagram); for DNS see [private-dns.md](private-dns.md).

## Inbound vs. outbound: who starts the connection

Inbound and outbound always depend on which service you look at:

- **Inbound to X:** someone else connects to X.
- **Outbound from X:** X connects to someone else.

The same connection is outbound for the caller and inbound for the target:

```text
   Indexer reads documents
   AI Search  ───────────────────►  Storage
   (outbound from Search)           (inbound to Storage)
```

Each side needs its own control:

| Side | Controls | Typical setting |
|---|---|---|
| Inbound (protect the target) | Who may reach me | Private endpoint, public network access disabled, firewall/IP rules |
| Outbound (control the caller) | How I reach others | Shared private link, VNet injection, firewall routing |

## Connections in this repo (Foundry + AI Search + Storage)

Resource names are from `infra/main.bicep` (`<token>` = per-environment resource token).
**Implemented** = deployed by default when the module/mode is enabled; **optional** = behind a
switch; **context only** = explained, not deployed by this template.

| Connection | Started by | Caller's view | Target's view | Mechanism | In this repo |
|---|---|---|---|---|---|
| Jumpbox / hub workstation / RAG VM → knowledge AI Search `srch-kb-<token>` | Client | Outbound from client | Inbound to Search | Search private endpoint (`searchService`, zone `privatelink.search.windows.net`) | **Implemented** (module 1) |
| Client → Foundry `aif-<token>` | Client | Outbound from client | Inbound to Foundry | Foundry private endpoint (`account`; zones `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com`), public network access disabled | **Implemented** (core) |
| Foundry agent runtime → agent AI Search `srch-agent-<token>`, Cosmos DB `cosmos-agent-<token>`, Storage `stagent<token>`, knowledge search, MCP endpoint | Foundry Agent Service | Outbound from Foundry | Inbound to those resources | Agent VNet injection (BYO subnet `snet-agent`, delegated to `Microsoft.App/environments`) → the resources' private endpoints (`searchService`, `Sql`, `blob`) | **Implemented** (core with `byoVnet`; knowledge search with modules 4/6) |
| AI Search → Foundry model (knowledge base query planning) | Search | Outbound from Search | Inbound to Foundry | Search **shared private link** `spl-foundry-openai` (group ID `openai_account`), approved on the Foundry account | **Optional**: `FOUNDRY_IQ_REASONING=low\|medium` (validated live 2026-11-19). Default `minimal` creates **no** shared private link |
| AI Search → Foundry (embedding skill, vectorizer, GenAI prompt skill) | Search | Outbound from Search | Inbound to Foundry | Shared private link (`openai_account`, `cognitiveservices_account` or `foundry_account`) | **Context only**: the sample index has no vectors and no skillset |
| AI Search → Storage (indexer, knowledge source ingestion) | Search | Outbound from Search | Inbound to Storage | Shared private link (`blob`, plus `dfs` for ADLS Gen2), approved on Storage | **Context only**: the sample index is **pushed** by a private client through the inbound Search endpoint; there is no indexer and no customer document storage |

Both AI Search services in this repo default to **Basic** (knowledge search: `AI_SEARCH_SKU`; agent vector
store: `AGENT_SEARCH_SKU`). All live validations used Basic.

## Terminology

- **Azure Private Link:** the platform technology. You don't deploy it directly.
- **Private endpoint:** a network interface with a private IP in your subnet that connects to one
  specific resource sub-resource. It secures **inbound** access to that resource. In this repo:
  Foundry `account`, Storage `blob`, Cosmos DB `Sql`, the two Search services `searchService`, and
  (monitoring module, standalone) `azuremonitor` for the AMPLS.
- **Private DNS zone** (e.g. `privatelink.services.ai.azure.com`): resolves the normal service name to
  the private endpoint's IP. Standalone creates the zones and links them to the VNet; hub-spoke uses the
  customer's central zones.
- **Public network access = Disabled:** a setting on the target. A private endpoint adds a private
  path but doesn't remove the public one; this setting does. Set on every data plane in this repo.
- **AI Search shared private link:** a private endpoint that AI Search creates and manages from its own
  Microsoft-managed network to your resource. It secures Search's **outbound** calls. The target
  resource's owner must approve it ([why](private-link-explained.md#2-shared-private-link-outbound-from-ai-search--needs-explicit-approval)).
  Learn: "a premium feature billed by usage" (Private Link pricing).
- **Private Link service:** a different feature, used to expose your own application behind a Standard
  Load Balancer. It isn't needed for these PaaS connections and isn't used here.

## Common misunderstandings

- A private endpoint on Search doesn't make Search's own calls private; those need a shared private link.
- Foundry VNet injection controls the agent runtime's outbound calls only. It doesn't block inbound
  public access to Foundry; disabling public network access does.
- A fully private path needs both ends configured: the caller's outbound route and the target's inbound
  restriction. If either is missing, traffic either goes public or is refused. Example from this repo:
  with `FOUNDRY_IQ_REASONING=low`, no shared private link and the Foundry trusted-service exception
  disabled, Search's model call fails with `403 … Public access is disabled` (observed 2026-11-19).
- A Foundry agent calling Search uses Search's **inbound** private endpoint (through the injected agent
  subnet). Search shared private links only cover connections that Search starts.

## AI Search shared private link notes

Source: [Make outbound connections through a shared private link](https://learn.microsoft.com/azure/search/search-indexer-howto-access-private) (checked 2026-11-19).

- If Storage has a private endpoint and public access disabled, Search needs its own shared private
  link; otherwise Storage refuses the indexer's connection. Create one shared private link per storage
  sub-resource (`blob`, `dfs`, …). For same-region Storage **without** a private endpoint, Learn notes
  the connection already uses the Microsoft backbone and a shared private link is redundant.
- Tier requirements (outbound shared private links):

  | Workload | Tier | Other conditions |
  |---|---|---|
  | Indexers without skillsets | Basic and above | — |
  | Embedding skills (integrated vectorization) | Basic and above | High-capacity regions; service created after 3 April 2024 |
  | Other built-in or custom skills | S1 and above | Service created after 3 April 2024 |
  | Knowledge bases calling Azure OpenAI (query planning) | Basic and above | — (used by this repo's optional query planning) |
  | Managed knowledge-source private ingestion (Blob, ADLS Gen2, SQL) | S2, S3, L1, L2 per Learn's knowledge-source matrix | See [private-link-explained.md](private-link-explained.md#4-what-this-means-for-foundry-iq-knowledge-sources) |

  Not supported on S3 HD or Serverless.
- Shared private links to Foundry for skill billing require managed identity (keyless) in the skillset.
- Alternative for some scenarios: the "trusted Microsoft services" exception on the target with managed
  identity. It's less explicit and less isolated than a shared private link; Learn: it "isn't equivalent
  to a Private Link connection". Learn still documents it as required for Foundry IQ **ingestion-time**
  embedding calls.

**Analogy:** inbound is the lock on your own front door; outbound is the private road you take to visit
someone else. A good lock doesn't decide which road you drive on.
