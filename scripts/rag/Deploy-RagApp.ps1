#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deploys (or updates) the private RAG demo app onto the RAG VM in snet-app.
  The VM has no public IP and no internet egress, so code is delivered over the Azure management
  plane with VM Run Command; the app itself uses only the Python standard library.

  Idempotent: rewrites app + unit, keeps the existing TLS certificate, restarts the service, then
  runs a health check and an in-VM smoke question (retrying while RBAC propagates).

.EXAMPLE
  pwsh ./scripts/rag/Deploy-RagApp.ps1
  pwsh ./scripts/rag/Deploy-RagApp.ps1 -Environment contoso-standalone
#>
[CmdletBinding()]
param([string]$Environment)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$envArgs = @(); if ($Environment) { $envArgs = @('-e', $Environment) }
$v = @{}
azd env get-values @envArgs 2>$null | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)="?(.*?)"?$') { $v[$Matches[1]] = ($Matches[2] -replace '\\"', '"') } }
if (-not $v.RAG_VM_NAME) { Write-Host 'ENABLE_RAG_DEMO is not enabled (no RAG_VM_NAME output). Nothing to deploy.'; exit 0 }

$port = if ($v.DEPLOYED_RAG_APP_PORT) { $v.DEPLOYED_RAG_APP_PORT } else { '8443' }
$appB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repo 'src/rag-demo/app.py')))

$remote = @'
#!/bin/bash
set -euo pipefail
APP_DIR=/opt/rag-demo
id rag-demo >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin rag-demo
mkdir -p $APP_DIR
echo '__APP_B64__' | base64 -d > $APP_DIR/app.py
IP=$(hostname -I | awk '{print $1}')
if [ ! -f $APP_DIR/tls.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout $APP_DIR/tls.key -out $APP_DIR/tls.crt \
    -subj "/CN=rag-demo" -addext "subjectAltName=IP:${IP}" >/dev/null 2>&1
fi
chown -R root:rag-demo $APP_DIR; chmod 750 $APP_DIR; chmod 640 $APP_DIR/*
cat > /etc/systemd/system/rag-demo.service <<UNIT
[Unit]
Description=Private RAG demo
After=network-online.target
Wants=network-online.target
[Service]
User=rag-demo
Group=rag-demo
Environment=SEARCH_ENDPOINT=https://__SEARCH__.search.windows.net
Environment=SEARCH_INDEX=__INDEX__
Environment=OPENAI_ENDPOINT=__OPENAI__
Environment=MODEL_DEPLOYMENT=__MODEL__
Environment=APP_PORT=__PORT__
Environment=TLS_CERT=$APP_DIR/tls.crt
Environment=TLS_KEY=$APP_DIR/tls.key
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
CapabilityBoundingSet=
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable rag-demo >/dev/null 2>&1
systemctl restart rag-demo
for i in $(seq 1 15); do curl -skf https://127.0.0.1:__PORT__/healthz >/dev/null && break; sleep 2; done
echo "HEALTH: $(curl -sk https://127.0.0.1:__PORT__/healthz)"
echo "URL: https://${IP}:__PORT__/"
# Smoke question; retry while new role assignments propagate (can take several minutes).
for i in $(seq 1 20); do
  R=$(curl -sk -m 90 -X POST https://127.0.0.1:__PORT__/api/ask -H 'Content-Type: application/json' \
      -d '{"question":"How do administrators access cloud workloads remotely?"}' || true)
  if echo "$R" | grep -q '"pol-003"' && echo "$R" | grep -q '"answer"'; then echo "SMOKE: PASS"; echo "$R" | head -c 600; echo; exit 0; fi
  echo "SMOKE attempt $i: $(echo "$R" | head -c 200)"; sleep 30
done
echo "SMOKE: FAIL"; journalctl -u rag-demo -n 20 --no-pager; exit 1
'@
$remote = $remote.Replace('__APP_B64__', $appB64).Replace('__SEARCH__', $v.KNOWLEDGE_SEARCH_NAME).Replace('__INDEX__', $v.KNOWLEDGE_SEARCH_INDEX).
    Replace('__OPENAI__', $v.AZURE_OPENAI_ENDPOINT.TrimEnd('/')).Replace('__MODEL__', $v.AZURE_AI_MODEL_DEPLOYMENT_NAME).Replace('__PORT__', $port)
$tmp = New-TemporaryFile
[IO.File]::WriteAllText($tmp, ($remote -replace "`r`n", "`n"))
$power = az vm get-instance-view --subscription $v.AZURE_SUBSCRIPTION_ID -g $v.AZURE_RESOURCE_GROUP -n $v.RAG_VM_NAME --query "instanceView.statuses[?starts_with(code,'PowerState')].code | [0]" -o tsv
if ($power -ne 'PowerState/running') { Write-Host "Starting $($v.RAG_VM_NAME) ($power; e.g. daily auto-shutdown)..."; az vm start --subscription $v.AZURE_SUBSCRIPTION_ID -g $v.AZURE_RESOURCE_GROUP -n $v.RAG_VM_NAME -o none }
Write-Host "Deploying RAG demo app to $($v.RAG_VM_NAME) (Run Command, management plane)..."
$out = az vm run-command invoke --subscription $v.AZURE_SUBSCRIPTION_ID -g $v.AZURE_RESOURCE_GROUP -n $v.RAG_VM_NAME --command-id RunShellScript --scripts "@$tmp" -o json | ConvertFrom-Json
Remove-Item $tmp
$msg = ($out.value | Select-Object -First 1).message
Write-Host $msg
if ($msg -notmatch 'SMOKE: PASS') { Write-Host 'RAG app deployment/smoke test failed. See output above.' -ForegroundColor Red; exit 1 }
Write-Host "RAG demo app deployed and verified. Private URL: $($v.RAG_APP_URL)" -ForegroundColor Green
