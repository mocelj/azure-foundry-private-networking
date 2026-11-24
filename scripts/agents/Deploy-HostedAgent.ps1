#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deploys the Contoso policy HOSTED agent (src/hosted-agents/contoso-policy-hosted) by source-code
  deployment (zip, remote_build; no container registry) and smoke-tests it.

  The project endpoint is private, so the data-plane calls run ON A PRIVATE CLIENT (default: the
  jumpbox; hub-spoke: PRIVATE_CLIENT_VM_ID) via VM Run Command with that VM's managed identity.
  The agent identity created by the platform gets Search Index Data Reader on the knowledge search
  (ARM, from this machine), so the agent can call the Foundry IQ knowledge base MCP endpoint
  through the delegated agent subnet.

.PARAMETER Action
  deploy  create or update the agent (content-addressed versioning) and wait for 'active'
  invoke  call the agent through its Responses endpoint and check for a grounded answer
  all     deploy, assign the knowledge base role, invoke (default)
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ClientVmId,
    [string]$AgentName = 'contoso-policy-hosted',
    [ValidateSet('all', 'deploy', 'invoke')][string]$Action = 'all'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }
$v = @{}
azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $v[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }

$vmSub = $v.AZURE_SUBSCRIPTION_ID; $vmRg = $v.AZURE_RESOURCE_GROUP; $vm = $v.JUMPBOX_VM_NAME
if (-not $ClientVmId -and -not $vm -and $v.PRIVATE_CLIENT_VM_ID) { $ClientVmId = $v.PRIVATE_CLIENT_VM_ID }
if ($ClientVmId) { $p = $ClientVmId.Split('/'); $vmSub = $p[2]; $vmRg = $p[4]; $vm = $p[8] }
if (-not $vm) { throw 'No private client VM (jumpbox or PRIVATE_CLIENT_VM_ID).' }

function Invoke-OnClient([string]$script) {
    $tmp = New-TemporaryFile; Set-Content $tmp $script
    $out = az vm run-command invoke --subscription $vmSub -g $vmRg -n $vm --command-id RunPowerShellScript --scripts "@$tmp" -o json | ConvertFrom-Json
    Remove-Item $tmp
    $so = ($out.value | Where-Object code -like '*StdOut*').message; $se = ($out.value | Where-Object code -like '*StdErr*').message
    if ($se) { Write-Host $se -ForegroundColor Red }
    $so
}

$common = @'
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$ep = '__EP__'; $agent = '__AGENT__'
$tok = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fai.azure.com' -Headers @{ Metadata = 'true' }).access_token
$h = @{ Authorization = "Bearer $tok" }
function Err($e) { $m = "$($e.ErrorDetails.Message)"; if (-not $m) { $m = "$($e.Exception.Message)" }; $m.Substring(0, [Math]::Min(600, $m.Length)) }
'@.Replace('__EP__', $v.AZURE_AI_PROJECT_ENDPOINT).Replace('__AGENT__', $AgentName)

