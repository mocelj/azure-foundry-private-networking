#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deploys the hosted-agent demo (src/hosted-agents: toolbox + hosted agent) with azd, the recommended
  workflow, running azd on a PRIVATE CLIENT inside the network (jumpbox / hub workstation acting as the
  in-VNet runner). The Foundry data plane has public access disabled, so azd can't deploy from here.

  Steps (each a VM Run Command, idempotent):
    setup   install azd + the azure.ai.agents / azure.ai.toolboxes extensions, sign in with the VM's
            managed identity (azd auth login --managed-identity)
    deploy  copy src/hosted-agents to the VM, create/refresh the runner azd env, `azd deploy`
            (toolbox `contoso-policy-tools` + hosted agent `contoso-policy-hosted`)
    invoke  `azd ai agent invoke` and check for a grounded answer from the knowledge base

  Runner identity requirements (granted here, from this machine via ARM):
    - Foundry Project Manager on the project (deploy hosted agents, create role assignments for the agent identity)
  Agent identity: no data-plane role for tools. The toolbox calls the knowledge base with its connection's
  credential (project managed identity), so the agent identity needs no Foundry User or Search role.
  Agent identity on the project's Application Insights: Monitoring Metrics Publisher (code-emitted traces with
  Entra-only ingestion; granted here after deploy). Learn: foundry/observability/how-to/trace-ingestion-entra-authentication

.EXAMPLE
  pwsh ./scripts/agents/Deploy-HostedAgentAzd.ps1 -Environment contoso-hosted2
#>
[CmdletBinding()]
param(
    [string]$Environment,
    [string]$ClientVmId,
    [ValidateSet('all', 'setup', 'deploy', 'rbac', 'invoke')][string]$Action = 'all'
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }
$v = @{}
azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $v[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }
$sub = $v.AZURE_SUBSCRIPTION_ID; $rg = $v.AZURE_RESOURCE_GROUP
$vmSub = $sub; $vmRg = $rg; $vm = $v.JUMPBOX_VM_NAME
if (-not $ClientVmId -and -not $vm -and $v.PRIVATE_CLIENT_VM_ID) { $ClientVmId = $v.PRIVATE_CLIENT_VM_ID }
if ($ClientVmId) { $p = $ClientVmId.Split('/'); $vmSub = $p[2]; $vmRg = $p[4]; $vm = $p[8] }
if (-not $vm) { throw 'No private client VM (jumpbox or PRIVATE_CLIENT_VM_ID).' }
$projectId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$($v.AZURE_AI_ACCOUNT_NAME)/projects/$($v.AZURE_AI_PROJECT_NAME)"

function Invoke-OnClient([string]$script, [string]$label) {
    Write-Host "[$label] running on $vm ..."
    $tmp = New-TemporaryFile; Set-Content $tmp $script
    $out = az vm run-command invoke --subscription $vmSub -g $vmRg -n $vm --command-id RunPowerShellScript --scripts "@$tmp" -o json | ConvertFrom-Json
    Remove-Item $tmp
    $so = ($out.value | Where-Object code -like '*StdOut*').message; $se = ($out.value | Where-Object code -like '*StdErr*').message
    Write-Host $so
    if ($se) { Write-Host $se -ForegroundColor DarkYellow }
    $so
}

