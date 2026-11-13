#Requires -Version 5.1
# Orchestrator Routing Tests. Prueft, ob agent.orchestrator.main_route eine Anfrage korrekt an den
# richtigen Spezialisten routet (Tool "Call 'agent.<x>'") oder selbst beantwortet (Non-Finance).
#
# Der Treiber feuert ein Telegram-foermiges Update mit numerischer chat_id (gepairter Owner-Sender) an den
#   echten Telegram-Trigger-Webhook des Orchestrators (Produktivpfad, wie real_ingress). Das echte
#   Send-and-Wait-Gate eines vom Sub-Agenten gewaehlten Write-Tools wird ueber das abgefangene
#   Mock-Telegram declined (kein Write, kein Spam) -> die Routing-Entscheidung steht im
#   Orchestrator-runData. Execution-Korrelation: monotone Exec-id.
#
# Voraussetzung: laufendes Substrat + enable_mock_telegram.ps1 (fuers Gate). Echtes LLM (Claude):
#   mock_llm nicht aktiv (sonst gescriptetes statt echtes Routing). .env TEST_HARNESS_SECRET nicht noetig.
#
# Case-Felder (Bot-Persona, alle optional): persona = Owner-Persona nur fuer diesen Fall (danach neutral);
#   verbatim_relay = true -> die Spezialisten-Antwort muss woertlich im Endtext stehen, plus hoechstens ein Satz;
#   expected_behavior = Rubric -> Eintrag im Judge-Bundle (inkl. specialist_output), Auswertung judge_eval.ps1;
#   followup_agent = 'agent.<x>' -> vor dem Fall die Knopf-Folge-Bindung dieses Chats setzen (Router-Regel 2a);
#   router_history = {human, agent, output} oder Liste davon -> fruehere Spezialisten-Turns im Router-Gedaechtnis, Form wie im Betrieb;
#     mit button = true (ohne human) traegt agent.fn_set_router_button_turn den Turn ein wie der Knopf-Arm;
#   expected_signal = FRAME|NOFRAME -> Router-Signal nach dem Spezialisten (Relay compose.signal, Regel 6 fuer alle);
#   expected_mood = LOVE|CHEER|RELIEF|FUN|'' -> Stimmung der Router-Zeile (Relay compose.mood; '' = keine);
#   expect_body_empty = true -> der Router antwortet nur mit einer Reaktion (Relay compose.body leer, kein Text).
#
# Usage:  .\scripts\orch_test.ps1 [-Id oc01] [-Timeout 90] [-Verbose]
# Exit-Code = Anzahl Fehler. Kostet LLM-Credits (owner-gegatet).
param(
    [string]$Id,
    [int]$Timeout = 90,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# N8N_URL/N8N_API_KEY kommen aus dem Docker-Test-Substrat, nicht aus .env.
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn        = Get-TestN8nConnection
$N8N_URL     = $conn.Url
$N8N_API_KEY = $conn.ApiKey
$Container   = $conn.Container
$Headers     = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }

$state = Get-TestN8nState
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (fuer die Gate-Aufloesung noetig). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
# Mock-LLM aktiv = gescriptetes statt echtes Routing -> hart abbrechen; der Waechter prueft den
# tatsaechlichen Gateway-Upstream, nicht nur den State-Block. Dazu die Start-Marke fuer die Kostenuebersicht.
Assert-LlmGatewayUpstream -Container $Container -Expect real
$llmCursor = Get-LlmUsageCursor -Container $Container

$AgentNode   = 'Orchestrator agent'
# Route-Agenten aus den Manifesten (Verdikt-Logik geteilt mit mock_route_test).
$routeAgents = Get-TestRouteAgent

