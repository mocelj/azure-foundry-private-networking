# Troubleshooting

| Symptom | Likely cause | Resolution |
|---|---|---|
| Preflight `[FAIL]` and nothing deployed | Invalid address plan, unregistered provider, model/quota, soft-deleted account | Follow the message; preflight never changes security settings |
| `NetworkSecurityGroupNotCompliantForAzureBastionSubnet` | Bastion NSG missing a platform-mandated rule | Do not customise `bastionRules` in `vnet.bicep`; see security-design.md |
| `error unmarshalling Bicep template parameters: invalid character` | An azd env value contains `"` / `{` / `\` (azd substitutes raw text) | Use the comma-separated formats documented in README; never JSON |
| `403 Public access is disabled. Please configure private endpoint.` | Caller is outside the VNet (expected) or DNS returns the public IP | Use the jumpbox / hub client; `Resolve-DnsName` must return the PE IP |
| DNS returns public IP inside the VNet | Zone not linked / custom DNS not forwarding | Link zones; forward public zones to `168.63.129.16` via resolver (private-dns.md) |
| `401`/`403` with correct network | Missing RBAC (role propagation can take ~5 min) | Check identity-rbac.md roles |
| `AuthorizationPermissionMismatch` (Storage) | RBAC | Assign data role |
| Hosted agent demo (module 7) not deployed / smoke test failed after `azd provision` | Postprovision step failed (runner setup, azd deploy, invoke); the provision itself succeeded | Re-run `pwsh ./scripts/agents/Deploy-HostedAgentAzd.ps1 -Environment <env> -Action all` (or a single step); details in [modules/hosted-agent-demo.md](modules/hosted-agent-demo.md#troubleshooting) |
| Hosted agent: `DelegatedSubnetInUse` on (re)provision | A soft-deleted Foundry account still holds the agent subnet | Purge the account (`az cognitiveservices account purge`); `azd down --purge` does it ([Foundry blog](https://devblogs.microsoft.com/foundry/hosted-agents-private-network-setup/)) |
| Hosted agent: `429 subnet_exhausted` | Delegated agent subnet out of addresses (sessions share it) | Size the subnet for concurrent sessions (`/24` recommended); can't be resized after assignment |
| Hosted agent: `EHOSTUNREACH` to a private endpoint | PE IP in `192.168.0.0/24` (internal sandbox range) | Keep private endpoint addresses out of `192.168.0.0/24` |
| Hosted agent / Agents page times out behind a firewall | TLS inspection of Entra / managed identity endpoints, or Cosmos DB zone not linked to the agent VNet | Exclude `login.microsoftonline.com`, `{region}.login.microsoft.com`, `control-{region}.identity.azure.net` from TLS inspection; link `privatelink.documents.azure.com` (hub-integration.md) |
| `AuthorizationFailure` (Storage) | Network (firewall / PNA) | Use private path |
| Agent version create → `502 upstream_dependency_failed` after ~100 s | Platform/tenant: Entra agent-identity provisioning (for example blocked by Conditional Access); **not** network | Retry later; open support case with request IDs; verify in a tenant without blocking Conditional Access. Do not open network rules. |
| `'agent' property is deprecated` (400) | Old Responses payload | Use `"agent_reference": {"name": "...", "type": "agent_reference"}` |
| `Subnet ... legionservicelink` on delete / redeploy | Foundry account not purged; capability host still bound to agent subnet | `az cognitiveservices account purge`; wait ~20 min |
| Soft-deleted account blocks redeploy | Same name in same RG | `azd down --purge` or purge manually (preflight detects) |
| Run Command fails / jumpbox unreachable | VM deallocated by auto-shutdown | `Test-Deployment.ps1` starts it; or `az vm start` |
| Entra RDP option missing in Bastion | Missing `Virtual Machine User Login` role or extension | Check identity section of validation |
| `OSProvisioningTimedOut` for `vm-jump-*` during `azd provision` | Windows first-boot setup didn't finish within the platform's time limit (VM shows provisioning `Failed`, agent `Not Ready`); not caused by the template | Delete the VM (`az vm delete -g <rg> -n vm-jump-<token> --yes`) and run `azd provision` again; the template recreates it identically |
| Bastion can't list or connect to the VM | Missing `Reader` on the VM, its NIC or the Bastion resource (+ VNet if Bastion is peered) | Re-run `azd provision` (assigned to the deploying principal) or assign Reader as in [identity-rbac.md](identity-rbac.md) |
| Agent creation fails with `name or host unknown` for tools | No project capability host | Capability host is created by default in `byoVnet` |
| Hub-spoke: workstation cannot resolve | Conditional forwarders missing for public zones | hub-integration.md §4 |
| Agent runtime cannot reach Entra in hub-spoke | Firewall allow-list incomplete | hub-integration.md §3; check `AZFWApplicationRule` / `AZFWNetworkRule` deny logs |
| `403 Traffic is not from an approved private endpoint` although PE approved + DNS correct, right after re-creating an account **with the same name** after purge | Service-side state tied to the reused name; persisted >60 min | Use a new `AZURE_ENV_NAME` (new resource token = new account name). Do not open network access |
| `azd provision` says *no changes* after a resource was deleted out-of-band | azd compares template + parameters with the last deployment | `azd provision --no-state` |
| `azd down`: `CannotDeleteWorkspaceWhenLinkedToPrivateLinkScopes` (module 5) | The Log Analytics workspace / App Insights are still scoped resources of an AMPLS (own, or the central hub AMPLS) | `Remove-Environment.ps1` unlinks them from every AMPLS before `azd down` and fails loudly if `azd down` fails |
| Clicking an agent citation opens `https://srch-kb-<token>.search.windows.net/` → **HTTP 401** | Index has no **searchable** `url` field, so the Azure AI Search tool links to the service root; the browser has no token | Re-run `Seed-KnowledgeIndex.ps1` (adds/rebuilds `url`, pointing to the RAG app's `/docs/<id>` page). 401, not 403, proves private reachability |
