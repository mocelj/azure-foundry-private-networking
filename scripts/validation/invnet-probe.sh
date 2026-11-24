#!/usr/bin/env bash
# In-VNet functional probe for Linux clients (e.g. a hub-connected workstation/VM).
# Equivalent to invnet-probe.ps1. Uses the VM's managed identity via IMDS (no secrets).
# Placeholders (__X__) are substituted by Test-Deployment.ps1; or set the env vars manually.
set -u
ACCOUNT="${ACCOUNT:-__ACCOUNT__}"
PROJECT_EP="${PROJECT_EP:-__PROJECT_ENDPOINT__}"
DEPLOYMENT="${DEPLOYMENT:-__DEPLOYMENT__}"
PE_PREFIX="${PE_PREFIX:-__PE_PREFIX__}"
EXTRA_HOSTS="${EXTRA_HOSTS:-__EXTRA_HOSTS__}"
RUN_AGENT="${RUN_AGENT:-__RUN_AGENT__}"
KB_SEARCH="${KB_SEARCH:-__KB_SEARCH__}"
KB_INDEX="${KB_INDEX:-__KB_INDEX__}"

RESULTS=()
add() { # cat name PASS|FAIL detail
  local d; d=$(printf '%s' "$4" | tr -d '"\\\n\r' | cut -c1-220)
  RESULTS+=("{\"c\":\"$1\",\"n\":\"$2\",\"r\":\"$3\",\"d\":\"$d\"}")
}
in_prefix() { python3 - "$1" "$2" <<'PY'
import ipaddress,sys
print(1 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 0)
PY
}
token() { curl -s -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=$1" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }
text_of() { python3 -c '
import sys,json
try:
  j=json.load(open(sys.argv[1]))
  print("".join(c.get("text","") for o in j.get("output",[]) if o.get("type")=="message" for c in o.get("content",[]) if c.get("type")=="output_text"))
except Exception: print("")' "$1"; }

HOSTS="$ACCOUNT.openai.azure.com $ACCOUNT.services.ai.azure.com $ACCOUNT.cognitiveservices.azure.com $(echo "$EXTRA_HOSTS" | tr ',' ' ')"
for h in $HOSTS; do
  ip=$(getent ahostsv4 "$h" | awk 'NR==1{print $1}')
  if [ -n "$ip" ] && [ "$(in_prefix "$ip" "$PE_PREFIX")" = "1" ]; then add dns "$h" PASS "A=$ip"; else add dns "$h" FAIL "A=$ip not in $PE_PREFIX"; fi
  if [ -n "$ip" ] && timeout 5 bash -c "</dev/tcp/$ip/443" 2>/dev/null; then add tcp443 "$h" PASS "$ip:443"; else add tcp443 "$h" FAIL "$ip:443"; fi
done

TOK=$(token https%3A%2F%2Fcognitiveservices.azure.com)
[ -n "$TOK" ] && add identity "managed identity token (cognitiveservices)" PASS IMDS || add identity "managed identity token (cognitiveservices)" FAIL IMDS
code=$(curl -s -m 120 -o /tmp/inf.json -w '%{http_code}' -X POST "https://$ACCOUNT.openai.azure.com/openai/v1/responses" \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$DEPLOYMENT\",\"input\":\"Reply with exactly the text PRIVATE-OK and nothing else.\",\"max_output_tokens\":64}")
t=$(text_of /tmp/inf.json)
[ "$code" = "200" ] && [[ "$t" == *PRIVATE-OK* ]] && add inference "responses API via private endpoint (Entra MI)" PASS "HTTP $code text=$t" \
  || add inference "responses API via private endpoint (Entra MI)" FAIL "HTTP $code $(head -c 200 /tmp/inf.json)"

ATOK=$(token https%3A%2F%2Fai.azure.com)
code=$(curl -s -m 60 -o /tmp/dep.json -w '%{http_code}' "$PROJECT_EP/deployments?api-version=v1" -H "Authorization: Bearer $ATOK")
[ "$code" = "200" ] && grep -q "$DEPLOYMENT" /tmp/dep.json && add project "list project deployments" PASS "HTTP $code" || add project "list project deployments" FAIL "HTTP $code"

if [ "$RUN_AGENT" = "true" ]; then
  AGENT=private-validation-agent
  code=000
  for i in 1 2 3; do
    code=$(curl -s -m 300 -o /tmp/ag.json -w '%{http_code}' -X POST "$PROJECT_EP/agents/$AGENT/versions?api-version=v1" \
      -H "Authorization: Bearer $ATOK" -H 'Content-Type: application/json' \
      -d "{\"definition\":{\"kind\":\"prompt\",\"model\":\"$DEPLOYMENT\",\"instructions\":\"You are a validation agent. Answer with exactly AGENT-PRIVATE-OK.\"}}")
    { [ "$code" = "200" ] || [ "$code" = "201" ]; } && break; sleep 20
  done
  { [ "$code" = "200" ] || [ "$code" = "201" ]; } && add agent "create agent version (Standard setup)" PASS "HTTP $code" || add agent "create agent version (Standard setup)" FAIL "HTTP $code $(head -c 200 /tmp/ag.json)"
  code=$(curl -s -m 120 -o /tmp/cv.json -w '%{http_code}' -X POST "$PROJECT_EP/openai/v1/conversations" -H "Authorization: Bearer $ATOK" -H 'Content-Type: application/json' -d '{"metadata":{"purpose":"private-validation"}}')
  CONV=$(python3 -c 'import json;print(json.load(open("/tmp/cv.json")).get("id",""))' 2>/dev/null)
  [ -n "$CONV" ] && add agent "create conversation (thread store in BYO Cosmos DB)" PASS "id=$CONV" || add agent "create conversation (thread store in BYO Cosmos DB)" FAIL "HTTP $code"
  code=$(curl -s -m 300 -o /tmp/run.json -w '%{http_code}' -X POST "$PROJECT_EP/openai/v1/responses" -H "Authorization: Bearer $ATOK" -H 'Content-Type: application/json' \
    -d "{\"agent_reference\":{\"name\":\"$AGENT\",\"type\":\"agent_reference\"},\"input\":\"Validation ping\",\"conversation\":\"$CONV\"}")
  t=$(text_of /tmp/run.json)
  [ "$code" = "200" ] && [[ "$t" == *AGENT-PRIVATE-OK* ]] && add agent "run agent (VNet-injected runtime)" PASS "HTTP $code text=$t" || add agent "run agent (VNet-injected runtime)" FAIL "HTTP $code $(head -c 200 /tmp/run.json)"
fi

if [ -n "${KB_SEARCH:-}" ] && [ "$KB_SEARCH" != "__KB""_SEARCH__" ]; then
  STOK=$(token https%3A%2F%2Fsearch.azure.com)
  code=$(curl -s -m 60 -o /tmp/kb.json -w '%{http_code}' -X POST "https://$KB_SEARCH.search.windows.net/indexes/$KB_INDEX/docs/search?api-version=2024-07-01" \
    -H "Authorization: Bearer $STOK" -H 'Content-Type: application/json' -d '{"search":"Bastion public IP remote access","top":1,"select":"id,title"}')
  top=$(python3 -c 'import json;v=json.load(open("/tmp/kb.json")).get("value",[]);print(v[0]["id"] if v else "")' 2>/dev/null)
  [ "$code" = "200" ] && [ "$top" = "pol-003" ] && add search "knowledge index query via private endpoint (Entra MI)" PASS "HTTP $code top=$top" \
    || add search "knowledge index query via private endpoint (Entra MI)" FAIL "HTTP $code top=$top"
fi

RAG_URL="${RAG_URL:-__RAG_URL__}"
DEMO_AGENT="${DEMO_AGENT:-__DEMO_AGENT__}"
if [ -n "$DEMO_AGENT" ] && [ "$DEMO_AGENT" != "__DEMO""_AGENT__" ]; then
  ATOK=$(token https%3A%2F%2Fai.azure.com)
  code=$(curl -s -m 300 -o /tmp/demo.json -w '%{http_code}' -X POST "$PROJECT_EP/openai/v1/responses" -H "Authorization: Bearer $ATOK" -H 'Content-Type: application/json' \
    -d "{\"agent_reference\":{\"name\":\"$DEMO_AGENT\",\"type\":\"agent_reference\"},\"input\":\"What is the hotel limit per night in major European cities?\"}")
  read -r types titles text < <(python3 -c '
import json
try:
  j=json.load(open("/tmp/demo.json")); o=j.get("output",[])
  m=[c for i in o if i.get("type")=="message" for c in i.get("content",[])]
  t=[a.get("title","") for c in m for a in c.get("annotations",[]) if a.get("type")=="url_citation"]
  print(",".join(i.get("type","") for i in o), ";".join(x.replace(" ","_") for x in t) or "-", "".join(c.get("text","") for c in m).replace("\n"," "))
except Exception: print("- - -")')
  [ "$code" = "200" ] && [[ ",$types," == *",azure_ai_search_call,"* ]] && add agent "demo agent called Azure AI Search tool (private index)" PASS "items=$types" \
    || add agent "demo agent called Azure AI Search tool (private index)" FAIL "HTTP $code items=$types"
  [[ "$text" == *220* ]] && [[ ";$titles;" == *";Expense_reimbursement;"* ]] && add agent "demo agent grounded answer (220 EUR, cites Expense reimbursement)" PASS "citations=$titles" \
    || add agent "demo agent grounded answer (220 EUR, cites Expense reimbursement)" FAIL "citations=$titles text=$text"
fi
if [ -n "$RAG_URL" ] && [ "$RAG_URL" != "__RAG""_URL__" ]; then
  u="${RAG_URL%/}"
  code=$(curl -sk -m 20 -o /dev/null -w '%{http_code}' "$u/healthz")
  [ "$code" = "200" ] && add rag "RAG app health over private network" PASS "$u HTTP $code" || add rag "RAG app health over private network" FAIL "$u HTTP $code"
  code=$(curl -sk -m 120 -o /tmp/rag.json -w '%{http_code}' -X POST "$u/api/ask" -H 'Content-Type: application/json' -d '{"question":"How do administrators access cloud workloads remotely?"}')
  ids=$(python3 -c 'import json;j=json.load(open("/tmp/rag.json"));print(",".join(s["id"] for s in j.get("sources",[])) if j.get("answer") else "")' 2>/dev/null)
  [ "$code" = "200" ] && [[ ",$ids," == *",pol-003,"* ]] && add rag "RAG answer grounded in private index (pol-003 cited)" PASS "sources=$ids" \
    || add rag "RAG answer grounded in private index (pol-003 cited)" FAIL "HTTP $code sources=$ids"
fi

IFS=,; echo "RESULT_JSON:[${RESULTS[*]}]"
