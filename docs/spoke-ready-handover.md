# Spoke-ready deployment and network handover

`NETWORK_MODE=spoke-ready` deploys a fully private Foundry workload that nobody can reach yet:
no Bastion, no jumpbox, no peering, no egress route, no public IPs. It fits organisations where
the workload team deploys first and the network team connects spokes later (landing-zone
vending, Azure Virtual Network Manager, change process). Sample: [`examples/hub-spoke/spoke-ready.env`](../examples/hub-spoke/spoke-ready.env)
(models only, `OUTBOUND_NETWORK_MODE=none`; use `byoVnet` if the spoke needs agents — that choice can't
be changed later).

## Decide DNS up front (recommended)

If the central private DNS zones already exist, deploy with them from day one:

```powershell
azd env set PRIVATE_DNS_ZONE_MODE existing
azd env set EXISTING_PRIVATE_DNS_ZONE_IDS "<comma-separated central zone IDs>"
```

Then the handover is **peering only**. Preflight warns when `spoke-ready` uses `create` mode.

## Handover runbook (spoke-ready deployed with its own DNS zones)

| Step | Who | Action |
|---|---|---|
| 1 | Network team | Peer spoke ↔ hub (and UDR to the hub firewall if workloads need egress). Validated: peering alone is **not** enough, see finding F1 |
| 2 | Network / workload team | `pwsh ./scripts/handover/Switch-ToCentralDns.ps1 -Environment <env> -CentralZoneIds <ids> -HubDnsServers <resolver IP>`: deletes the PE DNS zone groups, re-provisions with `PRIVATE_DNS_ZONE_MODE=existing` (records land in the central zones), verifies every PE, removes the empty local zones, sets the spoke VNet DNS to the hub resolver |
| 3 | Workload team | Validate from a hub-connected client: `Test-Deployment.ps1 -Environment <env> -ClientVmId <hub VM>` |

Nothing is opened publicly at any point. During step 2 the private names are unresolvable for a
few minutes; Foundry stays private.

## Live validation (2026-11-18)

Isolation after deployment: **20/20 PASS** (public access → `403 Public access is disabled`; no peerings, route tables, public IPs or VMs). Peering only: hub clients get **NXDOMAIN** (finding F1). After `Switch-ToCentralDns.ps1`: **30/30 PASS** from a hub-connected client (central DNS → private endpoint IPs, inference, project API 200, public 403). Teardown with `Remove-Environment.ps1`: ~14 min.

## Findings

| # | Finding | Consequence |
|---|---|---|
| F1 | After peering, hub clients get **NXDOMAIN**, not the public IP: the central `privatelink.*` zones are authoritative and have no records for the spoke's account | Peering alone isn't enough: hub DNS can't resolve the spoke's private endpoints until their records move to the central zones (handover script, validated 30/30) |
| F2 | Azure rejects repointing a PE DNS zone config to another zone: `UpdatingPrivateDnsZoneIdOnPrivateDnsZoneConfigNotAllowed` | Zone groups must be deleted and recreated → `Switch-ToCentralDns.ps1` |
| F3 | Account **re-created with the same name** ~20 min after purge. Through the approved PE (DNS and NIC IP mapping verified): inference via `*.cognitiveservices` / `*.services.ai` 200, via `*.openai` 404, project API `403 Traffic is not from an approved private endpoint`. Persisted >60 min, and after the PE was deleted and recreated. A deployment with a never-used name passed 30/30, so this is tied to **name reuse** | Not a network-design issue (deployments with never-used names passed 30/30). Suspected service-side Private Link state tied to the reused name. **Avoid reusing account names right after purge** (new `AZURE_ENV_NAME` → new token). Never "fixed" by opening network access |
| F4 | After deleting a resource out-of-band, `azd provision` reported "no changes" and did not recreate it (azd compares template + parameters with the last deployment) | Use `azd provision --no-state` |
| F5 | Without its PE the account is still not reachable: names fall back to the public IP and get `403 Public access is disabled` | Isolation holds even in a broken state |
