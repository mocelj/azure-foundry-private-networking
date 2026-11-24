# Private DNS

Private endpoints only work if clients resolve the service FQDN to the endpoint's private IP.
Peering a VNet **does not** make DNS work.

## Zones used

| Service | PE group | Private DNS zone | Public zone to forward |
|---|---|---|---|
| Foundry account (project API, agents) | `account` | `privatelink.services.ai.azure.com` | `services.ai.azure.com` |
| Foundry OpenAI-compatible inference | `account` | `privatelink.openai.azure.com` | `openai.azure.com` |
| Foundry Tools / Cognitive Services | `account` | `privatelink.cognitiveservices.azure.com` | `cognitiveservices.azure.com` |
| Storage (agent files) | `blob` | `privatelink.blob.core.windows.net` | `blob.core.windows.net` |
| Cosmos DB (agent threads) | `Sql` | `privatelink.documents.azure.com` | `documents.azure.com` |
| AI Search (agent vectors) | `searchService` | `privatelink.search.windows.net` | `search.windows.net` |
| Azure Monitor Private Link Scope (module 5, **standalone only**) | `azuremonitor` | `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net`, `privatelink.blob.core.windows.net` | shared Azure Monitor endpoints (`api.loganalytics.io`, `*.in.applicationinsights.azure.com`, …). One AMPLS per DNS; hub-spoke joins the central AMPLS, see [modules/monitoring.md](modules/monitoring.md) |

The Foundry account has **one** private endpoint (group `account`) with **three** IP configurations on
one NIC, one per zone: `default` → `privatelink.cognitiveservices.azure.com`, `secondary` →
`privatelink.openai.azure.com`, `third` → `privatelink.services.ai.azure.com` (live `contoso-standalone2`:
10.80.1.17 / .18 / .19). The PE's zone group has three configs, so each zone gets its own A record.

## Resolution chain

```text
aif-xxxx.openai.azure.com
  CNAME aif-xxxx.privatelink.openai.azure.com
    ├─ inside VNet (zone linked):   A 10.80.1.x      → private endpoint
    └─ outside (public DNS):        CNAME …cloudapp… → public IP → 403 (public access disabled)
```

## Modes

| `PRIVATE_DNS_ZONE_MODE` | Behaviour |
|---|---|
| `create` (default) | Creates the zones in the workload RG and links them to the spoke VNet. |
| `existing` | **Creates no zones and no links.** PE zone groups write A records into the zone resource IDs given in `EXISTING_PRIVATE_DNS_ZONE_IDS` (comma-separated; the zone name is taken from the ID). JSON is deliberately not used: azd substitutes environment values into `main.parameters.json` without escaping. The platform team links those zones to the hub/resolver VNet. Avoids duplicate zones. |

The deployer needs `Private DNS Zone Contributor` (or `…/privateDnsZones/A/write` +
`join/action`) on central zones in `existing` mode.

## Custom DNS / on-premises

- Set `CUSTOM_DNS_SERVERS` (comma-separated) to point the spoke at the hub **Private DNS Resolver
  inbound endpoint** (or your DNS servers).
- A spoke deployed with local zones (`spoke-ready`) can't simply be re-pointed. Peering alone isn't
  enough: hub DNS can't resolve the spoke's private endpoints (NXDOMAIN) until their records move to the
  central zones, and PE zone groups can't be changed in place. Use
  [`scripts/handover/Switch-ToCentralDns.ps1`](../scripts/handover/Switch-ToCentralDns.ps1), see
  [spoke-ready-handover.md](spoke-ready-handover.md).
- The resolver VNet must be linked to all zones above.
- On-premises DNS: create **conditional forwarders** for each *public* zone in the table
  (`openai.azure.com`, `services.ai.azure.com`, …) to the resolver inbound IP. Forwarding only
  the `privatelink.*` names is not enough, because clients query the public name first.
- Azure-provided DNS (`168.63.129.16`) is only reachable from inside Azure VNets.

## Validation

`Test-Deployment.ps1` (in-VNet section) resolves every FQDN on the jumpbox and verifies all A
records are inside the PE subnet, then opens TCP 443. Manual check from a private client:

```powershell
Resolve-DnsName aif-xxxx.services.ai.azure.com   # expect 10.80.1.x
Test-NetConnection 10.80.1.x -Port 443
```
