#Requires -Version 5.1
# Agent Routing Tests -- Layer 2 der TDD-Infrastruktur (Weg C / Teststrategie Phase 8).
# Feuert tests\agent\finance\finance_cases.json gegen den Finance-Agenten. Hybrid:
#   (1) deterministisch -> wurde das erwartete tool_* aufgerufen? (expected_tool [+ expected_tool_args])
#   (2) optional Verhaltens-Rubric (expected_behavior) -> Judge-Bundle fuer einen AI-Judge.
#
# Trigger: POST an den Agent-Harness (agent.finance.test_harness, Header-Auth) -> Execute Workflow ruft
#   den Agenten ueber dessen PRODUKTIONS-executeWorkflowTrigger auf (kein Test-Sonderknoten im Agenten).
#
# WEG C: KEIN test_-Gate-Bypass mehr. chat_id ist NUMERISCH; das echte Send-and-Wait-Gate eines
#   Write-Tools wird ueber das abgefangene Mock-Telegram DECLINEd (Wait-ExecResolvingGates -Approve
#   $false) -> kein DB-Write, kein Spam; die Routing-Entscheidung steht trotzdem im runData. Execution-
#   Korrelation: monotone Exec-id auf dem Ziel-Workflow (Get-MaxExecId vor dem Feuern; die suspendierte
#   Execution liefert KEINE Run-Info-subExecution mehr).
#
# Pre-Flight (jeder Paket-Agent): seedet + verifiziert die Routing-Fixtures + abgeschlossenes Onboarding.
# Ziel/Paket-Eigenschaften leitet Get-TestRouteAgent aus den Manifesten + core.context_scopes ab (kein Paket im Treiber).
#
# Usage:
#   .\scripts\n8n_test.ps1                  # alle Testfaelle
#   .\scripts\n8n_test.ps1 -Id tc03         # nur einen Testfall
#   .\scripts\n8n_test.ps1 -TargetWorkflow agent.finance_advisor -WebhookPath advisor-test `
#       -WriteTools tool_save_plan_section,tool_publish_plan,tool_create_monitor_trigger,tool_search_documents,tool_set_asset_classes -CasesFile tests\agent\finance\advisor_cases.json
#
# Exit-Code = Anzahl fehlgeschlagener Tests. KOSTET LLM-Credits (owner-gegatet).
# Voraussetzung: Docker-Test-Substrat + enable_mock_telegram.ps1 (fuers Gate) + .env TEST_HARNESS_SECRET.
#   Mock-LLM NICHT aktiv (echtes Routing). Test-Memory wird je Case in der Container-DB geleert.
param(
    [string]$Id,
    [int]$Timeout = 60,
    [string]$CasesFile = 'tests\agent\finance\finance_cases.json',
    [string]$TargetWorkflow = 'agent.finance',
    [string]$WebhookPath = 'finance-test',
    [string[]]$WriteTools = @(),
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Ueber powershell.exe -File (z. B. aus Bash) kommt "a,b,c" als EIN String an -> sonst zaehlte kein Write (Muster mock_route_test).
$WriteTools = @($WriteTools | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

Get-Content "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') { Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script }
}
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn        = Get-TestN8nConnection
$N8N_URL     = $conn.Url
$N8N_API_KEY = $conn.ApiKey
$Container   = $conn.Container
if ([string]::IsNullOrEmpty($TEST_HARNESS_SECRET)) { throw "TEST_HARNESS_SECRET ist nicht gesetzt in .env" }
$Headers     = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }
$AuthHeader  = 'X-Test-Auth'
$WebhookUrl  = "$N8N_URL/webhook/$WebhookPath"

$state = Get-TestN8nState
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (fuer die Gate-Aufloesung noetig). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
# Echte Claude-Antworten noetig (Gateway-Upstream = API, nicht Mock) + Start-Marke fuer die Kostenuebersicht.
Assert-LlmGatewayUpstream -Container $Container -Expect real
$llmCursor = Get-LlmUsageCursor -Container $Container

# -------------------------------------------------------
# Hilfsfunktionen
# -------------------------------------------------------
function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8N_URL/api/v1/$Path" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) {
    try { Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
}

