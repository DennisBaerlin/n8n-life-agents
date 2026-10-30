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
# Case-Felder (Bot-Persona, alle optional): persona = Owner-Persona nur fuer diesen Fall (danach neutral);
#   verbatim_relay = true -> die Spezialisten-Antwort muss woertlich im Endtext stehen, plus hoechstens ein Satz;
#   expected_behavior = Rubric -> Eintrag im Judge-Bundle (inkl. specialist_output), Auswertung judge_eval.ps1;
#   followup_agent = 'agent.<x>' -> vor dem Fall die Knopf-Folge-Bindung dieses Chats setzen (Router-Regel 2a);
#   expected_signal = FRAME|NOFRAME -> Router-Signal nach dem Spezialisten (Relay compose.signal, Regel 6 fuer alle).
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
$state = Get-TestN8nState
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
    # Woertliches Weiterreichen: die GESENDETE Nachricht baut 'Relay compose' (Teile, HTML-escapt); der Agent selbst
    # liefert nach einem Spezialisten nur FRAME/NOFRAME. Fuer Judge und verbatim_relay zaehlt der gesendete Text.
    if ($RunData.PSObject.Properties.Name.Contains('Relay compose')) {
        try { return [string]$RunData.'Relay compose'[0].data.main[0][0].json.body } catch { return '' }
    }
    if (-not $RunData.PSObject.Properties.Name.Contains($AgentNode)) { return $txt }
    foreach ($run in $RunData.$AgentNode) { try { if ($run.data.main[0][0].json.output) { $txt = $run.data.main[0][0].json.output } } catch { } }
    return $txt
}
# Bot-Persona (Rahmen-Modell): die Antwort des Spezialisten = laengster Text-Blatt-Wert der "Call 'agent.<x>'"-Tool-
# Nodes (ein JSON-String mit .output wird ausgepackt). Leer = kein Spezialist gerufen.
function Get-StringLeafList($Obj) {
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [string]) { return @($Obj) }
    if ($Obj -is [System.Collections.IEnumerable]) { return @($Obj | ForEach-Object { Get-StringLeafList $_ }) }
    if ($Obj -is [pscustomobject]) { return @($Obj.PSObject.Properties | ForEach-Object { Get-StringLeafList $_.Value }) }
    return @()
}
function Get-SpecialistOutput([object]$RunData) {
    $best = ''
    foreach ($p in @($RunData.PSObject.Properties | Where-Object { $_.Name -like "Call 'agent.*'" })) {
        foreach ($s in (Get-StringLeafList $p.Value)) {
            $t = $s
            if ($t.TrimStart().StartsWith('{')) { try { $j = $t | ConvertFrom-Json; if ($j.output) { $t = [string]$j.output } } catch { } }
            if ($t.Length -gt $best.Length) { $best = $t }
        }
    }
    return $best
}
# verbatim_relay: der Spezialisten-Text steht (Leerraum normalisiert) im Endtext, und ausserhalb davon steht hoechstens
# EIN Satz (der Persona-Rahmensatz). Liefert @{ ok; reason }.
function Test-VerbatimRelay([string]$Specialist, [string]$Final) {
    $norm = { param($s) ([regex]::Replace("$s", '\s+', ' ')).Trim() }
    $sp = & $norm $Specialist; $fi = & $norm $Final
    if (-not $sp) { return @{ ok = $false; reason = 'kein Spezialisten-Text gefunden' } }
    $at = $fi.IndexOf($sp)
    if ($at -lt 0) { return @{ ok = $false; reason = 'Spezialisten-Text nicht woertlich im Endtext' } }
    $rest = ($fi.Substring(0, $at) + ' ' + $fi.Substring($at + $sp.Length)).Trim()
    $sentences = @([regex]::Split($rest, '(?<=[.!?。！？])\s+') | Where-Object { $_.Trim() -match '\w' })
    if ($sentences.Count -gt 1) { return @{ ok = $false; reason = "$($sentences.Count) Saetze ausserhalb des Spezialisten-Texts (max. 1)" } }
    return @{ ok = $true; reason = "Rahmen: $($sentences.Count) Satz" }
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
$passed = 0; $failed = 0; $judgeBundle = @()

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
    # Folge-Bindung (Case-Feld followup_agent, 2026-10-28): simuliert "ein Knopf hat eben agent.<x> gestartet" fuer genau
    # diesen Chat (agent.fn_set_dispatch_followup, wie der Knopf-Arm nach dem Relay) -> die Nachricht prueft die
    # Router-Regel 2a. Ohne Feld wird eine Rest-Bindung des Chats geloescht (fn_take liest+loescht einmalig).
    $fuAgent = if ($tc.PSObject.Properties['followup_agent'] -and $tc.followup_agent) { [string]$tc.followup_agent } else { '' }
    if ($fuAgent -and $fuAgent -notmatch '^agent\.[a-z][a-z0-9_]*$') { throw "[$($tc.id)] followup_agent '$fuAgent' ungueltig" }
    $fuSql = if ($fuAgent) { "SELECT agent.fn_set_dispatch_followup(jsonb_build_object('chat_id','$chatId','agent','$fuAgent'));" }
             else { "SELECT agent.fn_take_dispatch_followup(jsonb_build_object('chat_id','$chatId'));" }
    $fuRes = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-t', '-A', '-c', $fuSql)
    if ($fuRes.Code -ne 0) { throw "[$($tc.id)] Folge-Bindung setzen fehlgeschlagen: $(($fuRes.Output | Where-Object { $_ }) -join ' ')" }
    $base = Get-MaxExecId -WfId $OrchWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY

    # Bot-Persona (Case-Feld persona): die Owner-Persona gilt NUR fuer diesen Fall -> im finally wieder neutral, weil
    # alle Faelle als derselbe gepairte Owner laufen (ein Rest wuerde die folgenden Faelle faerben).
    if ($tc.persona -and -not (Set-TestPersonaFact -Container $Container -PersonId 'owner' -Code "$($tc.persona)")) {
        Write-Host "    [FAIL] Persona '$($tc.persona)' konnte nicht gesetzt werden." -ForegroundColor Red; $failed++; continue
    }
    try {
        Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $chatId -FromUid $PairedUid -Text $tc.task | Out-Null
        $ex = Wait-ExecResolvingGates -WfId $OrchWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $caseTimeout
    } finally {
        if ($tc.persona) { [void](Set-TestPersonaFact -Container $Container -PersonId 'owner' -Code '') }
    }
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
    $specialistOut = Get-SpecialistOutput $runData
    if ($tc.verbatim_relay) {
        $vr = Test-VerbatimRelay $specialistOut (Get-AgentOutput $runData)
        Write-Host "    verbatim_relay: $($vr.ok) ($($vr.reason))"
        if (-not $vr.ok) { $pass = $false }
    }
    # expected_signal (Bot mit Gesicht): FRAME|NOFRAME, das der Router nach dem Spezialisten liefert (Relay compose.signal;
    # Regel 6 gilt fuer ALLE Personen, NOFRAME = ernst -> kein Sticker).
    if ($tc.expected_signal) {
        $sig = ''
        if ($runData.PSObject.Properties.Name.Contains('Relay compose')) { try { $sig = [string]$runData.'Relay compose'[0].data.main[0][0].json.signal } catch { } }
        Write-Host "    signal: '$sig' (erwartet $($tc.expected_signal))"
        if ($sig -ne "$($tc.expected_signal)") { $pass = $false }
    }
    if ($tc.expected_behavior) {
        $judgeBundle += [ordered]@{
            id = $tc.id; name = $tc.name; task = $tc.task
            expected_behavior = $tc.expected_behavior; expected_tool = $tc.expected_route
            det_pass = $pass; actual_tool = $routeShown; actual_tool_input = ''
            read_tools = ''; specialist_output = $specialistOut; actual_output = (Get-AgentOutput $runData)
        }
        Write-Host "    [JUDGE] Verhalten zur AI-Bewertung vorgemerkt" -ForegroundColor Cyan
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
Write-JudgeBundle -Entries $judgeBundle -RepoRoot $RepoRoot
Write-LlmCostReport -Usage (Get-LlmUsage -Container $Container -AfterCursor $llmCursor) -Label 'orch_test' -RepoRoot $RepoRoot
Write-Host ""
exit $failed
