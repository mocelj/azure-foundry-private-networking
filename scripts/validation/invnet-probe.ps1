# In-VNet functional probe. Executed ON THE JUMPBOX via Azure VM Run Command (management plane), so
# it needs no RDP session. Placeholders (__X__) are substituted by Test-Deployment.ps1.
# Authenticates with the jumpbox system-assigned managed identity via IMDS (no secrets).
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$cfg = @{
    Account     = '__ACCOUNT__'
    ProjectEp   = '__PROJECT_ENDPOINT__'
    Deployment  = '__DEPLOYMENT__'
    PePrefix    = '__PE_PREFIX__'
    ExtraHosts  = '__EXTRA_HOSTS__'
    RunAgent    = '__RUN_AGENT__'
    KbSearch    = '__KB_SEARCH__'
    KbIndex     = '__KB_INDEX__'
    KbName      = '__KB_NAME__'
    KbReasoning = '__KB_REASONING__'
    RagUrl      = '__RAG_URL__'
    DemoAgent   = '__DEMO_AGENT__'
    IqAgent     = '__IQ_AGENT__'
    AppiId      = '__APPI_ID__'
    WorkspaceId = '__WORKSPACE_ID__'
    MonitorPrefix = '__MONITOR_PREFIX__'
}
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result($cat, $name, $ok, $detail) { $d = "$detail"; if ($d.Length -gt 220) { $d = $d.Substring(0, 220) }; $results.Add([ordered]@{ c = $cat; n = $name; r = $(if ($ok) { 'PASS' } else { 'FAIL' }); d = $d }) }

function Test-InPrefix([string]$ip, [string]$cidr) {
    $parts = $cidr.Split('/'); $bits = [int]$parts[1]
    $toInt = { param($a) $b = ([Net.IPAddress]::Parse($a)).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
    $mask = if ($bits -eq 0) { 0 } else { [uint32]::MaxValue -shl (32 - $bits) }
    return ((& $toInt $ip) -band $mask) -eq ((& $toInt $parts[0]) -band $mask)
}

function Get-MiToken([string]$resource) {
    $u = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=$([uri]::EscapeDataString($resource))"
    (Invoke-RestMethod -Uri $u -Headers @{ Metadata = 'true' } -TimeoutSec 30).access_token
}

function Invoke-Api([string]$method, [string]$uri, [string]$token, $body) {
    $h = @{ Authorization = "Bearer $token" }
    try {
        $p = @{ Method = $method; Uri = $uri; Headers = $h; TimeoutSec = 300; ContentType = 'application/json' }
        if ($body) { $p.Body = ($body | ConvertTo-Json -Depth 10 -Compress) }
        $resp = Invoke-WebRequest @p -UseBasicParsing
        return @{ status = [int]$resp.StatusCode; body = $resp.Content }
    } catch {
        $code = 0; $content = $_.Exception.Message
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($_.ErrorDetails.Message) { $content = $_.ErrorDetails.Message }
        return @{ status = $code; body = $content }
    }
}

# --- DNS + TCP: every private endpoint FQDN must resolve to an IP inside the PE subnet -------------
$hosts = @("$($cfg.Account).openai.azure.com", "$($cfg.Account).services.ai.azure.com", "$($cfg.Account).cognitiveservices.azure.com")
$hosts += $cfg.ExtraHosts.Split(',') | Where-Object { $_ }
foreach ($h in $hosts) {
    try {
        $ips = @(Resolve-DnsName -Name $h -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object IPAddress)
        $chain = (Resolve-DnsName -Name $h -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'CNAME' } | ForEach-Object NameHost) -join ' -> '
        $private = $ips.Count -gt 0 -and -not ($ips | Where-Object { -not (Test-InPrefix $_ $cfg.PePrefix) })
        Add-Result 'dns' $h $private "A=$($ips -join ',') via $chain"
        if ($ips) {
            $tcp = Test-NetConnection -ComputerName $ips[0] -Port 443 -WarningAction SilentlyContinue
            Add-Result 'tcp443' $h $tcp.TcpTestSucceeded "$($ips[0]):443"
        }
    } catch { Add-Result 'dns' $h $false $_.Exception.Message }
}

