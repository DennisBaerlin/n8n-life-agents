#Requires -Version 5.1
# Multi-Turn-Agent-Tests (Weg C / Teststrategie Phase 8). Feuert tests\agent\cross\multiturn_cases.json:
# je Case MEHRERE Turns sequenziell ueber DIESELBE (numerische) chat_id (KEIN Memory-Clear zwischen den
# Turns) -> prueft Kontext-Erhalt (Pronomen-Aufloesung) UND den HITL-Korrektur-Loop (ablehnen ->
# korrigieren -> neu planen). Der letzte Turn wird gegen expected_tool (+ optional expected_tool_args)
# deterministisch geprueft.
#
# WEG C: KEIN test_-Gate-Bypass mehr. Jeder Turn feuert am Agent-Harness (finance-test); ruft ein Turn
#   ein Write-Tool, wird das echte Send-and-Wait-Gate ueber das abgefangene Mock-Telegram DECLINEd
#   (= die "ablehnen"-Haelfte des Korrektur-Loops). Execution-Korrelation: monotone Exec-id je Turn.
#
# Usage:  .\scripts\multiturn_test.ps1 [-Id mt01] [-Timeout 70] [-Verbose]
# Exit-Code = Anzahl Fehler. KOSTET LLM-Credits (owner-gegatet).
# Voraussetzung: Docker-Test-Substrat + enable_mock_telegram.ps1 (fuers Gate) + .env TEST_HARNESS_SECRET.
param(
    [string]$Id,
    [int]$Timeout = 70,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
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
$Headers    = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }
$AuthHeader = 'X-Test-Auth'
$WebhookUrl = "$N8N_URL/webhook/finance-test"

$state = [System.IO.File]::ReadAllText((Join-Path $RepoRoot '.local\n8ntest_state.json'), $Utf8NoBom) | ConvertFrom-Json
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (fuer die Gate-Aufloesung noetig). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
# Echte Claude-Antworten noetig (Gateway-Upstream = API, nicht Mock) + Start-Marke fuer die Kostenuebersicht.
Assert-LlmGatewayUpstream -Container $Container -Expect real
$llmCursor = Get-LlmUsageCursor -Container $Container

function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8N_URL/api/v1/$Path" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) { try { Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { } }
function Get-ToolCall([object]$RunData, [string]$AgentNodeName) {
    $out = @()
    if ($null -eq $AgentNodeName -or -not $RunData.PSObject.Properties.Name.Contains($AgentNodeName)) { return $out }
    foreach ($run in $RunData.$AgentNodeName) {
        $actions = $null; try { $actions = $run.metadata.subNodeExecutionData.actions } catch { }
        if (-not $actions) { continue }
        foreach ($a in $actions) {
            $nn = $null; try { $nn = $a.action.nodeName } catch { }; if (-not $nn) { try { $nn = $a.nodeName } catch { } }
            if ($nn) { $out += @{ tool = $nn; inputObj = $a.action.input } }
        }
    }
    return $out
}
function Get-CalledTool([object]$RunData, [string]$AgentNodeName) {
    foreach ($c in (Get-ToolCall $RunData $AgentNodeName)) { if ($c.tool -like 'tool_*') { return $c.tool } }
    return $null
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
    if ($aIsNum -ne $eIsNum) { return $false }
    if ($aStr -ieq $eStr) { return $true }
    $al = $aStr.ToLowerInvariant(); $el = $eStr.ToLowerInvariant(); return ($al.Contains($el) -or $el.Contains($al))
}
function Test-ToolArg([object]$InputObj, [object]$Expected) {
    if ($null -eq $InputObj) { return @('kein Tool-Input erfassbar') }
    if ($InputObj -is [string]) { try { $InputObj = $InputObj | ConvertFrom-Json } catch { return @("Tool-Input nicht parsebar") } }
    $errs = @()
    foreach ($p in $Expected.PSObject.Properties) {
        $act = $null; try { $act = $InputObj.$($p.Name) } catch { }
        if (-not (Compare-ArgValue $act $p.Value)) { $errs += "$($p.Name): erwartet '$($p.Value)', erhalten '$(if($null -eq $act){'(fehlt)'}else{$act})'" }
    }
    return $errs
}

