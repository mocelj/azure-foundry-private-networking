#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Live validation of a deployed environment: network isolation, identity/RBAC, negative public
  tests and in-VNet functional tests (DNS, TCP, private model inference, project API, agent run).

.DESCRIPTION
  Sections
    network   - management-plane checks of isolation settings (PNA, ACLs, PEs approved, no public NICs, NSGs)
    identity  - managed identities, expected role assignments, no broad roles, local auth disabled
    public    - data-plane calls from THIS machine (outside the VNet) WITH a valid Entra token.
                PASS only when the service rejects the call for a *network* reason (HTTP 403 +
                network error code). 401 or an authorization error is reported as INCONCLUSIVE,
                because it does not prove the endpoint is private.
    invnet    - runs scripts/validation/invnet-probe.ps1 on the jumpbox via VM Run Command.
    hosted    - hosted agent demo (only when DEPLOYED_HOSTED_AGENT_DEMO=true): scripts/validation/hosted-agent-probe.ps1
                on the private client (agent exists, private invoke with citation, jailbreak -> 400 content_filter),
                public negative on the agent Responses endpoint from this machine, agent identity RBAC (ARM).

  Writes a JSON + Markdown report to .test-output/.
.EXAMPLE
  pwsh ./scripts/validation/Test-Deployment.ps1
  pwsh ./scripts/validation/Test-Deployment.ps1 -Sections network,identity,public
#>
[CmdletBinding()]
param(
    [ValidateSet('network', 'identity', 'public', 'invnet', 'hosted')]
    [string[]]$Sections = @('network', 'identity', 'public', 'invnet', 'hosted'),
    [switch]$SkipAgentRun,
    [string]$Environment,
    # Resource ID of a private client VM (e.g. in the customer hub) to run the in-VNet probe from.
    # Defaults to the jumpbox. Linux VMs run invnet-probe.sh, Windows VMs invnet-probe.ps1.
    [string]$ClientVmId,
    # NETWORK_MODE=public only: a Windows VM whose egress IP is NOT in PUBLIC_ALLOWED_IPS (proves the firewall rejects other sources).
    [string]$OutsiderVmId
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }

# ----------------------------------------------------------------------------- context
$envValues = @{}
azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $envValues[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }
function E([string]$k) { $envValues[$k] }
$rg = E 'AZURE_RESOURCE_GROUP'; $account = E 'AZURE_AI_ACCOUNT_NAME'; $project = E 'AZURE_AI_PROJECT_NAME'
if (-not $rg -or -not $account) { throw 'azd environment has no provisioned outputs (run azd provision first).' }
$sub = az account show --query id -o tsv
$accountId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$account"
$outboundMode = E 'DEPLOYED_OUTBOUND_NETWORK_MODE'
$mvnet = $outboundMode -eq 'managedVnet'
# Standard agent setup exists with BYO VNet injection and with the managed VNet.
$agentsOn = $outboundMode -in 'byoVnet', 'managedVnet'
$kbSearch = E 'KNOWLEDGE_SEARCH_NAME'; $kbIndex = E 'KNOWLEDGE_SEARCH_INDEX'
$appiName = E 'APPLICATIONINSIGHTS_NAME'; $amplsId = E 'AMPLS_ID'
$ragVm = E 'RAG_VM_NAME'; $ragUrl = E 'RAG_APP_URL'

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Section, [string]$Test, [ValidateSet('PASS', 'FAIL', 'INCONCLUSIVE', 'SKIP')][string]$Result, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Section = $Section; Test = $Test; Result = $Result; Detail = $Detail })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; INCONCLUSIVE = 'Yellow'; SKIP = 'DarkGray' }[$Result]
    Write-Host ("  [{0,-12}] {1}  {2}" -f $Result, $Test, $Detail) -ForegroundColor $color
}
function Check([string]$Section, [string]$Test, [bool]$Ok, [string]$Detail = '') { Add-Result $Section $Test $(if ($Ok) { 'PASS' } else { 'FAIL' }) $Detail }
function ArmGet([string]$id, [string]$api) { az rest --method get --url "https://management.azure.com$id`?api-version=$api" -o json 2>$null | ConvertFrom-Json }

Write-Host "`n=== Validating $rg ($account) ===" -ForegroundColor Cyan

# ============================================================================= public quick-demo mode
# NETWORK_MODE=public is deliberately NOT private: instead of proving that public access is rejected,
# prove that it is restricted to the allow-list, Entra-only, and that the demo works from this machine.
function Write-Report {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outDir = Join-Path $repo '.test-output'; New-Item -ItemType Directory $outDir -Force | Out-Null
    $results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir "validation-$stamp.json")
    $md = @("# Validation report $stamp", '', "Resource group: ``$rg`` - account: ``$account`` - mode: $(E 'DEPLOYED_NETWORK_MODE') / $(E 'DEPLOYED_OUTBOUND_NETWORK_MODE')", '', '| Section | Test | Result | Detail |', '|---|---|---|---|')
    $md += $results | ForEach-Object { "| $($_.Section) | $($_.Test) | $($_.Result) | $(($_.Detail -replace '\|', '/')) |" }
    $md | Set-Content (Join-Path $outDir "validation-$stamp.md")
    $summary = $results | Group-Object Result | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host "`nSummary: $($summary -join '  ')   report: .test-output/validation-$stamp.md"
    if ($results.Result -contains 'FAIL') { exit 1 } else { exit 0 }
}
function Invoke-Data([string]$Method, [string]$Url, [string]$Resource, $Body, [hashtable]$Headers = @{}) {
    $h = @{} + $Headers
    if ($Resource) { $h.Authorization = "Bearer $(az account get-access-token --resource $Resource --query accessToken -o tsv)" }
    $p = @{ Method = $Method; Uri = $Url; Headers = $h; SkipHttpErrorCheck = $true; TimeoutSec = 120 }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    try { $r = Invoke-WebRequest @p; return @{ status = [int]$r.StatusCode; body = [string]$r.Content } } catch { return @{ status = 0; body = $_.Exception.Message } }
}
function Get-OutputText($body) { (((($body | ConvertFrom-Json).output) | Where-Object type -eq 'message').content | Where-Object type -eq 'output_text').text -join '' }
function Cut([string]$s) { if ($s.Length -gt 250) { $s.Substring(0, 250) } else { $s } }

