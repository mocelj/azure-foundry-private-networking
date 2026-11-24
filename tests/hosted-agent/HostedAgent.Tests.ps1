#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Optional module 7 (hosted agent demo): flag wiring, preflight gates, azd project and agent code limits.
# Offline: no Azure access (preflight runs with -SkipAzure in a clean child process).

BeforeDiscovery {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $root 'tests/TestHelpers.psm1') -Force
    $script:hostedProfiles = @(Get-ChildItem (Join-Path $root 'examples') -Recurse -Filter '*.env' |
            Where-Object { (Read-EnvFile $_.FullName).ENABLE_HOSTED_AGENT_DEMO -eq 'true' } |
            ForEach-Object { @{ Name = $_.BaseName; EnvFile = $_.FullName } })
    $py = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    $script:noPyYaml = -not $py -or -not (& $py -c 'import yaml; print(1)' 2>$null)
}

BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $script:root 'tests/TestHelpers.psm1') -Force
    $script:out = Join-Path $script:root '.test-output/hosted-agent'
    $script:template = Build-MainTemplate $script:out
    $script:compiled = Get-Content $script:template -Raw | ConvertFrom-Json -Depth 100
    $script:agentDir = Join-Path $script:root 'src/hosted-agents'
    $script:python = @('python3', 'python') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    $script:preflight = Join-Path $script:root 'scripts/preflight/preflight.ps1'

    function Invoke-Preflight([hashtable]$Settings) {
        # Clean child process: only the given settings, never values from the caller's shell or azd env.
        $set = ($Settings.GetEnumerator() | ForEach-Object { "`$env:$($_.Key) = '$($_.Value)'" }) -join '; '
        $cmd = "Get-ChildItem env: | Where-Object Name -match '^(ENABLE_|NETWORK_MODE|OUTBOUND_|PRIVATE_CLIENT|PUBLIC_|MANAGED_VNET|FOUNDRY_IQ|MONITOR_|EXISTING_|HUB_|AZURE_ENV|AZURE_LOCATION)' | Remove-Item; " +
            "`$env:AZURE_ENV_NAME = 'ci'; `$env:AZURE_LOCATION = 'swedencentral'; $set; & '$($script:preflight)' -SkipAzure"
        $text = pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
        @{ Exit = $LASTEXITCODE; Text = $text }
    }
    $script:base = @{ NETWORK_MODE = 'standalone'; OUTBOUND_NETWORK_MODE = 'byoVnet'; ENABLE_JUMPBOX = 'true'; ENABLE_AI_SEARCH = 'true'; ENABLE_FOUNDRY_IQ = 'true'; ENABLE_ADVANCED_MONITORING = 'true'; ENABLE_HOSTED_AGENT_DEMO = 'true' }
    function With([hashtable]$Changes) { $h = $script:base.Clone(); $Changes.GetEnumerator() | ForEach-Object { $h[$_.Key] = $_.Value }; $h }
}

