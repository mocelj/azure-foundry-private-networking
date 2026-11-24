#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Creates (or updates) the demo prompt agent defined in src/agents/policy-agent.json and smoke-tests it.
  Agents are Foundry data-plane objects (not ARM resources), and the project endpoint is private, so
  the REST calls run ON A PRIVATE CLIENT (default: the jumpbox) via VM Run Command, authenticating
  with that VM's managed identity (Foundry User on the project).

  Idempotent: a new agent version is created only when the rendered definition changes
  (SHA-256 stored in the version metadata). The smoke test asserts that the agent actually called
  the Azure AI Search tool and returned a citation from the private index.

.EXAMPLE
  pwsh ./scripts/agents/Deploy-DemoAgent.ps1
  pwsh ./scripts/agents/Deploy-DemoAgent.ps1 -Environment contoso-spoke -ClientVmId /subscriptions/.../virtualMachines/vm-hub-workstation
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ClientVmId,
    [ValidateSet('search-tool', 'foundry-iq')][string]$Variant = 'search-tool'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }
$v = @{}
azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $v[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }
# Variants: search-tool = native Azure AI Search tool (module 4); foundry-iq = Foundry IQ knowledge base via MCP (module 6).
if ($Variant -eq 'foundry-iq') {
    $agent = if ($v.FOUNDRY_IQ_KNOWLEDGE_BASE) { 'contoso-iq-agent' } else { '' }
    $defFile = 'src/agents/policy-agent-iq.json'; $expectItem = 'mcp_call'; $expectCitation = ''; $expectText = 'Bastion'
    if (-not $agent) { Write-Host 'ENABLE_FOUNDRY_IQ is not enabled (no FOUNDRY_IQ_KNOWLEDGE_BASE output). Nothing to deploy.'; exit 0 }
} else {
    $agent = $v.DEMO_AGENT_NAME
    $defFile = 'src/agents/policy-agent.json'; $expectItem = 'azure_ai_search_call'; $expectCitation = 'Remote access standard'; $expectText = ''
    if (-not $agent) { Write-Host 'ENABLE_AGENT_DEMO is not enabled (no DEMO_AGENT_NAME output). Nothing to deploy.'; exit 0 }
}

$vmSub = $v.AZURE_SUBSCRIPTION_ID; $vmRg = $v.AZURE_RESOURCE_GROUP; $vm = $v.JUMPBOX_VM_NAME
if (-not $ClientVmId -and -not $vm -and $v.PRIVATE_CLIENT_VM_ID) { $ClientVmId = $v.PRIVATE_CLIENT_VM_ID }  # hub-spoke: existing private client
if ($ClientVmId) { $p = $ClientVmId.Split('/'); $vmSub = $p[2]; $vmRg = $p[4]; $vm = $p[8] }
if (-not $vm) { throw 'No jumpbox in this mode. Pass -ClientVmId of a private Windows client VM (Foundry User on the project) with network access to the project endpoint.' }

$def = (Get-Content (Join-Path $repo $defFile) -Raw).Replace('__MCP_URL__', [string]$v.FOUNDRY_IQ_MCP_URL).Replace('__MCP_CONNECTION__', [string]$v.FOUNDRY_IQ_MCP_CONNECTION).
    Replace('__MODEL__', $v.AZURE_AI_MODEL_DEPLOYMENT_NAME).Replace('__CONNECTION_ID__', $v.KNOWLEDGE_SEARCH_CONNECTION_ID).Replace('__INDEX__', $v.KNOWLEDGE_SEARCH_INDEX)
$defObj = $def | ConvertFrom-Json
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(($defObj | ConvertTo-Json -Depth 20 -Compress)))).Replace('-', '').Substring(0, 32).ToLower()
$defObj | Add-Member -NotePropertyName metadata -NotePropertyValue @{ definition_sha = $sha; managed_by = 'azure-foundry-private-networking' } -Force
$defB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($defObj | ConvertTo-Json -Depth 20 -Compress)))

