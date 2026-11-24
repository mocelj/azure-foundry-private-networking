#!/usr/bin/env pwsh
# postprovision hook: prints how to reach the private deployment. Never prints secrets.
$ErrorActionPreference = 'Continue'
$rg = $env:AZURE_RESOURCE_GROUP
Write-Host "`n=== Private Foundry deployed ===" -ForegroundColor Cyan
Write-Host "Resource group     : $rg"
Write-Host "Network mode       : $env:DEPLOYED_NETWORK_MODE (egress: $env:EGRESS_MODE, outbound: $env:DEPLOYED_OUTBOUND_NETWORK_MODE)"
Write-Host "Foundry account    : $env:AZURE_AI_ACCOUNT_NAME (public network access: Disabled)"
Write-Host "Project endpoint   : $env:AZURE_AI_PROJECT_ENDPOINT"
Write-Host "Model deployment   : $env:AZURE_AI_MODEL_DEPLOYMENT_NAME"
if ($env:JUMPBOX_VM_NAME) {
    Write-Host "`nPrivate access: Azure portal > $env:JUMPBOX_VM_NAME > Connect > Bastion > Microsoft Entra ID"
    Write-Host "  or: az network bastion rdp -n $env:BASTION_NAME -g $rg --target-resource-id $env:JUMPBOX_VM_ID --enable-mfa"
}
Write-Host "`nValidate:  pwsh ./scripts/validation/Test-Deployment.ps1"
Write-Host "These endpoints are NOT reachable from the public internet by design.`n"

$privateClient = if (-not $env:JUMPBOX_VM_NAME -and $env:PRIVATE_CLIENT_VM_ID) { "private client VM '$(($env:PRIVATE_CLIENT_VM_ID -split '/')[-1])'" } else { 'jumpbox' }

if ($env:KNOWLEDGE_SEARCH_NAME) {
    if ($env:JUMPBOX_VM_NAME -or $env:PRIVATE_CLIENT_VM_ID) {
        Write-Host "Seeding the private knowledge index from inside the network ($privateClient, VM Run Command)..." -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot '..\ai-search\Seed-KnowledgeIndex.ps1')
        if ($LASTEXITCODE) { Write-Host "Seeding failed; re-run: pwsh ./scripts/ai-search/Seed-KnowledgeIndex.ps1" -ForegroundColor Yellow }
    } else {
        Write-Host "Knowledge search deployed without a jumpbox or PRIVATE_CLIENT_VM_ID: seed it from a private client:" -ForegroundColor Yellow
        Write-Host "  pwsh ./scripts/ai-search/Seed-KnowledgeIndex.ps1 -ClientVmId <private Windows VM resource ID>"
    }
}

if ($env:DEMO_AGENT_NAME) {
    if ($env:JUMPBOX_VM_NAME -or $env:PRIVATE_CLIENT_VM_ID) {
        Write-Host "`nDeploying the demo agent '$env:DEMO_AGENT_NAME' from inside the network ($privateClient, VM Run Command)..." -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot '..\agents\Deploy-DemoAgent.ps1')
        if ($LASTEXITCODE) { Write-Host "Demo agent deployment failed; re-run: pwsh ./scripts/agents/Deploy-DemoAgent.ps1" -ForegroundColor Yellow }
    } else {
        Write-Host "Demo agent enabled without a jumpbox or PRIVATE_CLIENT_VM_ID: deploy it from a private client:" -ForegroundColor Yellow
        Write-Host "  pwsh ./scripts/agents/Deploy-DemoAgent.ps1 -ClientVmId <private Windows VM resource ID>"
    }
}

if ($env:FOUNDRY_IQ_KNOWLEDGE_BASE) {
    if ($env:JUMPBOX_VM_NAME -or $env:PRIVATE_CLIENT_VM_ID) {
        Write-Host "`nDeploying the Foundry IQ demo agent (knowledge base '$env:FOUNDRY_IQ_KNOWLEDGE_BASE' via MCP)..." -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot '..\agents\Deploy-DemoAgent.ps1') -Variant foundry-iq
        if ($LASTEXITCODE) { Write-Host "Foundry IQ agent deployment failed; re-run: pwsh ./scripts/agents/Deploy-DemoAgent.ps1 -Variant foundry-iq" -ForegroundColor Yellow }
    } else {
        Write-Host "Foundry IQ enabled without a jumpbox or PRIVATE_CLIENT_VM_ID: deploy the agent from a private client:" -ForegroundColor Yellow
        Write-Host "  pwsh ./scripts/agents/Deploy-DemoAgent.ps1 -Variant foundry-iq -ClientVmId <private Windows VM resource ID>"
    }
}

if ($env:DEPLOYED_HOSTED_AGENT_DEMO -eq 'true') {
    if ($env:JUMPBOX_VM_NAME -or $env:PRIVATE_CLIENT_VM_ID) {
        # After seeding: the toolbox needs the Foundry IQ knowledge base behind connection knowledge-base-mcp.
        Write-Host "`nDeploying the hosted agent demo (azd on the $privateClient as in-network runner: toolbox + hosted agent)..." -ForegroundColor Cyan
        $haFailed = $false
        try { & (Join-Path $PSScriptRoot '..\agents\Deploy-HostedAgentAzd.ps1') -Environment $env:AZURE_ENV_NAME -Action all; $haFailed = [bool]$LASTEXITCODE }
        catch { Write-Host $_ -ForegroundColor Red; $haFailed = $true }
        if ($haFailed) { Write-Host "Hosted agent deployment failed; re-run: pwsh ./scripts/agents/Deploy-HostedAgentAzd.ps1 -Environment $env:AZURE_ENV_NAME -Action all" -ForegroundColor Yellow }
    } else {
        Write-Host "Hosted agent demo enabled without a jumpbox or PRIVATE_CLIENT_VM_ID: deploy it from a private client:" -ForegroundColor Yellow
        Write-Host "  pwsh ./scripts/agents/Deploy-HostedAgentAzd.ps1 -ClientVmId <private Windows VM resource ID>"
    }
}

if ($env:RAG_VM_NAME) {
    Write-Host "`nDeploying the private RAG demo app (VM Run Command)..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot '..\rag\Deploy-RagApp.ps1')
    if ($LASTEXITCODE) { Write-Host "RAG app deployment failed; re-run: pwsh ./scripts/rag/Deploy-RagApp.ps1" -ForegroundColor Yellow }
    else { Write-Host "Open $env:RAG_APP_URL from a private client (jumpbox / hub workstation via Bastion)." }
}
