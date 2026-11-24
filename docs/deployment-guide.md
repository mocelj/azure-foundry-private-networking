# Deployment guide

Operator reference for every deployment mode and optional module. For a narrated, step-by-step first
deployment see [walkthrough.md](walkthrough.md); for names see [naming-conventions.md](naming-conventions.md).

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| Tools | Azure CLI ≥ 2.70, Bicep ≥ 0.49, `azd` ≥ 1.37, PowerShell 7.4 (`pwsh`). Python is not needed locally (only for regenerating the draw.io diagram) |
| Permissions | Subscription **Owner**, or **Contributor + Role Based Access Control Administrator**. Hub-spoke extras: *Network Contributor* on the hub VNet (only if `ENABLE_HUB_SIDE_PEERING=true`), *Private DNS Zone Contributor* on the central zones, write on the central AMPLS (module 5) |
| Region | Foundry Agent Service with BYO VNet + model quota. Validated: **swedencentral** |
| Providers | Checked (and reported) by preflight: CognitiveServices, App, ContainerService, Network, Compute, Storage, DocumentDB, Search, OperationalInsights, Insights, DevTestLab |

## 2. Choose a mode

| Goal | Mode | Profile | Environment name |
|---|---|---|---|
| Self-contained demo / PoC | `standalone` | `examples/standalone/standalone-bastion.env` (core) or `examples/private-rag/full-demo.env` (all modules) or `examples/private-rag/full-demo-hosted.env` (all modules + hosted agent) | `<prefix>-standalone` |
| Production-like, existing landing zone | `hub-spoke` | `examples/hub-spoke/hub-spoke.env` | `<prefix>-spoke` |
| Quick demo from a laptop, synthetic data (**not private**) | `public` | `examples/public/public-quick-demo.env` | `<prefix>-public` |
| Microsoft-managed agent network (preview) | `standalone` or `hub-spoke` + `OUTBOUND_NETWORK_MODE=managedVnet` | `examples/managed-vnet/managed-vnet.env` | `<prefix>-mvnet` |
| Deploy now, network team connects later | `spoke-ready` | `examples/hub-spoke/spoke-ready.env` | `<prefix>-spokeready` |

## 3. Deploy

```powershell
azd auth login; az login
azd env new <prefix>-standalone --location swedencentral
Get-Content examples/private-rag/full-demo.env | ? { $_ -match '^([^#=]+)=(.*)$' } | % { azd env set $Matches[1] $Matches[2] }
azd provision        # = preflight -> Bicep -> postprovision hooks (seed index, RAG app, demo agents)
```

`azd up` also works (no application service is packaged; app code is pushed by the hooks over the
management plane, see below).

### What runs where

| Phase | Runs on | Purpose |
|---|---|---|
| `preprovision` | your machine | `scripts/preflight/preflight.ps1`: config, feature gates, address plan, providers, model quota, soft-deleted accounts, DNS zone inputs. **Fails** instead of silently ignoring unsupported options |
| Bicep | ARM | All Azure resources, private endpoints, DNS, RBAC, project connections |
| `postprovision` | your machine → **VM Run Command** on a private client (jumpbox or hub workstation) | Data-plane steps that require network line-of-sight: seed the knowledge index + Foundry IQ knowledge base, create demo agents, deploy the hosted agent with azd (module 7, the private client is the azd runner), deploy the RAG app. Stopped VMs (auto-shutdown) are started automatically |

## 4. Optional modules

| Module | Switch | Requires | Doc |
|---|---|---|---|
| 1 AI Search (knowledge) | `ENABLE_AI_SEARCH` | — | [modules/ai-search.md](modules/ai-search.md) |
| 3 RAG demo app | `ENABLE_RAG_DEMO` | AI Search | [modules/rag-demo.md](modules/rag-demo.md) |
| 4 Demo agent (AI Search tool) | `ENABLE_AGENT_DEMO` | AI Search, `byoVnet` | [modules/agent-demo.md](modules/agent-demo.md) |
| 5 Advanced monitoring / agent traces | `ENABLE_ADVANCED_MONITORING` (+ `EXISTING_AMPLS_ID` in hub-spoke) | — | [modules/monitoring.md](modules/monitoring.md) |
| 6 Foundry IQ | `ENABLE_FOUNDRY_IQ` (+ `FOUNDRY_IQ_REASONING=low` for query planning over a shared private link) | AI Search, `byoVnet` | [modules/foundry-iq.md](modules/foundry-iq.md) |
| 7 Hosted agent demo (Agent Framework + toolbox) | `ENABLE_HOSTED_AGENT_DEMO` (+ `HOSTED_AGENT_RAI_POLICY`) | Foundry IQ, jumpbox or `PRIVATE_CLIENT_VM_ID` (Windows), `byoVnet`/`managedVnet`, not spoke-ready / public; monitoring recommended | [modules/hosted-agent-demo.md](modules/hosted-agent-demo.md) |

