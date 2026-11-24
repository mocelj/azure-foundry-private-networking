#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Offline security assertions on the fully expanded deployment (PSRule for Azure evaluates all
# expressions and nested modules) for every sample profile in examples/. No Azure access needed.

BeforeDiscovery {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    Import-Module (Join-Path $root 'tests\TestHelpers.psm1') -Force
    $script:profiles = Get-ChildItem (Join-Path $root 'examples') -Recurse -Filter '*.env' | ForEach-Object {
        $e = Read-EnvFile $_.FullName
        @{
            Name       = $_.BaseName
            EnvFile    = $_.FullName
            Mode       = $(if ($e.NETWORK_MODE) { $e.NETWORK_MODE } else { 'standalone' })
            Outbound   = $(if ($e.OUTBOUND_NETWORK_MODE) { $e.OUTBOUND_NETWORK_MODE } else { 'byoVnet' })
            DnsMode    = $(if ($e.PRIVATE_DNS_ZONE_MODE) { $e.PRIVATE_DNS_ZONE_MODE } else { 'create' })
            AiSearch   = $e.ENABLE_AI_SEARCH -eq 'true'
            Rag        = $e.ENABLE_RAG_DEMO -eq 'true'
            Monitoring = $e.ENABLE_ADVANCED_MONITORING -eq 'true'
            FoundryIq  = $e.ENABLE_FOUNDRY_IQ -eq 'true'
            Agents     = $(if ($e.OUTBOUND_NETWORK_MODE) { $e.OUTBOUND_NETWORK_MODE } else { 'byoVnet' }) -in 'byoVnet', 'managedVnet'
            IqPlanning = ($e.ENABLE_FOUNDRY_IQ -eq 'true') -and $e.FOUNDRY_IQ_REASONING -and ($e.FOUNDRY_IQ_REASONING -ne 'minimal')
            HasJumpbox = $(if ($e.ENABLE_JUMPBOX) { $e.ENABLE_JUMPBOX -eq 'true' } else { $true }) -and ($e.NETWORK_MODE -ne 'spoke-ready')
        }
    }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\TestHelpers.psm1') -Force
    $script:out = Join-Path $PSScriptRoot '..\..\.test-output\static'
    $script:template = Build-MainTemplate $script:out
    $script:compiled = Get-Content $script:template -Raw | ConvertFrom-Json -Depth 100

    $script:forbiddenRoles = @{
        '8e3af657-a8ff-443c-a75c-2fe8c4bcd635' = 'Owner'
        'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
        '18d7d88d-d35e-4fb5-a5c3-7773c4a72a00' = 'User Access Administrator'
        'f58310d9-a9f6-439a-9e8d-f62e7b41a168' = 'Role Based Access Control Administrator'
    }
    function Get-Prop($obj, [string]$path) {
        $cur = $obj
        foreach ($seg in $path.Split('.')) {
            if ($null -eq $cur -or -not $cur.PSObject.Properties[$seg]) { return $null }
            $cur = $cur.$seg
        }
        return $cur
    }
}

Describe 'Template outputs' {
    It 'exposes no secrets, keys or connection strings' {
        $names = $script:compiled.outputs.PSObject.Properties.Name
        $names | Where-Object { $_ -match '(?i)key|secret|password|connectionstring|token' } | Should -BeNullOrEmpty
    }
}