Describe 'Hosted agent demo: flag wiring' {
    It 'main.parameters.json maps ENABLE_HOSTED_AGENT_DEMO (default false) to enableHostedAgentDemo' {
        (Get-Content (Join-Path $script:root 'infra/main.parameters.json') -Raw | ConvertFrom-Json).parameters.enableHostedAgentDemo.value | Should -Be '${ENABLE_HOSTED_AGENT_DEMO=false}'
    }
    It 'template parameter is bool, default false' {
        $script:compiled.parameters.enableHostedAgentDemo.type | Should -Be 'bool'
        $script:compiled.parameters.enableHostedAgentDemo.defaultValue | Should -BeFalse
    }
    It 'output DEPLOYED_HOSTED_AGENT_DEMO is true only together with a deployed Foundry IQ' {
        $script:compiled.outputs.DEPLOYED_HOSTED_AGENT_DEMO.type | Should -Be 'bool'
        $script:compiled.outputs.DEPLOYED_HOSTED_AGENT_DEMO.value | Should -Match "variables\('deployHostedAgentDemo'\)"
        $script:compiled.variables.deployHostedAgentDemo | Should -Match "parameters\('enableHostedAgentDemo'\)"
        $script:compiled.variables.deployHostedAgentDemo | Should -Match "variables\('deployFoundryIq'\)"
    }
    It 'at least one example profile enables the module' {
        @(Get-ChildItem (Join-Path $script:root 'examples') -Recurse -Filter '*.env' | Where-Object { (Read-EnvFile $_.FullName).ENABLE_HOSTED_AGENT_DEMO -eq 'true' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Hosted agent profile <Name>' -ForEach $script:hostedProfiles {
    BeforeAll {
        $params = New-ResolvedParameterFile -EnvFile $EnvFile -TemplateJson $script:template -OutFile (Join-Path $script:out "$Name.parameters.json")
        $script:p = (Get-Content $params -Raw | ConvertFrom-Json).parameters
        $script:e = Read-EnvFile $EnvFile
    }
    It 'resolves enableHostedAgentDemo=true with its prerequisites (Foundry IQ, AI Search, agent network, private network)' {
        $script:p.enableHostedAgentDemo.value | Should -BeTrue
        $script:p.enableFoundryIq.value | Should -BeTrue
        $script:p.enableAiSearch.value | Should -BeTrue
        $script:p.outboundNetworkMode.value | Should -BeIn 'byoVnet', 'managedVnet'
        $script:p.networkMode.value | Should -BeIn 'standalone', 'hub-spoke'
    }
    It 'has an in-network private client (jumpbox or PRIVATE_CLIENT_VM_ID)' {
        ($script:p.enableJumpbox.value -or $script:e.PRIVATE_CLIENT_VM_ID) | Should -BeTrue
    }
    It 'passes preflight (offline)' {
        $r = Invoke-Preflight $script:e
        $r.Text | Should -Match 'Optional module hosted agent demo enabled'
        $r.Exit | Should -Be 0 -Because $r.Text
    }
}

Describe 'Hosted agent demo: preflight fails closed' {
    It 'passes with all prerequisites' {
        $r = Invoke-Preflight $script:base
        $r.Exit | Should -Be 0 -Because $r.Text
        $r.Text | Should -Not -Match 'ENABLE_HOSTED_AGENT_DEMO without ENABLE_ADVANCED_MONITORING'
    }
    It 'fails without Foundry IQ' {
        $r = Invoke-Preflight (With @{ ENABLE_FOUNDRY_IQ = 'false' })
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'ENABLE_HOSTED_AGENT_DEMO=true requires ENABLE_FOUNDRY_IQ=true'
    }
    It 'fails without an isolated agent network (OUTBOUND_NETWORK_MODE=none)' {
        $r = Invoke-Preflight (With @{ OUTBOUND_NETWORK_MODE = 'none' })
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'ENABLE_HOSTED_AGENT_DEMO=true requires OUTBOUND_NETWORK_MODE=byoVnet or managedVnet'
    }
    It 'fails without a private client' {
        $r = Invoke-Preflight (With @{ ENABLE_JUMPBOX = 'false' })
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'requires an in-network private client'
    }
    It 'accepts PRIVATE_CLIENT_VM_ID instead of a jumpbox, rejects a malformed ID' {
        $vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub/providers/Microsoft.Compute/virtualMachines/vm-hub-workstation'
        $r = Invoke-Preflight (With @{ ENABLE_JUMPBOX = 'false'; PRIVATE_CLIENT_VM_ID = $vmId })
        $r.Exit | Should -Be 0 -Because $r.Text
        $r = Invoke-Preflight (With @{ ENABLE_JUMPBOX = 'false'; PRIVATE_CLIENT_VM_ID = 'vm-hub-workstation' })
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'PRIVATE_CLIENT_VM_ID is not a virtual machine resource ID'
    }
    It 'fails in spoke-ready mode' {
        $r = Invoke-Preflight (With @{ NETWORK_MODE = 'spoke-ready' })
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'not supported with NETWORK_MODE=spoke-ready'
    }
    It 'fails in public mode' {
        $r = Invoke-Preflight @{ NETWORK_MODE = 'public'; OUTBOUND_NETWORK_MODE = 'none'; PUBLIC_NETWORK_ACCESS_ACK = 'true'; ENABLE_BASTION = 'false'; ENABLE_JUMPBOX = 'false'; ENABLE_HOSTED_AGENT_DEMO = 'true' }
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'ENABLE_HOSTED_AGENT_DEMO=true is not supported with NETWORK_MODE=public'
    }
    It 'only warns without advanced monitoring (no telemetry role)' {
        $r = Invoke-Preflight (With @{ ENABLE_ADVANCED_MONITORING = 'false' })
        $r.Exit | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match '\[WARN\] ENABLE_HOSTED_AGENT_DEMO without ENABLE_ADVANCED_MONITORING'
    }
}

Describe 'Hosted agent azd project (src/hosted-agents)' {
    BeforeAll {
        $script:main = Get-Content (Join-Path $script:agentDir 'contoso-policy-hosted/main.py') -Raw
        if ($script:python) {
            $json = & $script:python -c "import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1], encoding='utf-8'))))" (Join-Path $script:agentDir 'azure.yaml')
            if (-not $LASTEXITCODE) {
                $script:y = $json | ConvertFrom-Json -AsHashtable
                $script:agent = $script:y.services['contoso-policy-hosted']
                $script:envVars = @{}; foreach ($ev in $script:agent.environmentVariables) { $script:envVars[$ev.name] = [string]$ev.value }
            }
        }
    }
    It 'azure.yaml parses' -Skip:$script:noPyYaml {
        $script:y | Should -Not -BeNullOrEmpty
    }
    It 'toolbox: MCP tool on the Foundry IQ connection knowledge-base-mcp' -Skip:$script:noPyYaml {
        $tb = $script:y.services['contoso-policy-tools']
        $tb.host | Should -Be 'azure.ai.toolbox'
        $tb.tools[0].type | Should -Be 'mcp'
        $tb.tools[0].project_connection_id | Should -Be 'knowledge-base-mcp'
    }
    It 'hosted agent: source-code deploy (remote_build, no registry), uses the toolbox, TOOLBOX_NAME matches' -Skip:$script:noPyYaml {
        $script:agent.kind | Should -Be 'hosted'
        $script:agent.host | Should -Be 'azure.ai.agent'
        $script:agent.codeConfiguration.dependencyResolution | Should -Be 'remote_build'
        $script:agent.codeConfiguration.entryPoint | Should -BeOfType [string]
        $script:agent.uses | Should -Contain 'contoso-policy-tools'
        $script:envVars.TOOLBOX_NAME | Should -Be 'contoso-policy-tools'
        $script:agent.Contains('image') | Should -BeFalse
    }
    It 'agent-level guardrail: rai_policy placeholder substituted by Deploy-HostedAgentAzd.ps1' -Skip:$script:noPyYaml {
        $pol = @($script:agent.policies | Where-Object { $_.type -eq 'rai_policy' })
        $pol.Count | Should -Be 1
        $pol[0].raiPolicyName | Should -Be '__RAI_POLICY_ID__'
        Get-Content (Join-Path $script:root 'scripts/agents/Deploy-HostedAgentAzd.ps1') -Raw | Should -Match "Replace\('__RAI_POLICY_ID__'"
    }
    It 'sets every loop limit read by main.py to a positive integer' -Skip:$script:noPyYaml {
        $names = @([regex]::Matches($script:main, '_limit\("(HOSTED_AGENT_[A-Z_]+)"') | ForEach-Object { $_.Groups[1].Value })
        $names | Should -Be @('HOSTED_AGENT_MAX_ITERATIONS', 'HOSTED_AGENT_MAX_TOOL_CALLS', 'HOSTED_AGENT_TIMEOUT_SECONDS', 'HOSTED_AGENT_MAX_OUTPUT_TOKENS')
        foreach ($n in $names) { $script:envVars[$n] | Should -Match '^[1-9]\d*$' -Because $n }
    }
    It 'main.py applies the limits with Agent Framework options (iterations, tool calls, duration, HTTP timeout, output tokens)' {
        foreach ($k in '"max_iterations": MAX_ITERATIONS', '"max_function_calls": MAX_TOOL_CALLS', '"max_duration_seconds": TIMEOUT_SECONDS', 'timeout=TIMEOUT_SECONDS', 'default_options={"max_tokens": MAX_OUTPUT_TOKENS}', 'prepare_options=cap_output_tokens') {
            $script:main | Should -Match ([regex]::Escape($k))
        }
    }
    It 'main.py is valid Python' -Skip:$script:noPyYaml {
        & $script:python -c "import ast, sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" (Join-Path $script:agentDir 'contoso-policy-hosted/main.py')
        $LASTEXITCODE | Should -Be 0
    }
    It 'requirements allow the core version that provides max_duration_seconds' {
        Get-Content (Join-Path $script:agentDir 'contoso-policy-hosted/requirements.txt') | Should -Contain 'agent-framework-core>=1.25.0,<2'
    }
}
