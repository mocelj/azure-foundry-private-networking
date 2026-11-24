#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# azd substitutes ${VAR} values into infra/main.parameters.json as raw text (no JSON escaping).
# Regression test: every sample profile must still produce a valid parameters document, i.e. no
# value may contain characters that break JSON (quotes, backslashes, braces in defaults).

BeforeDiscovery {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:profiles = Get-ChildItem (Join-Path $root 'examples') -Recurse -Filter '*.env' | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\TestHelpers.psm1') -Force
    $script:paramText = Get-Content (Join-Path $PSScriptRoot '..\..\infra\main.parameters.json') -Raw
    function Invoke-AzdLikeSubstitution([string]$text, [hashtable]$vars) {
        [regex]::Replace($text, '\$\{([A-Z0-9_]+)(=([^}]*))?\}', {
                param($m)
                if ($vars.ContainsKey($m.Groups[1].Value)) { $vars[$m.Groups[1].Value] } else { $m.Groups[3].Value }
            })
    }
}

Describe 'main.parameters.json' {
    It 'no template output name collides with an azd input variable (azd down would erase the input)' {
        $inputs = [regex]::Matches($script:paramText, '\$\{([A-Z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $bicep = Get-Content (Join-Path $PSScriptRoot '..\..\infra\main.bicep') -Raw
        $outputs = [regex]::Matches($bicep, '(?m)^output\s+([A-Za-z0-9_]+)\s') | ForEach-Object { $_.Groups[1].Value }
        $allowed = @('AZURE_RESOURCE_GROUP')
        $outputs | Where-Object { $_ -in $inputs -and $_ -notin $allowed } | Should -BeNullOrEmpty
    }
    It 'defaults contain no characters that terminate ${VAR=default} early' {
        [regex]::Matches($script:paramText, '\$\{[A-Z0-9_]+=([^}]*)\}') | ForEach-Object {
            $_.Groups[1].Value | Should -Not -Match '[{"\\]'
        }
    }
    It 'is valid JSON with all defaults' {
        { Invoke-AzdLikeSubstitution $script:paramText @{ AZURE_ENV_NAME = 'x'; AZURE_LOCATION = 'swedencentral'; AZURE_PRINCIPAL_ID = '' } | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Profile <Name> survives raw azd substitution' -ForEach $script:profiles {
    It 'produces a valid parameters document' {
        $vars = Read-EnvFile $Path
        $vars.AZURE_ENV_NAME = 'x'; $vars.AZURE_LOCATION = 'swedencentral'; $vars.AZURE_PRINCIPAL_ID = '11111111-1111-1111-1111-111111111111'
        { Invoke-AzdLikeSubstitution $script:paramText $vars | ConvertFrom-Json } | Should -Not -Throw
    }
    It 'uses no JSON-encoded values' {
        (Read-EnvFile $Path).Values | ForEach-Object { $_ | Should -Not -Match '["{}\\]' }
    }
}
