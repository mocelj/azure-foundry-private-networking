# Validation summary

What was tested, how, and with which result, for every deployment option of this repository. All live
tests ran in **Sweden Central** between **17 and 24 November 2026**. A capability counts as *validated
live* only if it was exercised against real Azure resources by the scripts below; everything else is
marked as not covered. Foundry networking changes often: re-run the validation in your own subscription
and region before relying on a result.

## 1. How the template is validated

| Layer | What it proves | Tool | Azure needed |
|---|---|---|---|
| Bicep build + lint | Template compiles; security linter rules (e.g. no secrets in outputs) are errors | `az bicep build`, `az bicep lint` | no |
| Static tests per profile | For **every** sample profile in `examples/`, the Bicep is expanded with that profile's parameters (PSRule for Azure) and each resource is checked: public network access disabled, local auth off, private endpoints present, NSG rules, RBAC without Owner/Contributor/User Access Administrator, deployment ordering, the public profile restricted to its allow-list | `Invoke-Pester tests` (also in CI) | no |
| Preflight (fail closed) | Unsupported combinations, address overlaps with reserved ranges, missing providers, model quota, soft-deleted accounts and missing acknowledgements for preview / public options stop the deployment **before** anything is created; preflight never opens network access to make something work | `scripts/preflight/preflight.ps1` (azd `preprovision` hook) | read-only |
| What-if | Policy denials and planned changes | `azd provision --preview` | yes |
| Live: network and identity | Private endpoints approved, private DNS records, public network access, network ACLs, role assignments per identity | `scripts/validation/Test-Deployment.ps1` | yes |
| Live: public negatives | Each data plane is called from the Internet **with a valid Entra token**. Only a **403 with a network reason** ("public access is disabled", "blocked by firewall") counts as PASS; a 401 only proves missing credentials and is reported as inconclusive | `Test-Deployment.ps1 -Sections public` | yes |
| Live: in-network functional tests | From a **private client** (the jumpbox, or an existing VM in the hub via `PRIVATE_CLIENT_VM_ID`) through **VM Run Command**, so no inbound port, VPN or public IP is needed: DNS resolves to private endpoint IPs, model inference, project API, agent create and run, AI Search tool with citations, Foundry IQ, RAG app, traces | `Test-Deployment.ps1 -Sections invnet` | yes |
| Live: hosted agents | Agent exists, private invoke with a grounded answer, jailbreak blocked by the agent guardrail, public 403 on the agent endpoint, agent identity RBAC | `Test-Deployment.ps1 -Sections hosted`, `scripts/validation/hosted-agent-probe.ps1` | yes |
| Firewall-log evidence (hub-spoke) | Which agent traffic reaches the hub firewall (only platform egress through the `0.0.0.0/0` route) and which never does (traffic to private endpoints follows the more specific endpoint routes) | Azure Firewall logs in the hub | yes |
| Search-log evidence (tool paths) | Which component calls the knowledge search: the caller address in the AI Search diagnostic logs (queried privately through AMPLS) shows the project **data proxy** in the agent subnet for toolbox and prompt-agent tool calls, and the hosted agent's micro VM only for direct MCP calls from agent code | AI Search resource logs | yes |

Reports: `Test-Deployment.ps1` writes a dated report to `.test-output/validation-<timestamp>.md`.

## 2. Results per option

Counts are the checks of the full `Test-Deployment.ps1` run (all sections) unless noted.

| Option | Profile (examples/) | Latest live result | Date |
|---|---|---|---|
| **A** standalone, all optional modules, Foundry IQ query planning, all trusted-service exceptions off | `private-rag/full-demo-query-planning.env` + `FOUNDRY_NETWORK_ACLS_BYPASS=None`, `AGENT_STORAGE_NETWORK_BYPASS=None` | **101/101** | 2026-11-19 |
| A standalone, all optional modules, default settings | `private-rag/full-demo.env` | **97/97** (from scratch) | 2026-11-19 |
| **B** hub-spoke, all optional modules, trusted-service exceptions off, hub VM as private client | `hub-spoke/hub-spoke.env` + modules | **91/91** + hosted agent; earlier 90/90; interactive end-to-end user test ([guide](../e2e-test-guide.md)) Parts 1–8 PASS | 2026-11-23 |
| **C** spoke-ready, models only, then handover | `hub-spoke/spoke-ready.env` | **20/20** isolation; **30/30** from a hub client after `Switch-ToCentralDns.ps1` | 2026-11-18 |
| **D** standalone + AI Search (module 1) | `private-rag/ai-search.env` | **66/66** (first run of the module) | 2026-11-18 |
| **E** standalone + optional modules 1–6 | `private-rag/full-demo.env` | see A; per module below | 2026-11-18/19 |
| **F** managed VNet (**preview**), all optional modules, trusted-service exceptions off | `managed-vnet/managed-vnet.env` | **104/104**; with hosted agent **105/105** + hosted agent PASS; full re-deploy (`azd provision --no-state`) idempotent | 2026-11-19 / 2026-11-23 |
| **G** public quick demo (**not private**) | `public/public-quick-demo.env` | **14/14**, including an outsider VM with another egress IP: 403 | 2026-11-19 |
| Hosted agents in **A**, **B**, **F** (azd from an in-network runner, toolbox, guardrails) | A / B / F profiles + `Deploy-HostedAgentAzd.ps1` | PASS in all three | 2026-11-23 |
| **Hosted-agent module** (module 7) | `private-rag/full-demo-hosted.env` | **103/103** incl. the `hosted` section; provision incl. all hooks 33 min | 2026-11-24 |
| **Published repository from a fresh clone**, following the README and deployment guide literally: E+ standalone, and B hub-spoke against the sample hub (`tests/integration/sample-hub/`) with all modules incl. the hosted agent | `private-rag/full-demo-hosted.env`; `hub-spoke/hub-spoke.env` + modules | **103/103** standalone; **86/86** hub-spoke incl. the `hosted` section (first hub-spoke run of the module) | 2026-11-25 |
| Offline: Bicep build + lint, Pester (all profiles) | all | green in CI | every push |

