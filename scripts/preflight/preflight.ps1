#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Preflight checks executed by `azd provision` (preprovision hook) before any resource is created.
  Fails fast with actionable messages. Never relaxes security settings.
.NOTES
  Reads configuration from azd environment variables (set by azd for hooks) with the same defaults
  as infra/main.parameters.json. Can also be run manually:  pwsh ./scripts/preflight/preflight.ps1
#>
[CmdletBinding()]
param([switch]$SkipAzure)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NetworkValidation.psm1') -Force

# When run manually, load values from the active azd environment.
if (-not $env:AZURE_ENV_NAME -and (Get-Command azd -ErrorAction SilentlyContinue)) {
    try {
        azd env get-values 2>$null | ForEach-Object {
            if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { Set-Item "env:$($Matches[1])" ($Matches[2] -replace '\\"', '"') }
        }
    } catch { }
}

function Get-Setting([string]$Name, [string]$Default = '') {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v.Trim() }
}
function Get-Bool([string]$Name, [bool]$Default) {
    $v = Get-Setting $Name ($Default.ToString())
    return $v -match '^(true|1|yes)$'
}

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
function Fail([string]$m) { $failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn([string]$m) { $warnings.Add($m); Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Pass([string]$m) { Write-Host "  [ OK ] $m" -ForegroundColor Green }

$cfg = [ordered]@{
    Location            = Get-Setting 'AZURE_LOCATION'
    EnvName             = Get-Setting 'AZURE_ENV_NAME'
    NetworkMode         = Get-Setting 'NETWORK_MODE' 'standalone'
    OutboundMode        = Get-Setting 'OUTBOUND_NETWORK_MODE' 'byoVnet'
    Bypass              = Get-Setting 'FOUNDRY_NETWORK_ACLS_BYPASS' 'AzureServices'
    VnetPrefix          = Get-Setting 'VNET_ADDRESS_PREFIX' '10.80.0.0/16'
    PeSubnet            = Get-Setting 'PE_SUBNET_PREFIX' '10.80.1.0/24'
    MgmtSubnet          = Get-Setting 'MANAGEMENT_SUBNET_PREFIX' '10.80.2.0/24'
    BastionSubnet       = Get-Setting 'BASTION_SUBNET_PREFIX' '10.80.3.0/26'
    AppSubnet           = Get-Setting 'APP_SUBNET_PREFIX'
    IntegrationSubnet   = Get-Setting 'INTEGRATION_SUBNET_PREFIX'
    AgentSubnet         = Get-Setting 'AGENT_SUBNET_PREFIX' '10.80.6.0/24'
    HubVnetId           = Get-Setting 'EXISTING_HUB_VNET_ID'
    HubPeering          = Get-Bool 'ENABLE_HUB_PEERING' $false
    HubSidePeering      = Get-Bool 'ENABLE_HUB_SIDE_PEERING' $false
    HubFirewallIp       = Get-Setting 'HUB_FIREWALL_PRIVATE_IP'
    DnsZoneMode         = Get-Setting 'PRIVATE_DNS_ZONE_MODE' 'create'
    DnsZoneIds          = Get-Setting 'EXISTING_PRIVATE_DNS_ZONE_IDS'
    EnableBastion       = Get-Bool 'ENABLE_BASTION' $true
    EnableJumpbox       = Get-Bool 'ENABLE_JUMPBOX' $true
    ModelFormat         = Get-Setting 'MODEL_FORMAT' 'OpenAI'
    ModelName           = Get-Setting 'MODEL_NAME' 'gpt-5.4-mini'
    ModelVersion        = Get-Setting 'MODEL_VERSION' '2026-03-17'
    ModelType           = Get-Setting 'MODEL_DEPLOYMENT_TYPE' 'DataZoneStandard'
    ModelCapacity       = [int](Get-Setting 'MODEL_CAPACITY' '10')
}

Write-Host "`n=== Preflight: azure-foundry-private-networking ===" -ForegroundColor Cyan
$cfg.GetEnumerator() | Where-Object { $_.Key -ne 'DnsZoneIds' } | ForEach-Object { Write-Host ("  {0,-18} {1}" -f $_.Key, $_.Value) }

# -----------------------------------------------------------------------------
Write-Host "`n[1] Configuration and feature gates"
if ([string]::IsNullOrWhiteSpace($cfg.Location)) { Fail 'AZURE_LOCATION is not set (azd env set AZURE_LOCATION <region>).' }
if ($cfg.NetworkMode -notin 'standalone', 'hub-spoke', 'spoke-ready', 'public') { Fail "NETWORK_MODE '$($cfg.NetworkMode)' invalid. Use standalone | hub-spoke | spoke-ready | public." }
if ($cfg.NetworkMode -eq 'public') {
    # Quick-demo mode: NOT private. Explicit acknowledgement, no private-only options, never for customer data.
    Write-Host '  [!!!!] NETWORK_MODE=public: Foundry data planes accept traffic from PUBLIC networks (Entra-only auth stays). For quick demos with synthetic data only; NOT for customer data. See docs/public-quick-demo.md.' -ForegroundColor Red
    if ((Get-Setting 'PUBLIC_NETWORK_ACCESS_ACK') -ne 'true') { Fail 'NETWORK_MODE=public requires PUBLIC_NETWORK_ACCESS_ACK=true (confirms that the Foundry account is reachable from public networks).' }
    $ips = @((Get-Setting 'PUBLIC_ALLOWED_IPS') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $badIps = @($ips | Where-Object { $_ -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$' })
    if ($badIps) { Fail "PUBLIC_ALLOWED_IPS contains invalid IPv4/CIDR values: $($badIps -join ', ')" }
    elseif ($ips.Count -eq 0) { Warn 'PUBLIC_ALLOWED_IPS is empty: the Foundry account is open to the whole internet (Entra-only). Set your client IP(s) to restrict it.' }
    else { Pass "Foundry firewall allow-list: $($ips -join ', ') (everything else denied)." }
    if ($cfg.OutboundMode -ne 'none') { Fail "NETWORK_MODE=public uses Basic agent setup without network isolation: set OUTBOUND_NETWORK_MODE=none (got '$($cfg.OutboundMode)')." }
    foreach ($m in 'ENABLE_AI_SEARCH', 'ENABLE_RAG_DEMO', 'ENABLE_AGENT_DEMO', 'ENABLE_ADVANCED_MONITORING', 'ENABLE_FOUNDRY_IQ', 'ENABLE_HOSTED_AGENT_DEMO', 'ENABLE_BASTION', 'ENABLE_JUMPBOX') {
        if (Get-Bool $m $false) { Fail "$m=true is not supported with NETWORK_MODE=public (the module relies on private endpoints / in-network clients). Set it to false." }
    }
}

switch ($cfg.OutboundMode) {
    { $cfg.NetworkMode -eq 'public' -and $_ -eq 'none' } { Pass 'Agents: Basic setup (agent state in Microsoft-managed storage), no network isolation (public mode).'; break }
    'byoVnet' { Pass 'Outbound: BYO VNet injection with Standard agent setup (default).' }
    'none' { Warn 'OUTBOUND_NETWORK_MODE=none: agents cannot be added later without redeploying the Foundry account.' }
    'managedVnet' {
        # Learn (managed-virtual-network): regions supporting managed VNet with the new Agent service.
        $mvnetRegions = 'eastus', 'eastus2', 'japaneast', 'francecentral', 'uaenorth', 'brazilsouth', 'spaincentral', 'germanywestcentral', 'italynorth', 'southcentralus', 'australiaeast', 'swedencentral', 'canadaeast', 'southafricanorth', 'westus', 'westus3', 'southindia', 'uksouth'
        if ((Get-Setting 'MANAGED_VNET_PREVIEW_ACK') -ne 'true') { Fail 'OUTBOUND_NETWORK_MODE=managedVnet is a PREVIEW (accounts/managedNetworks has only preview API versions) and IRREVERSIBLE for the account (no disable, no switch to BYO VNet). Set MANAGED_VNET_PREVIEW_ACK=true to confirm. See docs/modules/managed-vnet.md.' }
        elseif ($cfg.Location -and $cfg.Location -notin $mvnetRegions) { Fail "OUTBOUND_NETWORK_MODE=managedVnet is not supported in '$($cfg.Location)'. Supported: $($mvnetRegions -join ', ')." }
        else { Warn 'Outbound: Microsoft-managed VNet (PREVIEW), AllowOnlyApprovedOutbound, no FQDN rules (no managed firewall). Agent egress is not visible in your firewall/logs; irreversible for this account.' }
    }
    default { Fail "OUTBOUND_NETWORK_MODE '$($cfg.OutboundMode)' invalid. Use byoVnet | managedVnet | none." }
}
if ($cfg.Bypass -notin 'AzureServices', 'None') { Fail "FOUNDRY_NETWORK_ACLS_BYPASS '$($cfg.Bypass)' invalid. Use AzureServices | None." }
if ($cfg.Bypass -eq 'None') { Warn 'FOUNDRY_NETWORK_ACLS_BYPASS=None: no trusted-service exception on Foundry (all validated paths work; untested features such as evaluations or Search skills calling Foundry may need it).' }
$stBypass = Get-Setting 'AGENT_STORAGE_NETWORK_BYPASS' 'AzureServices'
if ($stBypass -notin 'AzureServices', 'None') { Fail "AGENT_STORAGE_NETWORK_BYPASS '$stBypass' invalid. Use AzureServices | None." }
elseif ($stBypass -eq 'None') { Write-Host '  [INFO] AGENT_STORAGE_NETWORK_BYPASS=None: no trusted-service exception on the agent storage account (validated for agent runs; file upload / file search not exercised).' }

if (Get-Bool 'ENABLE_AI_SEARCH' $false) {
    $sku = Get-Setting 'AI_SEARCH_SKU' 'basic'
    if ($sku -eq 'free') { Fail 'AI_SEARCH_SKU=free does not support private endpoints or managed identity. Use basic or higher.' }
    else { Pass "Optional module AI Search enabled (SKU $sku, private endpoint, Entra-only)." }
}
if (Get-Bool 'ENABLE_ADVANCED_MONITORING' $false) {
    $amplsId = Get-Setting 'EXISTING_AMPLS_ID'
    $pubIngest = Get-Setting 'MONITOR_PUBLIC_INGESTION' 'Disabled'
    if ($pubIngest -notin 'Enabled', 'Disabled') { Fail "MONITOR_PUBLIC_INGESTION '$pubIngest' invalid. Use Disabled | Enabled." }
    if ($amplsId -and $amplsId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Insights/privateLinkScopes/[^/]+$') { Fail "EXISTING_AMPLS_ID is not an Azure Monitor Private Link Scope resource ID: $amplsId" }
    switch ($cfg.NetworkMode) {
        'standalone' { Pass 'Advanced monitoring: Application Insights (Entra-only) + own AMPLS (standalone owns its DNS), query private-only.' }
        'hub-spoke' {
            if ($amplsId) { Pass 'Advanced monitoring: joining the central hub AMPLS (no new private endpoint / DNS records in the spoke).' }
            else { Warn 'Advanced monitoring without EXISTING_AMPLS_ID: App Insights / Log Analytics stay reachable on public endpoints (Entra-only). Creating a spoke AMPLS is deliberately NOT done: it would override shared Azure Monitor DNS for every workload using the hub DNS.' }
        }
        default { Warn 'Advanced monitoring in spoke-ready mode: no AMPLS; the network team must add the workspace and App Insights to the central AMPLS.' }
    }
    if ($cfg.OutboundMode -eq 'managedVnet' -and $cfg.NetworkMode -ne 'standalone' -and -not $amplsId) { Warn 'managedVnet without an AMPLS: the managed network has no route to App Insights ingestion (no FQDN rules), so server-side agent traces will not arrive. Set EXISTING_AMPLS_ID.' }
    if ($pubIngest -eq 'Enabled') { Warn 'MONITOR_PUBLIC_INGESTION=Enabled: telemetry ingestion accepted from public networks (Entra-only, write-only). Query stays private. Explicit decision - see docs/modules/monitoring.md.' }
}
if (Get-Bool 'ENABLE_FOUNDRY_IQ' $false) {
    if (-not (Get-Bool 'ENABLE_AI_SEARCH' $false)) { Fail 'ENABLE_FOUNDRY_IQ=true requires ENABLE_AI_SEARCH=true (the knowledge base is built over the private knowledge index).' }
    elseif ($cfg.OutboundMode -notin 'byoVnet', 'managedVnet') { Fail 'ENABLE_FOUNDRY_IQ=true requires OUTBOUND_NETWORK_MODE=byoVnet or managedVnet: agents reach a private Foundry IQ service only from an isolated agent network (documented limitation).' }
    else { Pass 'Optional module Foundry IQ enabled (knowledge base over the private index; MCP endpoint api-version 2026-10-01 GA).' }
}
$iqReasoning = Get-Setting 'FOUNDRY_IQ_REASONING' 'minimal'
if ($iqReasoning -notin 'minimal', 'low', 'medium') { Fail "FOUNDRY_IQ_REASONING '$iqReasoning' invalid. Use minimal | low | medium." }
elseif ($iqReasoning -ne 'minimal') {
    if (-not (Get-Bool 'ENABLE_FOUNDRY_IQ' $false)) { Fail "FOUNDRY_IQ_REASONING=$iqReasoning requires ENABLE_FOUNDRY_IQ=true." }
    else {
        Pass "Foundry IQ query planning ($iqReasoning): shared private link knowledge search -> Foundry (openai_account), Search MI gets Cognitive Services OpenAI User; no trusted-service bypass needed (validated live on Basic, 2026-11-19)."
        if ((Get-Setting 'FOUNDRY_IQ_AUTO_APPROVE' 'true') -eq 'false') { Warn 'FOUNDRY_IQ_AUTO_APPROVE=false: the Foundry account owner must approve the pending shared private link; seeding fails until then.' }
        else { Write-Host '  [INFO] The pending shared private link is approved post-provision by scripts/ai-search/Approve-SharedPrivateLink.ps1 (only this environment''s exact request).' }
    }
}
if (Get-Bool 'ENABLE_AGENT_DEMO' $false) {
    if (-not (Get-Bool 'ENABLE_AI_SEARCH' $false)) { Fail 'ENABLE_AGENT_DEMO=true requires ENABLE_AI_SEARCH=true (the agent is grounded on the private knowledge index).' }
    elseif ($cfg.OutboundMode -notin 'byoVnet', 'managedVnet') { Fail 'ENABLE_AGENT_DEMO=true requires OUTBOUND_NETWORK_MODE=byoVnet or managedVnet: the Azure AI Search tool cannot reach a private search service without an isolated agent network (documented limitation).' }
    else { Pass 'Optional module agent demo enabled (prompt agent + Azure AI Search tool, created post-provision from inside the network).' }
    if ((-not $cfg.EnableJumpbox -or $cfg.NetworkMode -ne 'standalone') -and -not (Get-Setting 'PRIVATE_CLIENT_VM_ID')) { Warn 'No jumpbox and no PRIVATE_CLIENT_VM_ID: run scripts/agents/Deploy-DemoAgent.ps1 -ClientVmId <private client> after provisioning.' }
}
# Public mode rejects the module above (private-only modules loop).
if ((Get-Bool 'ENABLE_HOSTED_AGENT_DEMO' $false) -and $cfg.NetworkMode -ne 'public') {
    # Hosted agent demo (module 7): azd runs on an in-network private client (VM Run Command), the toolbox uses the
    # Foundry IQ connection. Fail closed: no fallback that would open the data plane to deploy from here.
    $privateClientId = Get-Setting 'PRIVATE_CLIENT_VM_ID'
    $haJumpbox = $cfg.EnableJumpbox -and $cfg.NetworkMode -in 'standalone', 'hub-spoke'
    $haErrors = $failures.Count
    if ($cfg.NetworkMode -eq 'spoke-ready') { Fail 'ENABLE_HOSTED_AGENT_DEMO=true is not supported with NETWORK_MODE=spoke-ready (no private client before handover). Deploy it after handover: scripts/agents/Deploy-HostedAgentAzd.ps1 -ClientVmId <private client>.' }
    if (-not (Get-Bool 'ENABLE_FOUNDRY_IQ' $false)) { Fail 'ENABLE_HOSTED_AGENT_DEMO=true requires ENABLE_FOUNDRY_IQ=true (the toolbox uses the knowledge base connection knowledge-base-mcp).' }
    if ($cfg.OutboundMode -notin 'byoVnet', 'managedVnet') { Fail 'ENABLE_HOSTED_AGENT_DEMO=true requires OUTBOUND_NETWORK_MODE=byoVnet or managedVnet: hosted agents need an isolated agent network to reach the private project endpoint.' }
    if ($privateClientId -and $privateClientId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/virtualMachines/[^/]+$') { Fail "PRIVATE_CLIENT_VM_ID is not a virtual machine resource ID: $privateClientId" }
    elseif (-not $haJumpbox -and -not $privateClientId) { Fail 'ENABLE_HOSTED_AGENT_DEMO=true requires an in-network private client to run azd (the Foundry data plane is private): ENABLE_JUMPBOX=true, or PRIVATE_CLIENT_VM_ID=<resource ID of a Windows VM in a connected network>.' }
    if ($failures.Count -eq $haErrors) {
        Pass "Optional module hosted agent demo enabled (toolbox + hosted agent, azd on the $(if ($haJumpbox) { 'jumpbox' } else { 'private client VM' }) via VM Run Command; managed VNet adds managed PE rule pe-foundry-account)."
        if (-not $haJumpbox -and -not $SkipAzure) {
            $os = az vm show --ids $privateClientId --query storageProfile.osDisk.osType -o tsv 2>$null
            if (-not $os) { Fail "Cannot read PRIVATE_CLIENT_VM_ID $privateClientId (check the ID and Reader permission)." }
            elseif ($os -ne 'Windows') { Fail "PRIVATE_CLIENT_VM_ID must be a Windows VM (the azd runner uses RunPowerShellScript); found $os." }
        }
        if ($cfg.NetworkMode -eq 'hub-spoke') { Write-Host '  [INFO] The azd runner downloads azd and its extensions from GitHub on first use: allow this for the private client in the hub firewall (validated with the hub workstation web rule).' }
    }
    if (-not (Get-Bool 'ENABLE_ADVANCED_MONITORING' $false)) { Warn 'ENABLE_HOSTED_AGENT_DEMO without ENABLE_ADVANCED_MONITORING: no Application Insights, so traces emitted by the agent code are not collected and the Monitoring Metrics Publisher grant is skipped.' }
}
$ragEnabled = Get-Bool 'ENABLE_RAG_DEMO' $false
if ($ragEnabled) {
    if (-not (Get-Bool 'ENABLE_AI_SEARCH' $false)) { Fail 'ENABLE_RAG_DEMO=true requires ENABLE_AI_SEARCH=true (the RAG app retrieves from the private knowledge index).' }
    $ragPort = Get-Setting 'RAG_APP_PORT' '8443'
    if ($ragPort -notmatch '^\d+$' -or [int]$ragPort -lt 1024 -or [int]$ragPort -gt 65535) { Fail "RAG_APP_PORT '$ragPort' must be 1024-65535 (the app runs unprivileged)." }
    if (-not $cfg.AppSubnet) { $cfg.AppSubnet = Get-CidrSubnet $cfg.VnetPrefix 24 4; Write-Host "  APP_SUBNET_PREFIX defaulted to $($cfg.AppSubnet) for the RAG demo." }
    Pass "Optional module RAG demo enabled (private VM in snet-app $($cfg.AppSubnet), port $ragPort, no public IP, no internet egress)."
    if (-not $cfg.EnableJumpbox -or $cfg.NetworkMode -ne 'standalone') { Write-Host '  [INFO] No jumpbox in this deployment: open the RAG app from a client in a connected network (e.g. hub workstation).' }
}

if ($cfg.NetworkMode -eq 'hub-spoke') {
    if ($cfg.EnableBastion) { Warn 'ENABLE_BASTION is ignored in hub-spoke mode (no new public IPs). Use the hub Bastion.' }
    if (($cfg.HubPeering -or $cfg.HubSidePeering) -and -not $cfg.HubVnetId) { Fail 'Hub peering requested but EXISTING_HUB_VNET_ID is empty.' }
    if (-not $cfg.HubFirewallIp) { Warn 'HUB_FIREWALL_PRIVATE_IP empty: workload subnets get NO egress route (agents need Entra ID egress; see docs/hub-integration.md).' }
    if ($cfg.HubFirewallIp -and $cfg.HubFirewallIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Fail "HUB_FIREWALL_PRIVATE_IP '$($cfg.HubFirewallIp)' is not an IPv4 address." }
}
if ($cfg.NetworkMode -eq 'spoke-ready') {
    Warn 'spoke-ready: no Bastion/jumpbox/peering/egress. Foundry is reachable only after the network team connects the spoke; agents need egress to Entra ID.'
    if ($cfg.DnsZoneMode -eq 'create') { Warn 'spoke-ready with PRIVATE_DNS_ZONE_MODE=create: peering alone will NOT make Foundry resolvable from the hub (central zones have no records -> NXDOMAIN). If central zones exist, set PRIVATE_DNS_ZONE_MODE=existing now; otherwise run scripts/handover/Switch-ToCentralDns.ps1 at handover (docs/spoke-ready-handover.md).' }
}

if ($cfg.DnsZoneMode -eq 'existing') {
    $required = @('privatelink.cognitiveservices.azure.com', 'privatelink.openai.azure.com', 'privatelink.services.ai.azure.com')
    if ($cfg.OutboundMode -in 'byoVnet', 'managedVnet') { $required += 'privatelink.blob.core.windows.net', 'privatelink.documents.azure.com' }
    if ($cfg.OutboundMode -in 'byoVnet', 'managedVnet' -or (Get-Bool 'ENABLE_AI_SEARCH' $false)) { $required += 'privatelink.search.windows.net' }
    if ((Get-Bool 'ENABLE_ADVANCED_MONITORING' $false) -and $cfg.NetworkMode -eq 'standalone') { $required += 'privatelink.monitor.azure.com', 'privatelink.oms.opinsights.azure.com', 'privatelink.ods.opinsights.azure.com', 'privatelink.agentsvc.azure-automation.net', 'privatelink.blob.core.windows.net' }
    $zoneMap = @{}
    foreach ($id in ($cfg.DnsZoneIds -split ',') | ForEach-Object Trim | Where-Object { $_ }) {
        if ($id -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/privateDnsZones/[^/]+$') { Fail "Not a private DNS zone resource ID: $id" }
        $zoneMap[($id -split '/')[-1]] = $id
    }
    foreach ($z in $required) {
        if (-not $zoneMap.ContainsKey($z) -or [string]::IsNullOrWhiteSpace($zoneMap[$z])) { Fail "PRIVATE_DNS_ZONE_MODE=existing but no zone ID for '$z'." }
    }
} elseif ($cfg.DnsZoneMode -ne 'create') { Fail "PRIVATE_DNS_ZONE_MODE '$($cfg.DnsZoneMode)' invalid. Use create | existing." }

# -----------------------------------------------------------------------------
Write-Host "`n[2] Address plan"
if ($cfg.NetworkMode -eq 'public') { Pass 'Public mode: no VNet deployed, address plan not applicable.' } else {
$isStandalone = $cfg.NetworkMode -eq 'standalone'
$subnets = @{
    privateEndpoints = $cfg.PeSubnet
    agent            = $(if ($cfg.OutboundMode -eq 'byoVnet') { $cfg.AgentSubnet } else { '' })
    management       = $(if ($cfg.EnableJumpbox -and $cfg.NetworkMode -ne 'spoke-ready') { $cfg.MgmtSubnet } else { '' })
    bastion          = $(if ($isStandalone -and $cfg.EnableBastion) { $cfg.BastionSubnet } else { '' })
    app              = $cfg.AppSubnet
    integration      = $cfg.IntegrationSubnet
}
$otherNetworks = @()
if ($cfg.HubVnetId -and -not $SkipAzure) {
    try {
        $otherNetworks = @(az network vnet show --ids $cfg.HubVnetId --query 'addressSpace.addressPrefixes' -o json 2>$null | ConvertFrom-Json)
        Pass "Hub VNet found ($($otherNetworks -join ', '))."
    } catch { Fail "Cannot read hub VNet $($cfg.HubVnetId) (check ID and Reader permission)." }
}
$planErrors = Test-AddressPlan -VnetPrefix $cfg.VnetPrefix -Subnets $subnets -OtherNetworks $otherNetworks
if ($planErrors.Count -eq 0) { Pass "Address plan valid ($($cfg.VnetPrefix))." } else { $planErrors | ForEach-Object { Fail $_ } }
}

if ($SkipAzure) { Write-Host "`n(-SkipAzure: Azure checks skipped)" }
else {
    # -------------------------------------------------------------------------
    Write-Host "`n[3] Resource providers"
    $providers = 'Microsoft.CognitiveServices', 'Microsoft.Network', 'Microsoft.Compute', 'Microsoft.OperationalInsights', 'Microsoft.Insights'
    if ($cfg.OutboundMode -eq 'byoVnet') { $providers += 'Microsoft.App', 'Microsoft.ContainerService', 'Microsoft.Storage', 'Microsoft.DocumentDB', 'Microsoft.Search' }
    if ($cfg.OutboundMode -eq 'managedVnet') { $providers += 'Microsoft.ContainerService', 'Microsoft.KeyVault', 'Microsoft.Storage', 'Microsoft.DocumentDB', 'Microsoft.Search' }
    if ($cfg.EnableJumpbox) { $providers += 'Microsoft.DevTestLab' }
    foreach ($p in $providers) {
        $state = az provider show -n $p --query registrationState -o tsv 2>$null
        if ($state -eq 'Registered') { Pass "$p registered." }
        else { Fail "$p is '$state'. Run: az provider register --namespace $p --wait" }
    }

    # -------------------------------------------------------------------------
    Write-Host "`n[4] Model availability and quota ($($cfg.Location))"
    $models = az cognitiveservices model list -l $cfg.Location -o json 2>$null | ConvertFrom-Json
    $match = $models | Where-Object { $_.model.name -eq $cfg.ModelName -and $_.model.version -eq $cfg.ModelVersion -and $_.model.format -eq $cfg.ModelFormat } | Select-Object -First 1
    if (-not $match) {
        $versions = ($models | Where-Object { $_.model.name -eq $cfg.ModelName } | ForEach-Object { $_.model.version } | Sort-Object -Unique) -join ', '
        Fail "Model $($cfg.ModelName) $($cfg.ModelVersion) not available in $($cfg.Location). Available versions: $(if($versions){$versions}else{'none'})."
    } else {
        $skus = @($match.model.skus | ForEach-Object { $_.name })
        if ($cfg.ModelType -notin $skus) { Fail "Deployment type $($cfg.ModelType) not supported for $($cfg.ModelName) in $($cfg.Location). Supported: $($skus -join ', ')." }
        else { Pass "Model $($cfg.ModelName) $($cfg.ModelVersion) [$($cfg.ModelType)] available (lifecycle: $($match.model.lifecycleStatus))." }
        if ($match.model.deprecation.inference) { Warn "Model inference retirement date: $($match.model.deprecation.inference)." }
    }
    $usageName = "$($cfg.ModelFormat).$($cfg.ModelType).$($cfg.ModelName)"
    $usage = az cognitiveservices usage list -l $cfg.Location -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name.value -eq $usageName }
    if ($usage) {
        $free = [int]$usage.limit - [int]$usage.currentValue
        if ($free -lt $cfg.ModelCapacity) { Fail "Insufficient quota for $usageName : requested $($cfg.ModelCapacity), available $free (limit $($usage.limit)). Lower MODEL_CAPACITY, choose another region/type, or request quota." }
        else { Pass "Quota $usageName : requested $($cfg.ModelCapacity), available $free." }
    } else { Warn "Could not find quota entry '$usageName'; deployment may fail if quota is missing." }

    # -------------------------------------------------------------------------
    Write-Host "`n[5] Soft-deleted Foundry accounts"
    $rgName = "rg-$($cfg.EnvName)"
    $deleted = az cognitiveservices account list-deleted -o json 2>$null | ConvertFrom-Json |
        Where-Object { $_.id -match "/resourceGroups/$([regex]::Escape($rgName))/" -and $_.location -eq $cfg.Location }
    if ($deleted) {
        foreach ($d in $deleted) { Fail "Soft-deleted account '$($d.name)' blocks redeployment. Purge: az cognitiveservices account purge -n $($d.name) -g $rgName -l $($cfg.Location) (then wait ~20 min before reusing the agent subnet)." }
    } else { Pass 'No conflicting soft-deleted accounts.' }

    # -------------------------------------------------------------------------
    Write-Host "`n[6] Deployer permissions"
    $me = az ad signed-in-user show --query id -o tsv 2>$null
    if ($me) {
        $sub = az account show --query id -o tsv
        $roles = az role assignment list --assignee $me --all --query "[?scope=='/subscriptions/$sub' || starts_with(scope, '/subscriptions/$sub/resourceGroups/$rgName')].roleDefinitionName" -o json 2>$null | ConvertFrom-Json
        if ($roles -contains 'Owner' -or (($roles -contains 'Contributor') -and ($roles -contains 'User Access Administrator' -or $roles -contains 'Role Based Access Control Administrator'))) {
            Pass "Deployer has $((@($roles) | Sort-Object -Unique) -join ', ')."
        } else { Warn 'Could not confirm Owner or Contributor + (Role Based Access Control Administrator | User Access Administrator); role assignments may fail. Group-based assignments are not evaluated.' }
    } elseif ((az account show --query user.type -o tsv 2>$null) -eq 'user') {
        Warn 'Could not read the signed-in user from Microsoft Graph (transient error or Conditional Access); permission check skipped.'
    } else { Warn 'Signed-in principal is not a user (service principal / managed identity); permission check skipped.' }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "Preflight FAILED with $($failures.Count) error(s). Nothing was deployed." -ForegroundColor Red
    exit 1
}
Write-Host "Preflight passed ($($warnings.Count) warning(s))." -ForegroundColor Green
exit 0
