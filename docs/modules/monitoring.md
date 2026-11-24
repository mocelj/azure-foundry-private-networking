# Optional module 5 — Advanced monitoring and agent tracing

Enable:

```powershell
azd env set ENABLE_ADVANCED_MONITORING true
azd env set MONITOR_ALERT_EMAIL ops@contoso.com   # optional
# hub-spoke only: join the central (hub-owned) Azure Monitor Private Link Scope
azd env set EXISTING_AMPLS_ID /subscriptions/<sub>/resourceGroups/<hub-rg>/providers/Microsoft.Insights/privateLinkScopes/<ampls>
azd provision
```

## What it deploys

| # | Component | Configuration |
|---|---|---|
| 1 | Application Insights `appi-<token>` | Workspace-based (existing Log Analytics workspace). `DisableLocalAuth: true`: **Entra-only ingestion**; instrumentation keys are rejected |
| 2 | Project connection `agent-traces` | Category `AppInsights`, `authType: ProjectManagedIdentity`. This turns on **server-side tracing** for every agent in the project, with no code changes |
| 3 | RBAC | Project MI → **Monitoring Metrics Publisher** on App Insights (writes server-side traces). Hosted agents: the **agent identity** → Monitoring Metrics Publisher too (code-emitted traces; granted by `Deploy-HostedAgentAzd.ps1`). Demo user → **Log Analytics Reader** on App Insights + workspace (views traces). Jumpbox MI (validation client) → Log Analytics Reader |
| 4 | Azure Monitor Private Link Scope `ampls-<token>` (**standalone only**) | Scopes the workspace + App Insights. Access modes **PrivateOnly** for ingestion **and** query. Private endpoint `pe-ampls-<token>` (group `azuremonitor`) + zones `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net`, `privatelink.blob.core.windows.net` |
| 5 | Public access on App Insights + workspace | `publicNetworkAccessForQuery: Disabled`; `publicNetworkAccessForIngestion: Disabled` (`MONITOR_PUBLIC_INGESTION`) whenever a private path (own or central AMPLS) exists |
| 6 | Alerts | **Security drift**: activity-log alert on writes/deletes of the Foundry account, Search, Storage, Cosmos DB, private endpoints, NSG rules and the AMPLS (e.g. someone enabling public access). `azd provision` also triggers it, which is expected. **Reliability**: Foundry `ServerErrors` > 5 / 15 min. **Responsible AI**: `RAIRejectedRequests` > 0. Optional e-mail action group |
| 7 | Query pack `qp-<env>` | Agent runs, tool calls, token usage by model, failed agent operations, blocked/failed Foundry requests |

## How agent traces flow

```text
Agent run (Foundry Agent Service, VNet-injected runtime)
  └─ server-side OpenTelemetry spans (GenAI semantic conventions), Entra token of the project MI
       └─► Application Insights appi-<token> (local auth disabled, ingestion PrivateOnly)
             └─ stored in Log Analytics: AppDependencies (spans), genAIContent (message content)
Viewing (Foundry portal "Traces", KQL) ─► api.loganalytics.io ─► AMPLS private endpoint (jumpbox/hub only)
```

Observed span tree for one `contoso-policy-agent` run:

| Span (`name`) | `gen_ai.operation.name` | Notes |
|---|---|---|
| `invoke_agent contoso-policy-agent:1` | `invoke_agent` | `gen_ai.agent.name`, `gen_ai.agent.version`, response id |
| `execute_tool remote_functions.azure_ai_search` | `execute_tool` | Private knowledge search tool call |
| `chat gpt-5.4-mini-2026-03-17` | `chat` | `gen_ai.request.model`, `gen_ai.usage.input_tokens` / `output_tokens` |

Queries scoped to the **App Insights resource** use the classic schema (`dependencies`,
`customDimensions`). Queries on the **workspace** use `AppDependencies` / `Properties`.

### Live finding: private-only ingestion works, but only with the right deployment order

Before testing, it was unclear whether platform-emitted server-side traces would reach an App
Insights resource with **public ingestion disabled and AMPLS ingestion PrivateOnly**. Two deployments
answer it:

| Deployment | Order | Result |
|---|---|---|
| 2026-11-18: module added to a running environment | Monitor PE + DNS existed **before** tracing started | Traces stored |
| 2026-11-18/19: from scratch | Foundry account (VNet-injected agent runtime) created **in parallel with / before** the monitor PE + DNS records | **No traces for 12 h**, although connection, roles and network settings were identical |

Root-cause investigation (2026-11-19, controlled experiment):

