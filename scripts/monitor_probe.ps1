#Requires -Version 5.1
# monitor_probe.ps1 - BEZAHLTE Einmal-Probe des Monitors (Owner-Fenster): echter Web-Wert bis Mock-Telegram (mp01), Nachrichten-Spike
# mit allowed_callers direct (mp04/mp02/mp03, direkter API-Weg ohne Produktionsknoten) und me04 (Agent legt Web-Waechter an) als
# Kindprozess. Misst Suchen, Tokens und Dollar je Fall. Die Grenze steht hier, weil der Hook nur Aufrufe durch Claude abfaengt:
# Summe bisher + Obergrenze des naechsten Falls > 0,95 $, Modell ohne Preis, Gateway nicht auf real oder Telegram nicht auf Mock -> Abbruch.
# Rohantworten nur in .local/monitor_probe/<zeit>/ (gitignored), Summe ueber Wiederholungen in .local/monitor_probe/kosten.json.
#
# Voraussetzung: Substrat, enable_mock_llm.ps1 -Down, enable_mock_telegram.ps1 aktiv, ANTHROPIC_API_KEY in .env.
# Usage:  $env:N8NTEST_CONTAINER='..'; $env:N8NTEST_PORT='..'; .\scripts\monitor_probe.ps1 [-Id mp01]
# Exit-Code = Anzahl roter Faelle; Abbruch durch die Geldgrenze zaehlt als 1.
param([string[]]$Id, [decimal]$Limit = 0.95, [int]$Timeout = 240)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\lib\dotenv.ps1"
Read-DotEnvLines (Join-Path $RepoRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') { Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script }
}
. "$PSScriptRoot\dev\test_n8n_state.ps1"
if ([string]::IsNullOrEmpty($ANTHROPIC_API_KEY)) { throw 'ANTHROPIC_API_KEY fehlt in .env.' }
$conn = Get-TestN8nConnection; $N8nUrl = $conn.Url; $ApiKey = $conn.ApiKey; $Container = $conn.Container
$state = Get-TestN8nState
if (-not $state.mock_telegram) { throw 'Mock-Telegram nicht aktiv: mp01 saendete sonst ueber den echten Test-Bot.' }
Assert-LlmGatewayUpstream -Container $Container -Expect real

$Dir = Join-Path $RepoRoot '.local\monitor_probe'; [void][IO.Directory]::CreateDirectory($Dir)
$RunDir = Join-Path $Dir (Get-Date -Format 'yyyyMMdd-HHmmss'); [void][IO.Directory]::CreateDirectory($RunDir)
$CostFile = Join-Path $Dir 'kosten.json'
$Ledger = if (Test-Path $CostFile) { [IO.File]::ReadAllText($CostFile, $Utf8NoBom) | ConvertFrom-Json } else { [pscustomobject]@{ total_usd = 0.0; runs = @() } }
$Prices = Get-LlmPriceTable -RepoRoot $RepoRoot
$AllCases = [IO.File]::ReadAllText((Join-Path $RepoRoot 'tests\agent\core\monitor_probe_cases.json'), $Utf8NoBom) | ConvertFrom-Json
$Cases = @($AllCases | Where-Object { -not $Id -or (@($Id | ForEach-Object { $_ -split ',' }) -contains $_.id) })

