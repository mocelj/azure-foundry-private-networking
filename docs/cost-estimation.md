# Cost estimation

Indicative **list prices, Sweden Central, USD, November 2026** (Azure Retail Prices API). Excludes
taxes, discounts, reservations. Re-check with the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) before quoting.

## Default profile (`standalone`, `byoVnet`) — fixed costs

| Resource | Unit price | Monthly (730 h) | Notes |
|---|---|---|---|
| Azure Bastion Standard (2 scale units) | $0.29/h | ~$212 | Largest fixed cost. Delete when not demoing, or use hub Bastion. |
| Jumpbox D2s_v5 Windows | $0.19/h | ~$139 always-on / **~$50** with 19:00 UTC auto-shutdown (≈ 11 h/day weekdays) | Deallocated VMs cost only disk (~$10). |
| Azure AI Search Basic (vector store) | $0.10/h | ~$74 | Required by Standard agent setup. |
| NAT gateway | ~$0.045/h + $0.045/GB | ~$33 + data | Standalone only. |
| Public IPs (Bastion, NAT) | ~$0.005/h each | ~$7 | |
| Private endpoints (4) | ~$0.01/h each + $0.01/GB | ~$29 + data | +1 per optional service. |
| Cosmos DB (agent threads) | $0.008 per 100 RU/s-h | depends on RU provisioned by Agent Service (containers created at runtime); budget ~$25–$60 | Check *Cosmos DB > Metrics > Provisioned throughput* after first use. |
| Storage (agent files, ZRS Hot) | ~$0.023/GB-month | < $1 for demos | |
| Private DNS zones (6) | $0.50/zone-month | $3 | Not created in hub mode with central DNS. |
| Log Analytics | ~$2.99/GB (first 5 GB free/billing account) | ~$0–10 | Retention 30 days. |
| **Approx. total** | | **~$450–$600 / month** (≈ $15–20 / day) | |

## Optional modules (add to the profile above)

| Module | Resources | Monthly (approx.) |
|---|---|---|
| 1 AI Search (knowledge) | Second Search Basic ($0.10/h), 1 PE, 1 DNS zone link | ~$80 |
| 3 RAG demo | Ubuntu VM D2s_v5 ($0.10/h; daily auto-shutdown like the jumpbox), disk | ~$25 with auto-shutdown / ~$75 always-on |
| 4 Agent demo | Agent definitions only; tokens per run | < $1 |
| 5 Advanced monitoring | App Insights (workspace-based, ~$2.99/GB ingested beyond the free allowance), AMPLS (free) + 1 PE in standalone, alerts, query pack | ~$10–20 for demo traffic |
| 6 Foundry IQ (option A) | Knowledge source/base on the existing knowledge search; `minimal` reasoning (no LLM call by Search) | ~$0 extra |

Full demo (standalone, all modules): **~$600–$750 / month** (≈ $20–25 / day). Prices from the Azure
Retail Prices API, Sweden Central, checked 2026-11-19.

## Variable costs

| Item | Driver |
|---|---|
| Model inference | Tokens × model price (`gpt-5.4-mini`, DataZoneStandard). Demo usage is typically < $1. |
| Hosted agents | $0.11 per vCPU-hour + $0.01 per GiB-hour (retail, Sweden Central, checked 2026-11-23) while a session's compute runs, including idle time until suspension (default 15 min). Demo agent (1 vCPU / 2 GiB) ≈ $0.13/h active. |
| Private endpoint data | $0.01/GB in + out. |
| NAT / Bastion egress | Per GB. |

## Hub-spoke profile

No Bastion, no jumpbox, no NAT, no public IPs, central DNS → **~$130–$180 / month**
(Search, PEs, Cosmos, LA). Customer hub costs (firewall, resolver, gateway) are not included.

## Reducing demo cost

- Tear down between demos with `scripts/cleanup/Remove-Environment.ps1` (re-deploy takes ~15–30 min; use a new environment name, see teardown notes).
- Keep auto-shutdown enabled (`JUMPBOX_AUTO_SHUTDOWN_UTC`); the validation script starts the VM when needed.
- Delete only Bastion between sessions: `az network bastion delete -g <rg> -n <bastion>` and
  re-run `azd provision` to restore it.
