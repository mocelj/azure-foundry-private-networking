# Security design

## Principles

1. **No public data plane.** Every PaaS data plane in the default profile has
   `publicNetworkAccess: Disabled` and is reachable only through a private endpoint.
2. **Identity, not keys.** Entra ID everywhere; local/key auth disabled on every service that
   supports it.
3. **Explicit egress.** Subnets are private (`defaultOutboundAccess: false`). Any outbound path is
   a deliberate resource (NAT gateway / hub firewall) and constrained by NSGs.
4. **Fail closed.** Preflight stops unsupported configurations before deployment; the template never
   opens network access to make them work (and never silently ignores an unimplemented feature).
5. **Least privilege.** No Owner/Contributor/UAA to workload identities; data-plane roles at the
   narrowest scope (project, database, ABAC-conditioned containers).

## Control matrix

| Control | Where | Value | Verified by |
|---|---|---|---|
| Foundry PNA | account | `Disabled` | static + live |
| Foundry ACL | account | `defaultAction: Deny`, no IP/VNet rules | static + live |
| Foundry trusted-service bypass | account | `AzureServices` (default) or `None` — see below | static |
| Foundry local auth | account | `disableLocalAuth: true` | static + live |
| Agent outbound | account | `networkInjections` BYO VNet, `useMicrosoftManagedNetwork: false` | static + live |
| Storage | agent files | PNA Disabled, shared key off, public blob off, TLS 1.2, HTTPS only, soft delete 7d | static + live |
| Cosmos DB | agent threads | PNA Disabled, `disableLocalAuth`, `disableKeyBasedMetadataWriteAccess`, TLS 1.2 | static + live |
| AI Search | agent vectors | PNA disabled, `disableLocalAuth` (RBAC only), `bypass: None` | static + live |
| Log Analytics | monitoring | `disableLocalAuth`, resource-permission access | static |
| VM public IP | jumpbox, RAG VM | none (the only public IPs are Bastion's managed ingress and the NAT gateway's egress IP, standalone only) | static + live |
| VM hardening | jumpbox | Trusted Launch (Secure Boot, vTPM), platform patching + hotpatch, Entra login, auto-shutdown | static |
| NSG inbound | all subnets | deny-all; only 443 from VNet (PE/app/integration), RDP only from Bastion subnet (mgmt), platform rules (Bastion) | static + live |
| NSG outbound | mgmt | 443 → PE subnet; 80/443/1688 → Internet via NAT; deny VNet (lateral) and other Internet | static |
| NSG outbound | agent | VNet; 443 → `AzureActiveDirectory`, `AzureMonitor`, `MicrosoftContainerRegistry`, `AzureFrontDoor.FirstParty`; deny Internet | static |
| Diagnostics | Foundry, Bastion, Cosmos, Storage (blob), Search | all logs → Log Analytics | static |
| Secrets in outputs | template | none (linter `outputs-should-not-contain-secrets` = error + test) | static |
| Tags | all | `azd-env-name`, `workload`, `network-mode` | — |

## Documented exceptions

| Exception | Reason | Mitigation |
|---|---|---|
| Bastion Standard public IP | Required by Bastion for its managed HTTPS ingress | Only TLS 443 to the Bastion service; Entra ID + MFA + Conditional Access; RDP never exposed; not created in hub-spoke / spoke-ready |
| Bastion subnet NSG outbound `22,3389 → VirtualNetwork` | **Platform-mandated** (the Bastion compliance check rejects a narrower destination — observed live: `NetworkSecurityGroupNotCompliantForAzureBastionSubnet`) | Target subnets' NSGs enforce reachability: only `snet-management` accepts RDP and only from `AzureBastionSubnet` |
| NAT gateway public IP (standalone) | Jumpbox needs Entra sign-in and the browser-based Foundry portal; agent runtime needs Entra ID / ACA platform endpoints | Outbound only (NAT cannot accept inbound); NSG restricts ports/tags; replace with hub firewall in hub-spoke |
| `networkAcls.bypass: AzureServices` on Foundry and agent Storage (default) | Microsoft's reference network-secured templates; enables trusted services (AI Search, Foundry Tools, Azure ML) with **managed identity + RBAC** | Not internet access. **`None` is validated live for every tested path** (101/101, 2026-11-19): set `FOUNDRY_NETWORK_ACLS_BYPASS=None` and `AGENT_STORAGE_NETWORK_BYPASS=None` unless a feature you need relies on it |
| `NETWORK_MODE=public` (quick-demo profile only) | Laptop demos without VNet/Bastion | Opt-in with `PUBLIC_NETWORK_ACCESS_ACK=true`; IP allow-list; Entra-only; no customer data; tag `network-exposure=public`; static tests keep all other profiles private ([public-quick-demo.md](../public-quick-demo.md)) |
| Agent state processed by Microsoft-managed agent runtime | Inherent to Agent Service | Runtime is injected into the customer subnet; state stored in customer Cosmos/Storage/Search |
| Log Analytics query endpoint | Public by default | Restricted by Entra RBAC; AMPLS is part of the optional advanced monitoring module |

## Trusted-service bypass trade-off

Parameters: `FOUNDRY_NETWORK_ACLS_BYPASS` (Foundry account) and `AGENT_STORAGE_NETWORK_BYPASS` (agent
Storage account), both `AzureServices` (default) or `None`. Cosmos DB and both AI Search services
always use `None`.

| Setting | Allows | Breaks / not covered |
|---|---|---|
| `AzureServices` | AI Search indexers/skillsets and Foundry Tools to call the account using MI (RBAC still required) | — |
| `None` | Nothing but private endpoint / approved shared private link traffic | **Validated live 2026-11-19 with both set to `None`: 101/101** — agent create/run (Standard setup: Cosmos threads, Storage, vector store), Azure AI Search tool, Foundry IQ incl. query planning (shared private link), traces, RAG, citations. Not covered by tests: file upload / file search / Code Interpreter files, evaluations, Search skillsets or integrated vectorization calling Foundry (Learn documents the bypass as required for ingestion-time embeddings) |

## Defender for Cloud recommendations (expected)

| Recommendation | Status in this design |
|---|---|
| Foundry/AI Services should restrict network access / use private link | Met |
| Foundry/AI Services should have local authentication disabled | Met |
| Storage accounts should prevent shared key access / public access | Met |
| Cosmos DB accounts should disable public network access / local auth | Met |
| Azure AI Search should use private link / disable local auth | Met |
| VMs should have Trusted Launch / no public IP / Entra login | Met |
| Diagnostic logs should be enabled | Met for Foundry, Bastion, Cosmos, Storage, Search |
| Storage/Cosmos/Search should use customer-managed keys | **Not met** (platform-managed keys). Add CMK if required by policy. |
| Enable Defender for AI / Storage / Cosmos plans | Subscription-level decision; not enabled by this repo. Recommended for production. |
| Encryption at host for VMs | Not enabled (requires subscription feature registration). |

## Azure Policy compatibility

The template satisfies common built-in deny policies: *Azure AI Services resources should restrict
network access*, *…should have key access disabled*, *Storage accounts should disable public
network access*, *Cosmos DB should disable public network access*, *Network interfaces should not
have public IPs* (only Bastion/NAT PIPs; exempt or use hub-spoke), *Subnets should be associated
with an NSG*. Run `azd provision --preview` (what-if) to surface policy denials before deploying.
