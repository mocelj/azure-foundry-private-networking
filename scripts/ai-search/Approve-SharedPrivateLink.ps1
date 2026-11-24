#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Approves the shared private link that the knowledge search requested on the Foundry account
  (Foundry IQ query planning, FOUNDRY_IQ_REASONING=low|medium). See docs/private-link-explained.md.

  A shared private link creates a private endpoint in the search service's Microsoft-managed
  network; it stays PENDING on the Foundry account until the account owner approves it. This script
  is that owner consent, deliberately narrow:
    - only connections on THIS environment's Foundry account,
    - named '<FOUNDRY_IQ_SPL_NAME>.<guid>' and carrying this environment's exact request message,
    - in state Pending, and exactly one of them (anything else fails loudly, nothing is approved).
  Set FOUNDRY_IQ_AUTO_APPROVE=false when the account owner must approve (separation of duties);
  the script then prints the command for the owner and fails until the link is approved.

.EXAMPLE
  pwsh ./scripts/ai-search/Approve-SharedPrivateLink.ps1 -Environment contoso-standalone2
#>
[CmdletBinding()]
param([string]$Environment, [int]$TimeoutMinutes = 10)
$ErrorActionPreference = 'Stop'
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }
$v = @{}
azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $v[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }
$spl = $v.FOUNDRY_IQ_SPL_NAME
if (-not $spl) { Write-Host 'Foundry IQ query planning not enabled (no FOUNDRY_IQ_SPL_NAME). Nothing to approve.'; exit 0 }
$rg = $v.AZURE_RESOURCE_GROUP; $search = $v.KNOWLEDGE_SEARCH_NAME; $account = $v.AZURE_AI_ACCOUNT_NAME
$expectedMessage = "Foundry IQ query planning from $search ($($v.AZURE_ENV_NAME))"

function Get-SplState { az search shared-private-link-resource show -g $rg --service-name $search -n $spl --query 'properties.status' -o tsv }
$state = Get-SplState
Write-Host "Shared private link $search/$spl -> $account : $state"
if ($state -eq 'Approved') { exit 0 }

$accountId = az cognitiveservices account show -g $rg -n $account --query id -o tsv
$conns = @(az network private-endpoint-connection list --id $accountId -o json | ConvertFrom-Json |
    Where-Object { $_.name -like "$account/$spl.*" -or $_.name -like "$spl.*" })
$pending = @($conns | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq 'Pending' })
$match = @($pending | Where-Object { $_.properties.privateLinkServiceConnectionState.description -eq $expectedMessage })
if ($match.Count -ne 1) {
    Write-Host "Refusing to approve: expected exactly 1 pending connection '$spl.*' with request message '$expectedMessage', found $($match.Count) (pending total: $($pending.Count))." -ForegroundColor Red
    exit 1
}
$cid = $match[0].id
if ($v.FOUNDRY_IQ_AUTO_APPROVE -eq 'false') {
    Write-Host "FOUNDRY_IQ_AUTO_APPROVE=false: the Foundry account owner must approve this connection:" -ForegroundColor Yellow
    Write-Host "  az network private-endpoint-connection approve --id $cid --description `"<reason>`""
    exit 1
}
az network private-endpoint-connection approve --id $cid --description "Approved by deployment ($($v.AZURE_ENV_NAME)): Foundry IQ query planning from $search" -o none
if ($LASTEXITCODE) { exit 1 }
Write-Host "Approved $($match[0].name)." -ForegroundColor Green

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do { Start-Sleep 15; $state = Get-SplState } while ($state -ne 'Approved' -and (Get-Date) -lt $deadline)
if ($state -ne 'Approved') { Write-Host "Search still reports '$state' after $TimeoutMinutes min." -ForegroundColor Red; exit 1 }
Write-Host "Search reports the shared private link as Approved." -ForegroundColor Green
