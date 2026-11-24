# Identity and RBAC

All data-plane access uses **Microsoft Entra ID**. Key/local authentication is disabled on the
Foundry account, Cosmos DB, AI Search, Storage (shared key) and Log Analytics. No API keys are
created, listed, output or stored.

## Identities

| # | Identity | Type | Purpose |
|---|---|---|---|
| 1 | **Deployer** (`azd` user or CI service principal) | User / SP (OIDC federated in CI) | Deployment-time only: creates resources and role assignments |
| 2 | **Foundry project MI** | System-assigned | Agent runtime identity: provisions and uses BYO Cosmos DB / Storage / AI Search |
| 3 | **Foundry account MI** | System-assigned | No roles in the BYO VNet profiles. Managed VNet (option F): *Azure AI Enterprise Network Connection Approver* on the resource group, so the managed network can create and approve its private endpoints |
| 4 | **Validation client MI** | System-assigned | Jumpbox MI (standalone), or the existing private client given by `PRIVATE_CLIENT_PRINCIPAL_ID` / `PRIVATE_CLIENT_VM_ID` (hub-spoke, e.g. a hub workstation). Runs the in-VNet tests and postprovision hooks (seeding, demo agents). Disable with `GRANT_JUMPBOX_VALIDATION_ROLES=false` |
| 5 | **Human admin / demo user** (`AZURE_PRINCIPAL_ID`) | User or group | Build/run in the project, invoke models, sign in to the jumpbox |
| 6 | **Search / knowledge retrieval** | Search service system MI | Created with AI Search; used by optional indexer/Foundry IQ modules (no roles in core) |
| 6b | **RAG VM MI** | System-assigned | Optional RAG demo app: retrieval + inference, read-only on search |
| 6c | **Runner MI** (hosted agents) | System-assigned (jumpbox / hub workstation) | In-network `azd` runner that deploys the hosted agent and toolbox (`scripts/agents/Deploy-HostedAgentAzd.ps1`) |
| 6d | **Agent identity** (hosted agents) | Platform-created Entra agent identity | Runtime identity of the hosted agent code; stable across versions |
| 7 | **Monitoring** | none | Diagnostic settings are ARM-managed; no identity or keys required |

## RBAC matrix (deployed by `azd provision`)

