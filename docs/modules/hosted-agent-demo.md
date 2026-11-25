# Optional module 7 — Hosted agent demo (Agent Framework + toolbox)

Your own agent code, run by Foundry as a **hosted agent** on the same private foundation as the prompt
agents. Decision and live evidence: [ADR 0003](../adr/0003-hosted-agents.md).

Enable (requires the Foundry IQ module and an in-network private client):

```powershell
azd env set ENABLE_AI_SEARCH true
azd env set ENABLE_FOUNDRY_IQ true
azd env set ENABLE_HOSTED_AGENT_DEMO true
azd env set ENABLE_ADVANCED_MONITORING true      # recommended: agent-code traces (warning only if off)
# optional: azd env set HOSTED_AGENT_RAI_POLICY <RAI policy name on the account>   (default Microsoft.DefaultV2)
azd provision      # preflight -> Bicep -> seed index + knowledge base -> prompt agents -> hosted agent (azd on the private client) -> smoke test
```

Sample profile: [`examples/private-rag/full-demo-hosted.env`](../../examples/private-rag/full-demo-hosted.env)
(full demo + this module, standalone). Hub-spoke and managed VNet: add `ENABLE_HOSTED_AGENT_DEMO=true`
to [`managed-vnet.env`](../../examples/managed-vnet/managed-vnet.env) (all modules already on), or to
[`hub-spoke.env`](../../examples/hub-spoke/hub-spoke.env) together with `ENABLE_AI_SEARCH`, `ENABLE_FOUNDRY_IQ`
and `PRIVATE_CLIENT_VM_ID` (hub workstation, as validated in B).

Status: **module implemented and validated live 2026-11-24** (standalone full demo: provision 33 min, `Test-Deployment.ps1` 103/103 incl. the `hosted` section, [validation summary](../security/validation-summary.md)) Hub-spoke (hub workstation as runner): **86/86** incl. the `hosted` section on 2026-11-25.. The deployment path itself
(azd project + script) was validated live in A, B and F on 2026-11-23
([validation summary](../security/validation-summary.md)).

## What it deploys

No new Azure resources: toolboxes and hosted agents are **data-plane objects** of the project. Bicep only
exposes `DEPLOYED_HOSTED_AGENT_DEMO` (true when the flag is set and Foundry IQ is deployed); the
postprovision hook then runs [`scripts/agents/Deploy-HostedAgentAzd.ps1`](../../scripts/agents/Deploy-HostedAgentAzd.ps1)
`-Action all` for the azd project [`src/hosted-agents`](../../src/hosted-agents/azure.yaml):

| Object | Definition |
|---|---|
| Toolbox `contoso-policy-tools` | MCP tool on the project connection `knowledge-base-mcp` (Foundry IQ knowledge base, project managed identity) |
| Hosted agent `contoso-policy-hosted` | [`main.py`](../../src/hosted-agents/contoso-policy-hosted/main.py): Agent Framework `FoundryChatClient` + `FoundryToolbox`, `ResponsesHostServer` (Responses protocol); source-code deploy with `remote_build` (no container registry), Python 3.13, 1 vCPU / 2 GiB |
| Agent guardrail | `policies: rai_policy` = `HOSTED_AGENT_RAI_POLICY` (default `Microsoft.DefaultV2`, preview); the script substitutes the full ARM ID |

Steps of `Deploy-HostedAgentAzd.ps1` (each a VM Run Command on the private client, idempotent):

| Step | What |
|---|---|
| `setup` | Grants the runner's managed identity *Foundry Project Manager* on the project (ARM); installs azd + `azure.ai.agents` / `azure.ai.toolboxes` on the runner; `azd auth login --managed-identity` |
| `deploy` | Copies `src/hosted-agents` to `C:\azd-runner\hosted-agents`, sets the runner azd env (`runner`), `azd deploy` |
| `rbac` | Grants the agent identity *Monitoring Metrics Publisher* on App Insights; skipped with a message when monitoring is off |
| `invoke` | `azd ai agent invoke` smoke test (answer must mention Bastion), retries for cold start |

Postprovision behaviour matches the other demo steps: a failure prints the re-run command
(`pwsh ./scripts/agents/Deploy-HostedAgentAzd.ps1 -Environment <env> -Action all`) and the provision
itself is not rolled back. Order: index + knowledge base seeding → prompt agents → hosted agent → RAG app.