- For a models-only demo, deploy a fresh environment with `OUTBOUND_NETWORK_MODE=none` (no
  Search/Cosmos/Storage, no agents). The mode can't be changed on an existing account.

## Teardown

```powershell
azd down --purge --force                                  # predown hook runs steps 1-4 below
pwsh ./scripts/cleanup/Remove-Environment.ps1            # same, plus a checked azd down
pwsh ./scripts/cleanup/Remove-Environment.ps1 -Environment contoso-spoke
```

**Order matters (verified 2026-11-17).** Without the `predown` hook, `azd down --purge` deletes the
resource group *before* purging the Foundry account. With BYO VNet injection the agent subnet holds a service
association link (`legionservicelink`) until the account is **deleted and purged**, so the
resource-group deletion fails with `InUseSubnetCannotBeDeleted` (and the NSGs, NAT gateway and
route table attached to the VNet fail with it). The script therefore:

1. deletes hub-side peering (if opted in) and AI Search **shared private links** (Foundry IQ
   `reasoning=low`: once the account is purged, Search can't be deleted, `LockedSPLResourceFound`);
2. deletes the Foundry **projects**, then deletes **and purges** the account (accounts with projects can't be deleted; the delete is retried while ARM catches up);
3. waits until `snet-agent` has no service association link (observed: up to ~20 min);
4. removes the Log Analytics workspace and App Insights from any Azure Monitor Private Link Scope
   (a scoped workspace can't be deleted: `CannotDeleteWorkspaceWhenLinkedToPrivateLinkScopes`);
5. runs `azd down --purge --force` and checks the result — the script fails loudly instead of
   reporting a partial cleanup as success.

Steps 1–4 are also the azd `predown` hook (`Remove-Environment.ps1 -PreDown`, via
`scripts/cleanup/predown.ps1`), so a plain `azd down --purge` follows the same order. Both refuse to
run when the az CLI default subscription differs from `AZURE_SUBSCRIPTION_ID` (otherwise every
"not found" check would pass against the wrong subscription while the resources stay behind).

Live 2026-11-19: `contoso-spoke` (script) and `contoso-standalone2` (plain `azd down --purge` + hook) deleted
cleanly; `contoso-public` with plain `azd down`. **Managed VNet** (`contoso-mvnet`): the account delete stayed
in `Deleting` for more than an hour and ended `Failed` overnight (ARM attempts returned `Conflict` /
`GatewayTimeout`); the hook failed safely and azd deleted nothing. Cause: the service-created account
capability host (`<account>@aml_aiagentservice`, bound to the managed VNet's agent subnet) survives
project deletion. After deleting it, the account was gone within ~15 min and a plain
`azd down --purge` completed (2026-11-20, 55 min in total). The script now deletes account capability
hosts first in managed VNet mode.

An interrupted teardown (for example, the sign-in can't be refreshed) stops `azd down` before it
deletes anything. Re-running `azd down --purge --force` is safe and continues from the current state.
Run long teardowns from a machine that stays online.

If `azd down` already failed: purge the account
(`az cognitiveservices account purge -g <rg> -n <account> -l <region>`), wait for the link to
clear, then rerun `azd down --purge --force`.

Special cleanup considerations:

| Resource | Behaviour | Action |
|---|---|---|
| Foundry account | Soft-deleted for 48 h; name and **agent subnet** stay reserved | Purge (script step 2) |
| Capability hosts | Removed with the purged account | — |
| Key Vault | Not deployed by any module today. If you add one: soft delete + purge protection → **cannot be purged** until retention ends | Use a new name for redeploys |
| Log Analytics | Soft-deleted 14 days | `azd down --purge` purges it |
| Cosmos DB / Search / Storage | Deleted immediately | — |
| Hub-side peering (if opted in) | Lives in the hub RG, not removed by `azd down` | Script step 1 |
| AMPLS scoped resources (module 5) | Block workspace deletion; the central hub AMPLS itself is never deleted | Script step 4 |

Observed full teardown with the script (hub-spoke, 2026-11-18): **46 min** end to end, no manual steps, nothing left soft-deleted.
