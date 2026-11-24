#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Creates the sample knowledge index and uploads synthetic documents into the PRIVATE knowledge
  search service. The data plane is not reachable from the internet, so the work is executed on a
  private client inside the network (default: the jumpbox) via VM Run Command, authenticating with
  that VM's managed identity (Search Service Contributor + Search Index Data Contributor).

  Idempotent: the index is created-or-updated and documents are merged-or-uploaded.

.EXAMPLE
  pwsh ./scripts/ai-search/Seed-KnowledgeIndex.ps1
  pwsh ./scripts/ai-search/Seed-KnowledgeIndex.ps1 -Environment contoso-standalone -ClientVmId /subscriptions/.../virtualMachines/vm-x
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ClientVmId
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }
$v = @{}
azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $v[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }
$search = $v.KNOWLEDGE_SEARCH_NAME; $index = $v.KNOWLEDGE_SEARCH_INDEX; $rg = $v.AZURE_RESOURCE_GROUP
if (-not $search) { Write-Host 'ENABLE_AI_SEARCH is not enabled (no KNOWLEDGE_SEARCH_NAME output). Nothing to seed.'; exit 0 }

$vmSub = $v.AZURE_SUBSCRIPTION_ID; $vmRg = $rg; $vm = $v.JUMPBOX_VM_NAME
if (-not $ClientVmId -and -not $vm -and $v.PRIVATE_CLIENT_VM_ID) { $ClientVmId = $v.PRIVATE_CLIENT_VM_ID }  # hub-spoke: existing private client
if ($ClientVmId) { $p = $ClientVmId.Split('/'); $vmSub = $p[2]; $vmRg = $p[4]; $vm = $p[8] }
if (-not $vm) { throw 'No jumpbox in this mode. Pass -ClientVmId of a private Windows client VM with network access to the search private endpoint.' }

$docs = Get-Content (Join-Path $repo 'src/sample-data/knowledge/contoso-policies.json') -Raw | ConvertFrom-Json
# Citation links: with the RAG module, every document gets a private, browsable source page
# (https://<rag-vm>:<port>/docs/<id>); otherwise url stays empty and citations show the title only.
$docBase = if ($v.RAG_APP_URL) { $v.RAG_APP_URL.TrimEnd('/') + '/docs/' } else { '' }
$batch = @{ value = @($docs | ForEach-Object { $h = [ordered]@{ '@search.action' = 'mergeOrUpload' }; $_.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }; $h['url'] = $(if ($docBase) { $docBase + $_.id } else { '' }); $h }) } | ConvertTo-Json -Depth 5 -Compress
$batchB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($batch))

