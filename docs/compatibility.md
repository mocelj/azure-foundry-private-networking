# Compatibility matrix and known limitations

Researched 2026-11-17 against Microsoft Learn and the live resource-provider metadata of the target
subscription; re-validated 2026-11-18/19 during Ignite 2026 (see [Ignite 2026 changes](#ignite-2026-changes-checked-2026-11-19)).
**Re-validate before each customer engagement** — Foundry networking changes often.

## Sources

| Topic | Source |
|---|---|
| Foundry network isolation (inbound/outbound, tool support, limitations) | https://learn.microsoft.com/azure/foundry/how-to/configure-private-link |
| Agent Service private networking (DNS zones, subnet rules, reserved ranges) | https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks |
| Managed virtual network | https://learn.microsoft.com/azure/foundry/how-to/managed-virtual-network |
| Bastion Entra ID authentication | https://learn.microsoft.com/azure/bastion/bastion-entra-id-authentication |
| Private endpoint DNS values | https://learn.microsoft.com/azure/private-link/private-endpoint-dns |

## Tooling and API versions

| Item | Value used | Notes |
|---|---|---|
| Bicep CLI | 0.49.x | `az bicep version` |
| azd | ≥ 1.37 | |
| `Microsoft.CognitiveServices/accounts` (+ `projects`, `deployments`, `connections`, `capabilityHosts`) | `2026-09-01` | GA `2026-11-01` and `2026-11-15-preview` are registered in the RP but Bicep 0.49.2 has **no types** for them yet (BCP081). Remaining suppressions: `authType: ProjectManagedIdentity` (BCP036), `capabilityHostKind` (BCP037). |
| `Microsoft.CognitiveServices/accounts/managedNetworks` | not used | RP lists **preview versions only** (`2026-11-15-preview` …), checked 2026-11-19. |
| `Microsoft.Search/searchServices` | `2026-11-01` (stable since Nov 2026; was `2025-05-01`) | Data plane: index/query REST `2024-07-01`; knowledge source/base GA `2026-10-01`; knowledge base MCP endpoint `2026-10-01` (GA, verified live 2026-11-19) |
| `Microsoft.DocumentDB/databaseAccounts` | `2025-04-15` | |
| `Microsoft.Storage/storageAccounts` | `2025-01-01` | |
| `Microsoft.Insights/components` / `privateLinkScopes` | `2020-02-02` / `2021-07-01-preview` | AMPLS has no newer GA API |
| `Microsoft.Network/*` | `2025-05-01` | Private DNS: `2024-06-01` |
| `Microsoft.Compute/virtualMachines` | `2025-04-01` | |
| `Microsoft.OperationalInsights/workspaces` | `2025-07-01` | |
| `Microsoft.Authorization/roleAssignments` | `2022-04-01` | |

## Core capability matrix (default profile)

| Capability | Private? | How | Status |
|---|---|---|---|
| Foundry account management (ARM) | n/a — management plane | `management.azure.com`, Entra + Azure RBAC. Private Link for Azure Resource Manager exists but is uncommon and **not in scope of this template**: a tenant-wide decision (root management group only), breaks Azure Bastion (`privatelink.azure.com` overlaps `management.azure.com`), not supported for AKS or multi-tenant accounts, needs Owner/Contributor at the root management group ([Learn](https://learn.microsoft.com/azure/azure-resource-manager/management/create-private-link-access-portal)) | GA |
| Foundry project API `https://<acct>.services.ai.azure.com/api/projects/<p>` | **Yes** | PE `account` + `privatelink.services.ai.azure.com` | GA |
| OpenAI-compatible inference `https://<acct>.openai.azure.com/openai/v1/...` | **Yes** | PE `account` + `privatelink.openai.azure.com` | GA |
| Foundry Tools endpoint `https://<acct>.cognitiveservices.azure.com` | **Yes** | PE `account` + `privatelink.cognitiveservices.azure.com` | GA |
| Key-based auth | **Disabled** | `disableLocalAuth: true` | GA |
| Foundry portal UI (`ai.azure.com`) | **Partially** | Static web app is public; its data-plane calls hit the account FQDNs and therefore only work from a network that resolves them privately (jumpbox / hub) | GA, feature-dependent |
| Model deployment (`DataZoneStandard`, `GlobalStandard`) | Inbound private | Inference processed in Microsoft data zone / globally; no customer egress | GA |
| Diagnostic logs → Log Analytics | Ingestion over Azure backbone (resource logs) | Querying is public unless AMPLS is added (optional advanced monitoring) | GA |

## Optional and agent capability matrix

| Capability | Fully private supported? | Notes / blockers |
|---|---|---|
| Azure AI Search (Basic+) with PE, PNA disabled | Yes — **validated live** | Optional module 1. Indexers that pull through PEs need `executionEnvironment: Private`; Foundry → Search requires trusted-service bypass or shared private link. |
| Agents (prompt) — **BYO VNet injection + Standard agent setup (default, `byoVnet`)** | Yes — **validated live** | Core. Injection must be set **at account creation**; `snet-agent` `/24` delegated exclusively to `Microsoft.App/environments`, one account per subnet; project capability host `Agents` with BYO Cosmos DB (threads), Storage (files) and AI Search (vectors), each behind a private endpoint, so agent state stays in the customer tenant. Egress requires Entra ID. Reference: templates `15-private-network-standard-agent-setup` / `19-private-network-agent-tools`. |
| Agents — Basic setup (platform-managed state) | Not offered | Agent state would live in Microsoft-managed storage outside the customer tenant; this repo always uses Standard setup with `byoVnet`. `none` = models only, no agents. |
| Agents with **Managed VNet** — option 2 | Yes — **validated live (preview)** | `OUTBOUND_NETWORK_MODE=managedVnet` + `MANAGED_VNET_PREVIEW_ACK=true`. `accounts/managedNetworks@2026-09-15-preview` (preview-only), `AllowOnlyApprovedOutbound`, no FQDN rules; irreversible; region subset; no egress logging. [modules/managed-vnet.md](modules/managed-vnet.md) |
| Foundry IQ knowledge base over a private index (option A, `minimal` reasoning) | Yes — **validated live** | Optional module 6. Agent → MCP endpoint via the knowledge search PE (RemoteTool connection, project MI). LLM query planning (A+, `FOUNDRY_IQ_REASONING=low|medium`) is an optional, validated extension over an approved shared private link; private ingestion (B) is deferred, see [modules/foundry-iq.md](modules/foundry-iq.md). Indexed knowledge sources with auto-generated indexers **don't support** the private execution environment. |
| Bing grounding / Web search / SharePoint grounding | **No** (public endpoint) | Excluded from the private profile. |
| Workflow agents | Inbound only | Outbound VNet injection not supported. |
| Browser automation, Computer use, Image generation tools, Logic Apps, Fabric Data Agent | **No** | Not supported in network-isolated Foundry. |
| Code Interpreter | Partial | BYO-VNet: no file upload/download via portal. |
| Hosted agents (BYO VNet: standalone, hub-spoke; managed VNet **preview**) | Yes — **validated live** (2026-11-23) | Source-code deploy (`remote_build`, no registry) with azd from an in-network runner (`scripts/agents/Deploy-HostedAgentAzd.ps1`, `src/hosted-agents`); Foundry IQ via a project toolbox; guardrails at deployment and agent level (agent level **preview**). Managed VNet needs the managed PE rule `pe-foundry-account`. Optional module 7 (`ENABLE_HOSTED_AGENT_DEMO`, [modules/hosted-agent-demo.md](modules/hosted-agent-demo.md)): requires Foundry IQ and a private client (jumpbox / `PRIVATE_CLIENT_VM_ID`); not spoke-ready / public. Agent code sets loop limits (`agent-framework-core` ≥ 1.25: `max_iterations`, `max_function_calls`, `max_duration_seconds`). Module validated live 2026-11-24 (standalone, 103/103) |
| Hosted agents with private ACR | Yes for projects created after 2026-06-25 | Not used (source-code deployment without a registry) |
| AI Gateway (APIM) created from Foundry portal | **No** (public by default) | Must be network-isolated separately. |

## Ignite 2026 changes (checked 2026-11-19)

| Change | Status | Impact on this repo |
|---|---|---|
| Hosted agents: network egress controls and shared subnet IPs | GA | Hosted agents validated live in A, B, F (2026-11-23, [module doc](modules/hosted-agent-demo.md)): same injection, own egress through the delegated subnet, source-code deployment without a registry; egress controls not configured |
| Hosted agents: Azure Policy egress governance, private CA trust; browser automation to private VNets | Preview | Not used; browser automation stays excluded from the private profile |
| Capability settings (`how-to/configure-capability-settings`, ARM `2026-07-15-preview`), provisioned with the **caller** identity | Preview | Possible future replacement of the project capability host; needs Storage Blob Data Contributor + Cosmos DB Operator for the caller on the BYO resources. Not adopted while preview |
| Knowledge base MCP endpoint `api-version=2026-10-01` | GA (Search REST) | **Adopted 2026-11-19** (`mcpApiVersion`); Learn samples still show `2026-11-01-preview` |
| Microsoft Retriever 1 (parameterless query-planning model) | Preview (`2026-11-01-preview`) | Not needed: Foundry IQ A+ with `gpt-5.4-mini` works privately on Basic over a shared private link (validated 2026-11-19) |
| `Microsoft.CognitiveServices` GA API `2026-11-01` | GA | Not adopted until Bicep types exist |
| Managed VNet (`accounts/managedNetworks`) | Still preview-only in the RP (Learn page shows `2026-05-01`, which isn't registered) | Implemented as an explicit preview option (2026-11-19) on `2026-09-15-preview` (newest with Bicep types) |
| Azure AI Gateway (`Microsoft.ApiManagement/aigateways`, API `2026-11-01`) | GA (resource); **inbound private endpoint preview, access request** | Not implemented |
| Microsoft `foundry-samples` GitHub repository | Returns HTTP 404 although Learn links it | Templates 11/15/18/19 can't be re-diffed |

## Network constraints

- Foundry account, private endpoint and VNet must be in the **same region**.
- Do not use `172.17.0.0/16` (Docker bridge). For agent-injected VNets also avoid
  `169.254.0.0/16`, `172.30.0.0/16`, `172.31.0.0/16`, `192.0.2.0/24`, `100.100.0.0/17`,
  `100.100.192.0/19`, `100.100.224.0/19`, and keep PE addresses out of `192.168.0.0/24`.
  The preflight script enforces these.
- Private endpoint connections must be **Approved**; same-subscription Bicep deployment auto-approves.
- Custom DNS servers must forward the `privatelink.*` zones (or the public zones) to
  `168.63.129.16` from a resolver that can see the zones.
- New subnets are created with `defaultOutboundAccess: false`; any egress is explicit (NAT
  gateway in standalone, hub firewall via UDR in hub mode).
- Agent subnet: must be delegated **only** to `Microsoft.App/environments`, used by a single
  Foundry account, and can't be changed after account creation. After deleting the account,
  **purge** it and wait up to ~20 minutes before reusing the subnet.
- Agent subnet egress (firewall/NSG) must allow Entra ID: `login.microsoftonline.com`,
  `{region}.login.microsoft.com`, `control-{region}.identity.azure.net` (or the
  `AzureActiveDirectory` service tag), plus the Container Apps managed-identity endpoints.
  Entra ID has no private endpoint: token traffic goes to the public Entra endpoints over the
  Microsoft backbone and carries no customer data. VM managed identities use IMDS (host-local, no
  egress); platform identities get their tokens inside the service.
- Required providers for injection: `Microsoft.App` **and** `Microsoft.ContainerService`
  (failure otherwise leaves the account in `Failed`, requiring purge). Preflight checks both.

## Bastion / jumpbox

| Item | Decision |
|---|---|
| Bastion SKU | Standard (portal Entra RDP needs Basic+; native client & tunnelling need Standard) |
| Bastion public IP | Required by Standard SKU for its managed HTTPS ingress — documented exception |
| Jumpbox auth | Entra ID (`AADLoginForWindows`) + RBAC `Virtual Machine User Login` (non-admin, assigned on the VM by `infra/modules/jumpbox/jumpbox.bicep`) + `Reader` on the VM, its NIC and the Bastion resource (required by Bastion to connect); the template never assigns `Virtual Machine Administrator Login` |
| Entra RDP limitations | Not with graphical session recording; native client requires an Entra-registered/joined Windows device |
| Jumpbox egress | NAT gateway (outbound only, HTTPS only via NSG) — required for Entra sign-in and portal UI |

## Model (validated region: Sweden Central)

| Parameter | Default | Validated |
|---|---|---|
| Model | `gpt-5.4-mini` | GA in `swedencentral` |
| Version | `2026-03-17` | Retires 2027-09-21 (no replacement listed yet): plan a model update before then |
| Deployment type | `DataZoneStandard` | EU data zone; quota 1000 TPM-K available |
| Capacity | `10` (thousand TPM) | |

The preflight script checks model, version, SKU and remaining quota for the selected region
before `azd provision` and fails with an actionable message.

## Reference templates

The numbered templates (`10-`, `11-`, `15-`, `18-`, `19-`…) are Microsoft's official Foundry infrastructure samples in the GitHub repository [microsoft-foundry/foundry-samples](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep), linked from Learn: [Networking options for Foundry Agent Service](https://learn.microsoft.com/azure/foundry/agents/concepts/networking-options#networking-options-by-scenario) and [Set up private networking (templates)](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks#configure-a-network-secured-environment). This repo's core design was compared against templates 11 and 15 on 2026-11-17 (README, `main.bicep` and `modules-network-secured/*`); the code here is an independent implementation, not a copy. Note (2026-11-18): the GitHub repository returned HTTP 404 (also unauthenticated) although Learn still links it; it may have been moved or temporarily restricted.