if ((E 'DEPLOYED_NETWORK_MODE') -eq 'public') {
    Write-Host "`n[public-mode] NETWORK_MODE=public - quick demo, NOT private" -ForegroundColor Yellow
    $acct = ArmGet $accountId '2026-09-01'
    $allowed = @((E 'PUBLIC_ALLOWED_IPS') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $acl = $acct.properties.networkAcls
    Check network 'Foundry publicNetworkAccess = Enabled (public mode, expected)' ($acct.properties.publicNetworkAccess -eq 'Enabled') $acct.properties.publicNetworkAccess
    if ($allowed) {
        $rules = @($acl.ipRules.value) -replace '/32$', ''
        $want = @($allowed) -replace '/32$', ''
        $same = (@($rules | Where-Object { $_ -notin $want }).Count -eq 0) -and (@($want | Where-Object { $_ -notin $rules }).Count -eq 0)
        Check network "Foundry firewall: deny by default, allow-list = PUBLIC_ALLOWED_IPS ($($allowed -join ','))" ($acl.defaultAction -eq 'Deny' -and $same) "default=$($acl.defaultAction) ipRules=$($rules -join ',')"
    } else {
        Add-Result network 'Foundry firewall: no allow-list (open to the internet, Entra-only)' 'INCONCLUSIVE' "default=$($acl.defaultAction) - set PUBLIC_ALLOWED_IPS to restrict"
    }
    Check identity 'Foundry local (key) auth disabled' ([bool]$acct.properties.disableLocalAuth)
    Check network 'No network injection (Basic agent setup)' (-not $acct.properties.networkInjections)
    $types = @(az resource list -g $rg --query '[].type' -o tsv)
    $unexpected = @($types | Where-Object { $_ -match '(?i)virtualNetworks|privateEndpoints|bastionHosts|virtualMachines|publicIPAddresses|natGateways|privateDnsZones' })
    Check network 'No VNet / private endpoints / VMs / public IPs deployed' ($unexpected.Count -eq 0) ($unexpected -join ',')
    Check network 'Resource group tagged network-exposure=public' ((az group show -n $rg --query tags -o json | ConvertFrom-Json).'network-exposure' -eq 'public')

    $me = E 'AZURE_PRINCIPAL_ID'; if (-not $me) { $me = az ad signed-in-user show --query id -o tsv 2>$null }
    if ($me) {
        # ARM only (az role assignment list also calls Microsoft Graph, which timed out intermittently).
        $ras = (az rest --method get --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$me'" -o json | ConvertFrom-Json).value.properties
        Check identity 'User: Foundry User on project' ([bool]($ras | Where-Object { $_.roleDefinitionId -like '*53ca6127-db72-4b80-b1b0-d745d6d5456d' -and $_.scope -like "*/accounts/$account/projects/$project" }))
        Check identity 'User: Cognitive Services OpenAI User on account' ([bool]($ras | Where-Object { $_.roleDefinitionId -like '*5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' -and $_.scope -like "*/accounts/$account" }))
    }

    Write-Host "`n[public-mode functional] (from this machine)"
    $ip = try { (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 10) } catch { 'unknown' }
    Write-Host "  caller public IP: $ip"
    $ep = E 'AZURE_AI_PROJECT_ENDPOINT'; $dep = E 'AZURE_AI_MODEL_DEPLOYMENT_NAME'
    $r = Invoke-Data POST "https://$account.openai.azure.com/openai/v1/responses" 'https://cognitiveservices.azure.com' @{ model = $dep; input = 'Reply with exactly the text PUBLIC-OK and nothing else.'; max_output_tokens = 64 }
    $text = if ($r.status -eq 200) { Get-OutputText $r.body } else { '' }
    Check functional 'Model inference from this machine (Entra token)' ($r.status -eq 200 -and $text -match 'PUBLIC-OK') "HTTP $($r.status) text='$text' $(if ($r.status -ne 200) { Cut $r.body })"
    $r = Invoke-Data POST "https://$account.openai.azure.com/openai/v1/responses" '' @{ model = $dep; input = 'x' } @{ 'api-key' = 'not-a-real-key' }
    Check functional 'Key auth rejected (no API keys)' ($r.status -in 401, 403) "HTTP $($r.status)"
    $r = Invoke-Data GET "$ep/deployments?api-version=v1" 'https://ai.azure.com' $null
    Check functional 'Project API from this machine' ($r.status -eq 200) "HTTP $($r.status)"
    if (-not $SkipAgentRun) {
        $name = 'public-validation-agent'
        $def = @{ definition = @{ kind = 'prompt'; model = $dep; instructions = 'You are a validation agent. Answer with exactly AGENT-PUBLIC-OK.' } }
        $r = $null
        foreach ($a in 1..3) { $r = Invoke-Data POST "$ep/agents/$name/versions?api-version=v1" 'https://ai.azure.com' $def; if ($r.status -in 200, 201) { break }; Start-Sleep 20 }
        Check functional 'Create agent version (Basic setup)' ($r.status -in 200, 201) "HTTP $($r.status) $(if ($r.status -notin 200, 201) { Cut $r.body })"
        $r = Invoke-Data POST "$ep/openai/v1/responses" 'https://ai.azure.com' @{ agent_reference = @{ name = $name; type = 'agent_reference' }; input = 'Validation ping' }
        $text = if ($r.status -eq 200) { Get-OutputText $r.body } else { '' }
        Check functional 'Run agent (Basic setup, Microsoft-managed state)' ($r.status -eq 200 -and $text -match 'AGENT-PUBLIC-OK') "HTTP $($r.status) text='$text' $(if ($r.status -ne 200) { Cut $r.body })"
    }

    if ($allowed -and $OutsiderVmId) {
        $p = $OutsiderVmId.Split('/')
        $pw = az vm get-instance-view --subscription $p[2] -g $p[4] -n $p[8] --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
        if ($pw -ne 'PowerState/running') { Write-Host "  starting $($p[8]) ($pw)..."; az vm start --subscription $p[2] -g $p[4] -n $p[8] -o none }
        # Authorization is evaluated before the IP firewall, so the outsider identity must be authorized for the
        # test to prove anything: grant a TEMPORARY role on this account and always remove it afterwards.
        $outMi = az vm show --subscription $p[2] -g $p[4] -n $p[8] --query identity.principalId -o tsv
        $tmpRa = az role assignment create --assignee-object-id $outMi --assignee-principal-type ServicePrincipal --role 'Cognitive Services OpenAI User' --scope $accountId --description 'TEMPORARY: Test-Deployment.ps1 public-mode firewall test (removed after the test)' --query id -o tsv 2>$null
        try {
            $probe = (Get-Content (Join-Path $PSScriptRoot 'outsider-probe.ps1') -Raw).Replace('__ACCOUNT__', $account).Replace('__DEPLOYMENT__', $dep)
            $tmp = New-TemporaryFile; Set-Content $tmp $probe
            $msg = (az vm run-command invoke --subscription $p[2] -g $p[4] -n $p[8] --command-id RunPowerShellScript --scripts "@$tmp" -o json | ConvertFrom-Json).value[0].message
            Remove-Item $tmp
        } finally { if ($tmpRa) { az role assignment delete --ids $tmpRa 2>$null; Write-Host '  temporary role assignment removed' } }
        $line = [string]($msg -split "`n" | Where-Object { $_ -match '^OUTSIDER ' } | Select-Object -First 1)
        $outsiderIp = if ($line -match '^OUTSIDER (\S+)') { $Matches[1] } else { '?' }
        $ok = ($line -match 'HTTP=403') -and ($line -match '(?i)Virtual Network/Firewall') -and ($outsiderIp -notin $allowed)
        Check public "Non-allow-listed source ($outsiderIp, VM $($p[8])) rejected by the Foundry firewall" $ok (Cut $(if ($line) { $line } else { "$msg" }))
    } elseif ($allowed) { Add-Result public 'Non-allow-listed source rejected' 'SKIP' 'pass -OutsiderVmId <Windows VM with another egress IP>' }
    Write-Report
}

# ============================================================================= network
if ('network' -in $Sections) {
    Write-Host "`n[network]"
    $acct = ArmGet $accountId '2026-09-01'
    Check network 'Foundry publicNetworkAccess = Disabled' ($acct.properties.publicNetworkAccess -eq 'Disabled') $acct.properties.publicNetworkAccess
    $acl = $acct.properties.networkAcls
    Check network 'Foundry networkAcls deny-by-default, no IP/VNet rules' ($acl.defaultAction -eq 'Deny' -and @($acl.ipRules).Count -eq 0 -and @($acl.virtualNetworkRules).Count -eq 0) "default=$($acl.defaultAction) bypass=$($acl.bypass)"
    if ($agentsOn) {
        $inj = @($acct.properties.networkInjections)
        if ($mvnet) {
            Check network 'Foundry managed VNet injection (Microsoft-managed network, no customer subnet)' ($inj.Count -eq 1 -and $inj[0].scenario -eq 'agent' -and $inj[0].useMicrosoftManagedNetwork -and -not $inj[0].subnetArmId) "useMicrosoftManagedNetwork=$($inj[0].useMicrosoftManagedNetwork)"
            $mn = ArmGet "$accountId/managedNetworks/default" '2026-09-15-preview'
            $mns = $mn.properties.managedNetwork
            Check network 'Managed VNet: isolation AllowOnlyApprovedOutbound (preview API)' ($mns.isolationMode -eq 'AllowOnlyApprovedOutbound') "isolation=$($mns.isolationMode) status=$($mns.status.status)"
            $rules = @((ArmGet "$accountId/managedNetworks/default/outboundRules" '2026-09-15-preview').value)
            Add-Result network 'Managed VNet: outbound rules (info)' 'PASS' (($rules | ForEach-Object { "$($_.properties.type)/$($_.properties.category)=$($_.properties.status) $((($_.properties.destination.serviceResourceId) -split '/')[-1])$($_.properties.destination.serviceTag) $($_.properties.destination.subresourceTarget)".Trim() }) -join ', ')
            Check network 'Managed VNet: no FQDN rules (no managed firewall, no internet egress)' (@($rules | Where-Object { $_.properties.type -eq 'FQDN' }).Count -eq 0)
            $vnetSubnets = az network vnet subnet list -g $rg --vnet-name (az network vnet list -g $rg --query '[0].name' -o tsv) --query '[].name' -o tsv
            Check network 'Managed VNet: no customer agent subnet (snet-agent)' ($vnetSubnets -notcontains 'snet-agent') ($vnetSubnets -join ',')
            foreach ($want in (E 'DEPLOYED_MANAGED_NETWORK_RULES') -split ',' | Where-Object { $_ }) {
                # The list API omits rule names; read each repo rule directly.
                $r = ArmGet "$accountId/managedNetworks/default/outboundRules/$want" '2026-09-15-preview'
                Check network "Managed VNet: private endpoint rule $want active" ($r -and $r.properties.type -eq 'PrivateEndpoint' -and $r.properties.status -eq 'Active') "status=$($r.properties.status) target=$(($r.properties.destination.serviceResourceId -split '/')[-1])/$($r.properties.destination.subresourceTarget)"
            }
        } else {
            Check network 'Foundry BYO VNet injection (agent subnet)' ($inj.Count -eq 1 -and $inj[0].scenario -eq 'agent' -and -not $inj[0].useMicrosoftManagedNetwork -and $inj[0].subnetArmId -match 'snet-agent$') ($inj | ForEach-Object { $_.subnetArmId.Split('/')[-1] })
        }
        $caphosts = (ArmGet "$accountId/projects/$project/capabilityHosts" '2026-09-01').value
        Check network 'Project capability host Succeeded (Standard setup)' (@($caphosts | Where-Object { $_.properties.provisioningState -eq 'Succeeded' }).Count -eq 1) (($caphosts | ForEach-Object { "$($_.name)=$($_.properties.provisioningState)" }) -join ',')
    }

    $pes = az network private-endpoint list -g $rg -o json | ConvertFrom-Json
    foreach ($pe in $pes) {
        $conn = @($pe.privateLinkServiceConnections) + @($pe.manualPrivateLinkServiceConnections) | Where-Object { $_ }
        $state = $conn[0].privateLinkServiceConnectionState.status
        Check network "PE $($pe.name) approved [$($conn[0].groupIds -join ',')]" ($pe.provisioningState -eq 'Succeeded' -and $state -eq 'Approved') $state
    }
    $expectedPe = 1 + $(if ($agentsOn) { 3 } else { 0 }) + $(if ($kbSearch) { 1 } else { 0 }) + $(if ($amplsId -and $amplsId -match "/resourceGroups/$rg/") { 1 } else { 0 })
    Check network "Expected number of private endpoints ($expectedPe)" (@($pes).Count -eq $expectedPe) "found $(@($pes).Count)"

    if ($agentsOn) {
        $st = az storage account show -g $rg -n (E 'AGENT_STORAGE_ACCOUNT_NAME') -o json | ConvertFrom-Json
        Check network 'Storage: PNA disabled, shared key off, no public blob, TLS1.2' ($st.publicNetworkAccess -eq 'Disabled' -and -not $st.allowSharedKeyAccess -and -not $st.allowBlobPublicAccess -and $st.minimumTlsVersion -eq 'TLS1_2')
        $cos = az cosmosdb show -g $rg -n (E 'AGENT_COSMOS_ACCOUNT_NAME') -o json | ConvertFrom-Json
        Check network 'Cosmos DB: PNA disabled, local auth off' ($cos.publicNetworkAccess -eq 'Disabled' -and $cos.disableLocalAuth)
        $srch = az search service show -g $rg -n (E 'AGENT_SEARCH_SERVICE_NAME') -o json | ConvertFrom-Json
        Check network 'AI Search: PNA disabled, local auth off' ($srch.publicNetworkAccess -eq 'disabled' -and $srch.disableLocalAuth) "pna=$($srch.publicNetworkAccess)"
    }

    if ($kbSearch) {
        $kb = az search service show -g $rg -n $kbSearch -o json | ConvertFrom-Json
        Check network 'Knowledge AI Search: PNA disabled, local auth off, no bypass, SKU >= basic' ($kb.publicNetworkAccess -eq 'disabled' -and $kb.disableLocalAuth -and $kb.networkRuleSet.bypass -eq 'None' -and $kb.sku.name -ne 'free') "sku=$($kb.sku.name) bypass=$($kb.networkRuleSet.bypass)"
    }

    if ($ragVm) {
        $ragNic = az vm show -g $rg -n $ragVm --query 'networkProfile.networkInterfaces[0].id' -o tsv
        $ragSubnetId = az network nic show --ids $ragNic --query 'ipConfigurations[0].subnet.id' -o tsv
        $appSn = az network vnet subnet show --ids $ragSubnetId -o json | ConvertFrom-Json
        Check network 'RAG VM: in snet-app, subnet default outbound access disabled' ($appSn.name -eq 'snet-app' -and $appSn.defaultOutboundAccess -eq $false) "subnet=$($appSn.name) defaultOutbound=$($appSn.defaultOutboundAccess)"
        $appNsg = az network nsg show --ids $appSn.networkSecurityGroup.id -o json | ConvertFrom-Json
        $inAllow = @($appNsg.securityRules | Where-Object { $_.direction -eq 'Inbound' -and $_.access -eq 'Allow' })
        $ragPort = [string](E 'DEPLOYED_RAG_APP_PORT')
        Check network "snet-app NSG: only TCP $ragPort from VirtualNetwork inbound" ($inAllow.Count -eq 1 -and $inAllow[0].sourceAddressPrefix -eq 'VirtualNetwork' -and $inAllow[0].destinationPortRange -eq $ragPort) (($inAllow | ForEach-Object { "$($_.name):$($_.sourceAddressPrefix)->$($_.destinationPortRange)" }) -join ',')
        Check network 'snet-app NSG: internet outbound denied' ([bool]($appNsg.securityRules | Where-Object { $_.direction -eq 'Outbound' -and $_.access -eq 'Deny' -and $_.destinationAddressPrefix -eq 'Internet' }))
    }

    if ($appiName) {
        $appi = ArmGet "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/components/$appiName" '2020-02-02'
        $p = $appi.properties
        Check network 'App Insights: local auth disabled (Entra-only ingestion), workspace-based' ($p.DisableLocalAuth -eq $true -and $p.WorkspaceResourceId) "DisableLocalAuth=$($p.DisableLocalAuth)"
        $lawObj = az monitor log-analytics workspace list -g $rg -o json | ConvertFrom-Json | Select-Object -First 1
        if ($amplsId) {
            Check network 'App Insights: public query disabled' ($p.publicNetworkAccessForQuery -eq 'Disabled') "query=$($p.publicNetworkAccessForQuery) ingestion=$($p.publicNetworkAccessForIngestion)"
            Check network 'Log Analytics: public query disabled' ($lawObj.publicNetworkAccessForQuery -eq 'Disabled') "query=$($lawObj.publicNetworkAccessForQuery) ingestion=$($lawObj.publicNetworkAccessForIngestion)"
            $am = ArmGet $amplsId '2021-07-01-preview'
            $ownAmpls = $amplsId -match "/resourceGroups/$rg/"
            if ($ownAmpls) { Check network 'AMPLS (own): ingestion + query access modes PrivateOnly' ($am.properties.accessModeSettings.queryAccessMode -eq 'PrivateOnly' -and $am.properties.accessModeSettings.ingestionAccessMode -eq 'PrivateOnly') "ingestion=$($am.properties.accessModeSettings.ingestionAccessMode) query=$($am.properties.accessModeSettings.queryAccessMode)" }
            else { Add-Result network 'AMPLS (central hub): access modes (info; isolation enforced by resource public access = Disabled)' 'PASS' "ingestion=$($am.properties.accessModeSettings.ingestionAccessMode) query=$($am.properties.accessModeSettings.queryAccessMode)" }
            $scoped = (ArmGet "$amplsId/scopedResources" '2021-07-01-preview').value.properties.linkedResourceId
            Check network 'AMPLS: workspace and App Insights are scoped' (($scoped | Where-Object { $_ -ieq $appi.id }) -and ($scoped | Where-Object { $_ -ieq $lawObj.id })) "$(@($scoped).Count) scoped resources"
        }
        $conn = ArmGet "$accountId/projects/$project/connections/agent-traces" '2026-09-01'
        Check network 'Project connection agent-traces: AppInsights, project managed identity (Entra)' ($conn.properties.category -eq 'AppInsights' -and $conn.properties.authType -eq 'ProjectManagedIdentity') "category=$($conn.properties.category) auth=$($conn.properties.authType)"
    }

    if (E 'FOUNDRY_IQ_KNOWLEDGE_BASE') {
        $kbc = ArmGet "$accountId/projects/$project/connections/$(E 'FOUNDRY_IQ_MCP_CONNECTION')" '2026-09-01'
        Check network 'Foundry IQ connection: RemoteTool, project MI, targets the private knowledge search' ($kbc.properties.category -eq 'RemoteTool' -and $kbc.properties.authType -eq 'ProjectManagedIdentity' -and $kbc.properties.target -like "https://$kbSearch.search.windows.net/knowledgebases/*") "target=$($kbc.properties.target)"
        if (E 'FOUNDRY_IQ_SPL_NAME') {
            $spl = ArmGet "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Search/searchServices/$kbSearch/sharedPrivateLinkResources/$(E 'FOUNDRY_IQ_SPL_NAME')" '2025-05-01'
            Check network 'Foundry IQ query planning: shared private link knowledge search -> Foundry approved (openai_account)' ($spl.properties.status -eq 'Approved' -and $spl.properties.provisioningState -eq 'Succeeded' -and $spl.properties.groupId -eq 'openai_account' -and $spl.properties.privateLinkResourceId -ieq $accountId) "status=$($spl.properties.status) prov=$($spl.properties.provisioningState) group=$($spl.properties.groupId)"
            $kbMi = az search service show -g $rg -n $kbSearch --query identity.principalId -o tsv
            $kbMiRoles = (az rest --method get --url "https://management.azure.com$accountId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$kbMi'" -o json 2>$null | ConvertFrom-Json).value.properties.roleDefinitionId
            Check identity 'Knowledge search MI: Cognitive Services OpenAI User on the Foundry account (query planning)' (@($kbMiRoles | Where-Object { $_ -like '*5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' }).Count -eq 1) "$(@($kbMiRoles).Count) assignment(s)"
        }
    }

    $nics = az network nic list -g $rg -o json | ConvertFrom-Json
    $publicNics = $nics | Where-Object { @($_.ipConfigurations | Where-Object { $_.publicIPAddress.id }).Count -gt 0 }
    Check network 'No NIC has a public IP' (-not $publicNics) (($publicNics.name) -join ',')

    $pips = az network public-ip list -g $rg -o json | ConvertFrom-Json
    $unexpected = $pips | Where-Object { $_.ipConfiguration.id -notmatch '/bastionHosts/|/natGateways/' -and $_.natGateway.id -eq $null }
    Check network 'Public IPs only on Bastion ingress / NAT egress' (-not $unexpected) (($pips | ForEach-Object { "$($_.name)->$((($_.ipConfiguration.id) -split '/')[7])$((($_.natGateway.id) -split '/')[7])" }) -join ', ')

    $nsgs = az network nsg list -g $rg -o json | ConvertFrom-Json
    $bad = foreach ($n in $nsgs) {
        foreach ($r in $n.securityRules | Where-Object { $_.direction -eq 'Inbound' -and $_.access -eq 'Allow' }) {
            $src = @($r.sourceAddressPrefix) + @($r.sourceAddressPrefixes) | Where-Object { $_ }
            if (($src | Where-Object { $_ -in '*', 'Internet', '0.0.0.0/0' }) -and -not ($n.name -match 'bastion' -and $r.destinationPortRange -eq '443')) { "$($n.name)/$($r.name)" }
        }
    }
    Check network 'NSGs: no inbound from Internet (except Bastion 443)' (-not $bad) ($bad -join ',')

    if ((E 'PRIVATE_DNS_ZONE_MODE') -eq 'existing') {
        # Central zones: verify each PE's records landed in the customer's zones (only zones this deployment uses).
        $neededZones = @('privatelink.cognitiveservices.azure.com', 'privatelink.openai.azure.com', 'privatelink.services.ai.azure.com')
        if ($agentsOn) { $neededZones += 'privatelink.blob.core.windows.net', 'privatelink.documents.azure.com', 'privatelink.search.windows.net' }
        if ($kbSearch) { $neededZones += 'privatelink.search.windows.net' }
        foreach ($zid in ((E 'EXISTING_PRIVATE_DNS_ZONE_IDS') -split ',' | ForEach-Object Trim | Where-Object { $_ -and (($_ -split '/')[-1] -in $neededZones) })) {
            $zp = $zid.Split('/')
            $records = az network private-dns record-set a list --subscription $zp[2] -g $zp[4] -z $zp[8] --query "[].{n:name,ip:aRecords[0].ipv4Address}" -o json | ConvertFrom-Json
            $mine = $records | Where-Object { $_.n -like "$account*" -or $_.n -like "*$((E 'AZURE_RESOURCE_GROUP') -replace '^rg-','')*" -or $_.n -in @((E 'AGENT_STORAGE_ACCOUNT_NAME'), (E 'AGENT_COSMOS_ACCOUNT_NAME'), "$(E 'AGENT_COSMOS_ACCOUNT_NAME')-$(E 'AZURE_LOCATION')", (E 'AGENT_SEARCH_SERVICE_NAME')) }
            Check network "Central DNS zone $($zp[8]): A records for this deployment" (@($mine).Count -ge 1) (($mine | ForEach-Object { "$($_.n)=$($_.ip)" }) -join ' ')
        }
        Check network 'No private DNS zones created in workload RG (central DNS)' (-not (az network private-dns zone list -g $rg --query "[].name" -o tsv))
    }
    $zones = az network private-dns zone list -g $rg -o json | ConvertFrom-Json
    foreach ($z in $zones) {
        $links = az network private-dns link vnet list -g $rg -z $z.name -o json | ConvertFrom-Json
        $records = az network private-dns record-set a list -g $rg -z $z.name --query "[].{n:name,ip:aRecords[0].ipv4Address}" -o json | ConvertFrom-Json
        Check network "DNS zone $($z.name): linked + A records" (@($links).Count -ge 1 -and @($records).Count -ge 1) (($records | ForEach-Object { "$($_.n)=$($_.ip)" }) -join ' ')
    }
}

# ============================================================================= identity
if ('identity' -in $Sections) {
    Write-Host "`n[identity]"
    $acct = ArmGet $accountId '2026-09-01'
    Check identity 'Foundry local (key) auth disabled' ([bool]$acct.properties.disableLocalAuth)
    Check identity 'Foundry account system-assigned identity' ([bool]$acct.identity.principalId)
    $proj = ArmGet "$accountId/projects/$project" '2026-09-01'
    Check identity 'Foundry project system-assigned identity' ([bool]$proj.identity.principalId)
    $projPid = $proj.identity.principalId

    $ras = az role assignment list --all -o json | ConvertFrom-Json | Where-Object { $_.scope -match "(?i)/resourceGroups/$([regex]::Escape($rg))(/|$)" }
    function Has([string]$principal, [string]$role, [string]$scopeLike) { [bool]($ras | Where-Object { $_.principalId -eq $principal -and $_.roleDefinitionName -eq $role -and $_.scope -like $scopeLike }) }

    $me = E 'AZURE_PRINCIPAL_ID'; if (-not $me) { $me = az ad signed-in-user show --query id -o tsv 2>$null }
    if ($me) {
        Check identity 'User: Foundry User on project' (Has $me 'Foundry User' "*/accounts/$account/projects/$project")
        Check identity 'User: Cognitive Services OpenAI User on account' (Has $me 'Cognitive Services OpenAI User' "*/accounts/$account")
    }
    $vm = E 'JUMPBOX_VM_NAME'
    if ($vm) {
        $vmPid = az vm show -g $rg -n $vm --query identity.principalId -o tsv
        Check identity 'Jumpbox MI: OpenAI User on account (validation client)' (Has $vmPid 'Cognitive Services OpenAI User' "*/accounts/$account")
        if ($me) { Check identity 'User: Virtual Machine User Login on jumpbox' (Has $me 'Virtual Machine User Login' "*/virtualMachines/$vm") }
        $aad = az vm extension show -g $rg --vm-name $vm -n AADLoginForWindows --query provisioningState -o tsv 2>$null
        Check identity 'Jumpbox Entra ID login extension' ($aad -eq 'Succeeded') $aad
    }
    if ($ragVm) {
        $ragPid = az vm show -g $rg -n $ragVm --query identity.principalId -o tsv
        Check identity 'RAG VM MI: Cognitive Services OpenAI User on account' (Has $ragPid 'Cognitive Services OpenAI User' "*/accounts/$account")
        Check identity 'RAG VM MI: Search Index Data Reader on knowledge search' (Has $ragPid 'Search Index Data Reader' "*/searchServices/$kbSearch")
        $ragExtra = @($ras | Where-Object { $_.principalId -eq $ragPid -and $_.roleDefinitionName -notin 'Cognitive Services OpenAI User', 'Search Index Data Reader' })
        Check identity 'RAG VM MI: no other role assignments (least privilege)' ($ragExtra.Count -eq 0) (($ragExtra | ForEach-Object roleDefinitionName) -join ',')
    }
    if ($agentsOn) {
        Check identity 'Project MI: Storage Blob Data Contributor' (Has $projPid 'Storage Blob Data Contributor' "*/storageAccounts/*")
        Check identity 'Project MI: Storage Blob Data Owner (ABAC, own containers)' ([bool]($ras | Where-Object { $_.principalId -eq $projPid -and $_.roleDefinitionName -eq 'Storage Blob Data Owner' -and $_.condition }))
        Check identity 'Project MI: Cosmos DB Operator' (Has $projPid 'Cosmos DB Operator' "*/databaseAccounts/*")
        Check identity 'Project MI: Search Index Data Contributor' (Has $projPid 'Search Index Data Contributor' "*/searchServices/*")
        $sql = az cosmosdb sql role assignment list -g $rg -a (E 'AGENT_COSMOS_ACCOUNT_NAME') -o json | ConvertFrom-Json
        Check identity 'Project MI: Cosmos data-plane role scoped to enterprise_memory' ([bool]($sql | Where-Object { $_.principalId -eq $projPid -and $_.scope -match '/dbs/enterprise_memory$' }))
    }
    if ($appiName) {
        Check identity 'Project MI: Monitoring Metrics Publisher on App Insights (trace ingestion)' (Has $projPid 'Monitoring Metrics Publisher' "*/components/$appiName")
    }
    $broad = $ras | Where-Object { $_.roleDefinitionName -in 'Owner', 'Contributor', 'User Access Administrator', 'Role Based Access Control Administrator' -and $_.principalType -eq 'ServicePrincipal' }
    Check identity 'No managed identity has Owner/Contributor/UAA/RBAC Admin in the RG' (-not $broad) (($broad | ForEach-Object { "$($_.principalName):$($_.roleDefinitionName)" }) -join ',')
}

# ============================================================================= public (negative)
function Test-PublicRejection([string]$Name, [string]$Url, [string]$Resource, [string]$Method = 'GET') {
    $token = az account get-access-token --resource $Resource --query accessToken -o tsv
    $status = 0; $body = ''
    try {
        $r = Invoke-WebRequest -Method $Method -Uri $Url -Headers @{ Authorization = "Bearer $token"; 'x-ms-version' = '2023-11-03' } -SkipHttpErrorCheck -TimeoutSec 30
        $status = [int]$r.StatusCode; $body = [string]$r.Content
    } catch { $body = $_.Exception.Message }
    $networkPattern = 'PrivateLinkValidationFailed|only permitted through a Private Link|publicNetworkAccess: Disabled|source is not allowed by applicable rules|<Code>AuthorizationFailure</Code>|public (network )?access is disabled|PublicNetworkAccessDisabled|not from an approved private endpoint|private endpoint|virtual network|IpAuthorizationError|ip address|firewall|AuthorizationFailure.*network|request originated from'
    $snippet = ($body -replace '\s+', ' '); if ($snippet.Length -gt 180) { $snippet = $snippet.Substring(0, 180) }
    if ($status -in 200..299) { Add-Result public $Name 'FAIL' "HTTP $status - endpoint is reachable from the public internet!" }
    elseif ($status -eq 403 -and $body -match $networkPattern) { Add-Result public $Name 'PASS' "HTTP 403 network rejection: $snippet" }
    elseif ($status -eq 0 -and $body -match 'No such host|name resolution|timed out|actively refused') { Add-Result public $Name 'PASS' "connection blocked: $snippet" }
    else { Add-Result public $Name 'INCONCLUSIVE' "HTTP $status (not a provable network rejection): $snippet" }
}
if ('public' -in $Sections) {
    Write-Host "`n[public] (from this machine, outside the VNet, with a VALID Entra token)"
    $ip = try { (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 10) } catch { 'unknown' }
    Write-Host "  caller public IP: $ip"
    foreach ($h in "$account.openai.azure.com", "$account.services.ai.azure.com") {
        $a = Resolve-DnsName $h -ErrorAction SilentlyContinue | Where-Object Type -eq 'A' | Select-Object -First 1
        $cn = (Resolve-DnsName $h -ErrorAction SilentlyContinue | Where-Object Type -eq 'CNAME' | ForEach-Object NameHost) -join ' -> '
        Add-Result public "Public DNS for $h (info)" 'PASS' "public A=$($a.IPAddress) via $cn"
    }
    Test-PublicRejection 'Model inference (openai/v1/models)' "https://$account.openai.azure.com/openai/v1/models" 'https://cognitiveservices.azure.com'
    Test-PublicRejection 'Foundry project API (deployments)' "$(E 'AZURE_AI_PROJECT_ENDPOINT')/deployments?api-version=v1" 'https://ai.azure.com'
        if ($kbSearch) { Test-PublicRejection 'Knowledge AI Search (query index)' "https://$kbSearch.search.windows.net/indexes/$kbIndex/docs?api-version=2024-07-01&search=*" 'https://search.azure.com' }
    if ($appiName -and $amplsId) { Test-PublicRejection 'Agent traces (App Insights query via Log Analytics API)' "https://api.loganalytics.io/v1/subscriptions/$sub/resourceGroups/$rg/providers/microsoft.insights/components/$appiName/query?query=AppDependencies%20%7C%20take%201" 'https://api.loganalytics.io' }
    if ($agentsOn) {
        Test-PublicRejection 'Storage blob (list containers)' "https://$(E 'AGENT_STORAGE_ACCOUNT_NAME').blob.core.windows.net/?comp=list" 'https://storage.azure.com'
        Test-PublicRejection 'AI Search (list indexes)' "https://$(E 'AGENT_SEARCH_SERVICE_NAME').search.windows.net/indexes?api-version=2024-07-01" 'https://search.azure.com'
        Test-PublicRejection 'Cosmos DB (list databases)' "https://$(E 'AGENT_COSMOS_ACCOUNT_NAME').documents.azure.com/dbs" 'https://cosmos.azure.com'
    }
}

# ============================================================================= in-VNet functional
if ('invnet' -in $Sections) {
    $vmRg = $rg; $vm = E 'JUMPBOX_VM_NAME'; $vmSub = $sub
    if (-not $ClientVmId -and -not $vm -and (E 'PRIVATE_CLIENT_VM_ID')) { $ClientVmId = E 'PRIVATE_CLIENT_VM_ID' }
    if ($ClientVmId) { $p = $ClientVmId.Split('/'); $vmSub = $p[2]; $vmRg = $p[4]; $vm = $p[8] }
    Write-Host "`n[invnet] (executed on $vm via VM Run Command)"
    if (-not $vm) { Add-Result invnet 'In-VNet tests' 'SKIP' 'No jumpbox in this mode; pass -ClientVmId <hub-connected VM> or run invnet-probe.ps1/.sh on a private client.' }
    else {
        $vmInfo = az vm show --subscription $vmSub -g $vmRg -n $vm --query "{os:storageProfile.osDisk.osType}" -o json | ConvertFrom-Json
        $power = az vm get-instance-view --subscription $vmSub -g $vmRg -n $vm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
        if ($power -ne 'PowerState/running') { Write-Host "  starting $vm ($power)..."; az vm start --subscription $vmSub -g $vmRg -n $vm -o none }
        if ($ragVm) {
            $rp0 = az vm get-instance-view -g $rg -n $ragVm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
            if ($rp0 -ne 'PowerState/running') { Write-Host "  starting $ragVm ($rp0)..."; az vm start -g $rg -n $ragVm -o none; Start-Sleep -Seconds 30 }
        }
        $extra = @()
        # Subnet of the AMPLS private endpoint (own PE subnet in standalone, hub subnet for a central AMPLS).
        $monitorPeSubnetPrefix = ''
        if ($amplsId) {
            $amPeId = (ArmGet $amplsId '2021-07-01-preview').properties.privateEndpointConnections[0].properties.privateEndpoint.id
            if ($amPeId) { $monitorPeSubnetPrefix = az network vnet subnet show --ids (az network private-endpoint show --ids $amPeId --query subnet.id -o tsv) --query addressPrefix -o tsv 2>$null }
        }
        if ($kbSearch) { $extra += "$kbSearch.search.windows.net" }
        if ($agentsOn) { $extra += "$(E 'AGENT_STORAGE_ACCOUNT_NAME').blob.core.windows.net", "$(E 'AGENT_COSMOS_ACCOUNT_NAME').documents.azure.com", "$(E 'AGENT_SEARCH_SERVICE_NAME').search.windows.net" }
        $clientIsLinux = $vmInfo.os -eq 'Linux'
        $probe = Join-Path $PSScriptRoot $(if ($clientIsLinux) { 'invnet-probe.sh' } else { 'invnet-probe.ps1' })
        $script = (Get-Content $probe -Raw).
            Replace('__ACCOUNT__', $account).Replace('__PROJECT_ENDPOINT__', (E 'AZURE_AI_PROJECT_ENDPOINT')).
            Replace('__DEPLOYMENT__', (E 'AZURE_AI_MODEL_DEPLOYMENT_NAME')).Replace('__PE_PREFIX__', (E 'DEPLOYED_PE_SUBNET_PREFIX')).
            Replace('__EXTRA_HOSTS__', ($extra -join ',')).Replace('__KB_SEARCH__', [string]$kbSearch).Replace('__KB_INDEX__', [string]$kbIndex).Replace('__KB_NAME__', [string](E 'FOUNDRY_IQ_KNOWLEDGE_BASE')).Replace('__KB_REASONING__', [string](E 'DEPLOYED_FOUNDRY_IQ_REASONING')).Replace('__RAG_URL__', [string]$ragUrl).Replace('__DEMO_AGENT__', [string](E 'DEMO_AGENT_NAME')).Replace('__IQ_AGENT__', $(if (E 'FOUNDRY_IQ_KNOWLEDGE_BASE') { 'contoso-iq-agent' } else { '' })).Replace('__APPI_ID__', $(if ($appiName) { "/subscriptions/$sub/resourceGroups/$rg/providers/microsoft.insights/components/$appiName" } else { '' })).Replace('__MONITOR_PREFIX__', [string]$monitorPeSubnetPrefix).Replace('__WORKSPACE_ID__', $(if ($appiName) { [string](az monitor log-analytics workspace list -g $rg --query '[0].customerId' -o tsv 2>$null) } else { '' })).Replace('__RUN_AGENT__', $(if ($agentsOn -and -not $SkipAgentRun) { 'true' } else { 'false' }))
        $tmp = New-TemporaryFile
        if ($clientIsLinux) { [IO.File]::WriteAllText($tmp, ($script -replace "`r`n", "`n")) } else { Set-Content $tmp $script }
        $cmd = if ($clientIsLinux) { 'RunShellScript' } else { 'RunPowerShellScript' }
        $out = az vm run-command invoke --subscription $vmSub -g $vmRg -n $vm --command-id $cmd --scripts "@$tmp" -o json | ConvertFrom-Json
        Remove-Item $tmp
        if ($clientIsLinux) { $stdout = $out.value[0].message; $stderr = '' }
        else {
            $stdout = ($out.value | Where-Object code -like '*StdOut*').message
            $stderr = ($out.value | Where-Object code -like '*StdErr*').message
        }
        $line = ($stdout -split "`n" | Where-Object { $_ -like 'RESULT_JSON:*' -or $_ -like 'RESULT_GZ:*' } | Select-Object -Last 1)
        if (-not $line) { Add-Result invnet 'Run Command probe' 'FAIL' "no result (output truncated or probe failed). stdout tail: $(if ($stdout) { $stdout.Substring([Math]::Max(0, $stdout.Length - 200)) }) stderr: $stderr" }
        else {
            $payload = if ($line -like 'RESULT_GZ:*') {
                $gzIn = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String($line.Substring(10).Trim())), [IO.Compression.CompressionMode]::Decompress)
                [IO.StreamReader]::new($gzIn).ReadToEnd()
            } else { $line.Substring(12) }
            foreach ($r in ($payload | ConvertFrom-Json)) { Add-Result invnet "$($r.c): $($r.n)" $r.r $r.d }
        }
    }
    if ($ragVm) {
        $rp = az vm get-instance-view -g $rg -n $ragVm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
        if ($rp -ne 'PowerState/running') { Write-Host "  starting $ragVm ($rp)..."; az vm start -g $rg -n $ragVm -o none }
        # Negative: the RAG host must have NO internet egress (it needs none: stdlib app, IMDS tokens, private endpoints).
        $probe = "for u in https://www.microsoft.com https://pypi.org; do echo `"EGRESS `$u `$(curl -s -m 8 -o /dev/null -w '%{http_code}' `$u)`"; done"
        $tmp = New-TemporaryFile; [IO.File]::WriteAllText($tmp, $probe)
        $msg = (az vm run-command invoke -g $rg -n $ragVm --command-id RunShellScript --scripts "@$tmp" -o json | ConvertFrom-Json).value[0].message
        Remove-Item $tmp
        $reached = @($msg -split "`n" | Where-Object { $_ -match '^EGRESS \S+ (\d{3})$' -and $Matches[1] -ne '000' })
        $ran = $msg -match 'EGRESS '
        Add-Result invnet 'rag: RAG VM has no internet egress (negative)' $(if (-not $ran) { 'INCONCLUSIVE' } elseif ($reached) { 'FAIL' } else { 'PASS' }) $(if ($reached) { $reached -join '; ' } else { 'www.microsoft.com, pypi.org unreachable' })
    }
}

# ============================================================================= hosted agent demo (module 7)
if ('hosted' -in $Sections -and (E 'DEPLOYED_HOSTED_AGENT_DEMO') -eq 'true') {
    $haAgent = 'contoso-policy-hosted'
    Write-Host "`n[hosted] hosted agent '$haAgent'"
    # (c) public negative: valid token from this machine, outside the network -> network rejection
    Test-PublicRejection "Hosted agent Responses endpoint ($haAgent)" "$(E 'AZURE_AI_PROJECT_ENDPOINT')/agents/$haAgent/endpoint/protocols/openai/responses?api-version=v1" 'https://ai.azure.com' 'POST'

    $vmRg = $rg; $vm = E 'JUMPBOX_VM_NAME'; $vmSub = $sub
    if (-not $ClientVmId -and -not $vm -and (E 'PRIVATE_CLIENT_VM_ID')) { $ClientVmId = E 'PRIVATE_CLIENT_VM_ID' }
    if ($ClientVmId) { $p = $ClientVmId.Split('/'); $vmSub = $p[2]; $vmRg = $p[4]; $vm = $p[8] }
    $agentPid = ''
    if (-not $vm) { Add-Result hosted 'Hosted agent probe' 'SKIP' 'No private client: pass -ClientVmId <Windows VM in a connected network>.' }
    elseif ((az vm show --subscription $vmSub -g $vmRg -n $vm --query storageProfile.osDisk.osType -o tsv) -ne 'Windows') { Add-Result hosted 'Hosted agent probe' 'SKIP' "Private client $vm is not Windows (the azd runner and probe use PowerShell)." }
    else {
        $power = az vm get-instance-view --subscription $vmSub -g $vmRg -n $vm --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
        if ($power -ne 'PowerState/running') { Write-Host "  starting $vm ($power)..."; az vm start --subscription $vmSub -g $vmRg -n $vm -o none }
        Write-Host "  (a/b/d executed on $vm via VM Run Command; cold start can take a few minutes)"
        $script = (Get-Content (Join-Path $PSScriptRoot 'hosted-agent-probe.ps1') -Raw).Replace('__PROJECT_ENDPOINT__', (E 'AZURE_AI_PROJECT_ENDPOINT')).Replace('__AGENT__', $haAgent)
        $tmp = New-TemporaryFile; Set-Content $tmp $script
        $out = az vm run-command invoke --subscription $vmSub -g $vmRg -n $vm --command-id RunPowerShellScript --scripts "@$tmp" -o json | ConvertFrom-Json
        Remove-Item $tmp
        $stdout = ($out.value | Where-Object code -like '*StdOut*').message
        if ($stdout -match 'AGENT_PRINCIPAL=([0-9a-f-]{36})') { $agentPid = $Matches[1] }
        $line = ($stdout -split "`n" | Where-Object { $_ -like 'RESULT_GZ:*' } | Select-Object -Last 1)
        if (-not $line) { Add-Result hosted 'Hosted agent probe' 'FAIL' "no result. stdout tail: $(if ($stdout) { $stdout.Substring([Math]::Max(0, $stdout.Length - 200)) }) stderr: $(($out.value | Where-Object code -like '*StdErr*').message)" }
        else {
            $gzIn = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String($line.Substring(10).Trim())), [IO.Compression.CompressionMode]::Decompress)
            foreach ($r in ([IO.StreamReader]::new($gzIn).ReadToEnd() | ConvertFrom-Json)) { Add-Result hosted $r.n $r.r $r.d }
        }
    }
    # (e) agent identity: Monitoring Metrics Publisher on App Insights (code-emitted traces, Entra-only ingestion)
    if (-not $appiName) { Add-Result identity 'Hosted agent identity: Monitoring Metrics Publisher on App Insights' 'SKIP' 'no Application Insights (ENABLE_ADVANCED_MONITORING=false)' }
    elseif (-not $agentPid) { Add-Result identity 'Hosted agent identity: Monitoring Metrics Publisher on App Insights' 'FAIL' 'agent identity principal ID not found (runner azd env / agent object)' }
    else {
        $appiId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/components/$appiName"
        $haRoles = (az rest --method get --url "https://management.azure.com$appiId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$agentPid'" -o json 2>$null | ConvertFrom-Json).value.properties
        Check identity 'Hosted agent identity: Monitoring Metrics Publisher on App Insights' ([bool]($haRoles | Where-Object { $_.roleDefinitionId -like '*3913510d-42f4-4e42-8a64-420c390055eb' })) "principal=$agentPid, $(@($haRoles).Count) assignment(s)"
    }
}

# ============================================================================= report
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $repo '.test-output'; New-Item -ItemType Directory $outDir -Force | Out-Null
$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir "validation-$stamp.json")
$md = @("# Validation report $stamp", '', "Resource group: ``$rg`` - account: ``$account`` - mode: $(E 'DEPLOYED_NETWORK_MODE') / $(E 'DEPLOYED_OUTBOUND_NETWORK_MODE')", '', '| Section | Test | Result | Detail |', '|---|---|---|---|')
$md += $results | ForEach-Object { "| $($_.Section) | $($_.Test) | $($_.Result) | $(($_.Detail -replace '\|', '/')) |" }
$md | Set-Content (Join-Path $outDir "validation-$stamp.md")

$summary = $results | Group-Object Result | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host "`nSummary: $($summary -join '  ')   report: .test-output/validation-$stamp.md"
if ($results.Result -contains 'FAIL') { exit 1 } else { exit 0 }