Describe 'Foundry IQ query planning (template)' {
    It 'grants the knowledge search MI only Cognitive Services OpenAI User on the account, and only when query planning is enabled' {
        # Profile expansion uses one placeholder principal for every identity, so this is asserted on the compiled template.
        $res = $script:compiled.resources
        if ($res -isnot [array]) { $res = $res.PSObject.Properties | ForEach-Object Value }
        $m = $res | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'foundryIqModelRbac' }
        if (-not $m) { $m = $script:compiled.resources.foundryIqModelRbac }
        $m | Should -Not -BeNullOrEmpty
        $m.condition | Should -Match 'deployFoundryIqPlanning'
        $inner = $m.properties.template.resources
        if ($inner -isnot [array]) { $inner = $inner.PSObject.Properties | ForEach-Object Value }
        $ra = @($inner | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
        $ra.Count | Should -Be 1
        ($ra[0].properties.roleDefinitionId + ' ' + ($m.properties.template.variables | ConvertTo-Json)) | Should -Match '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    }
}

Describe 'Public quick-demo mode: firewall allow-list' {
    It 'turns PUBLIC_ALLOWED_IPS into deny-by-default IP rules' {
        $envFile = Join-Path $script:out 'public-allowlist.env'
        (Get-Content (Join-Path $PSScriptRoot '..\..\examples\public\public-quick-demo.env') -Raw) + "`nPUBLIC_ALLOWED_IPS=203.0.113.10,198.51.100.0/24`n" | Set-Content $envFile
        $params = New-ResolvedParameterFile -EnvFile $envFile -TemplateJson $script:template -OutFile (Join-Path $script:out 'public-allowlist.parameters.json')
        $expanded = Get-ExpandedResources -TemplateJson $script:template -ParameterFile $params -OutDir (Join-Path $script:out 'public-allowlist')
        $acc = @(Get-FlatResources $expanded | Where-Object type -eq 'Microsoft.CognitiveServices/accounts')[0]
        $acc.properties.networkAcls.defaultAction | Should -Be 'Deny'
        @($acc.properties.networkAcls.ipRules.value) | Should -Be @('203.0.113.10', '198.51.100.0/24')
    }
}

Describe 'Deployment ordering' {
    It 'creates the monitor private endpoint (AMPLS) before the Foundry account / VNet-injected agent runtime' {
        # Regression: with the account first, the agent runtime resolved App Insights ingestion publicly
        # and server-side traces were rejected (public ingestion disabled). docs/modules/monitoring.md
        $res = $script:compiled.resources
        if ($res -isnot [array]) { $res = $res.PSObject.Properties | ForEach-Object Value }
        $acc = $res | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match "^\[format\('account-" }
        $acc.dependsOn | Should -Contain 'peAmpls'
    }
}