function Grant-Role([string]$principalId, [string]$roleId, [string]$scope, [string]$what) {
    $id = [guid]::NewGuid()
    $body = @{ properties = @{ roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$roleId"; principalId = $principalId; principalType = 'ServicePrincipal' } } | ConvertTo-Json -Compress
    $f = New-TemporaryFile; Set-Content $f $body
    $r = az rest --method put --url "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments/$($id)?api-version=2022-04-01" --body "@$f" -o none 2>&1
    Remove-Item $f
    if ($r -and "$r" -notmatch 'RoleAssignmentExists') { Write-Host "$what : $r" -ForegroundColor Yellow } else { Write-Host "$what : ok" }
}

# Common prelude on the runner: azd on PATH, isolated azd config, skill user agent.
$prelude = @'
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$env:AZD_CONFIG_DIR = 'C:\azd-runner\config'; $env:AZD_SKIP_UPDATE_CHECK = 'true'; $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
$env:AZD_DEMO_COLLECT_TELEMETRY = 'no'; $env:AZURE_DEV_COLLECT_TELEMETRY = 'no'
$azdDirs = @("$env:ProgramFiles\Azure Dev CLI", "$env:LOCALAPPDATA\Programs\Azure Dev CLI", 'C:\azd-runner\bin')
foreach ($d in $azdDirs) { if (Test-Path "$d\azd.exe") { $env:PATH = "$d;$env:PATH" } }
New-Item -ItemType Directory -Force C:\azd-runner\config, C:\azd-runner\logs | Out-Null
function Tail($file, $n = 25) { if (Test-Path $file) { (Get-Content $file -Tail $n) -join "`n" } }
'@

if ($Action -in 'all', 'setup') {
    $mi = az vm show --subscription $vmSub -g $vmRg -n $vm --query identity.principalId -o tsv
    Grant-Role $mi 'eadc314b-1a2d-4efa-be10-5d325db5065e' $projectId "Runner $vm -> Foundry Project Manager (project)"
    $remote = $prelude + @'

if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
  $msi = 'C:\azd-runner\azd-windows-amd64.msi'
  Invoke-WebRequest -UseBasicParsing 'https://github.com/Azure/azure-dev/releases/latest/download/azd-windows-amd64.msi' -OutFile $msi
  $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart ALLUSERS=1" -Wait -PassThru
  "MSI exit: $($p.ExitCode)"
  foreach ($d in @("$env:ProgramFiles\Azure Dev CLI", "${env:ProgramFiles(x86)}\Azure Dev CLI", "$env:LOCALAPPDATA\Programs\Azure Dev CLI")) { if (Test-Path "$d\azd.exe") { $env:PATH = "$d;$env:PATH" } }
}
"AZD: $((azd version) -join ' ')"
foreach ($ext in 'azure.ai.agents', 'azure.ai.toolboxes') {
  $o = azd extension install $ext --no-prompt 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -and $o -notmatch 'already installed') { $o = azd extension upgrade $ext --no-prompt 2>&1 | Out-String }
  "EXT $ext : $(($o -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1))"
}
azd auth login --managed-identity 2>&1 | Out-String | ForEach-Object { "LOGIN: $($_.Trim())" }
"SETUP: DONE"
'@
    $out = Invoke-OnClient $remote 'setup'
    if ($out -notmatch 'SETUP: DONE') { throw 'Runner setup failed.' }
}

if ($Action -in 'all', 'deploy') {
    $src = Join-Path $repo 'src/hosted-agents'
    $stage = Join-Path ([IO.Path]::GetTempPath()) 'hosted-agents-stage'; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $stage | Out-Null
    Copy-Item (Join-Path $src 'contoso-policy-hosted') $stage -Recurse
    $raiId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$($v.AZURE_AI_ACCOUNT_NAME)/raiPolicies/$($v.HOSTED_AGENT_RAI_POLICY ?? 'Microsoft.DefaultV2')"
    (Get-Content (Join-Path $src 'azure.yaml') -Raw).Replace('__RAI_POLICY_ID__', $raiId) | Set-Content (Join-Path $stage 'azure.yaml') -NoNewline
    $zip = Join-Path ([IO.Path]::GetTempPath()) 'hosted-agents-src.zip'; Remove-Item $zip -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage 'azure.yaml'), (Join-Path $stage 'contoso-policy-hosted') -DestinationPath $zip
    $vals = [ordered]@{
        AZURE_SUBSCRIPTION_ID = $sub; AZURE_LOCATION = $v.AZURE_LOCATION; AZURE_RESOURCE_GROUP = $rg
        AZURE_AI_PROJECT_ID = $projectId; AZURE_AI_PROJECT_ENDPOINT = $v.AZURE_AI_PROJECT_ENDPOINT; FOUNDRY_PROJECT_ENDPOINT = $v.AZURE_AI_PROJECT_ENDPOINT
        AZURE_AI_ACCOUNT_NAME = $v.AZURE_AI_ACCOUNT_NAME; AZURE_AI_PROJECT_NAME = $v.AZURE_AI_PROJECT_NAME
        AZURE_AI_MODEL_DEPLOYMENT_NAME = $v.AZURE_AI_MODEL_DEPLOYMENT_NAME
    }
    $setLines = ($vals.GetEnumerator() | ForEach-Object { "azd env set $($_.Key) '$($_.Value)' --no-prompt | Out-Null" }) -join "`n"
    $remote = $prelude + @'

