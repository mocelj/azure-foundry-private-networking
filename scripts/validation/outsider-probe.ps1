# Executed via VM Run Command on a VM whose egress IP is NOT in PUBLIC_ALLOWED_IPS (Test-Deployment.ps1
# -OutsiderVmId, NETWORK_MODE=public). Calls the Foundry account with a valid AND authorized Entra token
# (the test grants the VM identity a temporary role); the firewall must reject it with HTTP 403.
# Note: authorization is evaluated before the IP firewall - an unauthorized token gets 401, which proves
# nothing about the network. __ACCOUNT__ / __DEPLOYMENT__ are substituted by Test-Deployment.ps1.
$ProgressPreference = 'SilentlyContinue'
$egress = try { Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 10 } catch { 'unknown' }
$body = Join-Path $env:TEMP 'outsider-body.json'
Set-Content $body '{"model":"__DEPLOYMENT__","input":"Reply OK","max_output_tokens":16}'
$last = ''
foreach ($i in 1..10) {
    $tok = (Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fcognitiveservices.azure.com' -Headers @{ Metadata = 'true' }).access_token
    $last = & curl.exe -s -m 60 -w " HTTP=%{http_code}" -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' --data "@$body" 'https://__ACCOUNT__.openai.azure.com/openai/v1/responses'
    if ($last -notmatch 'PermissionDenied') { break }   # wait for the temporary role assignment to propagate
    Start-Sleep -Seconds 30
}
"OUTSIDER $egress $($last -replace '\s+', ' ')"