# Alle Tool-Calls (Read + Write) als Liste @{ tool; input; inputObj }.
function Get-ToolCall([object]$RunData, [string]$AgentNodeName) {
    $out = @()
    if ($null -eq $AgentNodeName -or -not $RunData.PSObject.Properties.Name.Contains($AgentNodeName)) { return $out }
    foreach ($run in $RunData.$AgentNodeName) {
        $actions = $null; try { $actions = $run.metadata.subNodeExecutionData.actions } catch { }
        if (-not $actions) { continue }
        foreach ($a in $actions) {
            $nn = $null; try { $nn = $a.action.nodeName } catch { }; if (-not $nn) { try { $nn = $a.nodeName } catch { } }
            $inp = ''; try { $inp = ($a.action.input | ConvertTo-Json -Depth 4 -Compress) } catch { }
            if ($nn) { $out += @{ tool = $nn; input = $inp; inputObj = $a.action.input } }
        }
    }
    return $out
}
function Test-IsWriteTool([string]$Name) {
    if ($script:WriteTools -and $script:WriteTools.Count -gt 0) { return ($script:WriteTools -contains $Name) }
    return ($Name -like 'tool_*')
}
# Werkzeug-Aufrufe aus den Sub-Workflow-Executions (zuverlaessig): der n8n-Action-Log (Get-ToolCall) laesst Aufrufe aus
# Modell-Antworten MIT Denk-Block aus (belegt 2026-10-23, tc12: stage_rows fehlte, commit_import stand drin) -> jede neue
# Execution nach $AfterId, deren Workflow-Name auf ein Werkzeug des Agenten endet (agent.<pkg>.tool_x -> tool_x), zaehlt mit.
# n8n vergibt Execution-ids global fortlaufend; die Tiers laufen sequentiell.
function Get-GlobalMaxExecId { $r = Invoke-N8nGet 'executions?limit=1'; if ($r.data -and $r.data.Count -gt 0) { return [long]$r.data[0].id }; return 0 }
function Get-ExecutedToolRun([long]$AfterId) {
    $out = @()
    foreach ($e in (Invoke-N8nGet 'executions?limit=100').data) {
        if ([long]$e.id -le $AfterId) { continue }
        $wn = $script:WfNameById[[string]$e.workflowId]
        if ($wn -and $wn -match '\.(tool_[a-z0-9_]+)$' -and $script:AgentToolNames -contains $Matches[1]) { $out += @{ tool = $Matches[1]; execId = [string]$e.id } }
    }
    return $out
}
# Eingabe eines Werkzeug-Laufs aus seiner Execution (Start-Knoten), wenn der Action-Log den Aufruf nicht hat.
function Get-ToolRunInput([string]$ExecId) {
    try {
        $d = Invoke-N8nGet "executions/$ExecId`?includeData=true"
        $rd = $d.data.resultData.runData
        $start = if ($rd.PSObject.Properties.Name -contains 'Start') { 'Start' } else { $rd.PSObject.Properties.Name | Select-Object -First 1 }
        return $rd.$start[0].data.main[0][0].json
    } catch { return $null }
}
function Get-CalledTool([object]$RunData, [string]$AgentNodeName) {
    foreach ($c in (Get-ToolCall $RunData $AgentNodeName)) { if (Test-IsWriteTool $c.tool) { return $c.tool } }
    return $null
}
function Format-AgentRunData([object]$RunData, [string]$AgentNodeName) {
    if ($null -eq $AgentNodeName -or -not $RunData.PSObject.Properties.Name.Contains($AgentNodeName)) { return "(kein runData fuer Agent-Node '$AgentNodeName')" }
    $lines = @()
    foreach ($c in (Get-ToolCall $RunData $AgentNodeName)) { $lines += "tool-call: $($c.tool)  input=$($c.input)" }
    foreach ($run in $RunData.$AgentNodeName) { $txt = $null; try { $txt = $run.data.main[0][0].json.output } catch { }; if ($txt) { $lines += "output: $txt" } }
    if ($lines.Count -eq 0) { return '(keine Tool-Calls/Output im runData)' }
    return ($lines -join "`n             ")
}
function Get-AgentOutput([object]$RunData, [string]$AgentNodeName) {
    $txt = ''
    if ($null -eq $AgentNodeName -or -not $RunData.PSObject.Properties.Name.Contains($AgentNodeName)) { return $txt }
    foreach ($run in $RunData.$AgentNodeName) { try { if ($run.data.main[0][0].json.output) { $txt = $run.data.main[0][0].json.output } } catch { } }
    return $txt
}
function Compare-ArgValue($Actual, $Expected) {
    if ($null -eq $Actual) { return $false }
    $aStr = ("$Actual").Trim(); $eStr = ("$Expected").Trim(); if ($aStr -eq '') { return $false }
    $aNum = 0.0; $eNum = 0.0; $inv = [Globalization.CultureInfo]::InvariantCulture; $any = [Globalization.NumberStyles]::Any
    $aIsNum = [double]::TryParse($aStr, $any, $inv, [ref]$aNum); $eIsNum = [double]::TryParse($eStr, $any, $inv, [ref]$eNum)
    if ($aIsNum -and $eIsNum) { return ([math]::Abs($aNum - $eNum) -lt 0.0001) }
    if ($aIsNum -ne $eIsNum)  { return $false }
    if ($aStr -ieq $eStr) { return $true }
    $al = $aStr.ToLowerInvariant(); $el = $eStr.ToLowerInvariant(); return ($al.Contains($el) -or $el.Contains($al))
}
function Test-ToolArg([object]$InputObj, [object]$Expected) {
    if ($null -eq $InputObj) { return @('kein Tool-Input im runData erfassbar') }
    if ($InputObj -is [string]) { try { $InputObj = $InputObj | ConvertFrom-Json } catch { return @("Tool-Input nicht parsebar: $InputObj") } }
    $errs = @()
    foreach ($p in $Expected.PSObject.Properties) {
        $act = $null; try { $act = $InputObj.$($p.Name) } catch { }
        if (-not (Compare-ArgValue $act $p.Value)) {
            $shown = if ($null -eq $act) { '(fehlt)' } else { "$act" }
            $errs += "$($p.Name): erwartet '$($p.Value)', erhalten '$shown'"
        }
    }
    return $errs
}