### Optional modules (first live run of each)

| Module | Result | Date |
|---|---|---|
| 1 AI Search | Index seeded from inside the VNet (managed identity); public query rejected with `403 publicNetworkAccess: Disabled`; 66/66 | 2026-11-18 |
| 3 RAG demo app | VM without public IP and without Internet egress answers with citations; only its two data-plane roles; 75/75 | 2026-11-18 |
| 4 Demo agent (Azure AI Search tool) | Agent calls the search tool, grounded answer with citation; 77/77 | 2026-11-18 |
| 5 Advanced monitoring | Agent traces in App Insights with public ingestion and query disabled; public trace query rejected (`PrivateLinkValidationFailedError`); validated standalone and hub-spoke (central AMPLS) | 2026-11-18/19 |
| 6 Foundry IQ | Knowledge base over the private index, MCP agent; standalone 71/71, hub-spoke 67/67 (network + in-network sections). Query planning (`low`): 403 without the shared private link, 403 while pending, 200 after approval; 101/101 | 2026-11-19 |
| 7 Hosted agent demo | 103/103 standalone; 86/86 hub-spoke (see above) | 2026-11-24 / 2026-11-25 |

### Hosted agents per network mode

| Mode | Result |
|---|---|
| A standalone | `azd deploy` from the jumpbox (in-network runner) in under 3 min; private invoke with citation through a project **toolbox**; tool calls reach the knowledge search from the **data proxy** in the agent subnet; jailbreak blocked by the **agent guardrail** (`400 content_filter` at input stage) and, without an agent policy, by the **model deployment's** content filter; Internet call `403 Public access is disabled` |
| B hub-spoke | `azd deploy` from a VM in the hub across the peering; private invoke with citation; public 403; agent guardrail blocks a jailbreak. Firewall log (3 h): model, toolbox and telemetry traffic never crossed the firewall; only platform egress did; no container registry or package index traffic from the spoke (remote build runs platform-side); **firewall allow-list unchanged** |
| F managed VNet (preview) | Without a managed private endpoint to the account every invoke failed (HTTP 500: the agent can't reach its own project endpoint); with the outbound rule **`pe-foundry-account`** (now part of the template) invoke PASS with citation, public 403, jailbreak blocked |
| All modes | Agent-code telemetry needs **Monitoring Metrics Publisher** for the agent identity on App Insights (Entra-only ingestion); granted by the deploy script. With the toolbox the agent identity needs **no** data-plane role on the tool target |

## 3. Durable findings from live testing

| Finding | Consequence in the template |
|---|---|
| Agent traces stay missing if the Foundry account (injected agent runtime) exists before the AMPLS private endpoint and DNS | The account is created after the AMPLS private endpoint (Bicep dependency, static test) |
| In managed VNet, hosted agents need a private path back to their own account | Managed outbound rule `pe-foundry-account` |
| Authorization is evaluated before the IP firewall (public profile): an unauthorized caller gets 401 even from a blocked IP | The outsider test grants a temporary role, so only the network can reject it |
| Peering alone doesn't make a spoke-ready spoke resolvable: the central zones have no records for its endpoints | Handover script moves the records into the central zones |
| A private endpoint DNS zone group can't be re-pointed to other zones | The handover script deletes and recreates zone groups |
| Re-creating an account with the **same name** shortly after purge can fail privately ("Traffic is not from an approved private endpoint") | Use a new environment name; never "fix" it by opening network access |
| Search → Foundry model calls (query planning) are private only through an **approved** shared private link | Bicep creates the link, a narrow script approves exactly that request |
| With both trusted-service exceptions off (`None`), every tested path still works | `None` documented as validated; default stays `AzureServices` |

## 4. Not covered by live tests

File upload / file search and Code Interpreter files, evaluations, Search skillsets or integrated
vectorization calling Foundry, Foundry IQ private ingestion (option B), and Foundry portal features beyond
those listed in the [end-to-end test guide](../e2e-test-guide.md). See
[private-networking limitations](../private-networking-limitations.md) before promising a feature.