# --- Setup ---
$wfList    = Invoke-N8nGet 'workflows?limit=200'
$financeWf = $wfList.data | Where-Object { $_.name -eq 'agent.finance' } | Select-Object -First 1
$harnessWf = $wfList.data | Where-Object { $_.name -eq 'agent.finance.test_harness' } | Select-Object -First 1
if (-not $financeWf) { throw "Workflow 'agent.finance' nicht gefunden." }
if (-not $harnessWf) { throw "agent.finance.test_harness nicht gefunden (build.ps1 -Only '*test_harness*' -> bootstrap_test_n8n.ps1 -Reset)." }
$FinanceWfId = $financeWf.id
$AgentNodeName = 'Finance Agent'
$wfDef = Invoke-N8nGet "workflows/$FinanceWfId"
foreach ($node in $wfDef.nodes) { if ($node.type -match 'langchain.agent') { $AgentNodeName = $node.name; break } }

$tcFile   = Join-Path $RepoRoot 'tests\agent\cross\multiturn_cases.json'
$allCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$cases    = if ($Id) { $allCases | Where-Object { $_.id -eq $Id } } else { $allCases }
if (-not $cases) { throw "Testfall '$Id' nicht gefunden." }

Write-Host ""
Write-Host "Multi-Turn-Agent-Tests -- $($cases.Count) Case(s)  (Webhook: $WebhookUrl)"
Write-Host ("-" * 64)
$passed = 0; $failed = 0

# Ein Turn = ein Harness-POST -> agent.finance-Execution; jedes Write-Gate wird DECLINEd.
function Invoke-Turn([string]$Task, [long]$ChatId, [int]$TurnTimeout) {
    Clear-MockTelegramRequests -Container $Container
    $base = Get-MaxExecId -WfId $FinanceWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
    $payload = @{ task = $Task; chat_id = "$ChatId"; call_depth = 0 } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
            -TimeoutSec 8 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
    } catch {
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) { throw }
    }
    return Wait-ExecResolvingGates -WfId $FinanceWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $TurnTimeout
}

foreach ($tc in $cases) {
    Write-Host ""
    Write-Host "  [$($tc.id)] $($tc.name)  ($($tc.turns.Count) Turns)"
    $caseTimeout = if ($tc.PSObject.Properties['timeout_s'] -and $tc.timeout_s) { [int]$tc.timeout_s } else { $Timeout }
    [long]$chatId = Get-TestChatId -Seed $tc.id
    # EINMAL je Case leeren (numerisch) -> Turns innerhalb des Cases bauen bewusst aufeinander auf.
    Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
    $ex = $null
    for ($i = 0; $i -lt $tc.turns.Count; $i++) {
        Write-Host "    Turn $($i+1): '$($tc.turns[$i])'"
        $ex = Invoke-Turn $tc.turns[$i] $chatId $caseTimeout
        if (-not $ex) { Write-Host "    [FAIL] Turn $($i+1): keine Execution gefunden (Timeout)." -ForegroundColor Red; break }
        if (-not ($i -eq $tc.turns.Count - 1) -and $Verbose) { Write-Host "      (Zwischen-Turn output: $(Get-AgentOutput $ex.data.resultData.runData $AgentNodeName))" -ForegroundColor DarkGray }
    }
    if (-not $ex) { $failed++; continue }

    $runData    = $ex.data.resultData.runData
    $calledTool = Get-CalledTool $runData $AgentNodeName
    Write-Host "    Letzter Turn: status=$($ex.status)  tool=$calledTool"

    $pass = ($calledTool -eq $tc.expected_tool)
    if (-not $pass) { Write-Host "    FEHLER: tool='$calledTool', erwartet='$($tc.expected_tool)'" -ForegroundColor Red }
    if ($pass -and $tc.expected_tool_args) {
        $wtool = (Get-ToolCall $runData $AgentNodeName | Where-Object { $_.tool -like 'tool_*' } | Select-Object -First 1)
        $argErr = Test-ToolArg $wtool.inputObj $tc.expected_tool_args
        if ($argErr.Count -gt 0) { $pass = $false; Write-Host "    FEHLER (Memory/Korrektur nicht uebernommen):" -ForegroundColor Red; $argErr | ForEach-Object { Write-Host "      - $_" -ForegroundColor Red } }
        else { Write-Host "    Args OK (Kontext ueber Turns): $(($tc.expected_tool_args.PSObject.Properties.Name) -join ', ')" -ForegroundColor DarkGreen }
    }

    if ($pass) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green }
    else {
        $failed++; Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
        Write-Host "    output: $(Get-AgentOutput $runData $AgentNodeName)" -ForegroundColor Yellow
    }
}

try { (Invoke-N8nGet "executions?workflowId=$FinanceWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($cases.Count) Multi-Turn-Cases bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-LlmCostReport -Usage (Get-LlmUsage -Container $Container -AfterCursor $llmCursor) -Label 'multiturn_test' -RepoRoot $RepoRoot
Write-Host ""
exit $failed