# -------------------------------------------------------
# Setup
# -------------------------------------------------------
Write-Host "Suche Workflows ($TargetWorkflow + $TargetWorkflow.test_harness) ..."
# Ziel aus den Manifesten (kein Paket im Treiber): ein Nicht-Route-Agent bricht ab.
$routeAgents = Get-TestRouteAgent
$target = Resolve-TestTarget -RouteAgents $routeAgents -TargetWorkflow $TargetWorkflow
if ($null -eq $target) { throw "n8n_test prueft einen Agenten ueber seinen Harness; fuer den Orchestrator: .\scripts\orch_test.ps1" }

$wfList = Invoke-N8nGet 'workflows?limit=200'
$targetWf  = $wfList.data | Where-Object { $_.name -eq $TargetWorkflow } | Select-Object -First 1
$harnessWf = $wfList.data | Where-Object { $_.name -eq "$TargetWorkflow.test_harness" } | Select-Object -First 1
if (-not $targetWf) { throw "Workflow '$TargetWorkflow' nicht gefunden." }
if (-not $harnessWf) { throw "Workflow '$TargetWorkflow.test_harness' nicht gefunden. Erst Harness bauen (build.ps1 -Only '*test_harness*') -> bootstrap_test_n8n.ps1 -Reset." }
$TargetWfId = $targetWf.id
if (-not $harnessWf.active) { Write-Host "  [WARN] Harness ist INAKTIV -> Webhook nicht registriert." -ForegroundColor Yellow }

$wfDef = Invoke-N8nGet "workflows/$TargetWfId"
$AgentNodeName = $null
foreach ($node in $wfDef.nodes) { if ($node.type -match 'langchain.agent') { $AgentNodeName = $node.name; break } }
if (-not $AgentNodeName) { throw "Kein AI-Agent-Node (langchain.agent) in '$TargetWorkflow' gefunden." }
Write-Host "  AI-Agent-Node: '$AgentNodeName'"
$script:AgentToolNames = @($wfDef.nodes | Where-Object { $_.name -like 'tool_*' } | ForEach-Object { $_.name })
$script:WfNameById = @{}; foreach ($w in $wfList.data) { $script:WfNameById[[string]$w.id] = $w.name }

$tcFile = if ([System.IO.Path]::IsPathRooted($CasesFile)) { $CasesFile } else { Join-Path $RepoRoot $CasesFile }
$allCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$cases = if ($Id) { $allCases | Where-Object { $_.id -eq $Id } } else { $allCases }
if (-not $cases) { throw "Testfall '$Id' nicht gefunden." }

