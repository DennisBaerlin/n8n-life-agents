#Requires -Version 5.1
# Infra Sub-Workflow Tests (Tier 4).
# Prueft Cross-Cutting-Sub-Workflows direkt und isoliert (Faelle: tests/agent/core/infra_cases.json):
#   agent.tool_load_context     -- Static + Lazy-Manifest Assembly (include_manifest-Flag)
#   core.sub_load_config        -- Config-Store-Read + Pivot (model-Objekt befuellt)
# Das HITL-Gate (agent.tool_human_approval) wird seit Teststrategie Phase 8 (Weg C) NICHT mehr hier
# geprueft (kein Test-Bypass mehr) -> Approve/Decline deckt scripts\dev\hitl_gate_test.ps1 ab (echtes
# Send-and-Wait ueber Mock-Telegram). Depth-Gates (ic08/11/12) + web_search/expert_panel-Guards bleiben.
#
# Jeder Test laeuft ueber einen dedizierten Harness-Webhook (build.ps1 -Only '*test_harness*' -> bootstrap_test_n8n.ps1 -Reset).
# Das Skript pollt die Ziel-Execution (seperater Datensatz, wie bei orch_test.ps1) und
# pruefte den Ausgabewert eines bestimmten Nodes.
#
# Assertions je Case: must_be_nonempty / must_contain / must_not_contain / must_equal.
# Optional je Case: requires = Name eines State-Blocks (z. B. 'mock_paperless'; Punkt-Pfad 'mock_llm.cred_id' = Feld darin muss
#   gesetzt sein) oder eine Liste davon, ohne die der Case mit klarem
#   Hinweis FAILt (statt gegen eine fehlende Attrappe zu laufen); der Body-Platzhalter __OWNER_CHAT_ID__ pairt den
#   Substrat-Owner deterministisch (Set-OwnerTelegramPairing, uid $TestOwnerTelegramUid wie mock_route_test) und setzt die uid ein —
#   fuer Pfade, die einen AUFGELOESTEN Haushalts-Absender brauchen (agent.sub_dispatch_tool: core.fn_resolve_service
#   ist fail-closed fuer unbekannte Absender).
#
# Usage:  .\scripts\infra_test.ps1 [-Id ic01] [-Timeout 30] [-Verbose]
# Exit-Code = Anzahl Fehler.
# Voraussetzungen: Harnesses aktiv (build.ps1 -Only '*test_harness*' -> bootstrap_test_n8n.ps1 -Reset);
#   .env mit TEST_HARNESS_SECRET.
param(
    [string]$Id,
    [int]$Timeout = 30,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

Get-Content "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') { Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script }
}
# N8N_URL/N8N_API_KEY kommen aus dem ephemeren Docker-Test-Substrat (raus aus Prod), nicht aus .env.
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn        = Get-TestN8nConnection
$N8N_URL     = $conn.Url
$N8N_API_KEY = $conn.ApiKey
if ([string]::IsNullOrEmpty($TEST_HARNESS_SECRET)) { throw "TEST_HARNESS_SECRET ist nicht gesetzt in .env" }
$Headers    = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }
$AuthHeader = 'X-Test-Auth'