| Identity | Scope | Role (ID) | Purpose / required permissions |
|---|---|---|---|
| Human user | Foundry **project** | Foundry User (`53ca6127-db72-4b80-b1b0-d745d6d5456d`) | Create/run agents, read project; data actions `Microsoft.CognitiveServices/*` limited to the project |
| Human user | Foundry **account** | Cognitive Services OpenAI User (`5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`) | Inference on account endpoints (`/openai/v1/...`); no management rights |
| Human user | Jumpbox VM | Virtual Machine User Login (`fb879df8-f326-4884-b1cf-06f3ad86be52`) | Entra RDP sign-in **without** local admin |
| Human user | Jumpbox VM, its NIC, Bastion | Reader (`acdd72a7-3385-48ef-bd42-f606fba81ae7`) | Required to connect through Azure Bastion ([Bastion FAQ](https://learn.microsoft.com/azure/bastion/bastion-faq)); assigned by `jumpbox.bicep` / `bastion.bicep`. Bastion and jumpbox share the VNet, so no VNet Reader is needed. Hub-spoke: the customer's hub Bastion needs the same Reader roles (+ Reader on the VNet if Bastion is in a peered VNet) |
| Validation client MI | Foundry account | Cognitive Services OpenAI User | In-VNet inference test |
| Validation client MI | Foundry project | Foundry User | In-VNet project API + agent test; creates the demo agents |
| Project MI | Storage account | Storage Blob Data Contributor (`ba92f5b4-…`) | Provision agent containers (before capability host) |
| Project MI | Storage account | Storage Blob Data Owner (`b7e6dc6d-…`) **with ABAC condition** | Only containers named `<projectWorkspaceId>*-azureml-agent` |
| Project MI | Cosmos DB account | Cosmos DB Operator (`230815da-…`) | Provision `enterprise_memory` database (before capability host) |
| Project MI | Cosmos DB `dbs/enterprise_memory` | Cosmos DB Built-in Data Contributor (SQL RBAC `…0002`) | Read/write threads in its own database only |
| Project MI | AI Search | Search Index Data Contributor (`8ebe5a00-…`) | Vector store data |
| Project MI | AI Search | Search Service Contributor (`7ca78c08-…`) | Create/manage agent vector indexes |
| Project MI | Knowledge AI Search (optional module) | Search Index Data Contributor + Search Service Contributor | Agent Azure AI Search tool — documented requirement; Index Data Reader alone fails (403 on `Indexes.Get`). Keys disabled on the service, so admin-key retrieval is not usable |
| Demo user | Knowledge AI Search | Search Index Data Reader | Query the knowledge index |
| Validation client MI | Knowledge AI Search | Search Service Contributor + Search Index Data Contributor | Seed the sample index and the Foundry IQ knowledge source/base from inside the network |
| RAG VM MI (optional module 3) | Foundry account | Cognitive Services OpenAI User | Model inference for the RAG app |
| Project MI (optional module 5) | Application Insights | Monitoring Metrics Publisher (`3913510d-…`) | Entra-authenticated **server-side agent trace** ingestion (local auth disabled on App Insights) |
| Demo user (optional module 5) | Application Insights + Log Analytics workspace | Log Analytics Reader (`73c42c96-…`) | View traces in the Foundry portal, run saved queries |
| Validation client MI (module 5) | Application Insights + Log Analytics workspace | Log Analytics Reader | Prove traces are stored and resource logs still arrive (query over AMPLS) |
| RAG VM MI (optional module 3) | Knowledge AI Search | Search Index Data Reader | Retrieval only (read-only) — validated live that it has no other assignments |
| Knowledge search MI (module 6, `FOUNDRY_IQ_REASONING=low\|medium`) | Foundry **account** | Cognitive Services OpenAI User | Knowledge base LLM query planning (documented: on the parent resource, not project/deployment) |
| Deployer (module 6 with query planning) | Foundry account | approval of the pending shared private link (`…/privateEndpointConnectionsApproval/action`, included in Owner / Contributor) | Owner consent for Search's outbound link; `FOUNDRY_IQ_AUTO_APPROVE=false` hands it to the account owner |
| Account MI (managed VNet, option F) | Resource group | Azure AI Enterprise Network Connection Approver (`b556d68e-…`) | Create **and approve** the managed network's private endpoints to the Standard setup resources, the knowledge search, AMPLS and the account itself (Learn requirement; `infra/modules/foundry/managed-network.bicep`) |

## Hosted-agent roles (granted by `scripts/agents/Deploy-HostedAgentAzd.ps1`, not by Bicep; with module 7 `ENABLE_HOSTED_AGENT_DEMO` the postprovision hook runs it)

| Identity | Scope | Role (ID) | Purpose |
|---|---|---|---|
| Runner MI (jumpbox / hub workstation) | Foundry **project** | Foundry Project Manager (`eadc314b-…`) | `azd deploy` of the toolbox and hosted agent; create role assignments for the agent identity |
| Agent identity | Application Insights | Monitoring Metrics Publisher (`3913510d-…`) | Code-emitted traces with Entra-only ingestion ([Learn](https://learn.microsoft.com/azure/foundry/observability/how-to/trace-ingestion-entra-authentication#set-up-entra-authentication-for-hosted-agent-traces)) |

The agent identity gets **no** data-plane role for tools: the toolbox calls the knowledge base with its
connection's credential (project MI). Direct MCP calls from agent code would need Search Index Data Reader.

## Scoped management-role exceptions

Workload identities otherwise hold only data-plane roles. Two management roles are required and are
scoped to a single resource:

| Role | Holder and scope | Why it is needed |
|---|---|---|
| Cosmos DB Operator | Project MI on the agent Cosmos DB account | Standard setup provisions the `enterprise_memory` database before the capability host; data access itself comes from the SQL data role at database scope |
| Search Service Contributor | Project MI on the agent and knowledge search services; validation client MI on the knowledge search | Create and manage indexes (agent vector store, Azure AI Search tool, seeding); documented requirement of the Azure AI Search tool |

Never assigned by this repository: **Owner, Contributor, User Access Administrator, Role Based
Access Control Administrator** (enforced by `tests/security/StaticSecurity.Tests.ps1` and
`scripts/validation/Test-Deployment.ps1`).

## Deployment-time vs runtime permissions

| Phase | Who | Minimum permissions |
|---|---|---|
| Deploy | Deployer | `Contributor` + `Role Based Access Control Administrator` (or `Owner`) on the subscription (RG is created by azd). Hub-side peering additionally needs `Network Contributor` on the hub VNet. Existing central DNS zones need `Private DNS Zone Contributor` on those zones. |
| Runtime | Project MI, validation client MI, users | Only the data-plane roles above (plus the two scoped management-role exceptions). No other control-plane write access. |

For CI, use a federated (OIDC) service principal; no client secrets. The included workflow
(`.github/workflows/ci.yml`) is offline only (build, lint, Pester) and needs no Azure credentials.

## Least-privilege notes

- Role names follow the current Foundry built-in roles: **Foundry User**, **Foundry Project Manager**,
  **Foundry Account Owner** and **Foundry Owner** were formerly named Azure AI User, Azure AI Project
  Manager, Azure AI Account Owner and Azure AI Owner; role IDs are unchanged
  ([Learn](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)). The Bicep uses role IDs.
- The demo user gets `Foundry User` on the **project**, not the account, so additional projects are
  not automatically accessible.
- To give a user agent *runtime* access only (no authoring), use **Foundry Agent Consumer** or
  **Foundry Project Runtime User** instead of Foundry User.
- To grant a group instead of a single user: `azd env set AZURE_PRINCIPAL_ID <groupObjectId>` and
  `azd env set AZURE_PRINCIPAL_TYPE Group`.
- Remove the validation identity's roles after acceptance testing:
  `azd env set GRANT_JUMPBOX_VALIDATION_ROLES false && azd provision`.