# Pre-Flight (jedes Ziel, gemeinsam mit mock_route_test: Initialize-AgentTestState): Absender = gepairter
# Fixture-Owner, Fixtures + abgeschlossenes Onboarding in die Container-DB seeden, dann verifizieren.
Write-Host "Pre-Flight: Owner pairen + Routing-Fixtures + abgeschlossenes Onboarding seeden ..."
Initialize-AgentTestState -Container $Container -RepoRoot $RepoRoot
& (Join-Path $RepoRoot 'scripts\test_fixtures.ps1') -Verify
switch ($LASTEXITCODE) {
    0 { Write-Host "Pre-Flight: Routing-Fixtures vollstaendig." -ForegroundColor DarkGreen }
    2 { Write-Host "[WARN] Fixture-Pre-Flight uebersprungen (kein Test-Substrat)." -ForegroundColor Yellow }
    default { throw "Routing-Fixtures fehlen trotz Seed -- Substrat pruefen: .\scripts\dev\bootstrap_test_n8n.ps1 -Reset" }
}
# WS-5b Test-Identitaets-Riegel: bricht VOR dem ersten (teuren) LLM-Call ab, falls der Substrat-Owner
# nicht der fiktive Golden-Owner 'Erika' ist (Mismatch verbrennt sonst die ganze Suite; faengt PII-Leaks).
Assert-GoldenHousehold -Container $Container

Write-Host ""
Write-Host "n8n Agent Routing Tests -- $($cases.Count) Testfall(e)  (Webhook: $WebhookUrl)"
Write-Host ("-" * 64)
$passed = 0; $failed = 0; $quarantined = 0; $judgeBundle = @(); $pkgOnbDirty = $false