## Requirements (preflight, fail closed)

| Requirement | Why | Preflight |
|---|---|---|
| `ENABLE_FOUNDRY_IQ=true` (implies `ENABLE_AI_SEARCH=true`) | The toolbox uses the knowledge base connection `knowledge-base-mcp` | FAIL |
| `OUTBOUND_NETWORK_MODE=byoVnet` or `managedVnet` | Hosted agents need the isolated agent network to reach the private project endpoint | FAIL |
| Private client: jumpbox (`ENABLE_JUMPBOX=true`, standalone / hub-spoke) or `PRIVATE_CLIENT_VM_ID` (Windows VM in a connected network) | azd must run inside the network: the data plane has public access disabled | FAIL (ID format; OS = Windows checked online) |
| Not `NETWORK_MODE=public` / `spoke-ready` | Private-only module; spoke-ready has no private client before handover (run the script after handover) | FAIL |
| `ENABLE_ADVANCED_MONITORING=true` | App Insights for traces emitted by the agent code | WARN only |
| Hub-spoke: runner may download azd + extensions from GitHub | First `setup` on the runner | INFO (allow it in the hub firewall for the runner) |

Managed VNet needs the managed private endpoint rule `pe-foundry-account` (subresource `account`), which
`infra/main.bicep` creates for every managed VNet deployment (without it every invoke returns HTTP 500).

## Network paths per mode