function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8N_URL/api/v1/$Path" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) {
    try { Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
}
function Get-ExecDetail([string]$ExecId) { Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId`?includeData=true" -Headers $Headers -Method Get }

function Find-Exec([string]$WfId, [datetime]$Since) {
    $all = @()
    foreach ($st in @('', 'waiting', 'running')) {
        $url = "executions?workflowId=$WfId&limit=10"; if ($st) { $url += "&status=$st" }
        try { $all += (Invoke-N8nGet $url).data } catch { }
    }
    $all | Where-Object { try { ([datetime]$_.startedAt).ToUniversalTime() -ge $Since.AddSeconds(-10) } catch { $false } } |
        Sort-Object { ([datetime]$_.startedAt).ToUniversalTime() } -Descending | Select-Object -First 1
}

function Get-FieldValue([object]$RunData, [string]$NodeName, [string]$FieldPath) {
    try {
        if (-not $RunData.PSObject.Properties.Name.Contains($NodeName)) { return $null }
        $obj = $RunData.$NodeName[0].data.main[0][0].json
        foreach ($seg in $FieldPath -split '\.') {   # ein rein numerisches Segment indiziert ein Array (opinions.0.model)
            if ($null -eq $obj) { return $null }
            if ($seg -match '^\d+$' -and $obj -is [array]) { $obj = if ([int]$seg -lt $obj.Count) { $obj[[int]$seg] } else { $null } }
            else { $obj = $obj.$seg }
        }
        return $obj
    } catch { return $null }
}

# --- Setup ---
Write-Host "Suche Workflows ..."
$wfList = Invoke-N8nGet 'workflows?limit=200'
$wfMap  = @{}
foreach ($wf in $wfList.data) { $wfMap[$wf.name] = $wf.id }

$PairedOwnerUid = $TestOwnerTelegramUid   # gepairter Fixture-Owner-Sender (scripts/dev/test_n8n_state.ps1)
$stateFile = Get-TestN8nStateFile
$substrateState = if (Test-Path $stateFile) { [System.IO.File]::ReadAllText($stateFile, $Utf8NoBom) | ConvertFrom-Json } else { $null }

$tcFile   = Join-Path $RepoRoot 'tests\agent\core\infra_cases.json'
$allCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$cases    = if ($Id) { $allCases | Where-Object { $_.id -eq $Id } } else { $allCases }
if (-not $cases) { throw "Testfall '$Id' nicht gefunden." }

Write-Host ""
Write-Host "Infra Sub-Workflow Tests -- $($cases.Count) Testfall(e)"
Write-Host ("-" * 64)
$passed = 0; $failed = 0

foreach ($tc in $cases) {
    Write-Host ""
    Write-Host "  [$($tc.id)] $($tc.name)"
    Write-Host "    Harness: $N8N_URL/webhook/$($tc.harness_path)  ->  $($tc.target_name)"

    $targetWfId = $wfMap[$tc.target_name]
    if (-not $targetWfId) {
        Write-Host "    [FAIL] Workflow '$($tc.target_name)' nicht gefunden (aktiv? build.ps1 -Only '*test_harness*' -> bootstrap_test_n8n.ps1 -Reset laufen lassen)." -ForegroundColor Red
        $failed++; continue
    }

    $missingReq = @()
    if ($tc.PSObject.Properties['requires'] -and $tc.requires) {
        foreach ($rq in @($tc.requires)) {   # ein Name oder eine Liste (z. B. ["mock_telegram","mock_llm"]); Punkt-Pfad = Feld im Block, nicht leer
            $node = $substrateState
            foreach ($seg in ($rq -split '\.')) { $node = if ($node -and $node.PSObject.Properties[$seg]) { $node.$seg } else { $null } }
            if ([string]::IsNullOrEmpty([string]$node)) { $missingReq += $rq }
        }
    }
    if ($missingReq.Count) {
        $hint = ($missingReq | ForEach-Object {
            $blk = ($_ -split '\.')[0]
            ".\scripts\dev\enable_$blk.ps1" + $(if ($_ -ne $blk) { " (Feld '$_' leer - fuer mock_llm.cred_id: TEST_GOOGLE_API_KEY in .env)" } else { '' })
        }) -join ' + '
        Write-Host "    [FAIL] Vorbedingung '$($missingReq -join "', '")' fehlt im Substrat-State -- zuerst: $hint" -ForegroundColor Red
        $failed++; continue
    }
    # mock_llm: der State-Block allein beweist nichts (das Laufzeit-Drop-in ueberlebt keinen Container-Neustart) ->
    # den tatsaechlichen Gateway-Upstream pruefen, sonst kostete dieser Gratis-Case echte Credits.
    if (@($tc.requires) -contains 'mock_llm') {
        try { Assert-LlmGatewayUpstream -Container $conn.Container -Expect mock }
        catch { Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red; $failed++; continue }
    }

    $webhookUrl = "$N8N_URL/webhook/$($tc.harness_path)"
    $tStart     = (Get-Date).ToUniversalTime()
    $payload    = ($tc.body | ConvertTo-Json -Compress)
    if ($payload.Contains('__OWNER_CHAT_ID__')) {
        # Gepairter Owner-Sender wie mock_route_test/real_ingress_test (der frisch gebootstrappte Owner hat noch keine
        # telegram_user_id -> fn_resolve_sender found=false). Idempotent, einmal je Lauf reicht -> hier je Case billig.
        Set-OwnerTelegramPairing -Container $conn.Container -Uid $PairedOwnerUid
        $payload = $payload.Replace('__OWNER_CHAT_ID__', "$PairedOwnerUid")
    }
    try {
        # Harness antwortet seit responseMode=lastNode erst nach Lauf-Ende -> POST blockiert;
        # Timeout ist KEIN Fehler (Polling unten uebernimmt wie bisher).
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
            -TimeoutSec ($Timeout + 10) `
            -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
    } catch {
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) {
            Write-Host "    [FAIL] Webhook-POST fehlgeschlagen: $_" -ForegroundColor Red
            Write-Host "    DIAGNOSE: Harness aktiv? Secret korrekt? URL: $webhookUrl" -ForegroundColor Yellow
            $failed++; continue
        }
    }

    $ex = $null; $start = Get-Date
    while ($true) {
        $cand = Find-Exec $targetWfId $tStart
        if ($cand -and $cand.status -ne 'running' -and $cand.status -ne 'new') { $ex = Get-ExecDetail $cand.id; break }
        if (((Get-Date) - $start).TotalSeconds -ge $Timeout) {
            if ($cand) { Stop-Exec $cand.id; $ex = Get-ExecDetail $cand.id }
            break
        }
        Start-Sleep -Milliseconds 1000
    }
    if (-not $ex) {
        Write-Host "    [FAIL] Keine Execution gefunden fuer '$($tc.target_name)' (Timeout $Timeout s)." -ForegroundColor Red
        $failed++; continue
    }
    Write-Host "    Execution: id=$($ex.id)  status=$($ex.status)"

    $runData = $ex.data.resultData.runData
    $val     = Get-FieldValue $runData $tc.check_node $tc.check_field
    $valStr  = if ($null -eq $val) { '(null)' } else { [string]$val }
    if ($Verbose) {
        $preview = if ($valStr.Length -gt 150) { $valStr.Substring(0, 150) + '...' } else { $valStr }
        Write-Host "    $($tc.check_node).$($tc.check_field) = $preview" -ForegroundColor DarkGray
    }

    $errors = @()
    if ($tc.must_be_nonempty -eq $true) {
        if ($valStr -eq '(null)' -or [string]::IsNullOrWhiteSpace($valStr)) { $errors += 'Feld ist leer / null' }
    }
    if ($null -ne $tc.must_contain) {
        if ($valStr.IndexOf($tc.must_contain, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $errors += "Enthaelt nicht: '$($tc.must_contain)'"
        }
    }
    if ($null -ne $tc.must_not_contain) {
        if ($valStr.IndexOf($tc.must_not_contain, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $errors += "Enthaelt unerwartet: '$($tc.must_not_contain)'"
        }
    }
    if ($null -ne $tc.must_equal) {
        if ($val -ne $tc.must_equal) { $errors += "Erwartet $($tc.must_equal), erhalten: $val" }
    }

    if ($errors.Count -eq 0) {
        $passed++
        Write-Host "    [PASS]" -ForegroundColor Green
    } else {
        $failed++
        foreach ($e in $errors) { Write-Host "    FEHLER: $e" -ForegroundColor Red }
        Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
    }
    if ($ex.status -eq 'waiting') { Stop-Exec $ex.id }
}

# Haengende Harness-Executions aufraeumen
$infraHarnesses = @('agent.tool_load_context.test_harness','core.sub_load_config.test_harness','agent.tool_human_approval.test_harness')
foreach ($hName in $infraHarnesses) {
    $hId = $wfMap[$hName]
    if ($hId) {
        try { (Invoke-N8nGet "executions?workflowId=$hId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }
    }
}

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($cases.Count) Tests bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-Host "Tipp: build.ps1 -Only '*test_harness*' -> bootstrap_test_n8n.ps1 -Reset ausfuehren falls Harnesses fehlen."
Write-Host ""
exit $failed
