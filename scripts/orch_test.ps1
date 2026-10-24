#Requires -Version 5.1
# Orchestrator Routing Tests -- Tier 3 der TDD-Infrastruktur (Weg C / Teststrategie Phase 8).
# Prueft, ob agent.orchestrator.main_route eine Anfrage korrekt an den richtigen Spezialisten routet
# (Tool "Call 'agent.<x>'") oder selbst beantwortet (Non-Finance).
#
# WEG C: KEIN test_-Bypass, KEIN "Test entry" mehr. Der Treiber feuert eine TELEGRAM-foermige Update
#   mit NUMERISCHER chat_id (gepairter Owner-Sender) an den ECHTEN Telegram-Trigger-Webhook des
#   Orchestrators (Produktivpfad, wie real_ingress). Das echte Send-and-Wait-Gate eines vom Sub-Agenten
#   gewaehlten Write-Tools wird ueber das abgefangene Mock-Telegram DECLINEd (kein Write, kein Spam) ->
#   die Routing-Entscheidung steht im Orchestrator-runData. Execution-Korrelation: monotone Exec-id.
#
# Voraussetzung: laufendes Substrat + enable_mock_telegram.ps1 (fuers Gate). REAL LLM (Claude)
#   -> mock_llm NICHT aktiv (sonst gescriptetes statt echtes Routing). .env TEST_HARNESS_SECRET nicht noetig.
#
# Usage:  .\scripts\orch_test.ps1 [-Id oc01] [-Timeout 90] [-Verbose]
# Exit-Code = Anzahl Fehler. KOSTET LLM-Credits (owner-gegatet).
param(
    [string]$Id,
    [int]$Timeout = 90,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# N8N_URL/N8N_API_KEY kommen aus dem ephemeren Docker-Test-Substrat (raus aus Prod), nicht aus .env.
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn        = Get-TestN8nConnection
$N8N_URL     = $conn.Url
$N8N_API_KEY = $conn.ApiKey
$Container   = $conn.Container
$Headers     = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }

# Mock-Telegram muss aktiv sein (fuer die Gate-Aufloesung); Mock-LLM darf NICHT aktiv sein (echtes Routing).
$state = [System.IO.File]::ReadAllText((Join-Path $RepoRoot '.local\n8ntest_state.json'), $Utf8NoBom) | ConvertFrom-Json
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (fuer die Gate-Aufloesung noetig). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
# Mock-LLM aktiv = gescriptetes statt echtes Routing -> hart abbrechen (vorher nur Warnung; der Waechter prueft den
# tatsaechlichen Gateway-Upstream, nicht nur den State-Block). Dazu die Start-Marke fuer die Kostenuebersicht.
Assert-LlmGatewayUpstream -Container $Container -Expect real
$llmCursor = Get-LlmUsageCursor -Container $Container

function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8N_URL/api/v1/$Path" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) {
    try { Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
}
$AgentNode   = 'Orchestrator agent'
# Route-Agenten aus den Manifesten (kein Paket im Treiber; Verdikt-Logik geteilt mit mock_route_test).
$routeAgents = Get-TestRouteAgent

function Get-ToolCall([object]$RunData) {
    $out = @()
    if (-not $RunData.PSObject.Properties.Name.Contains($AgentNode)) { return $out }
    foreach ($run in $RunData.$AgentNode) {
        $actions = $null; try { $actions = $run.metadata.subNodeExecutionData.actions } catch { }
        if (-not $actions) { continue }
        foreach ($a in $actions) {
            $nn = $null; try { $nn = $a.action.nodeName } catch { }; if (-not $nn) { try { $nn = $a.nodeName } catch { } }
            if ($nn) { $out += $nn }
        }
    }
    return $out
}
function Get-AgentOutput([object]$RunData) {
    $txt = ''
    if (-not $RunData.PSObject.Properties.Name.Contains($AgentNode)) { return $txt }
    foreach ($run in $RunData.$AgentNode) { try { if ($run.data.main[0][0].json.output) { $txt = $run.data.main[0][0].json.output } } catch { } }
    return $txt
}

# --- Setup: echten Ingress aufloesen + Owner pairen ---
$ingress = Resolve-OrchestratorIngress -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
$OrchWfId = $ingress.OrchWfId
$PairedUid = $TestOwnerTelegramUid
Set-OwnerTelegramPairing -Container $Container -Uid $PairedUid
Write-Host "  Orchestrator: id=$OrchWfId   Ingress: $($ingress.Url)"

$tcFile = Join-Path $RepoRoot 'tests\agent\core\orch_cases.json'
$allCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$cases = if ($Id) { $allCases | Where-Object { $_.id -eq $Id } } else { $allCases }
if (-not $cases) { throw "Testfall '$Id' nicht gefunden." }

Write-Host ""
Write-Host "Orchestrator Routing Tests -- $($cases.Count) Testfall(e)  (echter Telegram-Ingress)"
Write-Host ("-" * 64)
$passed = 0; $failed = 0

foreach ($tc in $cases) {
    Write-Host ""
    Write-Host "  [$($tc.id)] $($tc.name)"
    Write-Host "    Task: '$($tc.task)'"
    $expShow = if ($tc.expected_route) { $tc.expected_route } else { '(kein Routing)' }
    Write-Host "    Erwartet: route=$expShow"

    $caseTimeout = if ($tc.PSObject.Properties['timeout_s'] -and $tc.timeout_s) { [int]$tc.timeout_s } else { $Timeout }
    [long]$chatId = Get-TestChatId -Seed $tc.id
    Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
    Clear-MockTelegramRequests -Container $Container
    $base = Get-MaxExecId -WfId $OrchWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY

    Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $chatId -FromUid $PairedUid -Text $tc.task | Out-Null
    $ex = Wait-ExecResolvingGates -WfId $OrchWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $caseTimeout
    if (-not $ex) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout $caseTimeout s)." -ForegroundColor Red; $failed++; continue }

    $runData = $ex.data.resultData.runData
    $tools = Get-ToolCall $runData
    $routed = Get-RoutedAgent -Tools $tools -RouteAgents $routeAgents
    $routeShown = $routed -join '+'; if (-not $routeShown) { $routeShown = '(kein)' }
    Write-Host "    Execution: id=$($ex.id)  status=$($ex.status)  route=$routeShown  tools=[$($tools -join ', ')]"

    $expect = [string]$tc.expected_route
    $pass = Test-ExpectedRoute -Routed $routed -Expected $expect -RouteAgents $routeAgents
    if (-not $pass) {
        $want = if ($expect) { $expect } else { 'kein Routing' }
        Write-Host "    FEHLER: erwartet $want, got $routeShown" -ForegroundColor Red
    }

    if ($pass) {
        $passed++; Write-Host "    [PASS] route=$routeShown" -ForegroundColor Green
        if ($Verbose) { Write-Host "    output: $(Get-AgentOutput $runData)" -ForegroundColor DarkGray }
    } else {
        $failed++; Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
        Write-Host "    output: $(Get-AgentOutput $runData)" -ForegroundColor Yellow
    }
}

# wartende Orchestrator-/Gate-Executions aufraeumen
try { (Invoke-N8nGet "executions?workflowId=$OrchWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($cases.Count) Tests bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-LlmCostReport -Usage (Get-LlmUsage -Container $Container -AfterCursor $llmCursor) -Label 'orch_test' -RepoRoot $RepoRoot
Write-Host ""
exit $failed