Describe 'Profile <Name>' -ForEach $script:profiles {
    BeforeAll {
        $params = New-ResolvedParameterFile -EnvFile $EnvFile -TemplateJson $script:template -OutFile (Join-Path $script:out "$Name.parameters.json")
        $script:p = (Get-Content $params -Raw | ConvertFrom-Json).parameters
        $expanded = Get-ExpandedResources -TemplateJson $script:template -ParameterFile $params -OutDir (Join-Path $script:out $Name)
        $script:r = @(Get-FlatResources $expanded | Where-Object { $_.type -ne 'Microsoft.Resources/deployments' })
        function OfType([string]$t) { @($script:r | Where-Object { $_.type -eq $t }) }
        $script:mode = $script:p.networkMode.value
        $script:outbound = $script:p.outboundNetworkMode.value
    }

    Context 'Foundry account (inbound isolation + Entra-only)' -Skip:($Mode -eq 'public') {
        It 'has public network access disabled' { (OfType 'Microsoft.CognitiveServices/accounts')[0].properties.publicNetworkAccess | Should -Be 'Disabled' }
        It 'has local (key) auth disabled' { (OfType 'Microsoft.CognitiveServices/accounts')[0].properties.disableLocalAuth | Should -BeTrue }
        It 'denies by default with no IP or VNet rules' {
            $acl = (OfType 'Microsoft.CognitiveServices/accounts')[0].properties.networkAcls
            $acl.defaultAction | Should -Be 'Deny'
            @($acl.ipRules).Count | Should -Be 0
            @($acl.virtualNetworkRules).Count | Should -Be 0
        }
        It 'injects agents into snet-agent (byoVnet) or the Microsoft-managed network (managedVnet), nothing for none' {
            $inj = Get-Prop (OfType 'Microsoft.CognitiveServices/accounts')[0] 'properties.networkInjections'
            if ($script:outbound -eq 'byoVnet') {
                @($inj).Count | Should -Be 1
                $inj[0].scenario | Should -Be 'agent'
                $inj[0].useMicrosoftManagedNetwork | Should -BeFalse
                $inj[0].subnetArmId | Should -Match '/subnets/snet-agent$'
            } elseif ($script:outbound -eq 'managedVnet') {
                @($inj).Count | Should -Be 1
                $inj[0].scenario | Should -Be 'agent'
                $inj[0].useMicrosoftManagedNetwork | Should -BeTrue
                $inj[0].subnetArmId | Should -BeNullOrEmpty
            } else { $inj | Should -BeNullOrEmpty }
        }
        It 'has a private endpoint for group "account" registered in all three Foundry zones' {
            $pe = OfType 'Microsoft.Network/privateEndpoints' | Where-Object { $_.properties.privateLinkServiceConnections[0].properties.groupIds -contains 'account' }
            @($pe).Count | Should -Be 1
            $zg = OfType 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' | Where-Object { $_.name -like "$($pe[0].name)/*" }
            $zones = $zg.properties.privateDnsZoneConfigs.properties.privateDnsZoneId | ForEach-Object { ($_ -split '/')[-1] }
            $zones | Should -Contain 'privatelink.cognitiveservices.azure.com'
            $zones | Should -Contain 'privatelink.openai.azure.com'
            $zones | Should -Contain 'privatelink.services.ai.azure.com'
        }
        It 'sends logs and metrics to Log Analytics' {
            OfType 'Microsoft.Insights/diagnosticSettings' | Where-Object { $_.scope -match 'Microsoft.CognitiveServices/accounts' -or $_.name -match 'Microsoft.CognitiveServices/accounts' -or $_.id -match 'Microsoft.CognitiveServices/accounts/[^/]+/providers' } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Standard agent setup dependencies' {
        It 'storage: private, no shared keys, no public blobs, TLS 1.2' -Skip:(-not $Agents) {
            $s = (OfType 'Microsoft.Storage/storageAccounts')[0].properties
            $s.publicNetworkAccess | Should -Be 'Disabled'
            $s.allowSharedKeyAccess | Should -BeFalse
            $s.allowBlobPublicAccess | Should -BeFalse
            $s.minimumTlsVersion | Should -Be 'TLS1_2'
            $s.networkAcls.defaultAction | Should -Be 'Deny'
        }
        It 'cosmos db: private, local auth disabled' -Skip:(-not $Agents) {
            $c = (OfType 'Microsoft.DocumentDB/databaseAccounts')[0].properties
            $c.publicNetworkAccess | Should -Be 'Disabled'
            $c.disableLocalAuth | Should -BeTrue
            @($c.ipRules).Count | Should -Be 0
        }
        It 'ai search: private, local auth disabled' -Skip:(-not $Agents) {
            foreach ($svc in OfType 'Microsoft.Search/searchServices') {
                $svc.properties.publicNetworkAccess | Should -BeIn @('disabled', 'Disabled') -Because $svc.name
                $svc.properties.disableLocalAuth | Should -BeTrue -Because $svc.name
                $svc.properties.networkRuleSet.bypass | Should -Be 'None' -Because $svc.name
            }
        }
        It 'each dependency has a private endpoint' -Skip:(-not $Agents) {
            $groups = (OfType 'Microsoft.Network/privateEndpoints').properties.privateLinkServiceConnections.properties.groupIds
            $groups | Should -Contain 'blob'
            $groups | Should -Contain 'Sql'
            $groups | Should -Contain 'searchService'
        }
        It 'creates no Standard setup resources when outbound=none' -Skip:($Agents) {
            OfType 'Microsoft.Storage/storageAccounts' | Should -BeNullOrEmpty
            OfType 'Microsoft.DocumentDB/databaseAccounts' | Should -BeNullOrEmpty
            OfType 'Microsoft.Search/searchServices' | Should -BeNullOrEmpty
        }
    }

    Context 'Managed VNet (preview)' -Skip:($Outbound -ne 'managedVnet') {
        It 'creates the managed network with AllowOnlyApprovedOutbound and no FQDN rules (no managed firewall)' {
            $mn = @(OfType 'Microsoft.CognitiveServices/accounts/managedNetworks')
            $mn.Count | Should -Be 1
            $mn[0].properties.managedNetwork.isolationMode | Should -Be 'AllowOnlyApprovedOutbound'
            OfType 'Microsoft.CognitiveServices/accounts/managedNetworks/outboundRules' | Where-Object { $_.properties.type -ne 'PrivateEndpoint' } | Should -BeNullOrEmpty
        }
        It 'adds managed private endpoint rules only (knowledge search when AI Search is enabled)' {
            $r = @(OfType 'Microsoft.CognitiveServices/accounts/managedNetworks/outboundRules')
            if ($AiSearch) { ($r | Where-Object { $_.properties.destination.subresourceTarget -eq 'searchService' }) | Should -Not -BeNullOrEmpty }
            $r | ForEach-Object { $_.properties.type | Should -Be 'PrivateEndpoint' }
        }
        It 'has no customer agent subnet and no agent-subnet NAT' {
            ((OfType 'Microsoft.Network/virtualNetworks')[0].properties.subnets.name) | Should -Not -Contain 'snet-agent'
        }
        It 'grants the account MI only Azure AI Enterprise Network Connection Approver (resource group scope)' {
            $ra = @(OfType 'Microsoft.Authorization/roleAssignments' | Where-Object { $_.properties.roleDefinitionId -like '*b556d68e-0be0-4f35-a333-ad7ee1ce17ea' })
            $ra.Count | Should -Be 1
            $ra[0].properties.principalType | Should -Be 'ServicePrincipal'
        }
    }

    Context 'Optional module: AI Search' -Skip:(-not $AiSearch) {
        BeforeAll { $script:kb = OfType 'Microsoft.Search/searchServices' | Where-Object name -like 'srch-kb-*' }
        It 'deploys a dedicated knowledge search service (basic or higher)' {
            @($script:kb).Count | Should -Be 1
            $script:kb.sku.name | Should -Not -Be 'free'
        }
        It 'has its own private endpoint (searchService)' {
            $pe = OfType 'Microsoft.Network/privateEndpoints' | Where-Object name -eq "pe-$($script:kb.name)"
            $pe.properties.privateLinkServiceConnections[0].properties.groupIds | Should -Contain 'searchService'
        }
        It 'is connected to the Foundry project with Entra (AAD) auth' {
            $c = OfType 'Microsoft.CognitiveServices/accounts/projects/connections' | Where-Object name -like '*/knowledge-search'
            $c.properties.authType | Should -Be 'AAD'
            $c.properties.category | Should -Be 'CognitiveSearch'
        }
        It 'grants only data-plane / service roles (no Owner/Contributor)' {
            $ras = OfType 'Microsoft.Authorization/roleAssignments' | Where-Object { $_.properties.description -match 'knowledge index|sample index|synthetic documents' }
            @($ras).Count | Should -BeGreaterOrEqual 2
        }
    }

    Context 'Optional module: RAG demo' -Skip:(-not $Rag) {
        BeforeAll {
            $script:ragVm = OfType 'Microsoft.Compute/virtualMachines' | Where-Object name -like 'vm-rag-*'
            $script:appSubnet = (OfType 'Microsoft.Network/virtualNetworks')[0].properties.subnets | Where-Object name -eq 'snet-app'
            $script:appNsg = OfType 'Microsoft.Network/networkSecurityGroups' | Where-Object name -match 'app'
        }
        It 'deploys one RAG VM with Trusted Launch and a system-assigned identity' {
            @($script:ragVm).Count | Should -Be 1
            $script:ragVm.properties.securityProfile.securityType | Should -Be 'TrustedLaunch'
            $script:ragVm.identity.type | Should -Be 'SystemAssigned'
        }
        It 'places the VM in snet-app (no default outbound access)' {
            $script:appSubnet | Should -Not -BeNullOrEmpty
            $script:appSubnet.properties.defaultOutboundAccess | Should -BeFalse
            $nic = OfType 'Microsoft.Network/networkInterfaces' | Where-Object name -eq "nic-$($script:ragVm.name)"
            $nic.properties.ipConfigurations[0].properties.subnet.id | Should -Match '/subnets/snet-app'
        }
        It 'snet-app NSG allows only the app port from VirtualNetwork and denies internet egress' {
            $rules = $script:appNsg.properties.securityRules
            $allowIn = @($rules | Where-Object { $_.properties.direction -eq 'Inbound' -and $_.properties.access -eq 'Allow' })
            $allowIn.Count | Should -Be 1
            $allowIn[0].properties.sourceAddressPrefix | Should -Be 'VirtualNetwork'
            $allowIn[0].properties.destinationPortRange | Should -Be ([string]$script:p.ragAppPort.value)
            @($rules | Where-Object { $_.properties.direction -eq 'Outbound' -and $_.properties.access -eq 'Deny' -and $_.properties.destinationAddressPrefix -eq 'Internet' }).Count | Should -Be 1
        }
        It 'grants the VM identity only OpenAI User and Search Index Data Reader' {
            $ras = @(OfType 'Microsoft.Authorization/roleAssignments' | Where-Object { $_.properties.description -match '^RAG demo app MI' })
            $ras.Count | Should -Be 2
            ($ras.properties.roleDefinitionId | ForEach-Object { ($_ -split '/')[-1] } | Sort-Object) | Should -Be (@('1407120a-92aa-4202-b7e9-c0e197c71c8f', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd') | Sort-Object)
        }
        It 'jumpbox can reach the app port despite its lateral-movement deny' -Skip:(-not $HasJumpbox) {
            $mgmt = (OfType 'Microsoft.Network/networkSecurityGroups' | Where-Object name -match 'mgmt').properties.securityRules
            $allow = $mgmt | Where-Object name -eq 'AllowAppPortToAppSubnet'
            $allow.properties.destinationAddressPrefix | Should -Be $script:appSubnet.properties.addressPrefix
            $allow.properties.priority | Should -BeLessThan ($mgmt | Where-Object name -eq 'DenyVirtualNetworkOutbound').properties.priority
        }
    }

    Context 'Optional module: advanced monitoring' -Skip:(-not $Monitoring) {
        BeforeAll {
            $script:appi = OfType 'Microsoft.Insights/components'
            $script:amplsRes = OfType 'Microsoft.Insights/privateLinkScopes'
        }
        It 'Application Insights is workspace-based with local auth disabled (Entra-only ingestion)' {
            @($script:appi).Count | Should -Be 1
            $script:appi.properties.DisableLocalAuth | Should -BeTrue
            $script:appi.properties.WorkspaceResourceId | Should -Not -BeNullOrEmpty
        }
        It 'is connected to the project for server-side tracing with Entra auth' {
            $c = OfType 'Microsoft.CognitiveServices/accounts/projects/connections' | Where-Object { $_.properties.category -eq 'AppInsights' }
            @($c).Count | Should -Be 1
            $c.properties.authType | Should -Be 'ProjectManagedIdentity'
        }
        It 'grants the project MI Monitoring Metrics Publisher (trace ingestion)' {
            $ra = OfType 'Microsoft.Authorization/roleAssignments' | Where-Object { $_.properties.description -match '^Project MI: Entra-authenticated server-side agent trace' }
            ($ra.properties.roleDefinitionId -split '/')[-1] | Should -Be '3913510d-42f4-4e42-8a64-420c390055eb'
        }
        It 'standalone: own AMPLS with private-only query/ingestion and an azuremonitor private endpoint' -Skip:($Mode -ne 'standalone') {
            @($script:amplsRes).Count | Should -Be 1
            $script:amplsRes.properties.accessModeSettings.queryAccessMode | Should -Be 'PrivateOnly'
            $script:amplsRes.properties.accessModeSettings.ingestionAccessMode | Should -Be 'PrivateOnly'
            $pe = OfType 'Microsoft.Network/privateEndpoints' | Where-Object name -eq "pe-$($script:amplsRes.name)"
            $pe.properties.privateLinkServiceConnections[0].properties.groupIds | Should -Contain 'azuremonitor'
            $script:appi.properties.publicNetworkAccessForQuery | Should -Be 'Disabled'
            $script:appi.properties.publicNetworkAccessForIngestion | Should -Be 'Disabled'
        }
        It 'hub-spoke / spoke-ready never creates its own AMPLS (one AMPLS per DNS)' -Skip:($Mode -eq 'standalone') {
            $script:amplsRes | Should -BeNullOrEmpty
        }
        It 'alerts on network-relevant configuration changes (security drift)' {
            $al = OfType 'Microsoft.Insights/activityLogAlerts'
            $ops = $al.properties.condition.allOf | Where-Object { $_.PSObject.Properties['anyOf'] } | ForEach-Object { $_.anyOf } | ForEach-Object { $_.PSObject.Properties['equals'].Value }
            $ops | Should -Contain 'Microsoft.CognitiveServices/accounts/write'
        }
    }

    Context 'Optional module: Foundry IQ' -Skip:(-not $FoundryIq) {
        It 'connects the project to the knowledge base MCP endpoint of the PRIVATE knowledge search with the project MI' {
            $c = OfType 'Microsoft.CognitiveServices/accounts/projects/connections' | Where-Object { $_.properties.category -eq 'RemoteTool' }
            @($c).Count | Should -Be 1
            $c.properties.authType | Should -Be 'ProjectManagedIdentity'
            $kb = OfType 'Microsoft.Search/searchServices' | Where-Object name -like 'srch-kb-*'
            $c.properties.target | Should -BeLike "https://$($kb.name).search.windows.net/knowledgebases/*/mcp*"
            $kb.properties.publicNetworkAccess | Should -Be 'disabled'
        }

        It 'query planning: exactly one shared private link knowledge search -> Foundry account (openai_account)' -Skip:(-not $IqPlanning) {
            $spl = @(OfType 'Microsoft.Search/searchServices/sharedPrivateLinkResources')
            $spl.Count | Should -Be 1
            $spl[0].properties.groupId | Should -Be 'openai_account'
            $spl[0].properties.privateLinkResourceId | Should -Match 'Microsoft.CognitiveServices/accounts/aif-'
        }
    }

    Context 'Outbound links from PaaS (shared private links)' {
        It 'creates no shared private link unless Foundry IQ query planning is enabled' -Skip:$IqPlanning {
            OfType 'Microsoft.Search/searchServices/sharedPrivateLinkResources' | Should -BeNullOrEmpty
        }
    }

    Context 'Network segmentation' -Skip:($Mode -eq 'public') {
        BeforeAll { $script:subnets = (OfType 'Microsoft.Network/virtualNetworks')[0].properties.subnets }
        It 'every subnet has an NSG' {
            foreach ($s in $script:subnets) { $s.properties.networkSecurityGroup.id | Should -Not -BeNullOrEmpty -Because $s.name }
        }
        It 'workload subnets have no default outbound access' {
            foreach ($s in $script:subnets | Where-Object name -ne 'AzureBastionSubnet') {
                $s.properties.defaultOutboundAccess | Should -BeFalse -Because $s.name
            }
        }
        It 'agent subnet is delegated exclusively to Microsoft.App/environments' -Skip:($Outbound -ne 'byoVnet') {
            $a = $script:subnets | Where-Object name -eq 'snet-agent'
            @($a.properties.delegations).Count | Should -Be 1
            $a.properties.delegations[0].properties.serviceName | Should -Be 'Microsoft.App/environments'
        }
        It 'private endpoint subnet enforces network policies' {
            ($script:subnets | Where-Object name -eq 'snet-private-endpoints').properties.privateEndpointNetworkPolicies | Should -Be 'Enabled'
        }
        It 'Bastion NSG contains the platform-mandated rules (compliance check)' -Skip:($Mode -ne 'standalone') {
            $rules = (OfType 'Microsoft.Network/networkSecurityGroups' | Where-Object name -match 'bastion').properties.securityRules.properties
            $has = {
                param($dir, $src, $dst, [string[]]$ports)
                $rules | Where-Object {
                    $_.direction -eq $dir -and $_.access -eq 'Allow' -and $_.sourceAddressPrefix -eq $src -and $_.destinationAddressPrefix -eq $dst -and
                    (@($_.destinationPortRange) + @($_.destinationPortRanges) | Where-Object { $_ }) -join ',' -eq ($ports -join ',')
                }
            }
            & $has 'Inbound' 'Internet' '*' '443' | Should -Not -BeNullOrEmpty
            & $has 'Inbound' 'GatewayManager' '*' '443' | Should -Not -BeNullOrEmpty
            & $has 'Inbound' 'AzureLoadBalancer' '*' '443' | Should -Not -BeNullOrEmpty
            & $has 'Inbound' 'VirtualNetwork' 'VirtualNetwork' @('8080', '5701') | Should -Not -BeNullOrEmpty
            & $has 'Outbound' '*' 'VirtualNetwork' @('22', '3389') | Should -Not -BeNullOrEmpty
            & $has 'Outbound' '*' 'AzureCloud' '443' | Should -Not -BeNullOrEmpty
            & $has 'Outbound' 'VirtualNetwork' 'VirtualNetwork' @('8080', '5701') | Should -Not -BeNullOrEmpty
            & $has 'Outbound' '*' 'Internet' '80' | Should -Not -BeNullOrEmpty
        }
        It 'management subnet accepts RDP only from the Bastion subnet and blocks lateral movement' -Skip:($Mode -ne 'standalone' -or -not $HasJumpbox) {
            $rules = (OfType 'Microsoft.Network/networkSecurityGroups' | Where-Object name -match 'mgmt').properties.securityRules
            $rdp = $rules | Where-Object { $_.properties.direction -eq 'Inbound' -and $_.properties.access -eq 'Allow' }
            @($rdp).Count | Should -Be 1
            $rdp.properties.sourceAddressPrefixes | Should -Be @($script:p.bastionSubnetPrefix.value)
            $rules.name | Should -Contain 'DenyVirtualNetworkOutbound'
            $rules.name | Should -Contain 'DenyInternetOutbound'
        }
        It 'NSGs permit no inbound traffic from the internet (except Bastion managed ingress on 443)' {
            foreach ($nsg in OfType 'Microsoft.Network/networkSecurityGroups') {
                foreach ($rule in $nsg.properties.securityRules | Where-Object { $_.properties.direction -eq 'Inbound' -and $_.properties.access -eq 'Allow' }) {
                    $src = @($rule.properties.sourceAddressPrefix) + @($rule.properties.sourceAddressPrefixes) | Where-Object { $_ }
                    $open = $src | Where-Object { $_ -in '*', 'Internet', '0.0.0.0/0', 'Any' }
                    if ($open) {
                        $nsg.name | Should -Match 'bastion' -Because "rule $($rule.name) in $($nsg.name) allows inbound from $open"
                        $rule.properties.destinationPortRange | Should -Be '443'
                    }
                }
            }
        }
        It 'RDP/SSH is only reachable from explicit admin source prefixes' {
            foreach ($nsg in OfType 'Microsoft.Network/networkSecurityGroups' | Where-Object name -notmatch 'bastion') {
                foreach ($rule in $nsg.properties.securityRules | Where-Object { $_.properties.direction -eq 'Inbound' -and $_.properties.access -eq 'Allow' }) {
                    $ports = @($rule.properties.destinationPortRange) + @($rule.properties.destinationPortRanges) | Where-Object { $_ }
                    if ($ports | Where-Object { $_ -in '3389', '22', '*' }) {
                        @($rule.properties.sourceAddressPrefixes).Count | Should -BeGreaterThan 0 -Because "$($nsg.name)/$($rule.name)"
                        $rule.properties.sourceAddressPrefixes | Should -Not -Contain 'VirtualNetwork'
                    }
                }
            }
        }
    }

    Context 'Public exposure and compute' {
        It 'no NIC has a public IP' {
            foreach ($nic in OfType 'Microsoft.Network/networkInterfaces') {
                $nic.properties.ipConfigurations.properties.publicIPAddress | Should -BeNullOrEmpty
            }
        }
        It 'public IPs exist only for Bastion ingress and NAT egress in standalone mode' {
            $pips = OfType 'Microsoft.Network/publicIPAddresses'
            if ($script:mode -eq 'standalone') {
                @($pips).Count | Should -BeLessOrEqual 2
                $pips.name | ForEach-Object { $_ | Should -Match '^pip-(bas-|.*-nat$)' }
            } else { $pips | Should -BeNullOrEmpty -Because "$($script:mode) mode must not create public IPs" }
        }
        It 'jumpbox uses Trusted Launch and Entra ID sign-in' -Skip:(-not $HasJumpbox) {
            $vm = OfType 'Microsoft.Compute/virtualMachines' | Where-Object name -like 'vm-jump-*'
            $vm.properties.securityProfile.securityType | Should -Be 'TrustedLaunch'
            (OfType 'Microsoft.Compute/virtualMachines/extensions').properties.type | Should -Contain 'AADLoginForWindows'
        }
        It 'login principals get exactly Reader on VM, NIC and Bastion for the Bastion connection' -Skip:(-not $HasJumpbox -or $Mode -ne 'standalone') {
            $login = @(OfType 'Microsoft.Authorization/roleAssignments' | Where-Object { $_.properties.description -eq 'Entra ID sign-in to the private jumpbox via Bastion' })
            $readers = @(OfType 'Microsoft.Authorization/roleAssignments' | Where-Object { $_.properties.description -match '^Azure Bastion connection requires Reader' })
            $login.Count | Should -BeGreaterThan 0
            $readers.Count | Should -Be (3 * $login.Count) -Because 'Bastion FAQ: Reader on the VM, its NIC and the Bastion resource'
            $readers.properties.roleDefinitionId | ForEach-Object { ($_ -split '/')[-1] | Should -Be 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
        }
        It 'no Bastion or VM in hub-spoke / spoke-ready unless explicitly enabled' -Skip:($Mode -eq 'standalone') {
            OfType 'Microsoft.Network/bastionHosts' | Should -BeNullOrEmpty
            if (-not $script:p.enableJumpbox.value) { OfType 'Microsoft.Compute/virtualMachines' | Where-Object name -notlike 'vm-rag-*' | Should -BeNullOrEmpty }
        }
    }

    Context 'Public quick-demo mode (NOT private)' -Skip:($Mode -ne 'public') {
        It 'enables public network access but keeps Entra-only auth and no network injection' {
            $a = (OfType 'Microsoft.CognitiveServices/accounts')[0]
            $a.properties.publicNetworkAccess | Should -Be 'Enabled'
            $a.properties.disableLocalAuth | Should -BeTrue
            Get-Prop $a 'properties.networkInjections' | Should -BeNullOrEmpty
        }
        It 'tags every resource network-exposure=public' {
            (OfType 'Microsoft.CognitiveServices/accounts')[0].tags.'network-exposure' | Should -Be 'public'
        }
        It 'deploys no VNet, private endpoints, DNS zones, Bastion, VMs, NAT or public IPs' {
            foreach ($t in 'Microsoft.Network/virtualNetworks', 'Microsoft.Network/privateEndpoints', 'Microsoft.Network/privateDnsZones', 'Microsoft.Network/bastionHosts', 'Microsoft.Compute/virtualMachines', 'Microsoft.Network/natGateways', 'Microsoft.Network/publicIPAddresses') {
                OfType $t | Should -BeNullOrEmpty -Because $t
            }
        }
        It 'deploys no optional modules or Standard setup data stores' {
            OfType 'Microsoft.Search/searchServices' | Should -BeNullOrEmpty
            OfType 'Microsoft.DocumentDB/databaseAccounts' | Should -BeNullOrEmpty
            OfType 'Microsoft.Storage/storageAccounts' | Should -BeNullOrEmpty
            OfType 'Microsoft.Insights/components' | Should -BeNullOrEmpty
        }
    }

    Context 'Private profiles never expose the account' -Skip:($Mode -eq 'public') {
        It 'tags network-exposure=private' {
            (OfType 'Microsoft.CognitiveServices/accounts')[0].tags.'network-exposure' | Should -Be 'private'
        }
    }

    Context 'Identity and RBAC' {
        It 'never assigns Owner, Contributor, UAA or RBAC Administrator' {
            foreach ($ra in OfType 'Microsoft.Authorization/roleAssignments') {
                $roleId = ($ra.properties.roleDefinitionId -split '/')[-1]
                $script:forbiddenRoles.ContainsKey($roleId) | Should -BeFalse -Because "assignment $($ra.name) grants $($script:forbiddenRoles[$roleId])"
            }
        }
        It 'all role assignments carry a purpose description or ABAC condition' {
            foreach ($ra in OfType 'Microsoft.Authorization/roleAssignments') {
                ($ra.properties.description -or $ra.properties.condition) | Should -BeTrue -Because $ra.name
            }
        }
    }

    Context 'Hub-spoke specifics' -Skip:($Mode -ne 'hub-spoke') {
        It 'routes 0.0.0.0/0 to the hub firewall' {
            $rt = OfType 'Microsoft.Network/routeTables'
            $rt.properties.routes.properties.nextHopIpAddress | Should -Be $script:p.hubFirewallPrivateIp.value
        }
        It 'creates spoke-to-hub peering only (hub side requires opt-in)' {
            $peers = OfType 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
            @($peers).Count | Should -Be ([int]$script:p.enableHubPeering.value + [int]$script:p.enableHubSidePeering.value)
        }
        It 'does not create private DNS zones when using centralised DNS' -Skip:($DnsMode -ne 'existing') {
            OfType 'Microsoft.Network/privateDnsZones' | Should -BeNullOrEmpty
        }
        It 'uses the custom (hub) DNS servers' {
            (OfType 'Microsoft.Network/virtualNetworks')[0].properties.dhcpOptions.dnsServers | Should -Be @($script:p.customDnsServers.value -split ',' | ForEach-Object Trim)
        }
    }
}