The full request flows, figures and evidence are in the [networking walk-through, 9.8](../networking/networking-walkthrough.md#98-s8--hosted-agents):

| Mode | Micro VM / data proxy | Runner (azd) | Figures |
|---|---|---|---|
| A standalone | delegated agent subnet in your VNet; platform egress NSG → NAT | jumpbox | [A — standalone](../networking/networking-walkthrough.md#a--standalone) (figures 8, S8) |
| B hub-spoke | spoke agent subnet; platform egress UDR → hub firewall (allow-list unchanged) | hub workstation (`PRIVATE_CLIENT_VM_ID`) | [B — hub-spoke](../networking/networking-walkthrough.md#b--hub-spoke) (figures 9, S9) |
| F managed VNet | Microsoft-managed VNet, managed PEs only (`pe-foundry-account`, `pe-knowledge-search`, `pe-ampls`) | jumpbox | [F — managed VNet](../networking/networking-walkthrough.md#f--managed-vnet-preview) (figures 10, S10) |

Common to all: invoke via the account private endpoint → agent guardrail → micro VM; the agent's model and
toolbox calls go to the project endpoint; tool calls are executed by the Foundry tools service through the
**data proxy** (not the micro VM); the Internet gets `403 Public access is disabled`.

## Identities and RBAC

| Identity | Role | Scope | Granted by |
|---|---|---|---|
| Runner VM managed identity (jumpbox / private client) | Foundry Project Manager | project | `Deploy-HostedAgentAzd.ps1 setup` |
| Agent identity (platform-created, per agent) | Monitoring Metrics Publisher | App Insights | `Deploy-HostedAgentAzd.ps1 rbac` |
| Agent identity | **none** on the knowledge search | — | the toolbox calls the knowledge base with the connection's credential (project MI) |
| Project managed identity | existing Foundry IQ / Search roles | knowledge search | Bicep (module 6) |

## Guardrails and limits

| Layer | Control |
|---|---|
| Agent boundary | `rai_policy` (`HOSTED_AGENT_RAI_POLICY`, preview): jailbreak → `HTTP 400 content_filter` at input stage, before the code runs |
| Model calls from code | The model deployment's content filter applies to every call |
| Agent loop (`main.py`) | A hosted agent owns its loop, so the code bounds it with Agent Framework options, set as environment variables in [`azure.yaml`](../../src/hosted-agents/azure.yaml) |

| Variable | Default | Agent Framework option |
|---|---|---|
| `HOSTED_AGENT_MAX_ITERATIONS` | 8 | `function_invocation_configuration.max_iterations` (model round-trips per request) |
| `HOSTED_AGENT_MAX_TOOL_CALLS` | 8 | `max_function_calls` (tool calls per request) |
| `HOSTED_AGENT_TIMEOUT_SECONDS` | 120 | `max_duration_seconds` (wall-clock budget of the tool loop) and `FoundryChatClient(timeout=)` (HTTP timeout per model call) |
| `HOSTED_AGENT_MAX_OUTPUT_TOKENS` | 4096 | `max_tokens` → Responses `max_output_tokens`; a caller can ask for less, never more (`prepare_options` hook) |

When a loop limit is reached the framework stops calling tools and forces a final text answer (best effort:
checked after each batch of tool calls). Worst case per request is therefore about the loop budget plus one
final model call (each model call ≤ `HOSTED_AGENT_TIMEOUT_SECONDS`). Options checked against
`agent-framework-core` 1.25/1.26 (`max_duration_seconds` exists since 1.25; `requirements.txt` pins `>=1.25.0`).
Change a limit: edit `azure.yaml` and re-run `Deploy-HostedAgentAzd.ps1 -Action deploy`.

## Cost

Per session while compute runs (incl. idle until suspension, default 15 min): Sweden Central retail
$0.11 per vCPU-hour + $0.01 per GiB-hour → demo agent (1 vCPU / 2 GiB) ≈ **$0.13/h active**; model and
knowledge base calls are billed separately. No registry, no extra VM (the jumpbox / private client is reused).
See [cost-estimation.md](../cost-estimation.md).

## Validation

`Test-Deployment.ps1` section `hosted` (runs when `DEPLOYED_HOSTED_AGENT_DEMO=true`;
probe [`hosted-agent-probe.ps1`](../../scripts/validation/hosted-agent-probe.ps1) on the private client):

| Check | Where | Expectation |
|---|---|---|
| Agent exists | private client, data plane | `contoso-policy-hosted`: kind `hosted`, latest version `active` |
| Private invoke | private client → agent Responses endpoint (account PE); retries for cold start; falls back to `azd ai agent invoke` to separate endpoint from agent problems | answer mentions Bastion and cites *Remote access standard* / `pol-xxx` |
| Guardrail | private client | jailbreak prompt → `HTTP 400 content_filter` |
| Public negative | this machine, valid token, agent Responses endpoint | `403` network rejection |
| Telemetry RBAC | ARM | agent identity has Monitoring Metrics Publisher on App Insights (SKIP without monitoring) |

Offline: [`tests/hosted-agent/HostedAgent.Tests.ps1`](../../tests/hosted-agent/HostedAgent.Tests.ps1) (flag
wiring, preflight gates, azd project, limits in `main.py`).

## Teardown

Nothing extra: hosted agents and toolboxes are project data-plane objects and are deleted with the project.
`predown` / [`Remove-Environment.ps1`](../../scripts/cleanup/Remove-Environment.ps1) deletes the projects,
then deletes and purges the account, retrying `FailedToDeleteAccount` (seen on accounts that ran hosted
agents, until backend cleanup finishes), then waits for the agent subnet link. The runner keeps its azd
install and `C:\azd-runner` (jumpbox: deleted with the resource group; hub workstation: remove the folder
if wanted). Role assignments of the runner and agent identities live in this resource group's scopes and
are removed with it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Preflight FAIL for the module | Follow the message (Foundry IQ, agent network, private client, mode) |
| `Runner setup failed` | Runner has no egress to GitHub for azd / extensions (hub firewall) or Run Command blocked; re-run `-Action setup` |
| `azd deploy` fails with 403 | Runner not in the network, or *Foundry Project Manager* not yet effective (wait ~5 min, re-run) |
| Invoke `HTTP 500` in managed VNet | Managed PE rule `pe-foundry-account` missing or not Active |
| Exporter `Forbidden` in the container log | Agent identity lacks Monitoring Metrics Publisher (`-Action rbac`) |
| Answer truncated (`incomplete`, `max_output_tokens`) | Raise `HOSTED_AGENT_MAX_OUTPUT_TOKENS` (reasoning tokens count) |
| `DelegatedSubnetInUse`, `429 subnet_exhausted`, `EHOSTUNREACH`, timeouts behind a firewall | Private-network checklist from the [Foundry blog 2026-11-21](https://devblogs.microsoft.com/foundry/hosted-agents-private-network-setup/), see [troubleshooting.md](../troubleshooting.md) |