# Anders als Get-AgentOutput (test_n8n_state.ps1): nach einem Spezialisten zaehlt der gesendete Text, nicht die Agent-Ausgabe.
function Get-SentOutput([object]$RunData) {
    $txt = ''
    # Die gesendete Nachricht = Rahmensatz aus 'Claim expression' (frame_r.text, falls da) + Leerzeile +
    # 'Relay compose'.body; der Agent selbst liefert nach einem Spezialisten nur FRAME/NOFRAME. Fuer Judge
    # und verbatim_relay zaehlt der gesendete Text.
    if ($RunData.PSObject.Properties.Name.Contains('Relay compose')) {
        $body = ''; $frame = ''
        try { $body = [string]$RunData.'Relay compose'[0].data.main[0][0].json.body } catch { }
        try { $frame = [string]$RunData.'Claim expression'[0].data.main[0][0].json.frame_r.text } catch { }
        if ($frame) { return "$frame`n`n$body" }
        return $body
    }
    if (-not $RunData.PSObject.Properties.Name.Contains($AgentNode)) { return $txt }
    foreach ($run in $RunData.$AgentNode) { try { if ($run.data.main[0][0].json.output) { $txt = $run.data.main[0][0].json.output } } catch { } }
    return $txt
}
# Die Antwort des Spezialisten = laengster Text-Blatt-Wert in der Ausgabe (.data) der "Call 'agent.<x>'"-Tool-Nodes
# (ein JSON-String mit .output wird ausgepackt). Leer = kein Spezialist gerufen. Nur .data: die Eingabe
# (inputOverride) traegt die Nutzernachricht, die sonst eine kuerzere Antwort als "laengster Text" schlaegt.
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
        foreach ($s in (Get-StringLeafList @($p.Value | ForEach-Object { $_.data }))) {
            $t = $s
            if ($t.TrimStart().StartsWith('{')) { try { $j = $t | ConvertFrom-Json; if ($j.output) { $t = [string]$j.output } } catch { } }
            if ($t.Length -gt $best.Length) { $best = $t }
        }
    }
    return $best
}
# verbatim_relay: der Spezialisten-Text steht (Leerraum normalisiert) im Endtext, und ausserhalb davon steht hoechstens
# ein Satz (der Persona-Rahmensatz). Liefert @{ ok; reason }.
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

# Router-Gedaechtnis: ein frueherer Spezialisten-Turn, Zeilenform wie im Betrieb (Mensch, Tool-Aufruf, Tool-Ergebnis, Signal).
# Die Tabelle legt der n8n-Memory-Node erst beim ersten Router-Turn an -> sonst klarer Abbruch statt stillem Fall ohne Verlauf.
function Set-TestRouterHistory {
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$SessionId, [Parameter(Mandatory)]$Turn)
    $meta = @{ additional_kwargs = @{}; response_metadata = @{} }
    $statements = @()
    $n = 0
    foreach ($t in @($Turn)) {
        $n++
        if ([string]$t.agent -notmatch '^agent\.[a-z][a-z0-9_.]*$') { throw "router_history.agent '$($t.agent)' ungueltig" }
        if ($t.PSObject.Properties['button'] -and $t.button) {
            $btn = ConvertTo-Json -Compress -InputObject @{ chat_id = $SessionId; agent = [string]$t.agent; output = [string]$t.output }
            $statements += "SELECT agent.fn_set_router_button_turn(`$hist`$$btn`$hist`$::jsonb);"
            continue
        }
        $rows = @()
        $toolName = 'Call_' + (([string]$t.agent) -replace '[^a-z0-9_]', '_') + '_'
        $callId = "toolu_test_router_history_$n"
        $rows += ($meta + @{ type = 'human'; content = [string]$t.human })
        $rows += ($meta + @{ type = 'ai'; content = @(); invalid_tool_calls = @(); tool_calls = @(@{ id = $callId; name = $toolName; type = 'tool_call'; args = @{ input = [string]$t.human } }) })
        $rows += ($meta + @{ type = 'tool'; name = $toolName; tool_call_id = $callId; content = (ConvertTo-Json -Compress -InputObject @(@{ output = [string]$t.output })) })
        $rows += ($meta + @{ type = 'ai'; content = 'NOFRAME'; invalid_tool_calls = @(); tool_calls = @() })
        $values = @($rows | ForEach-Object { "('$SessionId', `$hist`$$(ConvertTo-Json -Compress -Depth 8 -InputObject $_)`$hist`$::jsonb)" }) -join ', '
        $statements += "INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES $values;"
    }
    # Ueber eine Datei: PowerShell 5.1 streift die Anfuehrungszeichen des JSON an nativen Argumenten ab.
    $sqlFile = Join-Path ([System.IO.Path]::GetTempPath()) "orch_router_history_$PID.sql"
    [System.IO.File]::WriteAllText($sqlFile, ($statements -join "`n"), $Utf8NoBom)
    try { $r = Invoke-TestN8nPsqlFile -Container $Container -HostFile $sqlFile -PsqlArgs @('-q') } finally { Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue }
    if ($r.Code -ne 0) { throw "router_history setzen fehlgeschlagen (Tabelle entsteht erst beim ersten Router-Turn): $(($r.Output | Where-Object { $_ }) -join ' ')" }
}

