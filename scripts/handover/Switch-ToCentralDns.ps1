#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Handover step for a spoke-ready (or standalone-DNS) deployment: moves all private endpoint DNS
  registrations from the workload's own private DNS zones to the central (hub) zones, then removes
  the now-empty local zones and points the VNet at the hub DNS resolver.

  Why a script: Azure does not allow repointing an existing private DNS zone config to a different
  zone (UpdatingPrivateDnsZoneIdOnPrivateDnsZoneConfigNotAllowed), so the zone groups must be
  deleted and recreated. Nothing is opened publicly; name resolution for the private endpoints is
  unavailable for a few minutes while the zone groups are recreated.

.PARAMETER CentralZoneIds
  Comma-separated resource IDs of the central private DNS zones (same format as EXISTING_PRIVATE_DNS_ZONE_IDS).
.PARAMETER HubDnsServers
  Comma-separated hub DNS resolver IP(s) for the spoke VNet (CUSTOM_DNS_SERVERS).

.EXAMPLE
  pwsh ./scripts/handover/Switch-ToCentralDns.ps1 -Environment contoso-spokeready -CentralZoneIds $ids -HubDnsServers 10.0.2.4
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$CentralZoneIds,
    [string]$HubDnsServers
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $repo
try {
    $rg = azd env get-value AZURE_RESOURCE_GROUP -e $Environment 2>$null
    if (-not $rg) { throw "Environment '$Environment' has no AZURE_RESOURCE_GROUP (not provisioned?)." }
    if ((azd env get-value PRIVATE_DNS_ZONE_MODE -e $Environment 2>$null) -eq 'existing') { Write-Host 'Already using central zones (PRIVATE_DNS_ZONE_MODE=existing).'; return }

    Write-Host "1/4 Delete private DNS zone groups in $rg (registrations in local zones)"
    foreach ($pe in (az network private-endpoint list -g $rg --query '[].name' -o tsv)) {
        if (az network private-endpoint dns-zone-group list -g $rg --endpoint-name $pe --query '[].name' -o tsv) {
            if ($PSCmdlet.ShouldProcess($pe, 'delete zone group')) { az network private-endpoint dns-zone-group delete -g $rg --endpoint-name $pe -n default -o none; Write-Host "   $pe" }
        }
    }

    Write-Host '2/4 Re-provision against the central zones'
    azd env set PRIVATE_DNS_ZONE_MODE existing -e $Environment 2>$null
    azd env set EXISTING_PRIVATE_DNS_ZONE_IDS $CentralZoneIds -e $Environment 2>$null
    if ($HubDnsServers) { azd env set CUSTOM_DNS_SERVERS $HubDnsServers -e $Environment 2>$null }
    if ($PSCmdlet.ShouldProcess($Environment, 'azd provision')) {
        $env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
        azd provision -e $Environment --no-prompt
        if ($LASTEXITCODE) { throw 'azd provision failed; local zones were NOT removed.' }
    }

    Write-Host '3/4 Verify every private endpoint is registered in a central zone'
    foreach ($pe in (az network private-endpoint list -g $rg --query '[].name' -o tsv)) {
        $zones = az network private-endpoint dns-zone-group show -g $rg --endpoint-name $pe -n default --query 'privateDnsZoneConfigs[].privateDnsZoneId' -o tsv 2>$null
        if (-not $zones -or ($zones | Where-Object { $_ -match "/resourceGroups/$rg/" })) { throw "$pe is not registered in the central zones; local zones kept." }
    }

    Write-Host '4/4 Remove the now-empty local private DNS zones (avoid split-brain for future spoke clients)'
    foreach ($z in (az network private-dns zone list -g $rg --query '[].name' -o tsv)) {
        if (az network private-dns record-set a list -g $rg -z $z --query '[].name' -o tsv) { Write-Host "   keeping $z (still has A records)" -ForegroundColor Yellow; continue }
        foreach ($l in (az network private-dns link vnet list -g $rg -z $z --query '[].name' -o tsv)) { az network private-dns link vnet delete -g $rg -z $z -n $l --yes -o none }
        az network private-dns zone delete -g $rg -n $z --yes -o none
        Write-Host "   deleted $z"
    }
    Write-Host 'Done. Validate from a hub client: pwsh ./scripts/validation/Test-Deployment.ps1 -Environment <env> -ClientVmId <hub VM id>' -ForegroundColor Green
}
finally { Pop-Location }