$remote = @'
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$ep = '__EP__'; $agent = '__AGENT__'; $sha = '__SHA__'
$tok = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fai.azure.com' -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }
$current = $null
try { $current = (Invoke-RestMethod -Uri "$ep/agents/$($agent)?api-version=v1" -Headers $h).versions.latest } catch { if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw } }
if ($current -and $current.metadata.definition_sha -eq $sha) { "AGENT: $agent v$($current.version) unchanged" }
else {
  $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__DEF__'))
  $r = Invoke-RestMethod -Method Post -Uri "$ep/agents/$agent/versions?api-version=v1" -Headers $h -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body))
  "AGENT: $agent v$($r.version) created"
}
$q = @{ agent_reference = @{ name = $agent; type = 'agent_reference' }; input = 'How do administrators access cloud workloads remotely?' } | ConvertTo-Json -Depth 5
foreach ($i in 1..4) {
  try {
    $r = Invoke-RestMethod -Method Post -Uri "$ep/openai/v1/responses" -Headers $h -ContentType 'application/json' -Body $q -TimeoutSec 180
    $types = @($r.output | ForEach-Object type)
    $titles = @(($r.output | Where-Object type -eq 'message').content.annotations | Where-Object type -eq 'url_citation' | ForEach-Object title)
    $text = (($r.output | Where-Object type -eq 'message').content | Where-Object type -eq 'output_text').text -join ''
    $mcpErr = @($r.output | Where-Object { $_.type -eq 'mcp_call' -and $_.error } | ForEach-Object { "$($_.error)" })
    "ITEMS: $($types -join ',') | CITATIONS: $($titles -join ';') $(if ($mcpErr) { '| MCP ERROR: ' + ($mcpErr -join ';') })"
    $ok = ($types -contains '__EXPECT_ITEM__') -and -not $mcpErr
    if ('__EXPECT_CITATION__') { $ok = $ok -and ($titles -contains '__EXPECT_CITATION__') }
    if ('__EXPECT_TEXT__') { $ok = $ok -and ($text -match '__EXPECT_TEXT__') }
    if ($ok) { 'SMOKE: PASS'; exit 0 }
  } catch { "attempt ${i}: $($_.ErrorDetails.Message)".Substring(0, [Math]::Min(300, "attempt ${i}: $($_.ErrorDetails.Message)".Length)) }
  Start-Sleep -Seconds 20
}
'SMOKE: FAIL'
'@
$remote = $remote.Replace('__EP__', $v.AZURE_AI_PROJECT_ENDPOINT).Replace('__AGENT__', $agent).Replace('__SHA__', $sha).Replace('__DEF__', $defB64).
    Replace('__EXPECT_ITEM__', $expectItem).Replace('__EXPECT_CITATION__', $expectCitation).Replace('__EXPECT_TEXT__', $expectText)
$tmp = New-TemporaryFile; Set-Content $tmp $remote
$power = az vm get-instance-view --subscription $vmSub -g $vmRg -n $vm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
if ($power -ne 'PowerState/running') { Write-Host "Starting $vm ($power; e.g. daily auto-shutdown)..."; az vm start --subscription $vmSub -g $vmRg -n $vm -o none }
Write-Host "Deploying demo agent '$agent' ($Variant) from $vm (inside the network)..."
$out = az vm run-command invoke --subscription $vmSub -g $vmRg -n $vm --command-id RunPowerShellScript --scripts "@$tmp" -o json | ConvertFrom-Json
Remove-Item $tmp
$stdout = ($out.value | Where-Object code -like '*StdOut*').message
$stderr = ($out.value | Where-Object code -like '*StdErr*').message
Write-Host $stdout
if ($stderr) { Write-Host $stderr -ForegroundColor Red }
if ($stdout -notmatch 'SMOKE: PASS') { Write-Host 'Demo agent smoke test failed (see output).' -ForegroundColor Red; exit 1 }
Write-Host "Demo agent '$agent' deployed and verified ($expectItem called, grounded answer returned)." -ForegroundColor Green