Modules can be enabled later on a running environment: `azd env set <SWITCH> true; azd provision`.
`OUTBOUND_NETWORK_MODE` can **not** be changed after the Foundry account exists: `byoVnet` (default) =
VNet injection + Standard agent setup; `none` = models only (no agents); `managedVnet` = Microsoft-managed agent network (preview, `MANAGED_VNET_PREVIEW_ACK=true`, [modules/managed-vnet.md](modules/managed-vnet.md)).

## 5. Hub-spoke specifics

Inputs from the network team (details: [hub-integration.md](hub-integration.md)):

| Variable | Value |
|---|---|
| `EXISTING_HUB_VNET_ID`, `ENABLE_HUB_PEERING` | Spoke → hub peering |
| `ENABLE_HUB_SIDE_PEERING` | Only if you may modify the hub (else the network team creates hub → spoke) |
| `HUB_FIREWALL_PRIVATE_IP` | UDR `0.0.0.0/0` for workload subnets (agents need Entra ID egress) |
| `CUSTOM_DNS_SERVERS` | Hub DNS resolver IP(s) |
| `PRIVATE_DNS_ZONE_MODE=existing`, `EXISTING_PRIVATE_DNS_ZONE_IDS` | Central private DNS zones |
| `EXISTING_AMPLS_ID` | Central Azure Monitor Private Link Scope (module 5) |

`spoke-ready` → hub: [spoke-ready-handover.md](spoke-ready-handover.md) (`scripts/handover/Switch-ToCentralDns.ps1`).

### Testing hub-spoke without a real hub

`tests/integration/sample-hub/` provides a sample hub for testing hub-spoke without a production hub (**test fixture, not product**): firewall with
the documented agent allow-list, DNS resolver, central DNS zones, Bastion, a corporate workstation VM
and a central AMPLS.

```powershell
az group create -n rg-<prefix>-sample-hub -l swedencentral
az deployment group create -g rg-<prefix>-sample-hub -n sample-hub -f tests/integration/sample-hub/sample-hub.bicep -p adminPrincipalId=$(az ad signed-in-user show --query id -o tsv)
az deployment group create -g rg-<prefix>-sample-hub -n sample-hub-ampls -f tests/integration/sample-hub/sample-hub-ampls.bicep
# outputs: hubVnetId, firewallPrivateIp, resolverInboundIp, zoneIdsJson, clientVmId, amplsId
```

Run the AMPLS step **only after** `sample-hub` succeeded. It adds `snet-hub-pe` to the hub VNet, which a
later `sample-hub` deployment would try to remove (`InUseSubnetCannotBeDeleted`); in that case delete
`pe-ampls-sample-hub` and `snet-hub-pe`, deploy `sample-hub` again, then the AMPLS step.

Then set the spoke variables from those outputs. To let the postprovision hooks (seeding, demo agents)
and `Test-Deployment.ps1` run **from the hub workstation automatically**, also set:

| Variable | Value | Effect |
|---|---|---|
| `PRIVATE_CLIENT_VM_ID` | resource ID of the private client VM | Scripts use it via Run Command when no jumpbox exists |
| `PRIVATE_CLIENT_PRINCIPAL_ID` | its managed identity object ID | Gets the same scoped, documented validation roles as the jumpbox (data-plane only; `GRANT_JUMPBOX_VALIDATION_ROLES=false` disables both) |

## 6. Validate

```powershell
pwsh -NoProfile -Command "& ./scripts/validation/Test-Deployment.ps1 -Environment <env>"                          # jumpbox, or PRIVATE_CLIENT_VM_ID when set
pwsh -NoProfile -Command "& ./scripts/validation/Test-Deployment.ps1 -Environment <env> -ClientVmId '<VM id>'"      # any other private client
Invoke-Pester tests                                                                                                # offline, no Azure
```

Sections: `network`, `identity`, `public` (negative tests from your machine with a **valid** token:
only a 403 with a network reason counts as PASS), `invnet` (functional tests on the private client), `hosted` (module 7 only: agent exists, private invoke with citation, jailbreak → `400 content_filter`, public 403 on the agent endpoint, agent identity RBAC).
Reports: `.test-output/validation-<timestamp>.md`.

## 7. Tear down

```powershell
azd down -e <env> --purge --force                                   # ~45 min with VNet injection, ~15 min without
# or: pwsh ./scripts/cleanup/Remove-Environment.ps1 -Environment <env>
az group delete -n rg-<prefix>-sample-hub --yes                          # sample hub (after the spokes)
```

`Remove-Environment.ps1` handles the required order: delete projects → delete account (retry) →
**purge** → wait for the agent subnet's service association link → unlink the workspace / App Insights
from any Azure Monitor Private Link Scope → `azd down --purge` (checked; the script fails loudly). The same
steps run as the azd `predown` hook, so plain `azd down --purge` works too. Hosted agents and toolboxes (module 7) are project objects and go with the project (accounts that ran hosted agents return `FailedToDeleteAccount` for a while; the script retries). Delete hub-side peerings you created manually before deleting a spoke.
Don't reuse the environment name immediately afterwards ([naming-conventions.md](naming-conventions.md)).

## 8. Troubleshooting

[troubleshooting.md](troubleshooting.md) and [private-networking-limitations.md](private-networking-limitations.md).