$work = 'C:\azd-runner\hosted-agents'
if (Test-Path $work) { Remove-Item "$work\azure.yaml", "$work\contoso-policy-hosted" -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $work | Out-Null
[IO.File]::WriteAllBytes("$work\src.zip", [Convert]::FromBase64String('__ZIP__'))
Expand-Archive "$work\src.zip" $work -Force; Remove-Item "$work\src.zip"
Set-Location $work
if (-not (Test-Path "$work\.azure\runner")) { azd env new runner --no-prompt 2>&1 | Out-Null }
azd env select runner 2>&1 | Out-Null
__SET__
$log = 'C:\azd-runner\logs\deploy.log'
azd deploy --no-prompt *> $log
"AZD DEPLOY EXIT: $LASTEXITCODE"
Tail $log 30
"ENV: $((azd env get-values | Select-String 'AGENT_|TOOLBOX') -join ' | ')"
'@
    $remote = $remote.Replace('__ZIP__', [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))).Replace('__SET__', $setLines)
    $out = Invoke-OnClient $remote 'deploy'
    if ($out -notmatch 'AZD DEPLOY EXIT: 0') { Write-Host 'azd deploy failed on the runner (see output).' -ForegroundColor Red; exit 1 }
}

if ($Action -in 'all', 'deploy', 'rbac' -and -not $v.APPLICATIONINSIGHTS_NAME) {
    Write-Host 'No Application Insights in this environment (ENABLE_ADVANCED_MONITORING=false): Monitoring Metrics Publisher grant skipped, agent code traces are not collected.' -ForegroundColor DarkYellow
} elseif ($Action -in 'all', 'deploy', 'rbac') {
    # Hosted-agent code emits its own traces with the agent identity -> needs Monitoring Metrics Publisher
    # on the connected Application Insights (ingestion is Entra-only, public ingestion disabled).
    $agentPid = (Invoke-OnClient ($prelude + @'

Set-Location C:\azd-runner\hosted-agents
"AGENT_PID=$((azd env get-value AGENT_CONTOSO_POLICY_HOSTED_INSTANCE_IDENTITY_PRINCIPAL_ID 2>$null))"
'@) 'agent identity' | Select-String 'AGENT_PID=([0-9a-f-]{36})').Matches.Groups[1].Value
    if (-not $agentPid) { throw 'Agent identity principal ID not found in the runner azd env.' }
    $appi = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/components/$($v.APPLICATIONINSIGHTS_NAME)"
    Grant-Role $agentPid '3913510d-42f4-4e42-8a64-420c390055eb' $appi "Agent identity $agentPid -> Monitoring Metrics Publisher (Application Insights)"
}

if ($Action -in 'all', 'invoke') {
    $remote = $prelude + @'

Set-Location 'C:\azd-runner\hosted-agents'
$log = 'C:\azd-runner\logs\invoke.log'
foreach ($i in 1..4) {
  azd ai agent invoke contoso-policy-hosted "How do administrators access cloud workloads remotely?" --no-prompt *> $log
  $t = Get-Content $log -Raw
  "--- attempt $i (exit $LASTEXITCODE)"; Tail $log 20
  if ($t -match 'Bastion') { 'INVOKE: PASS'; exit 0 }
  Start-Sleep 30
}
'INVOKE: FAIL'
'@
    $out = Invoke-OnClient $remote 'invoke'
    if ($out -notmatch 'INVOKE: PASS') { Write-Host 'Hosted agent smoke test failed (see output).' -ForegroundColor Red; exit 1 }
    Write-Host 'Hosted agent (azd + toolbox) answered from the private knowledge base.' -ForegroundColor Green
}
exit 0