1. Re-creating the trace connection: no effect (not an RBAC propagation race).
2. Temporarily enabling **public ingestion only** (query private, local auth off): traces arrived within 150 s.
3. Disabling it again: traces **kept arriving** 2 min and 48 min later, with public ingestion disabled.

The trace path itself is therefore private (agent runtime in our VNet → AMPLS private endpoint).
In the from-scratch deployment the runtime had resolved the ingestion endpoint
(`<region>-0.in.applicationinsights.azure.com`) **before** the `privatelink.monitor.azure.com` records
existed, got the public IP, and stayed on that rejected path. The brief opening let that stuck path
drain; afterwards the runtime used the private one.

**Fix (in code):** in standalone mode the Foundry account `dependsOn` the AMPLS private endpoint, so
Log Analytics → App Insights → AMPLS → PE + DNS exist before the agent runtime starts. A static test
(`Deployment ordering`) guards it. **Validated:** fresh deployment (no manual steps)
stores traces with public ingestion disabled. Hub-spoke isn't affected: the central AMPLS and DNS exist
before the spoke. `MONITOR_PUBLIC_INGESTION=Enabled` remains only as a documented escape hatch.

Microsoft's network-isolation guidance lists `*.in.applicationinsights.azure.com` among the outbound
destinations for "Evaluations & Traces" (i.e. the public, Entra-authenticated ingestion endpoint).
This repo keeps ingestion private instead and validates that it works.

### Privacy: trace content

Server-side tracing also writes **message content** (prompts, tool inputs/outputs, responses) to the
`genAIContent` table. It is protected by private-only query + Log Analytics RBAC and retained for
`LOG_RETENTION_DAYS` (default 30). Treat the workspace as containing business data: restrict
readers, and align retention with policy (e.g. Contoso pol-002 "logged for 30 days").

## Why AMPLS is standalone-only (hub-spoke caveat)

Azure Monitor uses **shared global endpoints** (`api.loganalytics.io`,
`<region>.in.applicationinsights.azure.com`, …). An AMPLS private endpoint registers those shared
names in the private DNS zones. In hub-spoke, the hub DNS serves every spoke, so a spoke-owned
AMPLS would redirect **all** Azure Monitor traffic in the company to a scope that only knows this
workload's resources, which breaks everyone else's monitoring. Microsoft's guidance is **one AMPLS
per DNS/network**.

| Mode | Behaviour |
|---|---|
| standalone | Creates its own AMPLS + PE + zones (its DNS is isolated) |
| hub-spoke + `EXISTING_AMPLS_ID` | Adds the workspace + App Insights to the **central** AMPLS as scoped resources. No PE, no DNS records in the spoke |
| hub-spoke without it / spoke-ready | No AMPLS. Public endpoints stay enabled (still Entra-only); preflight warns |

## Validation

| Layer | Checks |
|---|---|
| Static (`rag` profile) | App Insights local auth off + workspace-based; one AppInsights connection with `ProjectManagedIdentity`; project MI has Monitoring Metrics Publisher; standalone AMPLS PrivateOnly/PrivateOnly + `azuremonitor` PE + public access disabled; hub/spoke-ready never create an AMPLS; drift alert watches `accounts/write` |
| Live network | App Insights + workspace public query disabled; AMPLS PrivateOnly; both resources scoped; monitor DNS zone records point into the PE subnet |
| Live identity | Project MI Monitoring Metrics Publisher |
| Live public negative | Trace query from the internet → `403 PrivateLinkValidationFailedError: only permitted through a Private Link` |
| Live in-VNet | `api.loganalytics.io` resolves to the AMPLS PE; **server-side spans for the demo agent are stored** (`invoke_agent` + `execute_tool …azure_ai_search`); Foundry resource logs still arrive in the workspace |

## Viewing traces

Bastion → jumpbox → Foundry portal → project → **Agents → Traces** (or **Monitor**). Or open the
query pack in Log Analytics (portal from the jumpbox). From a notebook outside the network the
portal shows the trace list as inaccessible, by design.

## Gotchas found while implementing

| Error | Cause / fix |
|---|---|
| `AuthType for AppInsights Connection can only be ProjectManagedIdentity, ApiKey` | Not `AAD`. `ProjectManagedIdentity` is not in the published Bicep type yet (`#disable-next-line BCP036`) |
| `Required metadata property ApplicationInsightsConnectionString is missing` | Needed even with MI auth. Read via `existing` reference inside the module and never output. The iKey is not a credential when local auth is disabled |
| KQL `SemanticError` on `AppDependencies` | Resource-centric queries on the component use the classic schema (`dependencies`) |
