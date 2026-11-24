# Shared helpers for offline (no-Azure) template tests.
Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Read-EnvFile([string]$Path) {
    $h = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $i = $line.IndexOf('=')
        $h[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim().Trim('"')
    }
    return $h
}

function Build-MainTemplate([string]$OutDir) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $out = Join-Path $OutDir 'main.json'
    $log = az bicep build --file (Join-Path $script:RepoRoot 'infra/main.bicep') --outfile $out 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bicep build failed:`n$($log -join "`n")" }
    return $out
}

function New-ResolvedParameterFile {
    <#
      Resolves infra/main.parameters.json (azd ${VAR=default} syntax) using an example .env file,
      converting values to the Bicep parameter types, exactly like azd does at provision time.
    #>
    param(
        [Parameter(Mandatory)][string]$EnvFile,
        [Parameter(Mandatory)][string]$TemplateJson,
        [Parameter(Mandatory)][string]$OutFile
    )
    $vars = @{
        AZURE_ENV_NAME     = 'ci-' + [IO.Path]::GetFileNameWithoutExtension($EnvFile)
        AZURE_LOCATION     = 'swedencentral'
        AZURE_PRINCIPAL_ID = '11111111-1111-1111-1111-111111111111'
    }
    (Read-EnvFile $EnvFile).GetEnumerator() | ForEach-Object { $vars[$_.Key] = $_.Value }

    $types = @{}
    (Get-Content $TemplateJson -Raw | ConvertFrom-Json -AsHashtable).parameters.GetEnumerator() |
        ForEach-Object { $types[$_.Key] = $_.Value.type.ToLower() }

    $raw = Get-Content (Join-Path $script:RepoRoot 'infra/main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
    $resolved = [ordered]@{}
    foreach ($p in $raw.parameters.GetEnumerator()) {
        $expr = [string]$p.Value.value
        $value = [regex]::Replace($expr, '\$\{([A-Z0-9_]+)(=([^}]*))?\}', {
                param($m)
                $name = $m.Groups[1].Value
                if ($vars.ContainsKey($name)) { $vars[$name] } else { $m.Groups[3].Value }
            })
        $typed = switch ($types[$p.Key]) {
            'bool' { $value -match '^(true|1)$' }
            'int' { [int]$value }
            { $_ -in 'array', 'object' } { if ([string]::IsNullOrWhiteSpace($value)) { $null } else { $value | ConvertFrom-Json -AsHashtable -NoEnumerate } }
            default { $value }
        }
        if ($types[$p.Key] -in 'securestring') { continue }
        if ($null -eq $typed -and $types[$p.Key] -eq 'array') { $typed = @() }
        $resolved[$p.Key] = @{ value = $typed }
    }
    $doc = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $resolved
    }
    $doc | ConvertTo-Json -Depth 20 | Set-Content $OutFile -Encoding utf8
    return $OutFile
}

function Get-ExpandedResources {
    <# Expands the template + parameters with PSRule for Azure (evaluates expressions and nested deployments). #>
    param([string]$TemplateJson, [string]$ParameterFile, [string]$OutDir)
    Import-Module PSRule.Rules.Azure -ErrorAction Stop
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $file = Export-AzRuleTemplateData -TemplateFile $TemplateJson -ParameterFile $ParameterFile -OutputPath $OutDir `
        -Subscription @{ SubscriptionId = '00000000-0000-0000-0000-000000000001'; DisplayName = 'ci' }
    return Get-Content $file.FullName -Raw | ConvertFrom-Json -Depth 100
}

function Get-FlatResources($Resources) {
    # Flattens nested deployment resources produced by PSRule expansion.
    foreach ($r in $Resources) {
        $r
        if ($r.PSObject.Properties['resources'] -and $r.resources) { Get-FlatResources $r.resources }
    }
}

Export-ModuleMember -Function Read-EnvFile, Build-MainTemplate, New-ResolvedParameterFile, Get-ExpandedResources, Get-FlatResources