# --- Model inference through the private endpoint with Entra (managed identity) --------------------
try {
    $tok = Get-MiToken 'https://cognitiveservices.azure.com'
    Add-Result 'identity' 'managed identity token (cognitiveservices)' ([bool]$tok) 'IMDS'
    $r = Invoke-Api POST "https://$($cfg.Account).openai.azure.com/openai/v1/responses" $tok @{ model = $cfg.Deployment; input = 'Reply with exactly the text PRIVATE-OK and nothing else.'; max_output_tokens = 64 }
    $text = ''
    if ($r.status -eq 200) { $j = $r.body | ConvertFrom-Json; $text = (($j.output | Where-Object type -eq 'message').content | Where-Object type -eq 'output_text').text -join '' }
    Add-Result 'inference' 'responses API via private endpoint (Entra MI)' ($r.status -eq 200 -and $text -match 'PRIVATE-OK') "HTTP $($r.status) text='$text' $(if($r.status -ne 200){$r.body.Substring(0,[Math]::Min(300,$r.body.Length))})"
} catch { Add-Result 'inference' 'responses API via private endpoint (Entra MI)' $false $_.Exception.Message }

# --- Foundry project data plane --------------------------------------------------------------------
try {
    $atok = Get-MiToken 'https://ai.azure.com'
    $r = Invoke-Api GET "$($cfg.ProjectEp)/deployments?api-version=v1" $atok $null
    Add-Result 'project' 'list project deployments' ($r.status -eq 200 -and $r.body -match [regex]::Escape($cfg.Deployment)) "HTTP $($r.status)"

    if ($cfg.RunAgent -eq 'true') {
        $agentName = 'private-validation-agent'
        $def = @{ definition = @{ kind = 'prompt'; model = $cfg.Deployment; instructions = 'You are a validation agent. Answer with exactly AGENT-PRIVATE-OK.' } }
        $r = $null
        foreach ($attempt in 1..3) {
            $r = Invoke-Api POST "$($cfg.ProjectEp)/agents/$agentName/versions?api-version=v1" $atok $def
            if ($r.status -in 200, 201) { break }
            Start-Sleep -Seconds 20
        }
        Add-Result 'agent' 'create agent version (Standard setup)' ($r.status -in 200, 201) "HTTP $($r.status) $(if($r.status -notin 200,201){$r.body.Substring(0,[Math]::Min(400,$r.body.Length))})"

        $r = Invoke-Api POST "$($cfg.ProjectEp)/openai/v1/conversations" $atok @{ metadata = @{ purpose = 'private-validation' } }
        $convId = if ($r.status -eq 200) { ($r.body | ConvertFrom-Json).id } else { $null }
        Add-Result 'agent' 'create conversation (thread store in BYO Cosmos DB)' ([bool]$convId) "HTTP $($r.status) id=$convId $(if(-not $convId){$r.body.Substring(0,[Math]::Min(400,$r.body.Length))})"

        $body = @{ agent_reference = @{ name = $agentName; type = 'agent_reference' }; input = 'Validation ping'; conversation = $convId }
        if (-not $convId) { $body.Remove('conversation') }
        $r = Invoke-Api POST "$($cfg.ProjectEp)/openai/v1/responses" $atok $body
        $text = ''
        if ($r.status -eq 200) { $j = $r.body | ConvertFrom-Json; $text = (($j.output | Where-Object type -eq 'message').content | Where-Object type -eq 'output_text').text -join '' }
        Add-Result 'agent' 'run agent (VNet-injected runtime)' ($r.status -eq 200 -and $text -match 'AGENT-PRIVATE-OK') "HTTP $($r.status) text='$text' $(if($r.status -ne 200){$r.body.Substring(0,[Math]::Min(400,$r.body.Length))})"
    }
} catch { Add-Result 'project' 'project data plane' $false $_.Exception.Message }

