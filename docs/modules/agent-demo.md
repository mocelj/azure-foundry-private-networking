# Optional module 4 — Demo agent on the private knowledge index

Enable (requires the AI Search module and `OUTBOUND_NETWORK_MODE=byoVnet`):

```powershell
azd env set ENABLE_AI_SEARCH true
azd env set ENABLE_AGENT_DEMO true
azd provision      # preflight -> Bicep -> seed index -> create/update agent -> smoke test
                   # (agent REST calls run via VM Run Command on the jumpbox or PRIVATE_CLIENT_VM_ID)
```

Sample profile: [`examples/private-rag/full-demo.env`](../../examples/private-rag/full-demo.env) (enables all modules; the agent demo itself needs only AI Search; with the RAG module, citations open the private document page).

## What it deploys

A reproducible **prompt agent** `contoso-policy-agent` (`DEMO_AGENT_NAME_INPUT` to rename) defined in
[`src/agents/policy-agent.json`](../../src/agents/policy-agent.json):

| Field | Value |
|---|---|
| Model | the core model deployment (`AZURE_AI_MODEL_DEPLOYMENT_NAME`) |
| Tool | native `azure_ai_search`, connection `knowledge-search` (Entra / project MI), index `contoso-policies`, `query_type: simple`, `top_k: 3` |
| Instructions | always search first, answer only from retrieved documents, cite them, otherwise "don't know" |
| Other tools | **none**: no web search, no code interpreter (data must not leave the private boundary) |

Agents are **data-plane objects**, not ARM resources, so Bicep cannot create them. And the project
endpoint is private. `scripts/agents/Deploy-DemoAgent.ps1` therefore runs the REST calls **on a
private client** (the jumpbox, or `-ClientVmId`) via VM Run Command, using its managed identity
(Foundry User on the project). The script is called by the postprovision hook.

### Idempotency

The rendered definition is hashed (SHA-256), and the hash is stored in the agent version's
`metadata.definition_sha`. A new version is created only when the definition changes; otherwise
the script reports `vN unchanged`. To change the agent, edit the JSON file and re-run the script
or `azd provision`.

## Design decisions

| Decision | Why |
|---|---|
| Native `azure_ai_search` tool instead of a toolbox / MCP | Learn documents both. The portal creates a *toolbox* exposed as MCP (seen on the user-created `policy-agent`), which needs a toolbox version plus a remote-tool connection. The native tool is one self-contained object and the simplest reproducible option. A toolbox is the better choice when several agents share tools. |
| "Search first" in the instructions | Live finding: with neutral instructions the model answered "don't know" **without calling the tool**. Requiring a search per question made every run call the tool. `tool_choice: required` was not needed. |
| Requires `byoVnet` | Documented limitation: without VNet injection (Basic setup) the AI Search tool cannot reach a private search service. Preflight fails rather than deploying a broken agent. |
| Project MI roles | Search Index Data Contributor + Search Service Contributor on the knowledge search (see [ai-search.md](ai-search.md)). |
| Name differs from portal-created agents | Avoids overwriting agents users create by hand (e.g. `policy-agent`). |

## Validation

| Layer | Check |
|---|---|
| Deploy-time smoke | Response contains an `azure_ai_search_call` item and a `url_citation` titled *Remote access standard* |
| Live `Test-Deployment.ps1` (in-VNet) | Agent called the search tool; answer to "hotel limit per night" contains **220** and cites *Expense reimbursement* |

Live results: 77/77 on the first standalone environment (2026-11-18; re-deploy reported `v1 unchanged`); latest 2026-11-19: standalone 97/97, hub-spoke 90/90, including the citation link check.

## Try it

Bastion → jumpbox → Edge → Foundry portal → project `private-demo` → **Agents** →
`contoso-policy-agent` → Playground. Use the questions from
[e2e-test-guide.md](../e2e-test-guide.md#part-8--private-rag-app-module-3-5-min).
Each answer cites the policy title. Citation markers such as `【4:0†source】` in the raw API text are
the standard Agent Service annotation placeholders.

## Citation links

The agent's `url_citation` annotations link to the index field `url`. The seeding script fills it with the
private document page of the RAG app (`https://<rag-vm>:8443/docs/<id>`) when module 3 is deployed, so a
click opens the source document from any private client. Findings (2026-11-19, live experiments):

| Index definition | Citation link |
|---|---|
| no `url` field | Search service root `https://srch-kb-<token>.search.windows.net/` → **HTTP 401** in the browser (no token; Entra-only) |
| `url` present but `searchable: false` | still the service root |
| `url` present and **`searchable: true`** | the document URL ✅ |
| field named `filepath` / `sourceUrl` | service root (not recognised) |

So the `url` field must be **searchable** for citations to link to the document page (observed 2026-11-19; not stated in the Learn docs). `Seed-KnowledgeIndex.ps1` rebuilds the synthetic demo index
once if it finds an older definition. Without the RAG module, `url` stays empty and citations show the title.
The Foundry IQ agent (module 6) links to the Search document-lookup URL instead: documented behaviour for
search-index knowledge sources, which needs a token.
