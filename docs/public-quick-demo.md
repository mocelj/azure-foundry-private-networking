# Public quick demo (`NETWORK_MODE=public`) — NOT private

> **Not a private deployment.** The Foundry data planes accept traffic from public networks,
> restricted to `PUBLIC_ALLOWED_IPS` when set. Use it for quick demos with **synthetic data only**,
> never for customer data. Every other profile in this repo stays private by default.

## Why

The private profiles prove an enterprise design, but they take 25–30 minutes to deploy, need Bastion
and a jumpbox (or a hub workstation) to reach anything, and cost about US$20/day. For a quick
"what does Foundry do" demo from a laptop, this profile deploys in **about 4 minutes** with no VMs.

## What it deploys

| | Public quick demo | Private profiles |
|---|---|---|
| Foundry account | `publicNetworkAccess: Enabled`; firewall **deny by default + `PUBLIC_ALLOWED_IPS`** (or Allow if empty, with a preflight warning) | `Disabled`, private endpoint only |
| Authentication | **Entra only** (`disableLocalAuth`), no API keys — unchanged | Entra only |
| Agents | **Basic setup**: agent state in Microsoft-managed storage, no network isolation (`OUTBOUND_NETWORK_MODE=none`) | Standard setup (BYO Cosmos DB, Storage, Search) with BYO or managed VNet |
| Network | No VNet, private endpoints, DNS zones, Bastion, jumpbox, NAT or public IPs | VNet + private endpoints + DNS (+ Bastion/jumpbox in standalone) |
| Optional modules | **None** (preflight fails; Bicep also skips them) | All |
| Tags | `network-exposure=public` on every resource | `network-exposure=private` |
| Deploy time / cost | ~4 min; model tokens + Log Analytics only | ~25–30 min; ~US$15–25/day |

## Deploy

```powershell
azd env new contoso-public --location swedencentral
Get-Content examples/public/public-quick-demo.env | ? { $_ -match '^([^#=]+)=(.*)$' } | % { azd env set $Matches[1] $Matches[2] }
azd env set PUBLIC_ALLOWED_IPS (Invoke-RestMethod https://api.ipify.org)   # your current public IPv4
azd provision
pwsh ./scripts/validation/Test-Deployment.ps1          # optional: -OutsiderVmId <VM with another egress IP>
```

Then open `https://ai.azure.com` from the allowed machine and pick the project `public-demo`.
If your IP changes (VPN, hotel Wi-Fi), update `PUBLIC_ALLOWED_IPS` and run `azd provision` again.

## Guardrails

| Guardrail | Where |
|---|---|
| `PUBLIC_NETWORK_ACCESS_ACK=true` required; red banner in preflight | `scripts/preflight/preflight.ps1` |
| `PUBLIC_ALLOWED_IPS` validated (IPv4/CIDR); warning when empty (open to the internet) | preflight |
| `OUTBOUND_NETWORK_MODE` must be `none`; every optional module, Bastion and jumpbox rejected | preflight + Bicep (`privateNetwork` guard) |
| Every non-public profile must keep `publicNetworkAccess: Disabled` and `network-exposure=private` | `tests/security/StaticSecurity.Tests.ps1` |
| Allow-list turns into deny-by-default IP rules | static test with a synthetic allow-list |

## Validation

`Test-Deployment.ps1` detects `DEPLOYED_NETWORK_MODE=public` and inverts the checks: instead of proving
that public access is rejected, it proves that access is **restricted and Entra-only**:

- account public access enabled, firewall default `Deny`, IP rules = `PUBLIC_ALLOWED_IPS`, local auth off,
  no network injection, no VNet/PE/VM/public IP, tag `network-exposure=public`;
- from the allowed machine: model inference (`PUBLIC-OK`), project API, agent create + run (Basic setup);
  a fake API key is rejected (401);
- with `-OutsiderVmId`: from a VM whose egress IP is **not** allow-listed, an authorized call gets
  `403 Access denied due to Virtual Network/Firewall rules`. The test grants that VM identity a
  **temporary** *Cognitive Services OpenAI User* role on the account and removes it afterwards, because
  authorization is evaluated before the IP firewall: an unauthorized token gets 401, which proves nothing
  about the network (observed 2026-11-19).

**Live result (2026-11-19, `contoso-public`, swedencentral): 14/14 PASS**, deployed in 3 min 53 s. Outsider:
the `contoso-standalone2` jumpbox (egress via its NAT IP) was rejected with 403.

## Not covered

- Private data sources, AI Search, RAG, monitoring module, Foundry IQ: use a private profile.
- The Foundry portal itself is always public; with this profile its data-plane calls work from the
  allowed IP only.
- IPv6 clients aren't supported by the allow-list.