# --- Optional: demo agent grounded on the private knowledge index (Azure AI Search tool) ----------
if ($cfg.DemoAgent -and $cfg.DemoAgent -notlike '__*') {
try {
    $atok = Get-MiToken 'https://ai.azure.com'
    $body = @{ agent_reference = @{ name = $cfg.DemoAgent; type = 'agent_reference' }; input = 'What is the hotel limit per night in major European cities?' }
    $r = Invoke-Api POST "$($cfg.ProjectEp)/openai/v1/responses" $atok $body
    $types = @(); $titles = @(); $text = ''
    if ($r.status -eq 200) {
        $j = $r.body | ConvertFrom-Json
        $types = @($j.output | ForEach-Object type)
        $msg = $j.output | Where-Object type -eq 'message'
        $text = ($msg.content | Where-Object type -eq 'output_text').text -join ''
        $titles = @($msg.content.annotations | Where-Object type -eq 'url_citation' | ForEach-Object title)
    }
    Add-Result 'agent' 'demo agent called Azure AI Search tool (private index)' ($types -contains 'azure_ai_search_call') "HTTP $($r.status) items=$($types -join ',')"
    Add-Result 'agent' 'demo agent grounded answer (220 EUR, cites Expense reimbursement)' ($text -match '220' -and $titles -contains 'Expense reimbursement') "citations=$($titles -join ';') text=$text"
    if ($cfg.RagUrl -and $cfg.RagUrl -notlike '__*') {
        # Citation links point to the private document page of the RAG app (index field url, searchable).
        $urls = @($msg.content.annotations | Where-Object type -eq 'url_citation' | ForEach-Object url)
        $docUrl = $urls | Where-Object { $_ -like "$($cfg.RagUrl.TrimEnd('/'))/docs/*" } | Select-Object -First 1
        $code = if ($docUrl) { & curl.exe -sk -m 20 -o NUL -w '%{http_code}' $docUrl } else { '' }
        Add-Result 'agent' 'citation links to the private document page (opens from this client)' ($docUrl -and $code -eq '200') "url=$($urls -join ',') HTTP $code"
    }
} catch { Add-Result 'agent' 'demo agent' $false $_.Exception.Message }
}

# --- Optional: Foundry IQ agent (knowledge base MCP endpoint over the private Search endpoint) -------
if ($cfg.IqAgent -and $cfg.IqAgent -notlike '__*') {
try {
    $atok = Get-MiToken 'https://ai.azure.com'
    $body = @{ agent_reference = @{ name = $cfg.IqAgent; type = 'agent_reference' }; input = 'What is the hotel limit per night in major European cities?' }
    $r = Invoke-Api POST "$($cfg.ProjectEp)/openai/v1/responses" $atok $body
    $calls = @(); $text = ''
    if ($r.status -eq 200) {
        $j = $r.body | ConvertFrom-Json
        $calls = @($j.output | Where-Object type -eq 'mcp_call' | ForEach-Object { "$($_.name):$(if ($_.error) { 'error' } else { 'ok' })" })
        $text = (($j.output | Where-Object type -eq 'message').content | Where-Object type -eq 'output_text').text -join ''
    }
    Add-Result 'foundry-iq' 'agent called knowledge_base_retrieve (MCP, private Search endpoint)' ($calls -contains 'knowledge_base_retrieve:ok') "HTTP $($r.status) calls=$($calls -join ',')"
    Add-Result 'foundry-iq' 'grounded answer from the knowledge base (220 EUR)' ($text -match '220') "text=$text"
} catch { Add-Result 'foundry-iq' 'Foundry IQ agent' $false $_.Exception.Message }
}

