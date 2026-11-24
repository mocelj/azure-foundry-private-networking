# Optional module 3 — Private RAG demo app

Enable (requires the AI Search module):

```powershell
azd env set ENABLE_AI_SEARCH true
azd env set ENABLE_RAG_DEMO true
azd provision            # preflight -> Bicep -> seed index -> deploy app -> in-VM smoke test
                         # (data-plane steps run via VM Run Command on the jumpbox or PRIVATE_CLIENT_VM_ID)
```

Sample profile: [`examples/private-rag/full-demo.env`](../../examples/private-rag/full-demo.env)

## What it is

The "private app tier" of the template (full-demo profile E). It is **not** part of the option A
baseline; it demonstrates the customer-app pattern: no Internet egress, managed identity only, an NSG
that admits only port 8443 from the VNet, and a citation target for the agents. For production
workloads, App Service or Container Apps (with private endpoints and VNet integration) are the usual
choice instead of a VM.

A small, keyless **retrieval-augmented generation** web app that answers questions about the
synthetic Contoso policies in the private knowledge index and cites its sources:

```text
browser (jumpbox / hub workstation)
   │ HTTPS :8443 (private IP only)
   ▼
vm-rag-<token>  (snet-app, no public IP, no internet egress)
   ├─ 1. IMDS → Entra tokens for search.azure.com + cognitiveservices.azure.com (VM managed identity)
   ├─ 2. POST srch-kb-<token>.search.windows.net/indexes/contoso-policies/docs/search   (private endpoint)
   └─ 3. POST aif-<token>.openai.azure.com/openai/v1/responses (model deployment)       (private endpoint)
```

| Endpoint | Purpose |
|---|---|
| `GET /` | HTML form (for the Bastion browser demo) |
| `POST /api/ask` `{"question": "..."}` | JSON `{answer, sources[{id,title,score}]}` |
| `GET /healthz` | Liveness |
| `GET /docs/<id>` | Read-only source document page (fetched by key from the private index with the VM identity). Used as **citation target** for the agents and the RAG answers |

Source: [`src/rag-demo/app.py`](../../src/rag-demo/app.py) — Python **standard library only**.

## Hosting decision (ADR summary)

The user chose **option A — private Linux VM in `snet-app`** over App Service / Container Apps with
private endpoints.

| Concern | Decision |
|---|---|
| Inbound | No public IP. `snet-app` NSG allows **only TCP `RAG_APP_PORT` (8443) from `VirtualNetwork`** (covers the peered hub). Everything else denied. |
| Outbound | `defaultOutboundAccess: false` + NSG `DenyInternetOutbound`. The VM needs no internet: stdlib app, tokens via IMDS, all data-plane calls go to private endpoints. Validated live (www.microsoft.com, pypi.org, login.microsoftonline.com all unreachable). |
| Code delivery | `scripts/rag/Deploy-RagApp.ps1` pushes the app over the **management plane** with VM Run Command — no SSH, no package feeds, no SCM endpoint, works from a notebook or CI runner outside the network. |
| Identity | System-assigned MI with **Cognitive Services OpenAI User** (account) and **Search Index Data Reader** (knowledge search) only. No keys anywhere. |
| VM hardening | Ubuntu 24.04, Trusted Launch (Secure Boot + vTPM), random admin password never output, no SSH rule, daily auto-shutdown (`JUMPBOX_AUTO_SHUTDOWN_TIME`). |
| Process hardening | systemd unit as unprivileged `rag-demo` user, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, empty capability set. |
| TLS | Self-signed certificate (SAN = private IP), generated on the VM at first deploy. **Demo only**: production should use a certificate from the enterprise PKI / Key Vault and a private DNS name. |
| Logging | Request method + path only — **no prompt or answer content** in logs (aligns with pol-002). |
| Jumpbox access | The management NSG's lateral-movement deny (`DenyVirtualNetworkOutbound`) gets one narrow exception `AllowAppPortToAppSubnet` (management subnet → `snet-app`, app port only). |

Why not App Service / Container Apps? Both work privately but need extra private endpoints (+ SCM),
a private registry or build agent with network line-of-sight, and more cost. They are the right
choice for production apps; the VM keeps the demo dependency-free and fully deployable from outside
the network. See [private-networking-limitations.md](../private-networking-limitations.md).

## Network address plan

`snet-app` = `APP_SUBNET_PREFIX`; if empty and the RAG demo is enabled it defaults to the 5th `/24`
of the VNet (`cidrSubnet(VNET_ADDRESS_PREFIX, 24, 4)` → `10.80.4.0/24` standalone, `10.81.4.0/24`
for the spoke example). Preflight computes the same default and checks overlaps.

## Using it

1. Bastion → jumpbox (or hub workstation) → Edge → `RAG_APP_URL` (e.g. `https://10.80.4.4:8443/`).
2. Accept the self-signed certificate warning (demo cert).
3. Ask: *How do administrators access cloud workloads remotely?* → answer cites `[pol-003]`.

| Question | Expected source |
|---|---|
| How do administrators access cloud workloads remotely? | pol-003 |
| What is the hotel limit per night in major European cities? | pol-004 (220 EUR) |
| How quickly must suspected data leakage be reported? | pol-005 (1 hour) |
| What is the capital of Australia? (control) | "I don't know" — not in the sources |

From PowerShell on the jumpbox: `curl.exe -sk -X POST -H "Content-Type: application/json" -d "{\"question\":\"...\"}" https://<ip>:8443/api/ask`

## Validation

| Layer | Checks |
|---|---|
| Static (`tests/security`, profile `rag`) | VM Trusted Launch + MI; in `snet-app` with no default outbound; NSG allows only app port from VNet + denies internet; exactly 2 role assignments (OpenAI User, Search Index Data Reader); jumpbox exception precedes the lateral-movement deny |
| Deploy-time (`Deploy-RagApp.ps1`) | `/healthz` + smoke question in-VM, retried while RBAC propagates |
| Live (`Test-Deployment.ps1`) | network: subnet/NSG; identity: VM MI roles + no other assignments; invnet (jumpbox → app over the VNet): health + grounded answer citing `pol-003`; negative: RAG VM has no internet egress |

Live results: 75/75 on the first standalone environment (2026-11-18, re-provision idempotent); latest full runs 2026-11-19: standalone 97/97, hub-spoke 90/90.

## Updating the app

Edit `src/rag-demo/app.py`, then `pwsh ./scripts/rag/Deploy-RagApp.ps1` (no re-provision needed).
