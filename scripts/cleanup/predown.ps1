#!/usr/bin/env pwsh
# azd `predown` hook: ordered teardown steps (peering, Foundry account delete + purge, agent subnet
# link release, AMPLS unlink) before azd deletes the resource group. See Remove-Environment.ps1.
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/Remove-Environment.ps1" -PreDown -Environment $env:AZURE_ENV_NAME
