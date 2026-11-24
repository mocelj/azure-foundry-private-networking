# Hub-spoke integration (`NETWORK_MODE=hub-spoke`)

The spoke is deployed with **no public IPs, no Bastion, and no jumpbox** by default. Customer-owned
networking (hub VNet, firewall, DNS) is **never modified** unless explicitly opted in.

## 1. Prerequisites from the network team

| Item | Variable | Notes |
|---|---|---|
| Non-overlapping spoke range | `VNET_ADDRESS_PREFIX`, subnet prefixes | Preflight checks overlap with the hub address space and Agent Service reserved ranges. |
| Hub VNet resource ID | `EXISTING_HUB_VNET_ID` | Reader access needed for preflight. |
| Firewall/NVA private IP | `HUB_FIREWALL_PRIVATE_IP` | Creates a `0.0.0.0/0` UDR on workload subnets (not the PE subnet). |
| DNS servers | `CUSTOM_DNS_SERVERS` | Hub DNS Private Resolver inbound IP. |
| Central private DNS zones | `PRIVATE_DNS_ZONE_MODE=existing`, `EXISTING_PRIVATE_DNS_ZONE_IDS` (comma-separated zone resource IDs) | 3 Foundry zones + blob, documents, search when `byoVnet` (search also for the AI Search module). |
| Central Azure Monitor Private Link Scope (optional, module 5) | `EXISTING_AMPLS_ID` | The spoke adds its Log Analytics workspace + App Insights as scoped resources; it never creates an AMPLS private endpoint or monitor DNS records (that would override shared Azure Monitor DNS for every workload). Deployer needs write on the AMPLS (e.g. Monitoring Contributor on it). |
| Private client VM for hooks and tests (optional) | `PRIVATE_CLIENT_VM_ID`, `PRIVATE_CLIENT_PRINCIPAL_ID` | An existing Azure VM with line-of-sight to the spoke (e.g. a hub workstation) and its managed identity object ID; see section 5. |
| Admin source prefixes (only if a spoke jumpbox is enabled) | `HUB_ADMIN_SOURCE_PREFIXES` | e.g. hub `AzureBastionSubnet` prefix. |

Template: [`examples/hub-spoke/hub-spoke.env`](../examples/hub-spoke/hub-spoke.env).

## 2. Peering

| Variable | Effect |
|---|---|
| `ENABLE_HUB_PEERING=true` | Creates the **spoke → hub** peering (in the workload RG). |
| `ENABLE_HUB_SIDE_PEERING=true` | Also creates **hub → spoke** in the hub RG. Opt-in: modifies customer networking; requires `Network Contributor` on the hub VNet. Otherwise the network team creates it. |
| `USE_HUB_GATEWAY=true` | Spoke uses the hub VPN/ER gateway (hub side needs `allowGatewayTransit`). |

The spoke can be deployed first with both peerings off (`spoke-ready`), then connected later.

## 3. Routing and firewall

With `HUB_FIREWALL_PRIVATE_IP` set, `snet-agent`, `snet-management`, `snet-app`,
`snet-integration` get a route table with `0.0.0.0/0 → firewall` and BGP propagation disabled.
The PE subnet is not routed (return traffic is symmetric via the VNet). `/32` routes take priority:
each private endpoint IP is added as a `/32` route in its VNet and peered VNets; as the most specific
route it takes priority over the `0.0.0.0/0` UDR, so private endpoint traffic does not pass the
firewall. Inspecting it would need private endpoint network policies for route tables on the PE subnet,
UDRs at least as specific as the VNet address space and SNAT on the firewall
([Learn](https://learn.microsoft.com/azure/private-link/disable-private-endpoint-network-policy)); not
part of this template.

Minimum firewall allow-list for the BYO VNet agent runtime (from Microsoft Learn):

| Purpose | FQDN / service tag | Port |
|---|---|---|
| Entra ID token acquisition | `login.microsoftonline.com`, `*.login.microsoftonline.com`, `*.login.microsoft.com`, `{region}.login.microsoft.com`, or tag `AzureActiveDirectory` | 443 |
| Managed identity (ACA) | `*.identity.azure.net`, `control-{region}.identity.azure.net` | 443 |
| Container platform | tags `MicrosoftContainerRegistry`, `AzureFrontDoor.FirstParty` | 443 |
| Monitoring | tag `AzureMonitor` | 443 |
| Evaluations / tracing (optional) | `*.livediagnostics.monitor.azure.com`, `*.in.applicationinsights.azure.com` (not needed when App Insights is reached through AMPLS) | 443 |
| Hosted agent → Agent 365 (optional) | `agent365.svc.cloud.microsoft` (or set `a365LoggingEnabled=false`) | 443 |

Do **not** allow `Internet` broadly. Tools that need public endpoints (Bing, web search,
SharePoint grounding) are intentionally excluded from the private profile.

Entra ID has no private endpoint: token traffic goes to the public Entra endpoints
(`AzureActiveDirectory` service tag / login FQDNs) over the Microsoft backbone and carries no
customer data. VM managed identities use IMDS (no egress); platform identities get their tokens
inside the service.

**TLS inspection (Azure Firewall Premium / NVA):** exclude `login.microsoftonline.com`,
`{region}.login.microsoft.com` and `control-{region}.identity.azure.net` from TLS inspection; hosted
agents can't complete token acquisition through an inspecting proxy
([Foundry blog, 2026-11-21](https://devblogs.microsoft.com/foundry/hosted-agents-private-network-setup/)).
Azure Firewall Basic/Standard (as in the sample hub for testing, `tests/integration/sample-hub/`) don't inspect TLS.

## 4. DNS

See [`private-dns.md`](private-dns.md). Peering alone does **not** give workstations private
resolution. Required:

1. Central zones linked to the resolver/hub VNet.
2. Spoke VNet DNS servers = resolver inbound IP (`CUSTOM_DNS_SERVERS`).
3. On-premises conditional forwarders for `services.ai.azure.com`, `openai.azure.com`,
   `cognitiveservices.azure.com`, `blob.core.windows.net`, `documents.azure.com`,
   `search.windows.net` → resolver inbound IP.

## 5. Client access

Workstations on the corporate network reach the PEs over ExpressRoute/VPN → hub → peering. NSG on
the PE subnet allows 443 from `VirtualNetwork` (includes peered and gateway-learned prefixes).
Validate from a workstation:

```powershell
Resolve-DnsName <account>.services.ai.azure.com     # must return the PE IP (10.81.1.x)
Test-NetConnection <pe-ip> -Port 443
```

Then run the in-network tests from that workstation. If it is an Azure VM, set
`PRIVATE_CLIENT_VM_ID` and `PRIVATE_CLIENT_PRINCIPAL_ID` (its managed identity) on the spoke
environment: the identity gets the scoped validation roles, the postprovision hooks (index seeding,
demo agents) run there via VM Run Command, and `Test-Deployment.ps1` uses it automatically.
Otherwise run `scripts/validation/invnet-probe.ps1` manually on the workstation (fill in the
placeholders) or `Test-Deployment.ps1 -Sections network,identity,public` from your machine.

## 6. Policy compatibility

The spoke is compatible with common landing-zone policies: deny public IPs, deny PNA on PaaS,
require private DNS zone groups (DINE policies that add zone groups will produce identical
records), deny local auth, require NSG on subnets.