# --- Optional: Foundry IQ query planning (option A+): Search -> model over the approved shared private link
if ($cfg.KbReasoning -in 'low', 'medium') {
try {
    $stok = Get-MiToken 'https://search.azure.com'
    $body = @{ messages = @(@{ role = 'user'; content = @(@{ type = 'text'; text = 'What is the hotel limit per night in major European cities, and can I book business class for a 5 hour flight?' }) }); retrievalReasoningEffort = @{ kind = $cfg.KbReasoning }; outputMode = 'extractiveData'; includeActivity = $true }
    $r = Invoke-Api POST "https://$($cfg.KbSearch).search.windows.net/knowledgebases('$($cfg.KbName)')/retrieve?api-version=2026-10-01" $stok $body
    $plan = $null; $refs = 0
    if ($r.status -eq 200) { $j = $r.body | ConvertFrom-Json; $plan = @($j.activity | Where-Object type -eq 'modelQueryPlanning'); $refs = @($j.references).Count }
    Add-Result 'foundry-iq' "knowledge base query planning ($($cfg.KbReasoning)): Search called the model over the shared private link" ($r.status -eq 200 -and $plan.Count -ge 1 -and $refs -ge 1) "HTTP $($r.status) planningTokens=$($plan[0].inputTokens) refs=$refs $(if ($r.status -ne 200) { $r.body })"
} catch { Add-Result 'foundry-iq' 'knowledge base query planning' $false $_.Exception.Message }
}

# --- Optional: private knowledge search query (Entra MI, Search Index Data Reader/Contributor) -------
if ($cfg.KbSearch -and $cfg.KbSearch -notlike '__*') {
    try {
        $stok = Get-MiToken 'https://search.azure.com'
        $q = @{ search = 'Bastion public IP remote access'; top = 1; select = 'id,title' }
        $r = Invoke-Api POST "https://$($cfg.KbSearch).search.windows.net/indexes/$($cfg.KbIndex)/docs/search?api-version=2024-07-01" $stok $q
        $top = if ($r.status -eq 200) { ($r.body | ConvertFrom-Json).value[0] } else { $null }
        Add-Result 'search' 'knowledge index query via private endpoint (Entra MI)' ($r.status -eq 200 -and $top.id -eq 'pol-003') "HTTP $($r.status) top=$($top.id) $($top.title)"
    } catch { Add-Result 'search' 'knowledge index query via private endpoint (Entra MI)' $false $_.Exception.Message }
}

# --- Optional: private RAG app (VM in snet-app). Self-signed demo cert => curl.exe -k for this call only
# (.NET Framework scriptblock cert callbacks are unreliable on worker threads under Windows PowerShell 5.1).
if ($cfg.RagUrl -and $cfg.RagUrl -notlike '__*') {
    try {
        $u = $cfg.RagUrl.TrimEnd('/')
        $code = & curl.exe -sk -m 20 -o NUL -w '%{http_code}' "$u/healthz"
        Add-Result 'rag' 'RAG app health over private network' ($code -eq '200') "$u/healthz HTTP $code"
        $reqFile = Join-Path $env:TEMP 'rag-req.json'; $respFile = Join-Path $env:TEMP 'rag-resp.json'
        [IO.File]::WriteAllText($reqFile, '{"question":"How do administrators access cloud workloads remotely?"}')
        $code = & curl.exe -sk -m 120 -o $respFile -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "@$reqFile" "$u/api/ask"
        $j = Get-Content $respFile -Raw | ConvertFrom-Json
        $ids = @($j.sources | ForEach-Object id)
        Add-Result 'rag' 'RAG answer grounded in private index (pol-003 cited)' ($code -eq '200' -and $ids -contains 'pol-003' -and $j.answer) "HTTP $code sources=$($ids -join ',') answer=$($j.answer)"
    } catch { Add-Result 'rag' 'RAG app over private network' $false $_.Exception.Message }
}

