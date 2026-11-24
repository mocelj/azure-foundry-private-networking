#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Ordered teardown for an azd environment of this repository.

  Order matters with BYO VNet injection: the agent subnet carries a service association link
  (legionservicelink) that is only released after the Foundry account is deleted AND purged.
  Deleting the resource group first fails with InUseSubnetCannotBeDeleted (observed 2026-11-17).

  1. Delete hub-side peering (if opted in).
  2. Delete + purge the Foundry account.
  3. Wait until the agent subnet's service association link is gone (typically up to ~20 min).
  4. Unlink Log Analytics / App Insights from Azure Monitor Private Link Scopes.
  5. azd down --purge (resource group, Log Analytics purge).

  -PreDown runs steps 1-4 only. It is wired as the azd `predown` hook (scripts/cleanup/predown.ps1),
  so a plain `azd down --purge` performs the same ordered teardown.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Environment,
    [int]$LinkTimeoutMinutes = 45,
    [switch]$PreDown
)
$ErrorActionPreference = 'Stop'
# This script's own `azd down` (step 5) triggers the predown hook again; steps 1-4 are already done.
if ($PreDown -and $env:FOUNDRY_ORDERED_TEARDOWN_DONE -eq '1') { Write-Host 'predown: ordered teardown already done.'; return }
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }
$vals = @{}
if ($PreDown -and $env:AZURE_RESOURCE_GROUP) {
    # inside an azd hook the environment values are already in the process environment
    Get-ChildItem env: | ForEach-Object { $vals[$_.Name] = $_.Value }
} else {
    azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $vals[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }
}
$rg = $vals.AZURE_RESOURCE_GROUP; $acct = $vals.AZURE_AI_ACCOUNT_NAME; $loc = $vals.AZURE_LOCATION; $vnet = $vals.VNET_NAME
if (-not $rg) {
    if ($PreDown) { Write-Host 'predown: environment not provisioned, nothing to order.'; return }
    throw 'No provisioned azd environment selected.'
}

# All az calls below use the az CLI default subscription: refuse to run against the wrong one
# (otherwise "not found" checks silently succeed and the real resources stay behind).
$cliSub = az account show --query id -o tsv
if ($vals.AZURE_SUBSCRIPTION_ID -and $cliSub -ne $vals.AZURE_SUBSCRIPTION_ID) {
    throw "az CLI default subscription is $cliSub but the environment uses $($vals.AZURE_SUBSCRIPTION_ID). Run: az account set --subscription $($vals.AZURE_SUBSCRIPTION_ID)"
}
if ((az group exists -n $rg) -ne 'true') {
    if ($PreDown) { Write-Host "predown: resource group $rg not found, nothing to order."; return }
}

# 1. hub-side peering
if ($vals.ENABLE_HUB_SIDE_PEERING -eq 'true' -and $vals.EXISTING_HUB_VNET_ID) {
    $p = $vals.EXISTING_HUB_VNET_ID.Split('/')
    $peer = "peer-to-$vnet"
    if ($PSCmdlet.ShouldProcess("$($p[8])/$peer", 'delete hub-side peering')) {
        az network vnet peering delete --subscription $p[2] -g $p[4] --vnet-name $p[8] -n $peer 2>$null
    }
}