function Save-Ledger { [IO.File]::WriteAllText($CostFile, ($Ledger | ConvertTo-Json -Depth 6), $Utf8NoBom) }
function Add-Cost([string]$CaseId, [double]$Usd, $Detail) {
    $Ledger.total_usd = [double]$Ledger.total_usd + $Usd
    $Ledger.runs = @($Ledger.runs) + @([pscustomobject]@{ t = (Get-Date).ToUniversalTime().ToString('o'); id = $CaseId; usd = [Math]::Round($Usd, 4); detail = $Detail })
    Save-Ledger
}
function Get-ModelId([string]$Tier) {
    $m = @($Prices.Keys | Where-Object { $_ -match $Tier } | Sort-Object -Descending | Select-Object -First 1)
    if (-not $m -or -not $m[0]) { throw "Modell $Tier ohne Preis in ai_models.json: Abbruch vor dem Aufruf." }
    return [string]$m[0]
}
function Invoke-Sql([string]$Sql) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "monpaid_$([guid]::NewGuid().ToString('N')).sql"
    try { [IO.File]::WriteAllText($tmp, $Sql, $Utf8NoBom); $r = Invoke-TestN8nPsqlFile -Container $Container -HostFile $tmp -PsqlArgs @('-q', '-tA') }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    if ($r.Code -ne 0) { throw "SQL fehlgeschlagen: $($r.Output -join "`n")" }
    return ((@($r.Output) | ForEach-Object { "$_" }) -join "`n").Trim()
}
function Measure-Gateway([string]$Cursor) {
    $rows = @(Get-LlmUsage -Container $Container -AfterCursor $Cursor)
    $usd = 0.0; $tok = 0; $web = 0
    foreach ($r in $rows) {
        $c = Get-LlmRequestCost -Row $r -Prices $Prices
        if (-not $c) { throw "Modell $($r.model) ohne Preis: Abbruch." }
        $usd += $c.Cost; $tok += [int]$r.input_tokens + [int]$r.cache_creation_input_tokens + [int]$r.cache_read_input_tokens + [int]$r.output_tokens; $web += [int]$r.web_search_requests
    }
    return [pscustomobject]@{ Usd = $usd; Tokens = $tok; Searches = $web; Requests = $rows.Count }
}
function Invoke-CronCase($Case) {
    Invoke-Sql "SELECT agent.fn_clear_e2e_data();" | Out-Null
    Invoke-Sql "INSERT INTO core.config (package,category,key,value) VALUES ('core','general','reminders_from','0'),('core','general','reminders_until','24') ON CONFLICT (category,key) DO UPDATE SET value=excluded.value;" | Out-Null
    $prompt = ([string]$Case.prompt).Replace("'", "''")
    $t = Invoke-Sql "INSERT INTO agent.monitor_triggers (domain,label,trigger_type,acquisition_method,acquisition_spec,comparator,threshold_value,expected_unit,check_interval,next_check_at) VALUES ('__e2e_monitor__','__E2E__ $($Case.id)','threshold','web_search',jsonb_build_object('prompt','$prompt'),'gte',$($Case.threshold),'$($Case.unit)',interval '12 hours',now()) RETURNING id;"
    Clear-MockTelegramRequests -Container $Container
    $wf = (Invoke-RestMethod -Uri "$N8nUrl/api/v1/workflows?limit=250" -Headers @{ 'X-N8N-API-KEY' = $ApiKey } -Method Get).data | Where-Object { $_.name -eq 'agent.monitor.cron_check_triggers' } | Select-Object -First 1
    while ((Get-Date).Minute -in @(9, 10, 11)) { Start-Sleep -Seconds 5 }
    $base = Get-MaxExecId -WfId $wf.id -BridgeUrl $N8nUrl -ApiKey $ApiKey
    $cur = Get-LlmUsageCursor -Container $Container
    Start-TestCron -BridgeUrl $N8nUrl -Secret $TEST_HARNESS_SECRET -WorkflowId $wf.id | Out-Null
    $until = (Get-Date).AddSeconds($Timeout); $x = $null
    while ((Get-Date) -lt $until -and -not $x) {
        $l = @((Invoke-RestMethod -Uri "$N8nUrl/api/v1/executions?workflowId=$($wf.id)&limit=3" -Headers @{ 'X-N8N-API-KEY' = $ApiKey } -Method Get).data | Where-Object { [int]$_.id -gt $base -and $_.stoppedAt })
        if ($l.Count) { $x = Get-ExecDetail ([string]$l[0].id) } else { Start-Sleep -Seconds 2 }
    }
    if (-not $x) { throw 'Keine Ausfuehrung des Crons.' }
    Start-Sleep -Seconds 3
    $m = Measure-Gateway $cur
    $raw = $x.data.resultData.runData.'Acquire web value' | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText((Join-Path $RunDir "$($Case.id).json"), $raw, $Utf8NoBom)
    $ok = Invoke-Sql "SELECT ok::text || '|' || COALESCE(value::text,'') || '|' || COALESCE(reason,'') FROM agent.monitor_observations WHERE trigger_id=$t ORDER BY id DESC LIMIT 1;"
    $status = Invoke-Sql "SELECT status FROM agent.monitor_triggers WHERE id=$t;"
    $sends = @(Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'sendMessage' }).Count
    Invoke-Sql "SELECT agent.fn_clear_e2e_data();" | Out-Null
    $pass = ($x.status -eq 'success') -and ($status -eq 'fired') -and ($sends -eq 1)
    return [pscustomobject]@{ Pass = $pass; Usd = $m.Usd; Tokens = $m.Tokens; Searches = $m.Searches; Finding = "exec=$($x.status) status=$status sends=$sends obs=$ok" }
}
function Invoke-NewsCase($Case) {
    $model = Get-ModelId ([string]$Case.model)
    $body = [ordered]@{
        model = $model; max_tokens = 6000; system = [string]$Case.system
        messages = @(@{ role = 'user'; content = [string]$Case.prompt })
        tools = @(@{ type = 'web_search_20260209'; name = 'web_search'; max_uses = [int]$Case.max_searches; allowed_callers = @('direct') })
    }
    if ($Case.structured) { $body.output_config = @{ format = @{ type = 'json_schema'; schema = $Case.schema } } }
    $json = $body | ConvertTo-Json -Depth 30
    try {
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -TimeoutSec $Timeout -ContentType 'application/json; charset=utf-8' `
            -Headers @{ 'x-api-key' = $ANTHROPIC_API_KEY; 'anthropic-version' = '2023-06-01' } -Body ([Text.Encoding]::UTF8.GetBytes($json))
    } catch {
        $msg = $_.ErrorDetails.Message; if (-not $msg) { $msg = $_.Exception.Message }
        [IO.File]::WriteAllText((Join-Path $RunDir "$($Case.id).error.txt"), [string]$msg, $Utf8NoBom)
        $rejected = $Case.structured -and ([string]$msg -match 'output_config|format')
        return [pscustomobject]@{ Pass = [bool]$rejected; Usd = 0.0; Tokens = 0; Searches = 0; Finding = "API-Ablehnung: $(([string]$msg).Substring(0, [Math]::Min(160, ([string]$msg).Length)))" }
    }
    [IO.File]::WriteAllText((Join-Path $RunDir "$($Case.id).json"), ($r | ConvertTo-Json -Depth 30), $Utf8NoBom)
    $hits = @(); foreach ($b in @($r.content)) { if ($b.type -eq 'web_search_tool_result') { $hits += @($b.content | Where-Object { $_.url }) } }
    $withAge = @($hits | Where-Object { $_.page_age }).Count
    $text = (@($r.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ')
    $cited = @([regex]::Matches($text, 'https?://[^\s")\]]+') | ForEach-Object { $_.Value.TrimEnd('.', ',') } | Select-Object -Unique)
    $urls = @($hits | ForEach-Object { [string]$_.url })
    $unknown = @($cited | Where-Object { $urls -notcontains $_ })
    $u = $r.usage
    $row = [pscustomobject]@{ model = $model; input_tokens = $u.input_tokens; cache_creation_input_tokens = [int]$u.cache_creation_input_tokens; cache_read_input_tokens = [int]$u.cache_read_input_tokens
        output_tokens = $u.output_tokens; ephemeral_1h_input_tokens = 0; web_search_requests = [int]$u.server_tool_use.web_search_requests }
    $c = Get-LlmRequestCost -Row $row -Prices $Prices
    if (-not $c) { throw "Modell $model ohne Preis." }
    $pct = if ($hits.Count) { [Math]::Round(100 * $withAge / $hits.Count, 1) } else { 0 }
    return [pscustomobject]@{ Pass = ($hits.Count -gt 0); Usd = $c.Cost; Tokens = ([int]$u.input_tokens + [int]$u.output_tokens); Searches = $row.web_search_requests
        Finding = "treffer=$($hits.Count) page_age=$withAge ($pct %) quellen_genannt=$($cited.Count) nicht_in_rohdaten=$($unknown.Count) stop=$($r.stop_reason)" }
}
function Invoke-E2eCase($Case) {
    $cur = Get-LlmUsageCursor -Container $Container
    $suite = Join-Path $PSScriptRoot 'e2e_test.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $suite -Id $Case.e2e_id -TargetWorkflow agent.monitor -WebhookPath monitor-test -CasesFile 'tests\agent\core\monitor_e2e_cases.json' | Tee-Object -FilePath (Join-Path $RunDir "$($Case.id).log") | Out-Host
    $code = $LASTEXITCODE
    $m = Measure-Gateway $cur
    return [pscustomobject]@{ Pass = ($code -eq 0); Usd = $m.Usd; Tokens = $m.Tokens; Searches = $m.Searches; Finding = "exit=$code" }
}

$failed = 0
foreach ($c in $Cases) {
    if (([decimal]$Ledger.total_usd + [decimal]$c.cap_usd) -gt $Limit) {
        Write-Host "ABBRUCH vor $($c.id): bisher $([Math]::Round([double]$Ledger.total_usd,3)) $ + Obergrenze $($c.cap_usd) $ > $Limit $." -ForegroundColor Red
        $failed++; break
    }
    Assert-LlmGatewayUpstream -Container $Container -Expect real
    Write-Host "[$($c.id)] $($c.name)" -ForegroundColor Cyan
    try {
        $res = switch ([string]$c.kind) { 'cron' { Invoke-CronCase $c } 'news' { Invoke-NewsCase $c } 'e2e' { Invoke-E2eCase $c } default { throw "Unbekannte Art $($c.kind)" } }
        Add-Cost $c.id $res.Usd $res.Finding
        $color = if ($res.Pass) { 'Green' } else { 'Red' }
        Write-Host ("    Suchen {0} | Tokens {1:N0} | {2:N3} $ | {3}" -f $res.Searches, $res.Tokens, $res.Usd, $res.Finding) -ForegroundColor $color
        if (-not $res.Pass) { $failed++ }
    } catch {
        $failed++
        # Der Abbruch kann nach dem bezahlten Aufruf liegen: zaehlt zur Sicherheit voll zur Summe, sonst ueberlaeuft die Grenze bei Wiederholungen.
        Add-Cost $c.id ([double]$c.cap_usd) "abgebrochen: $($_.Exception.Message)"
        Write-Host "    [FAIL] $($_.Exception.Message) (Obergrenze des Falls verbucht)" -ForegroundColor Red
    }
}
Write-Host ("Summe gesamt: {0:N3} $ (Grenze {1} $), {2} rot. Rohdaten: {3}" -f [double]$Ledger.total_usd, $Limit, $failed, $RunDir)
exit $failed