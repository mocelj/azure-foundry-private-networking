# ADR 0001 — Foundry resource architecture and private networking model

- **Status:** Accepted
- **Date:** 2026-11-17 (amended 2026-11-19, see [Amendments](#amendments))
- **Deciders:** Platform engineering / security architecture

## Context

The repository must deliver a reusable, security-first Microsoft Foundry deployment, orchestrated
by `azd`, that does not expose Foundry data-plane endpoints publicly by default and that can run
standalone (Bastion + jumpbox), as a spoke of an existing enterprise hub, or as an unconnected
"spoke-ready" landing zone.

Two Foundry resource models exist:

1. **Legacy hub-based model** — `Microsoft.MachineLearningServices/workspaces` (kind `Hub` /
   `Project`) plus a separately created Azure OpenAI / AI Services account, Storage account, and
   Key Vault, all private-linked individually; outbound isolation via the AML managed VNet.
2. **Current Foundry model** — a `Microsoft.CognitiveServices/accounts` resource of kind
   `AIServices` with `allowProjectManagement: true` and child
   `Microsoft.CognitiveServices/accounts/projects`. Model deployments, projects, connections and
   capability hosts are children of the same account. One private endpoint (group `account`)
   serves the account, its projects and the OpenAI-compatible inference endpoints.

## Decision

1. **Use the current Foundry model** (`Microsoft.CognitiveServices/accounts` kind `AIServices` +
   `accounts/projects`). No hub, no `MachineLearningServices` workspace.
2. **API version:** `2026-09-01` (GA) for `accounts`, `accounts/projects`, `accounts/deployments`.
   `2026-11-01` is registered in the resource provider but the Bicep type library (Bicep 0.49.2)
   has no types for it yet; we prefer compile-time validation. Re-evaluate on Bicep upgrade.
3. **Inbound isolation (default and mandatory in every mode):**
   - `publicNetworkAccess: Disabled`
   - `networkAcls.defaultAction: Deny`, no IP rules, no VNet rules.
   - `networkAcls.bypass: AzureServices` (parameter `networkAclsBypass`, may be set to `None`; the agent
     Storage account has the same choice via `AGENT_STORAGE_NETWORK_BYPASS`. `None` for both is validated
     live for every tested path, 2026-11-19).
     This matches Microsoft's network-secured reference templates and lets only the *trusted
     services* (Foundry Tools, Azure AI Search, Azure ML) reach the account using their managed
     identity **and** an RBAC grant. It is not public access. `None` is supported for customers
     that do not use AI Search / evaluations; the trade-off is documented in
     `docs/security/security-design.md`.
   - One private endpoint, group ID `account`, registered in **three** private DNS zones:
     `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`,
     `privatelink.services.ai.azure.com`.
4. **Authentication:** Microsoft Entra ID only. `disableLocalAuth: true` on the account; no keys
   are listed, output, or stored.
5. **Outbound isolation — BYO VNet injection is the primary (default) mode.**
   Parameter `OUTBOUND_NETWORK_MODE` / `outboundNetworkMode`:

   | Value | Status | Behaviour |
   |---|---|---|
   | `byoVnet` (**default**) | Implemented | Dedicated `snet-agent` (`/24`) delegated **exclusively** to `Microsoft.App/environments`, referenced by `networkInjections[scenario=agent, useMicrosoftManagedNetwork=false]` **at account creation**, plus a project capability host (`capabilityHostKind: Agents`) with **Standard agent setup** (BYO Cosmos DB, Storage, AI Search, each behind a private endpoint) *(amended, A1)*. Mirrors the official `15-private-network-standard-agent-setup` / `19-private-network-agent-tools` templates. |
   | `managedVnet` | **Implemented, PREVIEW** *(A6)* | Microsoft-managed VNet (`accounts/managedNetworks@2026-09-15-preview`, `AllowOnlyApprovedOutbound`, no FQDN rules), Standard setup kept. Requires `MANAGED_VNET_PREVIEW_ACK=true` and a supported region: preview-only API, irreversible, no switch from/to BYO VNet. See `docs/modules/managed-vnet.md` |
   | `none` | Implemented | Models only; no agent subnet, no capability host. |

   Rationale: outbound mode is a **creation-time** decision — `networkInjections` cannot be added
   or changed later and there is no BYO→managed upgrade path. Making BYO VNet the default means a
   customer who later adds agents does not have to redeploy Foundry, and keeps all agent egress
   inside customer-controlled subnets, NSGs, UDRs and firewalls (hub mode).
   Agent subnet egress is **explicit and restricted**: NSG outbound allows only `VirtualNetwork`
   and the service tags required by the injected Container Apps environment and Entra ID
   (`AzureActiveDirectory`, `AzureMonitor`, `MicrosoftContainerRegistry`,
   `AzureFrontDoor.FirstParty`) and denies `Internet`. Standalone uses a NAT gateway for that
   path; hub mode routes via the customer firewall. Agent tools that require public endpoints
   (Bing, Web search, SharePoint) are therefore blocked by design.
   **Standard agent setup** (BYO Storage + Cosmos DB + AI Search with private endpoints,
   template 15/19 pattern) is part of the core with `byoVnet` *(amended, A1)*.
6. **No Key Vault and no secrets in the core.** *(Amended, A1: Storage, Cosmos DB and AI Search are
   in the core as Standard agent setup dependencies when `byoVnet`.)* Originally: "No Storage / Key
   Vault / Cosmos DB in the core. The core holds no secrets and stores no data; adding unused PaaS
   resources increases attack surface and cost." All data services (Standard setup dependencies and
   optional modules) are deployed with private endpoints, PNA disabled, RBAC-only access, and (for
   any future Key Vault) soft delete + purge protection.
7. **Administrative access (standalone):** Azure Bastion **Standard** (needed for native client
   tunnelling and Entra auth via CLI) + Windows Server 2025 jumpbox with **no public IP**,
   Trusted Launch, Entra ID sign-in (`AADLoginForWindows`), and a random, never-output local
   administrator password (break-glass only via ARM `VMAccess`).
8. **Jumpbox egress:** New Azure subnets are private by default (no default outbound access). The
   jumpbox needs outbound HTTPS for Entra sign-in and for the browser-based Foundry portal shell.
   In standalone mode a **NAT gateway** on the management subnet only provides explicit,
   outbound-only egress; NSG outbound rules allow HTTPS only. In hub mode egress goes through the
   customer firewall via UDR; no NAT/public IP is created.
9. **DNS:** Standalone/spoke-ready create and link the zones to the spoke VNet. Hub mode can
   reference **existing centrally-managed zones** (no zone creation, no links — the hub team links
   them to the hub/DNS resolver VNet).
10. **Modes** share the same modules and differ only in parameters: `standalone` (default),
    `hub-spoke`, `spoke-ready`.

## Consequences

- One PE + three zones covers the account, project API (`*.services.ai.azure.com`), Foundry
  Tools (`*.cognitiveservices.azure.com`) and OpenAI-compatible inference (`*.openai.azure.com`).
- Users outside the VNet (including a laptop on the internet) get HTTP **403** with a
  public-access-disabled error even with a valid token; the validation suite checks the error
  code, not just the status, to distinguish network rejection from authentication failure.
- The Foundry portal (`ai.azure.com`) is a public web app; its *data-plane* calls are made from the
  browser to the account FQDNs, so it only works from a network that resolves those FQDNs to the
  private endpoint (the jumpbox, or a hub-connected workstation).
- With the default `byoVnet`, agents can be built immediately (Standard setup; agent state in the customer tenant). Switching to
  `managedVnet` or `none` — or changing the agent subnet — requires redeploying the Foundry
  account. Account deletion must be followed by a **purge** and ~20 min wait before the agent
  subnet can be reused (service association link `legionservicelink`).
- Bastion (Standard) requires a Standard public IP for its managed ingress on 443. This is the
  Bastion service endpoint only; RDP/SSH are never exposed and the jumpbox has no public IP.
  A NAT gateway public IP is used for jumpbox **egress only** (no inbound possible).

## Alternatives considered

| Alternative | Reason not chosen |
|---|---|
| Legacy hub (`MachineLearningServices` workspaces) | Superseded; more resources/PEs; spec forbids unless required. |
| Managed VNet for outbound (as default) | Kept as **option 2** (`managedVnet`). Preview API in this subscription; irreversible; no customer control of egress firewall; no NIC visibility for audits. |
| Model-only core without injection | Would force a Foundry redeployment as soon as agents are needed. Still available as `outboundNetworkMode=none`. |
| `publicNetworkAccess: Enabled` + IP rules | Still a public endpoint; violates default requirement. |
| Bastion Developer SKU | No VNet-injected subnet/NSG control, no native client, limited regions. |
| Bastion Premium private-only | Requires ExpressRoute/VPN into the VNet; documented for hub mode. |
| Default outbound access for jumpbox | Being retired; implicit, unmanaged, not auditable. |

## Amendments

| # | Date | Change | Reason |
|---|---|---|---|
| A1 | 2026-11-17 | `byoVnet` uses **Standard agent setup** (BYO Cosmos DB, Storage, AI Search with private endpoints) in the core instead of Basic setup | With Basic setup, threads, files and vectors live in Microsoft-managed storage outside the customer tenant; the enterprise goal (data residency, private access to agent state) requires Standard setup. Decision 6 no longer excludes Storage / Cosmos DB from the core |
| A2 | 2026-11-18 | Hub-spoke joins a **central** Azure Monitor Private Link Scope (`EXISTING_AMPLS_ID`); only standalone creates its own | An AMPLS private endpoint in a spoke would override shared Azure Monitor DNS for every workload using the hub DNS |
| A3 | 2026-11-18 | Managed VNet (option 2) to be implemented as an explicitly marked **preview** option in a separate environment | `accounts/managedNetworks` is still preview-only after Ignite 2026; irreversible per account |
| A7 | 2026-11-19 | `NETWORK_MODE=public` quick-demo profile: Foundry public access with IP allow-list, Entra-only, Basic agent setup, no VNet / optional modules; requires `PUBLIC_NETWORK_ACCESS_ACK=true`; tagged `network-exposure=public` | Fast (~4 min), cheap demos from a laptop with synthetic data. Explicit opt-in, separate profile, static tests keep every other profile private; validated 14/14 incl. an outsider IP rejected by the firewall |
| A6 | 2026-11-19 | Managed VNet implemented: `OUTBOUND_NETWORK_MODE=managedVnet` + `MANAGED_VNET_PREVIEW_ACK=true`; `AllowOnlyApprovedOutbound` only, no FQDN rules; account MI gets Azure AI Enterprise Network Connection Approver on the RG; repo adds managed PE rules for the knowledge search and AMPLS. Default stays `byoVnet`. *Addendum 2026-11-23:* managed PE rule to the account itself (`pe-foundry-account`, subresource `account`) added, required for hosted agents | Validated live 104/104. BYO VNet stays default: GA, customer firewall and egress logging |
| A4 | 2026-11-19 | The Foundry account is created **after** the AMPLS private endpoint and DNS (standalone) | The injected agent runtime otherwise resolves the public ingestion endpoint and never sends traces (observed live, see `docs/modules/monitoring.md`) |
| A5 | 2026-11-19 | Optional Foundry IQ query planning (`FOUNDRY_IQ_REASONING=low\|medium`) uses an outbound **shared private link** knowledge search → Foundry (`openai_account`), approved post-provision by a narrow script (exact request, exactly one, fail otherwise; `FOUNDRY_IQ_AUTO_APPROVE=false` for owner approval). Default stays `minimal` (no outbound call) | Keeps the model call on Private Link instead of the trusted-service exception (validated with the exception off). The only automatically approved connection that originates outside the customer's network, hence opt-in |