foreach ($tc in $cases) {
    Write-Host ""
    Write-Host "  [$($tc.id)] $($tc.name)"
    Write-Host "    Task: '$($tc.task)'"
    $expShow = if ($tc.expected_tool) { $tc.expected_tool } else { '(keins)' }
    Write-Host "    Erwartet: tool=$expShow"

    $caseTimeout = if ($tc.PSObject.Properties['timeout_s'] -and $tc.timeout_s) { [int]$tc.timeout_s } else { $Timeout }
    [long]$chatId = $TestOwnerTelegramUid
    Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
    # Optionaler Haushalts-/Paket-Onboarding-Vorzustand des Cases (Guide: neuer Nutzer = unknown; "package_onboarding":
    # offener Paket-Bereich); sonst gilt completed.
    try {
        Set-TestHouseholdOnboarding -Container $Container -Status $(if ($tc.onboarding) { "$($tc.onboarding)" } else { 'completed' })
        if ($tc.package_onboarding -or $pkgOnbDirty) {
            Set-TestPackageOnboarding -Container $Container -Sections $tc.package_onboarding
            $pkgOnbDirty = [bool]$tc.package_onboarding
        }
    }
    catch { Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red; $failed++; continue }
    Clear-MockTelegramRequests -Container $Container
    $base = Get-MaxExecId -WfId $TargetWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
    $globalBase = Get-GlobalMaxExecId

    $payload = @{ task = $tc.task; chat_id = "$chatId"; call_depth = 0 } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
            -TimeoutSec 8 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
    } catch {
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) {
            Write-Host "    [FAIL] Webhook-POST fehlgeschlagen: $_" -ForegroundColor Red
            Write-Host "    DIAGNOSE: Harness aktiv? Header-Auth-Secret korrekt (X-Test-Auth)? URL: $WebhookUrl" -ForegroundColor Yellow
            $failed++; continue
        }
    }

    $ex = Wait-ExecResolvingGates -WfId $TargetWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $caseTimeout
    if (-not $ex) { Write-Host "    [FAIL] Keine $TargetWorkflow-Execution gefunden (Timeout $caseTimeout s)." -ForegroundColor Red; $failed++; continue }

    $runData = $ex.data.resultData.runData
    $calledTool = Get-CalledTool $runData $AgentNodeName
    # Alle Schreib-Werkzeuge dieses Laufs: Action-Log UND Werkzeug-Executions (der Log allein ist unvollstaendig).
    $loggedWrite = @(Get-ToolCall $runData $AgentNodeName | Where-Object { Test-IsWriteTool $_.tool })
    $execWrite = @(Get-ExecutedToolRun -AfterId $globalBase | Where-Object { Test-IsWriteTool $_.tool })
    $allWrite = @(@($loggedWrite | ForEach-Object { $_.tool }) + @($execWrite | ForEach-Object { $_.tool }) | Select-Object -Unique)
    if (-not $calledTool -and $allWrite.Count -gt 0) { $calledTool = $allWrite[0] }
    Write-Host "    Execution: id=$($ex.id)  status=$($ex.status)  tool=$calledTool$(if ($allWrite.Count -gt 1) { "  (alle: $($allWrite -join ', '))" })"

    $pass = $false
    if ($null -eq $tc.expected_tool) {
        if ($allWrite.Count -eq 0) { $pass = $true }
        else { Write-Host "    FEHLER: Tool='$($allWrite -join ', ')' aufgerufen, obwohl keins erwartet" -ForegroundColor Red }
    } else {
        # PASS, wenn das erwartete Werkzeug im Lauf aufgerufen wurde (nicht nur, wenn es zufaellig als erstes protokolliert ist).
        if ($allWrite -contains $tc.expected_tool) { $pass = $true; $calledTool = $tc.expected_tool }
        else { Write-Host "    FEHLER: Tool='$($allWrite -join ', ')', erwartet='$($tc.expected_tool)'" -ForegroundColor Red }
    }

    if ($pass -and $tc.expected_tool_args) {
        $writeCall = ($loggedWrite | Where-Object { $_.tool -eq $tc.expected_tool } | Select-Object -First 1)
        if (-not $writeCall) {
            $run = $execWrite | Where-Object { $_.tool -eq $tc.expected_tool } | Select-Object -First 1
            if ($run) { $writeCall = @{ tool = $run.tool; inputObj = (Get-ToolRunInput $run.execId) } }
        }
        $argErrors = Test-ToolArg $writeCall.inputObj $tc.expected_tool_args
        if ($argErrors.Count -gt 0) {
            $pass = $false
            Write-Host "    FEHLER: Tool='$calledTool' mit falschen/fehlenden Argumenten:" -ForegroundColor Red
            foreach ($ae in $argErrors) { Write-Host "      - $ae" -ForegroundColor Red }
        } else {
            Write-Host "    Args OK: $(($tc.expected_tool_args.PSObject.Properties.Name) -join ', ')" -ForegroundColor DarkGreen
        }
    }

    if ($tc.quarantined) {
        $quarantined++
        $qv = if ($pass) { 'PASS' } else { 'FAIL' }
        Write-Host "    [QUARANTINE -> $qv] flaky/bekannt -- aus Pass/Fail + Judge-Bundle ausgeschlossen" -ForegroundColor Magenta
        Write-Host "    runData: $(Format-AgentRunData $runData $AgentNodeName)" -ForegroundColor DarkGray
        continue
    }

    if ($pass) {
        $passed++; Write-Host "    [PASS] tool=$calledTool" -ForegroundColor Green
        if ($Verbose) { Write-Host "    runData: $(Format-AgentRunData $runData $AgentNodeName)" -ForegroundColor DarkGray }
    } else {
        $failed++
        Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
        Write-Host "    --- AI-Agent runData (Diagnose) ---" -ForegroundColor Yellow
        Write-Host "    $(Format-AgentRunData $runData $AgentNodeName)" -ForegroundColor Yellow
        Write-Host "    -----------------------------------" -ForegroundColor Yellow
    }

    if ($tc.expected_behavior) {
        $allCalls = Get-ToolCall $runData $AgentNodeName
        # Eingabe des bewerteten Werkzeugs: aus dem Action-Log, sonst aus seiner Execution (Log unvollstaendig, s. o.).
        $wtool    = $allCalls | Where-Object { $_.tool -eq $calledTool } | Select-Object -First 1
        $wInput   = if ($wtool) { $wtool.input } else { '' }
        if (-not $wInput -and $calledTool) {
            $run = $execWrite | Where-Object { $_.tool -eq $calledTool } | Select-Object -First 1
            if ($run) { $ri = Get-ToolRunInput $run.execId; if ($ri) { $wInput = ($ri | ConvertTo-Json -Depth 4 -Compress) } }
        }
        $readTools = ($allCalls | Where-Object { -not (Test-IsWriteTool $_.tool) } | ForEach-Object { $_.tool } | Select-Object -Unique) -join ', '
        $judgeBundle += [ordered]@{
            id = $tc.id; name = $tc.name; task = $tc.task
            expected_behavior = $tc.expected_behavior; expected_tool = $tc.expected_tool
            det_pass = $pass; actual_tool = $calledTool
            actual_tool_input = $wInput
            read_tools = $readTools; actual_output = (Get-AgentOutput $runData $AgentNodeName)
        }
        Write-Host "    [JUDGE] Verhalten zur AI-Bewertung vorgemerkt" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
$qNote = if ($quarantined -gt 0) { " ($quarantined in Quarantaene, nicht gewertet)" } else { '' }
Write-Host "Deterministisch (Tool-Routing): $passed/$($cases.Count) bestanden, $failed fehlgeschlagen$qNote." -ForegroundColor $color

Write-JudgeBundle -Entries $judgeBundle -RepoRoot $RepoRoot
Write-LlmCostReport -Usage (Get-LlmUsage -Container $Container -AfterCursor $llmCursor) -Label "n8n_test $([System.IO.Path]::GetFileNameWithoutExtension($CasesFile))" -RepoRoot $RepoRoot
Write-Host ""
exit $failed
