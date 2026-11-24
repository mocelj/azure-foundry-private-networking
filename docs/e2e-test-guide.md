# End-to-end test guide — from your notebook

Goal: experience the private Foundry deployment as a corporate user would, **without installing
anything or connecting your notebook to the customer network**. Your notebook only uses a browser
(Azure portal) and, optionally, PowerShell in this repo.

Prerequisites: a hub-spoke deployment with the optional modules (profile `examples/hub-spoke/hub-spoke.env` plus
`ENABLE_AI_SEARCH`, `ENABLE_RAG_DEMO`, `ENABLE_AGENT_DEMO`, `ENABLE_ADVANCED_MONITORING`, `ENABLE_FOUNDRY_IQ`),
connected to a hub with Bastion and a workstation VM, for example the sample hub test fixture
(`tests/integration/sample-hub/`, see the [deployment guide](deployment-guide.md#testing-hub-spoke-without-a-real-hub));
optionally a standalone deployment (`examples/private-rag/full-demo.env`) for comparison.

Placeholders below (names per [naming-conventions.md](naming-conventions.md)): `<prefix>` = your environment
name prefix; `<spoke-token>` / `<standalone-token>` = the 13-character resource token of each environment
(the suffix of `AZURE_AI_ACCOUNT_NAME` in `azd env get-values`); `<…-token6>` = its first six characters;
`<subscription>` = your subscription. `azd env get-values` lists the account, search, RAG and jumpbox names.

| Item | Hub-spoke (main path) | Standalone (optional comparison) |
|---|---|---|
| Resource group | `rg-<prefix>-spoke` (the **workload spoke**) | `rg-<prefix>-standalone` |
| Foundry account / project | `aif-<spoke-token>` / `spoke-demo` | `aif-<standalone-token>` / `standalone-demo` |
| Model deployment | `gpt-5.4-mini` | `gpt-5.4-mini` |
| Knowledge search / index / Foundry IQ KB | `srch-kb-<spoke-token>` / `contoso-policies` / `contoso-policies-kb` | `srch-kb-<standalone-token>` / same |
| Agent stores | `cosmos-agent-…`, `stagent…`, `srch-agent-…` (token `<spoke-token>`) | token `<standalone-token>` |
| Demo agents | `contoso-policy-agent`, `contoso-iq-agent`, `private-validation-agent` | same |
| RAG app | `https://10.81.4.4:8443/` (`vm-rag-<spoke-token6>`) | `https://10.80.4.4:8443/` (`vm-rag-<standalone-token6>`) |
| Agent traces | `appi-<spoke-token>` via central `ampls-sample-hub` | `appi-<standalone-token>` via own AMPLS |
| Access path | **Sample hub** `rg-<prefix>-sample-hub`: Bastion `bas-sample-hub` → `vm-hub-workstation` | Own Bastion `bas-<standalone-token>` → `vm-jump-<standalone-token6>` |

```text
Notebook browser ──HTTPS──► bas-sample-hub (hub) ──RDP──► vm-hub-workstation (hub, no public IP)
                                                          │ DNS: hub resolver 10.0.2.4 → central privatelink zones
                                                          ▼ peering hub ↔ spoke
                          spoke private endpoints 10.81.1.x ──► Foundry / Search / Cosmos / Storage
                          spoke snet-app 10.81.4.4:8443   ──► RAG demo app
```

The two environments are **separate networks**: the hub workstation can't reach the standalone
environment (no peering), and the standalone jumpbox can't reach the spoke. That's isolation by design.

---

## Part 0 — Prepare the browser (2 min)

If your browser is signed in to another tenant, use an **InPrivate window** (or a separate Edge profile) for
all steps, so that single sign-on doesn't pick the wrong account.

1. InPrivate window → `https://portal.azure.com` → sign in with an account that has access to the deployment.
2. Top bar → *Directories + subscriptions* → confirm the directory and the subscription `<subscription>`.

## Part 1 — Inspect the isolation from the notebook (management plane, 10 min)

Management (ARM) is reachable from anywhere; only the data planes are private.

| # | Where | What to check | Expected |
|---|---|---|---|
| 1.1 | `rg-<prefix>-spoke` → Overview | Resource list | No public IP, no Bastion; one VM only, the RAG VM (`vm-rag-<spoke-token6>`, no public IP; present because this environment enables the RAG module) |
| 1.2 | `aif-<spoke-token>` → *Networking* → *Firewalls and virtual networks* | Public access | **Disabled** |
| 1.3 | same → *Private endpoint connections* | PE | `pe-aif-…` **Approved** |
| 1.4 | same → *Keys and Endpoint* | Keys | Local auth disabled (keys unusable) |
| 1.5 | `cosmos-agent-…`, `stagent…`, `srch-agent-…`, `srch-kb-…` → *Networking* | Public access | **Disabled**, each with an approved PE |
| 1.6 | `vnet-<prefix>-spoke-<spoke-token>` → *Peerings* | Peering to `vnet-sample-hub` | **Connected** |
| 1.7 | same → *Subnets* | `snet-agent` | Delegated to `Microsoft.App/environments`, NSG + route table |
| 1.8 | `rt-<prefix>-spoke-to-hub` → *Routes* | Route | `0.0.0.0/0 → 10.0.1.4` (hub firewall) |
| 1.9 | `rg-<prefix>-sample-hub` → `privatelink.openai.azure.com` → *Recordsets* | A record | `aif-<spoke-token> → 10.81.1.5` (spoke PE registered in the **central** zone) |
| 1.10 | `appi-<spoke-token>` → *Network Isolation* | Ingestion / query | Both public access **Disabled**; linked to `ampls-sample-hub` |

## Part 2 — Prove the data plane is closed to your notebook (5 min)

| # | Action (on the notebook) | Expected |
|---|---|---|
| 2.1 | InPrivate → `https://ai.azure.com` → sign in with your account → open project `spoke-demo` | Portal shell loads, but project content fails (*public access is disabled* / network error) |
| 2.2 | Azure portal → `srch-kb-<spoke-token>` → *Search explorer* → Search | Error: request denied, public network access disabled |
| 2.3 | Optional, in this repo: `pwsh -NoProfile -Command "& ./scripts/validation/Test-Deployment.ps1 -Environment <prefix>-spoke -Sections public"` | Every service returns **403 with a network reason** although a *valid* token is sent |

## Part 3 — Connect to the corporate workstation (3 min)

1. Azure portal → `rg-<prefix>-sample-hub` → `vm-hub-workstation` → **Connect** → **Connect via Bastion**.
   If the VM shows *Stopped (deallocated)* (daily auto-shutdown), click **Start** first.
2. *Authentication type*: **Microsoft Entra ID** → **Connect** (allow the pop-up for
   `bastion.azure.com`). Sign in with your account if prompted. No VM password is needed.
3. A Windows Server desktop opens in a browser tab.

If *Microsoft Entra ID* isn't offered, close and retry once; the VM extension and your
*Virtual Machine User Login* role are already in place.

## Part 4 — Network checks on the workstation (3 min)

Start → *Windows PowerShell*:

```powershell
Resolve-DnsName aif-<spoke-token>.services.ai.azure.com   # 10.81.1.x via ...privatelink...
Resolve-DnsName aif-<spoke-token>.openai.azure.com        # 10.81.1.5
Resolve-DnsName srch-kb-<spoke-token>.search.windows.net  # 10.81.1.x
Test-NetConnection aif-<spoke-token>.services.ai.azure.com -Port 443   # TcpTestSucceeded: True
```

Compare with the same `Resolve-DnsName` on your notebook: public IP via `cloudapp.azure.com`.

## Part 5 — Foundry portal over Private Link (10–15 min)

On the workstation: Edge → `https://ai.azure.com` → sign in with your account → select project
**spoke-demo**. Note for each page whether it works:

| # | Page | Try | Expected |
|---|---|---|---|
| 5.1 | Home / Overview | Project endpoint shown | Loads |
| 5.2 | Models + endpoints | `gpt-5.4-mini` listed | Loads |
| 5.3 | Playground (chat) | Ask "Summarise the benefits of private endpoints in two sentences" | Answer |
| 5.4 | Agents | `private-validation-agent` → chat "ping" | Replies `AGENT-PRIVATE-OK` |
| 5.5 | Agents → `contoso-policy-agent` (created by `azd`, Azure AI Search tool) | Ask the four questions below | Correct answers with citations; run details show an **Azure AI Search** tool call |
| 5.6 | Management center → Connected resources | `knowledge-search`, `knowledge-base-mcp`, `agent-traces`, Cosmos, Storage, Search | Listed, Entra / project managed identity auth |

Test questions:

| Question | Expected | Source |
|---|---|---|
| How do administrators access cloud workloads remotely? | Bastion, jump hosts without public IP, Entra ID + MFA | Remote access standard |
| What is the hotel limit per night in major European cities? | 220 EUR | Expense reimbursement |
| How quickly must suspected data leakage be reported? | Within 1 hour (SOC) | Incident response for data leakage |
| What is the capital of Australia? | I don't know (control) | — |

Then, still on the workstation, Azure portal → `srch-kb-<spoke-token>` → *Search explorer* →
`remote access` → results (contrast with 2.2).

## Part 6 — Foundry IQ agent (module 6, 3 min)

Agents → `contoso-iq-agent` → Playground → ask the questions above. The run shows an MCP tool call
`knowledge_base_retrieve` against the knowledge base `contoso-policies-kb`; answers cite the policy
documents. Compare with `contoso-policy-agent`. Details: [modules/foundry-iq.md](modules/foundry-iq.md).

## Part 7 — Agent traces (module 5, 5 min)

After Part 5/6, wait 2–5 min → Agents → **Traces** (or **Monitor**). Open a trace: `invoke_agent` →
`execute_tool remote_functions.azure_ai_search` (or the MCP call) → `chat gpt-5.4-mini` with token
counts. From the notebook the same page can't load trace data (private-only query), by design.
Details: [modules/monitoring.md](modules/monitoring.md).

## Part 8 — Private RAG app (module 3, 5 min)

On the workstation: Edge → `https://10.81.4.4:8443/` → accept the certificate warning (self-signed demo
certificate: *Advanced → Continue*) → ask the test questions. Each answer cites `[pol-…]` sources,
listed under the answer; the control question returns "don't know". The app runs on a VM with
**no public IP and no internet egress**, using only its managed identity. See
[modules/rag-demo.md](modules/rag-demo.md).

## Part 9 — Optional: the standalone environment (10 min)

Shows the self-contained variant with its **own** Bastion and jumpbox. Portal → `rg-<prefix>-standalone` →
`vm-jump-<standalone-token6>` → Connect → Bastion → Microsoft Entra ID. Repeat Parts 4–8 with the standalone names
from the table at the top (project `standalone-demo`, RAG app `https://10.80.4.4:8443/`).
`https://10.81.4.4:8443/` (spoke) times out from here: the networks aren't connected.

## Part 10 — Automated full validation (from the notebook, 15 min)

```powershell
pwsh -NoProfile -Command "& ./scripts/validation/Test-Deployment.ps1 -Environment <prefix>-spoke"        # runs in-VNet tests on vm-hub-workstation
pwsh -NoProfile -Command "& ./scripts/validation/Test-Deployment.ps1 -Environment <prefix>-standalone"  # runs in-VNet tests on the jumpbox
```

Latest runs ([validation summary](security/validation-summary.md)):
standalone **101/101** (2026-11-19), hub-spoke **91/91** + hosted agent, managed VNet **105/105** + hosted
agent (2026-11-23), public **14/14**, spoke-ready **20/20** isolation → **30/30** after handover. Reports in
`.test-output/`.

## Part 11 — What to report back

- Results of Parts 5–8 (works / error message); compare with [compatibility](compatibility.md) and the
  [validation summary](security/validation-summary.md).
- Anything that required public access to work (it must not be "fixed" by opening access).

## Cleanup

```powershell
pwsh ./scripts/cleanup/Remove-Environment.ps1 -Environment <prefix>-spoke         # ~20–45 min
pwsh ./scripts/cleanup/Remove-Environment.ps1 -Environment <prefix>-standalone   # ~20–45 min
az group delete -n rg-<prefix>-sample-hub --yes                                        # sample hub test fixture only (after the spoke); never a real hub
```