# 2. delete projects, then delete + purge the Foundry account (accounts with projects can't be deleted)
# 2a. AI Search shared private links (Foundry IQ query planning) must go first: once the target account is
#     purged, Search can't delete itself (LockedSPLResourceFound, observed 2026-11-19).
foreach ($svc in @(az resource list -g $rg --resource-type Microsoft.Search/searchServices --query '[].name' -o tsv 2>$null)) {
    foreach ($spl in @(az search shared-private-link-resource list -g $rg --service-name $svc --query '[].name' -o tsv 2>$null)) {
        if ($PSCmdlet.ShouldProcess("$svc/$spl", 'delete AI Search shared private link')) {
            Write-Host "  deleting shared private link $svc/$spl ..."
            az search shared-private-link-resource delete -g $rg --service-name $svc -n $spl --yes -o none
            if ($LASTEXITCODE) { throw "Failed to delete shared private link $svc/$spl" }
        }
    }
}
if ($acct -and $PSCmdlet.ShouldProcess($acct, 'delete projects, delete and purge Foundry account')) {
    $sub = az account show --query id -o tsv
    $acctId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$acct"
    $exists = az cognitiveservices account show -g $rg -n $acct --query name -o tsv 2>$null
    if ($exists) {
        $projects = az rest --method get --url "https://management.azure.com$acctId/projects?api-version=2026-09-01" --query "value[].name" -o tsv
        foreach ($p in ($projects | ForEach-Object { $_.Split('/')[-1] })) {
            Write-Host "  deleting project $p ..."
            az rest --method delete --url "https://management.azure.com$acctId/projects/$p`?api-version=2026-09-01"
            if ($LASTEXITCODE) { throw "Failed to delete project $p" }
            do { Start-Sleep 15; $still = az rest --method get --url "https://management.azure.com$acctId/projects/$p`?api-version=2026-09-01" --query name -o tsv 2>$null } while ($still)
        }
        Write-Host "  deleting account $acct ..."
        # Managed VNet: the service-created account capability host (…@aml_aiagentservice) survives project
        # deletion and the account delete then hangs in Deleting/Failed (observed 2026-11-19/20). Delete it first.
        if ($vals.DEPLOYED_OUTBOUND_NETWORK_MODE -eq 'managedVnet') {
            foreach ($ch in @(az rest --method get --url "https://management.azure.com$acctId/capabilityHosts?api-version=2026-09-01" --query "value[].name" -o tsv 2>$null)) {
                Write-Host "  deleting account capability host $ch ..."
                az rest --method delete --url "https://management.azure.com$acctId/capabilityHosts/$ch`?api-version=2026-09-01" -o none
                if ($LASTEXITCODE) { throw "Failed to delete capability host $ch" }
            }
        }
        $ok = $false
        $deadline = (Get-Date).AddMinutes(60); $i = 0
        while ((Get-Date) -lt $deadline) {
            $state = az cognitiveservices account show -g $rg -n $acct --query properties.provisioningState -o tsv 2>$null
            if (-not $state) { $ok = $true; break }
            if ($state -eq 'Deleting') {
                # an earlier delete is still running (managed VNet accounts take long): wait, don't re-issue
                Write-Host '  account is Deleting, waiting ...'; Start-Sleep 60; continue
            }
            az cognitiveservices account delete -g $rg -n $acct 2>&1 | Tee-Object -Variable delOut | Out-Null
            if (-not $LASTEXITCODE) { $ok = $true; break }
            # eventual consistency after project deletion; managed network (managed VNet) still deprovisioning;
            # accounts that ran hosted agents return FailedToDeleteAccount for a while until backend cleanup finishes
            if ("$delOut" -notmatch 'nested resources|provisioning state is not terminal|FailedToDeleteAccount' -or ++$i -ge 20) { Write-Host "$delOut"; break }
            Write-Host "  account not deletable yet (nested resources / non-terminal state / backend cleanup), retry $i/20 in 60 s ..."
            Start-Sleep 60
        }
        if (-not $ok) { throw "Failed to delete Foundry account $acct" }
    }
    $deleted = az cognitiveservices account list-deleted --query "[?name=='$acct']" -o json | ConvertFrom-Json
    if ($deleted) {
        Write-Host "  purging account $acct (can take 15-25 min) ..."
        az cognitiveservices account purge -g $rg -n $acct -l $loc
        if ($LASTEXITCODE) { throw "Failed to purge Foundry account $acct" }
    }
}

# 3. wait for the agent subnet service association link to clear
if ($vnet -and $vals.DEPLOYED_OUTBOUND_NETWORK_MODE -ne 'none') {
    $deadline = (Get-Date).AddMinutes($LinkTimeoutMinutes)
    do {
        $links = az network vnet subnet show -g $rg --vnet-name $vnet -n snet-agent --query "serviceAssociationLinks[].name" -o tsv 2>$null
        if (-not $links) { break }
        Write-Host "  waiting for service association link to clear on snet-agent ($links)..."
        Start-Sleep -Seconds 60
    } while ((Get-Date) -lt $deadline)
    if ($links) { throw "Service association link still present after $LinkTimeoutMinutes min. Re-run later." }
}

# 4. unlink Log Analytics / App Insights from Azure Monitor Private Link Scopes (own or central hub AMPLS);
#    Azure refuses to delete a workspace that is still scoped (CannotDeleteWorkspaceWhenLinkedToPrivateLinkScopes).
$monitorIds = @(az resource list -g $rg --query "[?type=='Microsoft.OperationalInsights/workspaces' || type=='Microsoft.Insights/components'].id" -o tsv 2>$null)
if ($monitorIds) {
    foreach ($ampls in @(az resource list --resource-type Microsoft.Insights/privateLinkScopes --query '[].id' -o tsv)) {
        $scoped = (az rest --method get --url "https://management.azure.com$ampls/scopedResources?api-version=2021-07-01-preview" -o json | ConvertFrom-Json).value
        foreach ($s in $scoped | Where-Object { $linked = $_.properties.linkedResourceId; $monitorIds | Where-Object { $_ -ieq $linked } }) {
            if ($PSCmdlet.ShouldProcess($s.id, 'remove AMPLS scoped resource')) {
                Write-Host "  unlinking $($s.properties.linkedResourceId.Split('/')[-1]) from AMPLS $($ampls.Split('/')[-1])"
                az rest --method delete --url "https://management.azure.com$($s.id)?api-version=2021-07-01-preview" -o none
                if ($LASTEXITCODE) { throw "Failed to remove AMPLS scoped resource $($s.id)" }
            }
        }
    }
}

if ($PreDown) { Write-Host 'predown: ordered teardown done, azd now deletes the resource group.'; return }

# 5. resource group
if ($PSCmdlet.ShouldProcess($rg, 'azd down --purge')) {
    $env:FOUNDRY_ORDERED_TEARDOWN_DONE = '1'
    azd down @envArgs --purge --force --no-prompt
    if ($LASTEXITCODE) { throw "azd down failed (exit $LASTEXITCODE); resource group $rg may still exist. Fix the cause and re-run this script." }
    if ((az group exists -n $rg) -eq 'true') { throw "Resource group $rg still exists after azd down." }
}
Write-Host 'Teardown complete.'
