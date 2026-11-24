# ADR 0003 — Hosted agents on the private Foundry foundation

| | |
|---|---|
| Status | **Accepted and implemented** as optional module 7 (`ENABLE_HOSTED_AGENT_DEMO`, [module doc](../modules/hosted-agent-demo.md)); validated live in A standalone, B hub-spoke and F managed VNet (**preview**) on 2026-11-23, module validated live on 2026-11-24 |
| Date | 2026-11-20, updated 2026-11-24 |
| Related | [ADR 0001](0001-foundry-resource-architecture.md) (amendment A9) · [networking walk-through, hosted agents](../networking/networking-walkthrough.md#98-s8--hosted-agents) · [validation summary](../security/validation-summary.md) |

## Context

The template originally covered **prompt agents** only: Agent Service runs the agent loop; the template
declares instructions, model and tools. **Hosted agents** run *your own code* (Microsoft Agent Framework,
LangGraph or custom; Python or C#) in per-session, VM-isolated sandboxes (micro VMs). The platform provides
the endpoint, a dedicated Entra identity per agent, scaling, session state and OpenTelemetry
([What are hosted agents?](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents)).

Code-first agents are what many enterprise teams build. The question was whether they work on the same
private foundation (private endpoints, BYO VNet injection or managed VNet, Entra-only, no public data plane)
without weakening it, and what has to change.

Relevant platform facts (Microsoft Learn, checked 2026-11-23):

| Topic | Fact |
|---|---|
| Endpoint | Under the project: `{project}/agents/{name}/endpoint/protocols/...` (Responses, Invocations, Activity, A2A), reached through the existing account private endpoint |
| Network injection | Same account-level injection as prompt agents; must exist at account creation; existing injected accounts need no redeployment ([Agent Service VNets](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks)) |
| Egress | The agent's **own** outbound traffic leaves through the delegated agent subnet (your NSG, NAT or hub firewall, private DNS). **Tool calls** go through the single-tenant **data proxy**, as for prompt agents ([networking deep dive](https://learn.microsoft.com/azure/foundry/agents/concepts/agents-networking-deep-dive)) |
| Subnet | Delegated to `Microsoft.App/environments`, `/27` minimum, `/24` recommended (the template uses `/24`); exhaustion shows as `429 subnet_exhausted`. Keep private endpoint addresses out of `192.168.0.0/24` (internal sandbox network) |
| Deployment | **Source-code deployment** (zip, `remote_build`): no container registry needed. A private registry is supported for projects created after 2026-06-25. With public access disabled, deployment must run from a client **inside the network** ([deploy from source code](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent-code)) |
| Managed VNet | Supports prompt and hosted agents ([managed virtual network](https://learn.microsoft.com/azure/foundry/how-to/managed-virtual-network)) |
| Tools | Foundry-managed tools (Foundry IQ, MCP, OpenAPI, …) through a project **toolbox** MCP endpoint |

## Decision

1. **Support hosted agents as an optional module** (`ENABLE_HOSTED_AGENT_DEMO=true`, default `false`) on the
   existing private foundation. No new Azure resources, subnets or private endpoints; the only template
   change for hosted agents is the managed outbound rule `pe-foundry-account` in managed VNet mode.
2. **Deployment from an in-network runner with azd.** The azd project `src/hosted-agents` (`azure.yaml`,
   `kind: hosted`, source-code deployment with `remote_build`) is deployed by
   `scripts/agents/Deploy-HostedAgentAzd.ps1`, which runs azd **on the private client** (the jumpbox in
   standalone and managed VNet, an existing VM in the hub set as `PRIVATE_CLIENT_VM_ID` in hub-spoke) through
   VM Run Command, signed in with the VM's managed identity (*Foundry Project Manager* on the project). The
   data plane stays private; nothing is deployed from the Internet.
3. **Tools through a project toolbox.** The sample agent `contoso-policy-hosted` (Agent Framework,
   `FoundryChatClient` + `FoundryToolbox`) reaches the Foundry IQ knowledge base through the toolbox
   `contoso-policy-tools` (MCP tool on the knowledge base connection, project managed identity).
4. **Guardrails at two layers.** The model deployment's content filter screens every model call, also those
   made from agent code. In addition the agent definition carries an agent-level guardrail
   (`HOSTED_AGENT_RAI_POLICY`, default `Microsoft.DefaultV2`; agent-level guardrails are **preview**), which
   screens input and output at the agent endpoint before the code runs.
5. **Bounded agent loop.** A hosted agent owns its loop, so the sample code sets iteration, tool-call, time
   and output limits (`agent-framework-core` ≥ 1.25: `max_iterations`, `max_function_calls`,
   `max_duration_seconds`, plus an HTTP timeout and capped `max_output_tokens`; environment variables in
   `azure.yaml`).
6. **Least-privilege identities.** Agent identity: **Monitoring Metrics Publisher** on App Insights only
   (agent-code telemetry with Entra-only ingestion); **no** data-plane role on the tool target, because the
   toolbox uses the connection's credential. Runner identity: *Foundry Project Manager* on the project.
7. **Fail closed.** Preflight rejects the module without Foundry IQ, without an agent network (`byoVnet` or
   `managedVnet`), without a private client, and in `spoke-ready` and `public` mode (warning only without the
   monitoring module).

## Findings per scenario (validated live)

| Scenario | Result |
|---|---|
| **A standalone** | azd deploy from the jumpbox in under 3 minutes; private invoke with a grounded, cited answer; toolbox calls reach the knowledge search from the **data proxy** in the agent subnet (AI Search logs), not from the micro VM; jailbreak → `HTTP 400 content_filter` at input stage (agent guardrail); without an agent policy the model deployment's filter blocks it; Internet call → `403 Public access is disabled`; works with both trusted-service exceptions off |
| **B hub-spoke** | azd deploy from a VM in the hub across the peering; private invoke with citation; public 403; agent guardrail blocks a jailbreak; full regression 91/91. Hub firewall log: model, toolbox and telemetry traffic never crossed the firewall (private endpoint routes take priority over the `0.0.0.0/0` route); only platform egress did; no container registry or package index traffic (remote build runs platform-side). **The firewall allow-list stays unchanged** ([hub integration](../hub-integration.md)) |
| **C spoke-ready** | Not supported before handover (no private client); deploy after the handover |
| **F managed VNet** (preview) | Without a managed private endpoint to the account itself every invoke fails with HTTP 500: from the Microsoft-managed VNet the agent has no private path back to its own project endpoint. With the outbound rule **`pe-foundry-account`** (`PrivateEndpoint`, subresource `account`; now always created in managed VNet mode) invoke PASS with citation, public 403, jailbreak blocked; telemetry through the managed AMPLS endpoint. No customer-side egress logs, as for all managed VNet traffic |
| **G public** | Simplest technically (public egress), but not validated in this repository |
| **Module 7** | Fresh deployment from `examples/private-rag/full-demo-hosted.env`: provision incl. all hooks 33 min, `Test-Deployment.ps1` **103/103** incl. the `hosted` section (agent exists, private invoke with citation, jailbreak → 400, public 403, agent identity RBAC) |

## Status, quota and cost (checked 2026-11-23)

| Topic | Finding |
|---|---|
| Status | Hosted agents (managed hosting) are **GA**; the Python hosting package `agent-framework-foundry-hosting` is **prerelease**; agent-level guardrails are **preview**; network egress controls in the guardrail are GA |
| Session quota | Default 2,000 concurrent hosted sessions per subscription in Sweden Central (1,000 in most other regions); idle sessions don't count; exceeded → `429 session_quota_exceeded` ([limits](https://learn.microsoft.com/azure/foundry/agents/concepts/limits-quotas-regions)) |
| Cost | Per session while its compute runs, including idle time until suspension (default 15 min): retail Sweden Central $0.11 per vCPU-hour + $0.01 per GiB-hour; the demo agent (1 vCPU / 2 GiB) ≈ $0.13/h active. Models and tools are billed separately ([cost estimation](../cost-estimation.md)) |

## Consequences

- Prompt and hosted agents run on the same private foundation; customers choose per agent.
- Hosted-agent deployment needs an **in-network runner** (jumpbox, hub VM or self-hosted CI agent); a
  GitHub-hosted runner or a notebook on the Internet can't deploy to a private project.
- The agent's own egress is subject to the customer's NSG / firewall (BYO VNet) and visible in firewall logs;
  in managed VNet it is governed by managed outbound rules without customer-side logs.
- Hub-spoke customers need no firewall change for hosted agents; TLS inspection must exclude the Entra and
  managed identity endpoints ([hub integration](../hub-integration.md)).
- The agent code is the customer's responsibility: loop limits, dependency pinning and testing; the
  platform guardrails screen model calls and (optionally, preview) the agent boundary.
- Teardown is unchanged: agents and toolboxes are project objects and are removed with the project.