# --- Optional: agent traces stored in the private Application Insights (query over AMPLS) ---------
if ($cfg.AppiId -and $cfg.AppiId -notlike '__*') {
    try {
        $ips = @(Resolve-DnsName -Name 'api.loganalytics.io' -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object IPAddress)
        $monPrefix = if ($cfg.MonitorPrefix -and $cfg.MonitorPrefix -notlike '__*') { $cfg.MonitorPrefix } else { $cfg.PePrefix }
        Add-Result 'monitor' 'api.loganalytics.io resolves to the AMPLS private endpoint' ($ips.Count -gt 0 -and -not ($ips | Where-Object { -not (Test-InPrefix $_ $monPrefix) })) "A=$($ips -join ',') expected in $monPrefix"
        $ltok = Get-MiToken 'https://api.loganalytics.io'
        $agentFilter = if ($cfg.DemoAgent -and $cfg.DemoAgent -notlike '__*') { $cfg.DemoAgent } else { 'private-validation-agent' }
        # Resource-centric queries on the App Insights component use the classic schema (dependencies, customDimensions).
        $kql = "dependencies | where timestamp > ago(3h) | where tostring(customDimensions['gen_ai.agent.name']) == '$agentFilter' or (tostring(customDimensions['gen_ai.agent.id']) startswith '$($agentFilter):') | summarize n = count(), names = make_set(name, 10)"
        $found = $null; $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline) {
            $r = Invoke-Api POST "https://api.loganalytics.io/v1$($cfg.AppiId)/query" $ltok @{ query = $kql }
            if ($r.status -eq 200) {
                $row = ($r.body | ConvertFrom-Json).tables[0].rows[0]
                if ($row -and [int]$row[0] -gt 0) { $found = $row; break }
            } else { $found = @(-1, "HTTP $($r.status) $($r.body.Substring(0, [Math]::Min(200, $r.body.Length)))"); break }
            Start-Sleep -Seconds 30
        }
        Add-Result 'monitor' "server-side agent traces stored in App Insights ($agentFilter)" ($found -and [int]$found[0] -gt 0 -and "$($found[1])" -match 'invoke_agent') $(if ($found) { "rows=$($found[0]) names=$($found[1])" } else { 'no spans within 10 min' })
        if ($agentFilter -eq $cfg.DemoAgent) {
            Add-Result 'monitor' 'trace includes the Azure AI Search tool span (execute_tool)' ($found -and "$($found[1])" -match 'execute_tool .*azure_ai_search') "names=$(if ($found) { $found[1] })"
        }
        if ($cfg.WorkspaceId -and $cfg.WorkspaceId -notlike '__*') {
            # Diagnostic settings use the Azure backbone, so they must keep flowing although the
            # workspace's public ingestion is disabled.
            # First records after a fresh deployment can take several minutes: poll up to 10 min.
            $row = $null; $deadline = (Get-Date).AddMinutes(10)
            do {
                $r = Invoke-Api POST "https://api.loganalytics.io/v1/workspaces/$($cfg.WorkspaceId)/query" $ltok @{ query = "union AzureDiagnostics, AzureMetrics | where TimeGenerated > ago(6h) and ResourceProvider == 'MICROSOFT.COGNITIVESERVICES' | summarize n = count(), lastSeen = max(TimeGenerated)" }
                $row = if ($r.status -eq 200) { ($r.body | ConvertFrom-Json).tables[0].rows[0] } else { $null }
                if ($row -and [int]$row[0] -gt 0) { break }
                Start-Sleep -Seconds 30
            } while ((Get-Date) -lt $deadline)
            Add-Result 'monitor' 'Foundry resource logs/metrics reach Log Analytics (public ingestion disabled)' ($row -and [int]$row[0] -gt 0) $(if ($row) { "rows=$($row[0]) lastSeen=$($row[1])" } else { "HTTP $($r.status)" })
        }
    } catch { Add-Result 'monitor' 'agent traces in App Insights' $false $_.Exception.Message }
}

# Run Command returns only ~4 KB of output: emit the results gzip-compressed + base64.
$json = $results | ConvertTo-Json -Compress -Depth 4
$ms = [IO.MemoryStream]::new(); $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
$bytes = [Text.Encoding]::UTF8.GetBytes($json); $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
'RESULT_GZ:' + [Convert]::ToBase64String($ms.ToArray())