$ingress = Resolve-OrchestratorIngress -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
$OrchWfId = $ingress.OrchWfId
# Dieselbe Vorbereitung wie n8n_test/mock_route_test/e2e_test (Fixtures + abgeschlossenes Onboarding): auf einem frischen
# Substrat leitet der Spezialist sonst auf die Einrichtung um und der Router-Pin onboarding_in_progress zieht Gruesse zum Guide.
Initialize-AgentTestState -Container $Container -RepoRoot $RepoRoot
$PairedUid = $TestOwnerTelegramUid
Set-OwnerTelegramPairing -Container $Container -Uid $PairedUid
Write-Host "  Orchestrator: id=$OrchWfId   Ingress: $($ingress.Url)"

$tcFile = Join-Path $RepoRoot 'tests\agent\core\orch_cases.json'
$allCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$cases = @(if ($Id) { $allCases | Where-Object { $_.id -eq $Id } } else { $allCases })
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
    # Chat = der gepairte Owner wie im Privatchat (chat.id = from.id): die Spezialisten loesen den Absender aus der chat_id auf,
    # mit einer fremden Test-chat_id gilt er als unbekannt. Die Isolation zwischen den Faellen halten Memory- und Karten-Reset.
    [long]$chatId = $PairedUid
    Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
    Clear-HitlPending -Container $Container
    Clear-MockTelegramRequests -Container $Container
    # Folge-Bindung (Case-Feld followup_agent): simuliert "ein Knopf hat eben agent.<x> gestartet" fuer genau
    # diesen Chat (agent.fn_set_dispatch_followup, wie der Knopf-Arm nach dem Relay) -> die Nachricht prueft die
    # Router-Regel 2a. Ohne Feld wird eine Rest-Bindung des Chats geloescht (fn_take liest+loescht einmalig).
    $fuAgent = if ($tc.PSObject.Properties['followup_agent'] -and $tc.followup_agent) { [string]$tc.followup_agent } else { '' }
    if ($fuAgent -and $fuAgent -notmatch '^agent\.[a-z][a-z0-9_]*$') { throw "[$($tc.id)] followup_agent '$fuAgent' ungueltig" }
    $fuSql = if ($fuAgent) { "SELECT agent.fn_set_dispatch_followup(jsonb_build_object('chat_id','$chatId','agent','$fuAgent'));" }
             else { "SELECT agent.fn_take_dispatch_followup(jsonb_build_object('chat_id','$chatId'));" }
    $fuRes = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-t', '-A', '-c', $fuSql)
    if ($fuRes.Code -ne 0) { throw "[$($tc.id)] Folge-Bindung setzen fehlgeschlagen: $(($fuRes.Output | Where-Object { $_ }) -join ' ')" }
    if ($tc.PSObject.Properties['router_history'] -and $tc.router_history) { Set-TestRouterHistory -Container $Container -SessionId "$chatId" -Turn $tc.router_history }
    $base = Get-MaxExecId -WfId $OrchWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY

    # Die Owner-Persona (Case-Feld persona) gilt nur fuer diesen Fall -> im finally wieder neutral, weil
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
    $tools = @(Get-ToolCall $runData $AgentNode | ForEach-Object { $_.tool })
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
        $vr = Test-VerbatimRelay $specialistOut (Get-SentOutput $runData)
        Write-Host "    verbatim_relay: $($vr.ok) ($($vr.reason))"
        if (-not $vr.ok) { $pass = $false }
    }
    # expected_signal: FRAME|NOFRAME, das der Router nach dem Spezialisten liefert (Relay compose.signal;
    # Regel 6 gilt fuer alle Personen, NOFRAME = ernst -> kein Sticker).
    if ($tc.expected_signal) {
        $sig = ''
        if ($runData.PSObject.Properties.Name.Contains('Relay compose')) { try { $sig = [string]$runData.'Relay compose'[0].data.main[0][0].json.signal } catch { } }
        Write-Host "    signal: '$sig' (erwartet $($tc.expected_signal))"
        if ($sig -ne "$($tc.expected_signal)") { $pass = $false }
    }
    # expected_mood / expect_body_empty: Stimmung bzw. reine Reaktion aus 'Relay compose' (Grammatik N1: FRAME <MOOD>,
    # REACT <MOOD> [+ Text]); die Entscheidung ueber die Reaktion faellt danach in agent.fn_claim_reaction.
    if ($null -ne $tc.expected_mood -or $tc.expect_body_empty) {
        $rc = $null
        if ($runData.PSObject.Properties.Name.Contains('Relay compose')) { try { $rc = $runData.'Relay compose'[0].data.main[0][0].json } catch { } }
        if ($null -ne $tc.expected_mood) {
            $mood = if ($rc) { [string]$rc.mood } else { '' }
            Write-Host "    mood: '$mood' (erwartet '$($tc.expected_mood)')"
            if ($mood -ne "$($tc.expected_mood)") { $pass = $false }
        }
        if ($tc.expect_body_empty) {
            $bodyEmpty = $rc -and -not [string]$rc.body
            Write-Host "    body leer: $bodyEmpty"
            if (-not $bodyEmpty) { $pass = $false }
        }
    }
    if ($tc.expected_behavior) {
        $judgeBundle += [ordered]@{
            id = $tc.id; name = $tc.name; task = $tc.task
            expected_behavior = $tc.expected_behavior; expected_tool = $tc.expected_route
            det_pass = $pass; actual_tool = $routeShown; actual_tool_input = ''
            read_tools = ''; specialist_output = $specialistOut; actual_output = (Get-SentOutput $runData)
        }
        Write-Host "    [JUDGE] Verhalten zur AI-Bewertung vorgemerkt" -ForegroundColor Cyan
    }

    if ($pass) {
        $passed++; Write-Host "    [PASS] route=$routeShown" -ForegroundColor Green
        if ($Verbose) { Write-Host "    output: $(Get-SentOutput $runData)" -ForegroundColor DarkGray }
    } else {
        $failed++; Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
        Write-Host "    output: $(Get-SentOutput $runData)" -ForegroundColor Yellow
    }
}

try { (Invoke-N8nGet "executions?workflowId=$OrchWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($cases.Count) Tests bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-JudgeBundle -Entries $judgeBundle -RepoRoot $RepoRoot
Write-LlmCostReport -Usage (Get-LlmUsage -Container $Container -AfterCursor $llmCursor) -Label 'orch_test' -RepoRoot $RepoRoot
Write-Host ""
exit $failed
