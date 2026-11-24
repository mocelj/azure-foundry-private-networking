# Threat model

Scope: default profile (`standalone`, `byoVnet`); hub-spoke differs only in the access path (no Bastion,
jumpbox or public IPs; egress via the customer firewall; central DNS and AMPLS). STRIDE-oriented; residual risk rated
Low / Medium / High after mitigations.

| # | Threat | Mitigation | Residual | Validation |
|---|---|---|---|---|
| 1 | **Public endpoint exposure** of Foundry, Storage, Cosmos DB, Search | PNA Disabled, ACL Deny, no IP/VNet rules, PEs only | Low — misconfiguration by later manual change | Static tests; live `public` section asserts **403 with a network error code** using a *valid* token (401 is treated as inconclusive) |
| 2 | **Unauthorized model invocation** | Entra-only (`disableLocalAuth`); `Cognitive Services OpenAI User` only to named principals; network restriction | Low | Live identity checks; key auth disabled check |
| 3 | **Excessive RBAC permissions** | No Owner/Contributor/UAA; project-scoped Foundry User; ABAC on blob; Cosmos SQL role at database scope | Low–Medium (deployer is privileged during deployment) | Static + live "no broad roles" checks; use OIDC SP with time-bound PIM for CI |
| 4 | **Prompt injection** (direct / indirect via documents) | `Microsoft.DefaultV2` RAI policy (Prompt Shields), restricted agent tools (no public-web tools in private profile), least-privilege tool identities | Medium — inherent to LLMs | Optional agent demo with adversarial prompts; review RAI content filter logs |
| 5 | **Data exfiltration** | Agent subnet NSG denies Internet except platform service tags; no public tools; PNA disabled on stores; hub firewall FQDN allow-list in enterprise mode | Medium — service tags (e.g. `AzureFrontDoor.FirstParty`) are broad | NSG static tests; firewall logs (hub); alternative: `OUTBOUND_NETWORK_MODE=managedVnet` (`AllowOnlyApprovedOutbound`, preview; no egress logs) |
| 6 | **Compromised managed identity** | System-assigned MIs (no exportable secrets); scoped roles; IMDS only reachable from the VM | Medium for jumpbox MI (validation roles) | Remove validation roles after testing (`GRANT_JUMPBOX_VALIDATION_ROLES=false`); Entra sign-in logs |
| 7 | **Malicious document ingestion** | Private stores; ingestion only by authorised identities; RAI policy on outputs | Medium | Optional RAG module: content validation step |
| 8 | **Search index data leakage** | Search PNA disabled, local auth disabled, RBAC; per-project vector indexes | Low–Medium (no document-level security trimming in core) | Live negative test; security trimming is an application concern |
| 9 | **Agent tool misuse** | Only BYO VNet tools; no Bing/web search/SharePoint; Foundry User required to change agents | Medium | Agent demo tests restricted tool set |
| 10 | **Secrets exposure** | No keys anywhere; jumpbox admin password random & never output; linter + test forbid secret outputs; `.azure/` git-ignored | Low | Static tests; repo secret scanning in CI |
| 11 | **Insecure outbound connectivity** | Private subnets; NAT/firewall explicit; NSG deny Internet; jumpbox only web ports | Medium (jumpbox can browse 443) | Static NSG tests |
| 12 | **DNS misconfiguration** (public resolution → bypass attempt / outage) | Zone groups on every PE; zones linked; hub mode uses central zones; validation resolves every FQDN from inside | Low (public resolution yields 403, not a bypass) | In-VNet DNS tests (all A records in PE subnet) |
| 13 | **Lateral movement between subnets** | Per-subnet NSGs with deny-all inbound; jumpbox NSG denies VNet outbound except PEs:443; Bastion→RDP only to management subnet | Low | Static NSG tests |
| 14 | **Logging of sensitive prompts / responses** | Foundry resource logs record metadata, not content; Log Analytics RBAC; no App Insights content capture in core | Low–Medium (if tracing with content capture is enabled later) | Review diagnostic categories; keep `enableContentRecording` off in agent tracing |
| 15 | **Bastion abuse** | Entra ID + MFA/CA; VM User Login (non-admin); no shareable links, no IP connect, no file copy | Low | Static Bastion properties; Bastion audit logs |
| 16 | **Deployment pipeline compromise** | OIDC federated credentials, no stored secrets, environment protection rules | Medium | CI configuration review |