$remote = @'
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$api = '2024-07-01'
$base = "https://__SEARCH__.search.windows.net"
$tok = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fsearch.azure.com' -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }
$index = @{
  name = '__INDEX__'
  fields = @(
    @{ name = 'id'; type = 'Edm.String'; key = $true; filterable = $true }
    @{ name = 'title'; type = 'Edm.String'; searchable = $true; analyzer = 'en.microsoft' }
    @{ name = 'category'; type = 'Edm.String'; searchable = $true; filterable = $true; facetable = $true }
    @{ name = 'content'; type = 'Edm.String'; searchable = $true; analyzer = 'en.microsoft' }
    # url must be SEARCHABLE: the agent Azure AI Search tool only uses it for citation links then
    # (verified 2026-11-19; with searchable=false citations point to the service root -> 401).
    @{ name = 'url'; type = 'Edm.String'; searchable = $true; filterable = $false; retrievable = $true }
  )
  semantic = @{ configurations = @(@{ name = 'default'; prioritizedFields = @{ titleField = @{ fieldName = 'title' }; prioritizedContentFields = @(@{ fieldName = 'content' }) } }) }
} | ConvertTo-Json -Depth 10
# Field attributes can't change in place. If an older definition exists (url missing or not searchable),
# rebuild the synthetic demo index; the Foundry IQ objects that reference it are recreated below.
$existing = $null
try { $existing = Invoke-RestMethod -Uri "$base/indexes/__INDEX__?api-version=$api" -Headers $h } catch { if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw } }
$urlField = if ($existing) { $existing.fields | Where-Object name -eq 'url' } else { $null }
if ($existing -and $urlField -and -not $urlField.searchable) {
  foreach ($obj in "knowledgebases('__KB__')", "knowledgesources('__KB__-ks')") {
    if ('__KB__') { try { Invoke-RestMethod -Method Delete -Uri "$base/$($obj)?api-version=2026-10-01" -Headers $h | Out-Null } catch { if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw } } }
  }
  Invoke-RestMethod -Method Delete -Uri "$base/indexes/__INDEX__?api-version=$api" -Headers $h | Out-Null
  "INDEX: rebuilt (url field schema changed)"
}
Invoke-RestMethod -Method Put -Uri "$base/indexes/__INDEX__?api-version=$api" -Headers $h -ContentType 'application/json' -Body $index | Out-Null
"INDEX: created-or-updated"
$batch = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__BATCH__'))
$r = Invoke-RestMethod -Method Post -Uri "$base/indexes/__INDEX__/docs/index?api-version=$api" -Headers $h -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($batch))
"DOCS: $(@($r.value | Where-Object status).Count)/$(@($r.value).Count) succeeded"
Start-Sleep -Seconds 3
$q = @{ search = 'Bastion public IP remote access'; top = 1; select = 'id,title' } | ConvertTo-Json
$res = Invoke-RestMethod -Method Post -Uri "$base/indexes/__INDEX__/docs/search?api-version=$api" -Headers $h -ContentType 'application/json' -Body $q
"QUERY top1: $($res.value[0].id) | $($res.value[0].title)"
if ('__KB__') {
  # Foundry IQ (optional module 6): knowledge source over the existing index + knowledge base.
  # minimal reasoning + extractiveData => no LLM, no outbound call from Search (fully private on Basic).
  # low/medium (option A+) => Search calls the model for query planning over the approved shared
  # private link (search MI, Cognitive Services OpenAI User); see docs/private-link-explained.md.
  $kapi = '2026-10-01'
  $ks = @{ name = '__KB__-ks'; kind = 'searchIndex'; description = 'Contoso internal policies (synthetic demo data)'; searchIndexParameters = @{ searchIndexName = '__INDEX__'; semanticConfigurationName = 'default' } } | ConvertTo-Json -Depth 5
  Invoke-RestMethod -Method Put -Uri "$base/knowledgesources('__KB__-ks')?api-version=$kapi" -Headers $h -ContentType 'application/json' -Body $ks | Out-Null
  $def = @{ name = '__KB__'; description = 'Contoso policy knowledge base (Foundry IQ)'; knowledgeSources = @(@{ name = '__KB__-ks' }); retrievalReasoningEffort = @{ kind = '__REASONING__' }; outputMode = 'extractiveData'; models = @() }
  if ('__REASONING__' -ne 'minimal') { $def.models = @(@{ kind = 'azureOpenAI'; azureOpenAIParameters = @{ resourceUri = '__AOAI__'; deploymentId = '__DEPLOYMENT__'; modelName = '__MODEL__' } }) }
  $kb = $def | ConvertTo-Json -Depth 6
  Invoke-RestMethod -Method Put -Uri "$base/knowledgebases('__KB__')?api-version=$kapi" -Headers $h -ContentType 'application/json' -Body $kb | Out-Null
  $rq = @{ intents = @(@{ type = 'semantic'; search = 'hotel limit per night in major European cities' }) } | ConvertTo-Json -Depth 5
  $rr = Invoke-RestMethod -Method Post -Uri "$base/knowledgebases('__KB__')/retrieve?api-version=$kapi" -Headers $h -ContentType 'application/json' -Body $rq
  $first = ($rr.response[0].content[0].text | ConvertFrom-Json)[0]
  "KB RETRIEVE top1: $($first.title)"
  if ('__REASONING__' -ne 'minimal') {
    $rq = @{ messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = 'What is the hotel limit per night in major European cities, and can I book business class for a 5 hour flight?' }) }); retrievalReasoningEffort = @{ kind = '__REASONING__' }; outputMode = 'extractiveData'; includeActivity = $true } | ConvertTo-Json -Depth 8
    $rr = Invoke-RestMethod -Method Post -Uri "$base/knowledgebases('__KB__')/retrieve?api-version=$kapi" -Headers $h -ContentType 'application/json' -Body $rq
    $plan = @($rr.activity | Where-Object type -eq 'modelQueryPlanning')
    "KB PLANNING: $(if ($plan) { 'ok' } else { 'missing' }) (input tokens $($plan[0].inputTokens), searches $(@($rr.activity | Where-Object type -eq 'searchIndex').Count))"
  }
}
'@
$reasoning = if ($v.DEPLOYED_FOUNDRY_IQ_REASONING) { $v.DEPLOYED_FOUNDRY_IQ_REASONING } else { 'minimal' }
if ($v.FOUNDRY_IQ_KNOWLEDGE_BASE -and $reasoning -ne 'minimal') {
    # Query planning needs the approved shared private link knowledge search -> Foundry before the KB is used.
    $approveArgs = @{}; if ($Environment) { $approveArgs.Environment = $Environment }
    & (Join-Path $PSScriptRoot 'Approve-SharedPrivateLink.ps1') @approveArgs
    if ($LASTEXITCODE) { Write-Host 'Shared private link is not approved; Foundry IQ query planning would fail.' -ForegroundColor Red; exit 1 }
}
$remote = $remote.Replace('__SEARCH__', $search).Replace('__INDEX__', $index).Replace('__BATCH__', $batchB64).Replace('__KB__', [string]$v.FOUNDRY_IQ_KNOWLEDGE_BASE).
    Replace('__REASONING__', $reasoning).Replace('__AOAI__', "https://$($v.AZURE_AI_ACCOUNT_NAME).openai.azure.com").Replace('__DEPLOYMENT__', [string]$v.AZURE_AI_MODEL_DEPLOYMENT_NAME).Replace('__MODEL__', [string]$v.DEPLOYED_MODEL_NAME)
