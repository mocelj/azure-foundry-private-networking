# Customer demonstration guide (20–30 minutes)

Preparation (day before): `azd provision`, run `Test-Deployment.ps1` (all PASS), open the
Azure portal on the resource group, have a terminal with `az` logged in, and start the private
client (standalone: the jumpbox; hub-spoke: the hub workstation). Keep the latest local
`.test-output/validation-*.md` report and the [validation summary](security/validation-summary.md) at hand as
evidence. The [end-to-end test guide](e2e-test-guide.md) has click-by-click steps for every module.

---

### 1. Architecture overview (4 min)

| | |
|---|---|
| **Show** | [Standalone diagram](img/architecture/architecture-standalone.png) (or `architecture.drawio`); the resource group in the portal |
| **Explain** | Current Foundry model (account + projects); one private endpoint per service; six core private DNS zones (more with optional modules); agent runtime injected into *your* subnet; agent data in *your* Cosmos/Storage/Search |
| **Expected** | Customer can map each box to a resource |
| **Security message** | "No data plane in this design accepts traffic from public networks — and we will prove it, not just claim it." |

### 2. Private endpoint demonstration (3 min)

| | |
|---|---|
| **Show** | Portal → Foundry account → Networking: *Public access: Disabled*; *Private endpoint connections: Approved*. Repeat for Cosmos DB, Storage, Search |
| **Explain** | PNA disabled is the control; the PE is the only path. Removing a PE does *not* make the service public |
| **Expected** | 4 core PEs (+ knowledge search, AMPLS with the optional modules), all Approved, PNA Disabled everywhere |
| **Security message** | Network isolation is enforced by the platform, not by obscurity |

### 3. DNS resolution (3 min)

| | |
|---|---|
| **Show** | Laptop: `Resolve-DnsName <acct>.openai.azure.com` → public IP via `privatelink` CNAME. Private client (jumpbox / hub workstation): same command → private PE IP (`10.80.1.x` standalone, `10.81.1.x` spoke) |
| **Explain** | Same URL, different answer depending on network — DNS is why private endpoints work transparently, and why hub-spoke needs DNS forwarding, not just peering |
| **Expected** | Public vs private IP |
| **Security message** | DNS misconfiguration fails closed (403), it never opens a bypass |

### 4. Public network access validation (4 min)

| | |
|---|---|
| **Show** | `pwsh ./scripts/validation/Test-Deployment.ps1 -Sections public` |
| **Explain** | We send a **valid Entra token** from the internet. A 401 would only prove we lacked credentials; a 403 *"Public access is disabled"* proves the network layer rejected us |
| **Expected** | Foundry: `403 Public access is disabled`; Cosmos: `blocked by firewall`; Search: `publicNetworkAccess: Disabled`; Storage: `AuthorizationFailure` |
| **Security message** | Identity alone is not enough — the request must also come from an approved network |

### 5. Secure model invocation (4 min)

| | |
|---|---|
| **Show** | `Test-Deployment.ps1 -Sections invnet` (or on the jumpbox, PowerShell with an Entra token) → `PRIVATE-OK` |
| **Explain** | Managed identity token from IMDS, call over the private endpoint, no API key exists (`disableLocalAuth`) |
| **Expected** | HTTP 200 with `PRIVATE-OK` |
| **Security message** | No secrets to leak or rotate |

### 6. Managed identity and RBAC (3 min)

| | |
|---|---|
| **Show** | Portal → Foundry project → Access control; `docs/identity-rbac.md` matrix; Storage role assignment with ABAC condition |
| **Explain** | Least privilege per identity; project MI can only touch its own containers/database; nobody gets Owner/Contributor at runtime |
| **Expected** | Matrix matches portal |
| **Security message** | Network isolation and RBAC are independent layers — both must be passed |

### 7. Optional: private agents, RAG, Foundry IQ, traces (6 min)

| | |
|---|---|
| **Show** | Private client → `ai.azure.com` → project → Agents → `contoso-policy-agent`: ask "What is the hotel limit per night in Europe?" → grounded answer with a citation that opens the private RAG document page. `contoso-iq-agent`: same question via the Foundry IQ knowledge base (MCP). RAG web app `https://10.80.4.4:8443/`. Traces tab: the run with its tool calls (stored in App Insights, query private only) |
| **Explain** | BYO VNet + Standard setup: runtime in your subnet, state in your tenant (Cosmos `enterprise_memory`); the search tool, MCP endpoint, model and traces are all reached over private endpoints; public tools (Bing, web search) are excluded — remove `web_search`, which the portal adds by default to new agents |
| **Expected** | Validated live 2026-11-19 in standalone and hub-spoke ([validation summary](security/validation-summary.md)) |
| **Security message** | Data residency and egress control for agentic workloads |

### 8. Hub-spoke integration discussion (3 min)

| | |
|---|---|
| **Show** | [Hub-spoke diagram](img/architecture/architecture-hub-spoke.png); `examples/hub-spoke/hub-spoke.env`; `docs/hub-integration.md` |
| **Explain** | No Bastion/jumpbox/public IP in the spoke; central DNS zones; UDR to your firewall; we never modify your hub unless you opt in |
| **Expected** | Agreement on DNS forwarding and firewall allow-list |
| **Security message** | Fits existing landing-zone guardrails and Azure Policy |

---

**Do not claim** that every Foundry portal feature works over Private Link, or that Foundry IQ private
ingestion (B) is private: validated are Foundry IQ option A (knowledge base over an existing private index)
and query planning (A+, model calls over an approved shared private link). Check the
[validation summary](security/validation-summary.md) and
[private-networking-limitations.md](private-networking-limitations.md) before promising a feature.
