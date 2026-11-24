# Naming conventions

Consistent names make it obvious which part of a deployment you are looking at. This matters most
in hub-spoke, where the **workload** (this repo) is a **spoke** and the **hub** belongs to someone else.

## Two meanings of "hub"

| Term | Meaning in this repo |
|---|---|
| **Hub** (network) | The customer's existing hub VNet: firewall, DNS resolver, gateways, central private DNS zones, central AMPLS. **Never deployed by this repo** |
| **Foundry hub** (legacy) | The older `Microsoft.MachineLearningServices` hub workspace. **Not used**; this repo uses the current Foundry account + project model |
| **Spoke** | The workload VNet this repo deploys in `hub-spoke` and `spoke-ready` mode |

## Environments and resource groups

`azd` derives the resource group from the environment name: `rg-<AZURE_ENV_NAME>`.

| Deployment | `AZURE_ENV_NAME` | Resource group | Example profile |
|---|---|---|---|
| Standalone workload | `<prefix>-standalone` | `rg-<prefix>-standalone` | `examples/standalone/standalone-bastion.env`, `examples/private-rag/full-demo.env` |
| Spoke workload (connected to a hub) | `<prefix>-spoke` | `rg-<prefix>-spoke` | `examples/hub-spoke/hub-spoke.env` |
| Spoke prepared for later integration | `<prefix>-spokeready` | `rg-<prefix>-spokeready` | `examples/hub-spoke/spoke-ready.env` |
| Public quick demo (NOT private) | `<prefix>-public` | `rg-<prefix>-public` | `examples/public/public-quick-demo.env` (project `public-demo`) |
| Standalone with managed VNet for agents (preview) | `<prefix>-mvnet` | `rg-<prefix>-mvnet` | `examples/managed-vnet/managed-vnet.env` (project `mvnet-demo`) |

`<prefix>` identifies the owner/tenant/purpose, e.g. `contoso` or `contoso-dev`.

Rules:

- **Never reuse an environment name right after deleting it.** The name determines the resource token,
  and therefore the Foundry account name. Re-creating a purged account with the same name caused
  persistent Private Link errors. Use a new name (e.g. `-2`).
- Set a **distinct `FOUNDRY_PROJECT_NAME`** per deployment (`standalone-demo`, `spoke-demo`,
  `spokeready-demo`). Otherwise several `private-demo` projects look identical in the Foundry portal.

## Resource names (workload, `infra/main.bicep`)

`<token>` = `uniqueString(subscription, AZURE_ENV_NAME, location)`, 13 characters.

| Resource | Pattern | Abbreviation source |
|---|---|---|
| Resource group | `rg-<env>` | CAF `rg` |
| Virtual network | `vnet-<env>-<token>` | CAF `vnet` |
| Subnets | `snet-private-endpoints`, `snet-agent`, `snet-management`, `snet-app`, `snet-integration`, `AzureBastionSubnet` | CAF `snet` (Bastion name is mandated) |
| NSG | `nsg-<vnet name>-{pe,agent,mgmt,bastion,app,integration}` | CAF `nsg` |
| Egress | standalone: NAT gateway `ng-<env>` + `pip-<env>-nat`; hub-spoke: route table `rt-<env>-to-hub` | CAF `ng`, `pip`, `rt` |
| Foundry account | `aif-<token>` | CAF `aif` (AI Foundry) |
| Foundry project | `FOUNDRY_PROJECT_NAME` | — |
| Private endpoint | `pe-<target resource name>[-<group>]` | CAF `pe` |
| Agent dependencies (Standard setup) | `cosmos-agent-<token>`, `stagent<token>`, `srch-agent-<token>` | CAF `cosmos`, `st`, `srch` |
| Knowledge search (module 1) | `srch-kb-<token>` | CAF `srch` |
| Log Analytics / App Insights / AMPLS | `log-<token>`, `appi-<token>`, `ampls-<token>` | CAF `log`, `appi`, `ampls` |
| Bastion / jumpbox / RAG VM | `bas-<token>`, `vm-jump-<token6>`, `vm-rag-<token6>` | CAF `bas`, `vm` |
| Alerts / query pack | `alert-<env>-<purpose>`, `ag-<env>`, `qp-<env>` | — |

## Repository names

| Item | Convention |
|---|---|
| Bicep modules | `infra/modules/<area>/<resource-or-purpose>.bicep`; direction explicit for peering (`spoke-to-hub-peering.bicep`, `hub-to-spoke-peering.bicep`) |
| azd outputs | Never identical to an input variable name (`azd down` deletes env keys that match outputs). Use `DEPLOYED_*` for echoed inputs |
| Demo objects | Agents `contoso-policy-agent` (Azure AI Search tool), `contoso-iq-agent` (Foundry IQ MCP), validation agent `private-validation-agent`; knowledge base `contoso-policies-kb` |