if ($Action -in 'all', 'deploy') {
    $src = Join-Path $repo 'src/hosted-agents/contoso-policy-hosted'
    $zip = Join-Path ([IO.Path]::GetTempPath()) "$AgentName.zip"; Remove-Item $zip -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $src 'main.py'), (Join-Path $src 'requirements.txt') -DestinationPath $zip
    $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    $meta = @{
        description = 'Contoso policy assistant (hosted agent, Agent Framework) - azure-foundry-private-networking'
        definition  = @{
            kind = 'hosted'; cpu = '1'; memory = '2Gi'
            protocol_versions = @(@{ protocol = 'responses'; version = '2.0.0' })
            code_configuration = @{ runtime = 'python_3_13'; entry_point = @('python', 'main.py'); dependency_resolution = 'remote_build' }
            environment_variables = @{ AZURE_AI_MODEL_DEPLOYMENT_NAME = $v.AZURE_AI_MODEL_DEPLOYMENT_NAME; KB_MCP_URL = $v.FOUNDRY_IQ_MCP_URL; PYTHONNOUSERSITE = '1' }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $remote = $common + @'

Add-Type -AssemblyName System.Net.Http
$zipBytes = [Convert]::FromBase64String('__ZIP__'); $sha = '__SHA__'
$meta = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__META__'))
function Send([string]$uri, [bool]$create) {
  $c = New-Object System.Net.Http.HttpClient; $c.Timeout = [TimeSpan]::FromMinutes(5)
  $c.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $tok)
  $c.DefaultRequestHeaders.Add('Accept', 'application/json'); $c.DefaultRequestHeaders.Add('x-ms-code-zip-sha256', $sha)
  if ($create) { $c.DefaultRequestHeaders.Add('x-ms-agent-name', $agent) }
  $mp = New-Object System.Net.Http.MultipartFormDataContent
  $m = New-Object System.Net.Http.StringContent($meta, [Text.Encoding]::UTF8, 'application/json'); $mp.Add($m, 'metadata')
  $z = New-Object System.Net.Http.ByteArrayContent(,$zipBytes); $z.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/zip'); $mp.Add($z, 'code', "$agent.zip")
  $r = $c.PostAsync($uri, $mp).GetAwaiter().GetResult()
  @{ status = [int]$r.StatusCode; body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
}
$r = Send "$ep/agents?api-version=v1" $true
if ($r.status -eq 409) { $r = Send "$ep/agents/$($agent)?api-version=v1" $false }
"POST: HTTP $($r.status)"
if ($r.status -ge 300) { "BODY: $($r.body.Substring(0, [Math]::Min(900, $r.body.Length)))"; 'DEPLOY: FAIL'; exit 0 }
$obj = $r.body | ConvertFrom-Json
$ver = if ($obj.versions.latest.version) { $obj.versions.latest.version } else { $obj.version }
"VERSION: $ver"
$deadline = (Get-Date).AddMinutes(20)
do {
  Start-Sleep 20
  $s = Invoke-RestMethod -Uri "$ep/agents/$agent/versions/$($ver)?api-version=v1" -Headers $h
} while ($s.status -notin 'active', 'failed' -and (Get-Date) -lt $deadline)
"STATUS: $($s.status)"
if ($s.status -ne 'active') { "ERROR: $($s.error | ConvertTo-Json -Compress -Depth 5)"; 'DEPLOY: FAIL'; exit 0 }
$ag = Invoke-RestMethod -Uri "$ep/agents/$($agent)?api-version=v1" -Headers $h
$ids = @($ag, $ag.versions.latest, $s) | ForEach-Object { $_.PSObject.Properties } | Where-Object { $_.Name -match 'identity' } | ForEach-Object { "$($_.Name)=$($_.Value | ConvertTo-Json -Compress -Depth 4)" }
"IDENTITY: $($ids -join ' | ')"
'DEPLOY: PASS'
'@
    $remote = $remote.Replace('__ZIP__', [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))).Replace('__SHA__', $sha).
        Replace('__META__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($meta)))
    Write-Host "Deploying hosted agent '$AgentName' (source code, remote_build, zip $sha) from $vm (inside the network)..."
    $out = Invoke-OnClient $remote
    Write-Host $out
    if ($out -notmatch 'DEPLOY: PASS') { Write-Host 'Hosted agent deployment failed (see output).' -ForegroundColor Red; exit 1 }

    # Agent identity -> Search Index Data Reader on the knowledge search (Foundry IQ via MCP).
    if ($out -match '"principal_id":"([0-9a-f-]{36})"' -or $out -match '"principalId":"([0-9a-f-]{36})"') {
        $principal = $Matches[1]
        $scope = "/subscriptions/$($v.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($v.AZURE_RESOURCE_GROUP)/providers/Microsoft.Search/searchServices/$($v.KNOWLEDGE_SEARCH_NAME)"
        $role = '1407120a-92aa-4202-b7e9-c0e197c71c8f' # Search Index Data Reader
        $id = [guid]::NewGuid()
        $body = @{ properties = @{ roleDefinitionId = "/subscriptions/$($v.AZURE_SUBSCRIPTION_ID)/providers/Microsoft.Authorization/roleDefinitions/$role"; principalId = $principal; principalType = 'ServicePrincipal' } } | ConvertTo-Json -Compress
        $f = New-TemporaryFile; Set-Content $f $body
        az rest --method put --url "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments/$($id)?api-version=2022-04-01" --body "@$f" -o none 2>&1 | Where-Object { $_ -notmatch 'RoleAssignmentExists' }
        Remove-Item $f
        Write-Host "Agent identity $principal -> Search Index Data Reader on $($v.KNOWLEDGE_SEARCH_NAME)"
    } else { Write-Host 'Agent identity principal id not found in the agent object; assign Search Index Data Reader manually.' -ForegroundColor Yellow }
}

if ($Action -in 'all', 'invoke') {
    $remote = $common + @'

$q = @{ input = 'How do administrators access cloud workloads remotely?'; stream = $false } | ConvertTo-Json
foreach ($i in 1..6) {
  try {
    $w = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$ep/agents/$agent/endpoint/protocols/openai/responses?api-version=v1" -Headers $h -ContentType 'application/json' -Body $q -TimeoutSec 240
    $r = $w.Content | ConvertFrom-Json; $rh = $w.Headers
    $types = @($r.output | ForEach-Object type)
    $text = (($r.output | Where-Object type -eq 'message').content | Where-Object type -eq 'output_text').text -join ''
    "SESSION: $($rh['x-agent-session-id']) | STATUS: $($r.status) | ERROR: $($r.error | ConvertTo-Json -Compress -Depth 5)"
    "ITEMS: $($types -join ',')"
    if (-not $types) { $raw = $r | ConvertTo-Json -Compress -Depth 8; "RAW: $($raw.Substring(0, [Math]::Min(1200, $raw.Length)))" }
    "TEXT: $($text.Substring(0, [Math]::Min(500, $text.Length)))"
    if ($text -match 'Bastion') { 'INVOKE: PASS'; exit 0 }
  } catch { "attempt ${i}: $(Err $_)" }
  Start-Sleep -Seconds 30
}
'INVOKE: FAIL'
'@
    Write-Host "Invoking hosted agent '$AgentName' from $vm (private endpoint)..."
    $out = Invoke-OnClient $remote
    Write-Host $out
    if ($out -notmatch 'INVOKE: PASS') { Write-Host 'Hosted agent smoke test failed (see output).' -ForegroundColor Red; exit 1 }
    Write-Host "Hosted agent '$AgentName' answered from the private knowledge base." -ForegroundColor Green
}