$power = az vm get-instance-view --subscription $vmSub -g $vmRg -n $vm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
if ($power -ne 'PowerState/running') { Write-Host "Starting $vm ($power; e.g. daily auto-shutdown)..."; az vm start --subscription $vmSub -g $vmRg -n $vm -o none }
$tmp = New-TemporaryFile; Set-Content $tmp $remote
Write-Host "Seeding $search/$index from $vm (inside the VNet)..."
$out = az vm run-command invoke --subscription $vmSub -g $vmRg -n $vm --command-id RunPowerShellScript --scripts "@$tmp" -o json | ConvertFrom-Json
Remove-Item $tmp
$stdout = ($out.value | Where-Object code -like '*StdOut*').message
$stderr = ($out.value | Where-Object code -like '*StdErr*').message
Write-Host $stdout
if ($stderr) { Write-Host $stderr -ForegroundColor Red; exit 1 }
if ($stdout -notmatch 'QUERY top1: pol-003') { Write-Host 'Seed verification query did not return the expected document.' -ForegroundColor Red; exit 1 }
if ($v.FOUNDRY_IQ_KNOWLEDGE_BASE -and $stdout -notmatch 'KB RETRIEVE top1: Expense reimbursement') { Write-Host 'Foundry IQ knowledge base retrieve did not return the expected document.' -ForegroundColor Red; exit 1 }
if ($v.FOUNDRY_IQ_KNOWLEDGE_BASE -and $reasoning -ne 'minimal' -and $stdout -notmatch 'KB PLANNING: ok') { Write-Host 'Foundry IQ query planning (modelQueryPlanning) did not run.' -ForegroundColor Red; exit 1 }
Write-Host 'Knowledge index seeded and verified.' -ForegroundColor Green
