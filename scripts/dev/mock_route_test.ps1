#Requires -Version 5.1
# mock_route_test.ps1 — DETERMINISTISCHER, GRATIS Routing-/Tool-Path-Test ueber den Mock-LLM
# (Teststrategie Phase 6, auf Weg C / Phase 8 umgestellt). KEIN echtes LLM, keine API-Credits ->
# eigener Tier (anders als die owner-gegateten n8n_test/orch_test) und vom PreToolUse-deny-Hook NICHT
# erfasst (anderer Name).
#
# WEG C (Phase 8): KEIN test_-Gate-Bypass, KEIN Orchestrator-"Test entry" mehr. Stattdessen Prod-Pfad:
#   - Orchestrator-Ziel  -> feuert am ECHTEN Telegram-Trigger-Webhook (numerische chat_id, gepairter
#                            Owner-Sender), wie real_ingress.
#   - Agent-Ziel (jeder Route-Agent aus provides.agents) -> feuert am Agent-Harness (<x>-test), der
#                            den Agenten als Sub-Workflow ueber seinen PRODUKTIONS-executeWorkflowTrigger
#                            aufruft (kein Test-Sonderknoten im Agenten).
#   Beide: Execution-Korrelation ueber monotone Exec-id (Get-MaxExecId vor dem Feuern); jedes echte
#   Send-and-Wait-Gate wird ueber das abgefangene Mock-Telegram DECLINEd (Wait-ExecResolvingGates) ->
#   das Tool nimmt den 'cancelled'-Ausgang (kein DB-Write), die Routing-Entscheidung steht im runData.
#
# Der Mock-LLM-Stub liefert pro Task gescriptete functionCall/Text-Antworten (tests/mock_llm/scenarios.json)
# -> deterministisches Routing. So wird der Agent-Tool-Pfad ein HARTES, gratis Gate.
#
# Assertion (auto je Case-Form):
#   - Case hat `expected_route` (orch_cases.json): prueft `Call 'agent.<route>'` im Orchestrator-runData.
#   - Case hat `expected_tool` (finance_cases.json etc.): prueft, ob genau dieses Write-Tool aufgerufen wurde.
#
# Modi:
#   .\scripts\dev\mock_route_test.ps1                       # Orchestrator-Routing (orch_cases.json)
#   .\scripts\dev\mock_route_test.ps1 -Discover -Id oc01    # NUR feuern + Mock-Log dumpen (Tool-Namen)
#   .\scripts\dev\mock_route_test.ps1 -TargetWorkflow agent.finance -WebhookPath finance-test `
#       -CasesFile tests\agent\finance\finance_cases.json   # Agent-Tool-Path (Agent-Node wird auto-erkannt)
#   Webhook-Pfade je Agent-Ziel: finance-test / advisor-test / monitor-test / guide-test.
#   ... -Id tc62; ... -Id tc06 -KeepMemory                  # Folge-Nachricht liest die Historie des ersten Falls
#                                                          (Mehr-Tool-Runden im Gedaechtnis wieder einlesen)
#
# Voraussetzung: laufendes Substrat + enable_mock_llm.ps1 + enable_mock_telegram.ps1 + .env TEST_HARNESS_SECRET.
# Exit-Code = Anzahl Fehler.
#   ... -Id oc01,oc02                                      # mehrere Faelle (unbekannte id = Abbruch vor dem Lauf)
#   ... -ForceAbortId oc01                                 # Testschalter: wirft am Anfang dieses Falls (oder von draft-fail) eine
#                                                          # Ausnahme und zeigt so den Abbruch-Pfad ohne echte Last
# Eine Ausnahme im Fall (z. B. HTTP 500 vom Eingang unter Last) macht NUR diesen Fall rot, der Lauf geht weiter.
param(
    [string[]]$Id,
    [string]$ForceAbortId,
    [int]$Timeout = 90,
    [string]$TargetWorkflow = 'agent.orchestrator.main_route',
    [string]$WebhookPath = 'finance-test',
    [string]$AgentNode = 'Orchestrator agent',
    [string]$CasesFile = 'tests\agent\core\orch_cases.json',
    # Welche Tool-Node-Namen als WRITE-Tool zaehlen (expected_tool-Matching). Leer = Default 'tool_*'
    # (Finance-Konvention). Seit Phase D sind ALLE Write-Tools tool_*-praefixiert -> der Default deckt auch
    # Advisor/Guide/Monitor; -WriteTools (z.B. tool_save_plan_section,tool_publish_plan,tool_create_monitor_trigger) nur noch zum Verengen.
    [string[]]$WriteTools = @(),
    [switch]$Discover,
    # Chat-Gedaechtnis NICHT vor dem Fall leeren -> zwei Aufrufe nacheinander pruefen das Wiedereinlesen einer
    # Historie mit mehreren Tool-Runden (n8n-Korrektur memory-all-tool-rounds, provisioning/lib/n8n_patches.sh).
    [switch]$KeepMemory,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
# Ueber powershell.exe -File (z. B. aus Bash) kommt "a,b,c" als EIN String an -> sonst zaehlte kein Write (2026-10-23).
$WriteTools = @($WriteTools | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Id = @($Id | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # ebenso -Id "a,b"

. "$PSScriptRoot\..\lib\dotenv.ps1"
Read-DotEnvLines "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') { Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script }
}
. "$PSScriptRoot\test_n8n_state.ps1"
$conn        = Get-TestN8nConnection
$N8N_URL     = $conn.Url
$N8N_API_KEY = $conn.ApiKey
$Container   = $conn.Container
if ([string]::IsNullOrEmpty($TEST_HARNESS_SECRET)) { throw "TEST_HARNESS_SECRET ist nicht gesetzt in .env" }
$Headers     = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }
$AuthHeader  = 'X-Test-Auth'

# --- Beide Mocks aktiv? (mock_llm fuer das Routing, mock_telegram fuer die Gate-Aufloesung) ----------
$stateFile = Get-TestN8nStateFile
$state = [System.IO.File]::ReadAllText($stateFile, $Utf8NoBom) | ConvertFrom-Json
if (-not $state.mock_llm) { throw "Mock-LLM nicht aktiv (kein mock_llm-Block im State). Zuerst: .\scripts\dev\enable_mock_llm.ps1" }
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (Gate-Aufloesung). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
# Der State-Block allein beweist nichts (Container-Neustart verwirft das Laufzeit-Drop-in) -> den tatsaechlichen
# Gateway-Upstream pruefen: zeigte er auf die echte API, kostete dieser Gratis-Tier Credits.
Assert-LlmGatewayUpstream -Container $Container -Expect mock


# --- "Bot denkt nach" (Schleife core.sub_show_thinking bis zur Antwort, Schalter agent.thinking_lease) ------------
# Zeiten als Epoch-Sekunden: Mock-Telegram-Log (t, ISO) und DB (clock_timestamp) laufen im selben Container.
function ConvertTo-EpochSec($T) {
    $dt = if ($T -is [datetime]) { $T } else { [datetime]::Parse([string]$T, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    ([DateTimeOffset]$dt.ToUniversalTime()).ToUnixTimeMilliseconds() / 1000.0
}
function Invoke-ScalarSql([string]$Sql) {
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', $Sql)
    if ($r.Code -ne 0) { throw "SQL fehlgeschlagen: $($r.Output -join ' ')" }
    ([string](@($r.Output) | Where-Object { "$_".Trim() } | Select-Object -Last 1)).Trim()
}
# Drafts (je mit .at = Epoch) + Zeitpunkt der Antwort = LETZTES sendMessage an den Chat (eine Bestaetigungskarte davor
# ist auch ein sendMessage; danach laeuft die Schleife legitim weiter, bis die Antwort kommt).
function Get-ThinkingTimeline([long]$ChatId) {
    $reqs = @(Get-MockTelegramRequests -Container $Container)
    $answer = $reqs | Where-Object { $_.method -eq 'sendMessage' -and [string]$_.body.chat_id -eq "$ChatId" } | Select-Object -Last 1
    [pscustomobject]@{
        Drafts = @($reqs | Where-Object { $_.method -eq 'sendMessageDraft' } | ForEach-Object {
            [pscustomobject]@{ at = (ConvertTo-EpochSec $_.t); chat = [string]$_.body.chat_id } })
        Answer = if ($answer) { ConvertTo-EpochSec $answer.t } else { $null }
    }
}
# Nach jeder Antwort: Schalter weg, kein Draft NACH der Antwort, jeder Draft an den Absender-Chat.
function Test-ThinkingAfterAnswer([long]$ChatId) {
    $tl = Get-ThinkingTimeline $ChatId
    $ok = $true
    $wrong = @($tl.Drafts | Where-Object { $_.chat -ne "$ChatId" })
    if ($wrong.Count -gt 0) { $ok = $false; Write-Host "    FEHLER: Anzeige an chat_id=$($wrong[0].chat) statt $ChatId" -ForegroundColor Red }
    if ($null -ne $tl.Answer) {
        $late = @($tl.Drafts | Where-Object { $_.at -gt $tl.Answer })
        if ($late.Count -gt 0) { $ok = $false; Write-Host "    FEHLER: $($late.Count) 'Denkt nach'-Anzeige(n) NACH der Antwort" -ForegroundColor Red }
    }
    $left = Invoke-ScalarSql "SELECT count(*) FROM agent.thinking_lease WHERE chat_id = $ChatId;"
    if ($left -ne '0') { $ok = $false; Write-Host "    FEHLER: 'Denkt nach'-Schalter nach der Antwort nicht geloescht ($left Zeile(n))" -ForegroundColor Red }
    return $ok
}
# Schleife endet nach dem Loeschen des Schalters (Befund 2026-10-24): spaetestens eine Runde (5 s Wait) nach dem
# Loeschen darf keine core.sub_show_thinking-Execution mehr laufen. Ueber die n8n-API, NICHT per Roh-SQL: n8n loescht
# nicht gespeicherte Laeufe (saveDataSuccessExecution none) nur weich -- execution_entity behaelt status 'running' mit
# deletedAt bis zum Pruning; die API blendet sie aus. Wartet mit fruehem Abbruch bis $TimeoutSec.
function Get-ThinkingWorkflowId {
    $wf = $wfList.data | Where-Object { $_.name -eq 'core.sub_show_thinking' } | Select-Object -First 1
    if (-not $wf -or -not $wf.id) { throw "core.sub_show_thinking nicht im Substrat (ohne id zaehlte der Filter jede laufende Execution)" }
    return [string]$wf.id
}
function Get-RunningThinkingLoop { @((Invoke-N8nGet "executions?workflowId=$(Get-ThinkingWorkflowId)&status=running&limit=20").data) }
function Test-NoThinkingLoopRunning([int]$TimeoutSec = 10) {
    $s = Get-Date
    do {
        $run = Get-RunningThinkingLoop
        if ($run.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    } while (((Get-Date) - $s).TotalSeconds -lt $TimeoutSec)
    Write-Host "    FEHLER: $($run.Count) 'Denkt nach'-Schleife(n) laufen $TimeoutSec s nach dem Loeschen des Schalters noch (ids $(($run | ForEach-Object { $_.id }) -join ', '))" -ForegroundColor Red
    return $false
}

# --- Ziel-Workflow + Ingress aufloesen --------------------------------------------------------------
$isOrch = ($TargetWorkflow -eq 'agent.orchestrator.main_route')
$wfList = Invoke-N8nGet 'workflows?limit=200'
$targetWf = $wfList.data | Where-Object { $_.name -eq $TargetWorkflow } | Select-Object -First 1
if (-not $targetWf) { throw "Ziel-Workflow '$TargetWorkflow' nicht gefunden." }
$TargetWfId = $targetWf.id

# Agent-Node auto-erkennen (erster langchain.agent-Node) — robuster als der -AgentNode-Default.
try {
    $wfDetail = Invoke-N8nGet "workflows/$TargetWfId"
    $agentNodeFound = ($wfDetail.nodes | Where-Object { $_.type -match 'langchain\.agent' } | Select-Object -First 1)
    if ($agentNodeFound) { $AgentNode = $agentNodeFound.name }
} catch { }
Write-Host "  Ziel: $TargetWorkflow  Agent-Node: '$AgentNode'"

$PairedUid = $TestOwnerTelegramUid    # gepairter Owner-Sender — Orchestrator-Pfad + per-Person-gegatete Agenten
# Ziel aus den Manifesten (kein Paket im Treiber): ein unbekanntes Ziel bricht ab.
$routeAgents = Get-TestRouteAgent
$null = Resolve-TestTarget -RouteAgents $routeAgents -TargetWorkflow $TargetWorkflow   # unbekanntes Ziel -> Abbruch
# Absender = gepairter Fixture-Owner (Orchestrator-Pfad UND jedes Agent-Ziel) + Fixtures/abgeschlossenes Onboarding:
# Initialize-AgentTestState (scripts/dev/test_n8n_state.ps1, gemeinsam mit n8n_test.ps1). Gratis, deterministisch;
# Container-DB-Pfad, NIE db_apply.ps1 (das zielt auf die db_test-DB; tests/CLAUDE.md).
Initialize-AgentTestState -Container $Container -RepoRoot $RepoRoot
if ($isOrch) {
    $ingress = Resolve-OrchestratorIngress -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
    Write-Host "  Ingress (echter Telegram-Webhook): $($ingress.Url)"
} else {
    $WebhookUrl = "$N8N_URL/webhook/$WebhookPath"
    Write-Host "  Ingress (Agent-Harness): $WebhookUrl"
}

$tcFile = Join-Path $RepoRoot $CasesFile
$allCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$cases = @(if ($Id) { $allCases | Where-Object { $_.id -in $Id } } else { $allCases })
# Jede genannte id muss es geben: sonst liefe ein Tippfehler still als kleinerer, gruener Lauf.
$missing = @(foreach ($one in $Id) { if ($one -notin @($allCases.id)) { $one } })
if ($missing.Count) { throw "Testfall nicht gefunden in ${CasesFile}: $($missing -join ', ')." }
if (-not $cases) { throw "Keine Testfaelle in $CasesFile." }
if ($ForceAbortId -and $ForceAbortId -notin (@($cases.id) + 'draft-fail')) { throw "-ForceAbortId $ForceAbortId ist nicht unter den ausgewaehlten Faellen (oder draft-fail)." }

# Aufraeumen nach einem abgebrochenen Fall: wartende Gate-Executions des Ziels stoppen, Sperr-Zeilen leeren (sonst waere der Folgefall rot).
function Clear-CaseLeftovers {
    try { (Invoke-N8nGet "executions?workflowId=$TargetWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }
    Clear-HitlPending -Container $Container
    Clear-ThinkingLease -Container $Container
}

Write-Host ""
Write-Host "Mock-Route-Test ($TargetWorkflow) -- $($cases.Count) Testfall(e)"
Write-Host ("-" * 64)
$passed = 0; $failed = 0; $pkgOnbDirty = $false

foreach ($tc in $cases) {
    try {
        Write-Host ""
        Write-Host "  [$($tc.id)] $($tc.name)"
        Write-Host "    Task: '$($tc.task)'"
        Test-ForceAbort $tc.id $ForceAbortId

        $caseTimeout = if ($tc.PSObject.Properties['timeout_s'] -and $tc.timeout_s) { [int]$tc.timeout_s } else { $Timeout }
        [long]$chatId = $PairedUid
        try {
            # Gedaechtnis + Wiederhol-Sperre (ohne Orchestrator-Abschluss bliebe die Karte des Vorfalls gesperrt) + Onboarding.
            Reset-TestCaseState -Container $Container -SessionId $(if ($KeepMemory) { '' } else { "$chatId" }) `
                -Onboarding $(if ($tc.onboarding) { "$($tc.onboarding)" } else { 'completed' })
            if (-not $KeepMemory -and $tc.PSObject.Properties['chat_history'] -and $tc.chat_history) { Set-TestChatHistory -Container $Container -SessionId "$chatId" -ChatHistory $tc.chat_history }
            if ($tc.package_onboarding -or $pkgOnbDirty) {
                Set-TestPackageOnboarding -Container $Container -Sections $tc.package_onboarding
                $pkgOnbDirty = [bool]$tc.package_onboarding
            }
            # Voraussetzungen wie im bezahlten Tier (eine Stelle: Invoke-TestCaseSetup); vorher alte __E2E__-Reste weg
            if ($tc.setup_sql) {
                [void](Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', 'SELECT agent.fn_clear_e2e_data();'))
                Invoke-TestCaseSetup -Container $Container -Sql "$($tc.setup_sql)"
            }
        }
        catch { Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red; $failed++; continue }
        Clear-MockRequestLogs -Container $Container
        $base = Get-MaxExecId -WfId $TargetWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY

        # Feuern: Orchestrator -> echter Telegram-Webhook; Agent -> Harness.
        try {
            if ($isOrch) {
                Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $chatId -FromUid $PairedUid -Text $tc.task | Out-Null
            } else {
                $payload = @{ task = $tc.task; chat_id = "$chatId"; call_depth = 0 } | ConvertTo-Json -Compress
                try {
                    Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
                        -TimeoutSec 8 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
                } catch {
                    if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) { throw }
                }
            }
        } catch {
            Write-Host "    [FAIL] Feuern fehlgeschlagen: $_" -ForegroundColor Red; $failed++; continue
        }

        # Execution zum Terminalstatus treiben + jedes Gate DECLINEn (Routing-Tier -> kein Write).
        $ex = Wait-ExecResolvingGates -WfId $TargetWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $caseTimeout
        if (-not $ex) { Write-Host "    [FAIL] Keine Execution gefunden (Timeout $caseTimeout s)." -ForegroundColor Red; $failed++; continue }

        if (-not $Discover -and $ex.status -eq 'error') {
            $errMsg = $null; try { $errMsg = $ex.data.resultData.error.message } catch { }
            Write-Host "    [FAIL] Execution status=error (kein gueltiges Routing-Ergebnis): $errMsg" -ForegroundColor Red
            if ($Verbose) { foreach ($m in (Get-MockLlmRequests -Container $Container)) { Write-Host "      mock: offered=[$($m.offered -join ', ')] decision=$($m.decision)" -ForegroundColor Yellow } }
            $failed++; continue
        }

        $runData = $ex.data.resultData.runData
        $tools = @(Get-ToolCall $runData $AgentNode | ForEach-Object { $_.tool })
        Write-Host "    Execution: id=$($ex.id)  status=$($ex.status)  tools=[$($tools -join ', ')]"

        if ($Discover) {
            Write-Host "    [DISCOVER] Mock-Entscheidungen:" -ForegroundColor Cyan
            foreach ($m in (Get-MockLlmRequests -Container $Container)) {
                Write-Host ("      offered=[{0}]  decision={1}" -f ($m.offered -join ', '), $m.decision) -ForegroundColor DarkCyan
            }
            continue
        }

        # --- Assertion: route (orchestrator) ODER tool (agent) je nach Case-Form ---
        $pass = $false
        if ($tc.PSObject.Properties['expected_route']) {
            $expect = [string]$tc.expected_route
            $hit = Get-RoutedAgent -Tools $tools -RouteAgents $routeAgents
            $pass = Test-ExpectedRoute -Routed $hit -Expected $expect -RouteAgents $routeAgents
            if (-not $pass) {
                $want = if ($expect) { "route=$expect" } else { 'kein Routing' }
                Write-Host "    FEHLER: erwartet $want, got [$($hit -join '+')]" -ForegroundColor Red
            }
        } elseif ($tc.PSObject.Properties['expected_tool']) {
            # Write-Tool-Erkennung: -WriteTools-Liste (Advisor: tool_save_plan_section,...) ODER Default tool_*.
            # WICHTIG: lokale Variable NICHT $writeTools nennen — PowerShell-Variablen sind case-insensitiv,
            # das wuerde den Param $WriteTools ueberschreiben (leeres $tools im 1. Case -> Param weg).
            $hitWrite = if ($WriteTools.Count -gt 0) { @($tools | Where-Object { $WriteTools -contains $_ }) }
                        else { @($tools | Where-Object { $_ -like 'tool_*' }) }
            $expTool = [string]$tc.expected_tool
            if ($expTool) {
                $pass = ($hitWrite -contains $expTool)
                if (-not $pass) { Write-Host "    FEHLER: erwartet tool=$expTool, got [$($hitWrite -join ', ')]" -ForegroundColor Red }
                # Aufgerufen heisst nicht gelaufen: scheitert der Aufruf am Eingabe-Schema (z. B. Zahl statt Text im
                # Szenario), laeuft der Tool-Workflow nie, der Agent bekommt nur eine Fehlermeldung (2026-10-23 so unbemerkt).
                if ($pass -and $runData.PSObject.Properties.Name -contains $expTool) {
                    $toolErr = @($runData.$expTool | Where-Object { $_.error -or $_.executionStatus -eq 'error' })
                    if ($toolErr.Count -gt 0) {
                        $pass = $false
                        $em = $null; try { $em = $toolErr[0].error.message } catch { }
                        Write-Host "    FEHLER: Aufruf von $expTool scheiterte (Tool-Workflow lief nicht): $em" -ForegroundColor Red
                    }
                }
            } else {
                $pass = ($hitWrite.Count -eq 0)
                if (-not $pass) { Write-Host "    FEHLER: kein Tool erwartet, got [$($hitWrite -join ', ')]" -ForegroundColor Red }
            }
        } else {
            Write-Host "    FEHLER: Case hat weder expected_route noch expected_tool." -ForegroundColor Red
        }

        # "Bot denkt nach": der Mock-LLM antwortet sofort -> ob VOR der Antwort ein Draft kam, ist ein Wettlauf und wird
        # hier nicht verlangt (das pruefen [thinking-keepalive] und [draft-fail] mit langsamem Mock). Hart: der Schalter
        # ist nach der Antwort weg und kein Draft kam NACH ihr.
        if ($pass -and $isOrch) { $pass = Test-ThinkingAfterAnswer $chatId }

        # Zurueckgespielte Werkzeugaufrufe muessen ihre Angaben behalten (der Mock schickt vor jedem Aufruf einen Denkblock;
        # n8n-Fix #41241 ab 2.45, Regressionswache). Fehlen sie, wiederholt das echte Modell den "leeren" Aufruf.
        if ($pass) {
            $lost = @(Get-MockLlmRequests -Container $Container | ForEach-Object { @($_.replay_lost) } | Where-Object { $_ })
            if ($lost.Count -gt 0) { $pass = $false; Write-Host "    FEHLER: Aufruf ohne Angaben oder unvollstaendig zurueckgespielt (dropped = Block fehlt, unpaired = ohne tool_result): $($lost -join ', ')" -ForegroundColor Red }
        }

        if ($pass) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green }
        else {
            $failed++; Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
            if ($Verbose) { foreach ($m in (Get-MockLlmRequests -Container $Container)) { Write-Host "      mock: offered=[$($m.offered -join ', ')] decision=$($m.decision)" -ForegroundColor Yellow } }
        }
    } catch {
        # Ausnahme im Fall = roter Fall, der Lauf geht weiter (Helfer in test_n8n_state.ps1, Abschnitt Fall-Abbruch).
        $failed++
        Write-CaseAbort -ErrorRecord $_ -CaseId $tc.id -Cleanup { Clear-CaseLeftovers }
    }
}

# --- Fehlerweg "Bot denkt nach": Telegram lehnt den Platzhalter ab (Mock-Schalter /__fail) -> die Antwort muss trotzdem
# kommen, die Execution ist success (kein Fehler-Alarm). Einmal je Orchestrator-Lauf; Mock-Szenario mit 3 s Verzoegerung
# (__mock_slow_answer_short__), damit die Schleife sicher mindestens einen Draft versucht.
$extra = 0
if ($isOrch -and -not $Discover -and @($cases).Count -gt 0) {
    $extra = 1
    $tc = [pscustomobject]@{ task = '__mock_slow_answer_short__' }
    Write-Host ""
    Write-Host "  [draft-fail] Platzhalter abgelehnt -> Antwort kommt trotzdem"
    $mockPort = if ($state.mock_telegram.port) { $state.mock_telegram.port } else { 8089 }
    function Set-MockDraftFail([bool]$On) {
        $q = if ($On) { 'method=sendMessageDraft' } else { 'method=sendMessageDraft&off=1' }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & docker exec $Container sh -c "curl -s 'http://127.0.0.1:$mockPort/__fail?$q'" 2>$null | Out-Null
        $ErrorActionPreference = $prev
    }
    $ok = $false
    try {
        Test-ForceAbort 'draft-fail' $ForceAbortId
        Set-MockDraftFail $true
        [long]$chatId = $PairedUid
        Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
        Clear-MockTelegramRequests -Container $Container
        $base = Get-MaxExecId -WfId $TargetWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
        Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $chatId -FromUid $PairedUid -Text $tc.task | Out-Null
        $ex = Wait-ExecResolvingGates -WfId $TargetWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $Timeout
        $reqs = @(Get-MockTelegramRequests -Container $Container)
        $drafts = @($reqs | Where-Object { $_.method -eq 'sendMessageDraft' }).Count
        $answers = @($reqs | Where-Object { $_.method -eq 'sendMessage' -and [string]$_.body.chat_id -eq "$chatId" }).Count
        if ($Verbose) { Write-Host "    abgelehnte Platzhalter=$drafts  Antworten=$answers  Execution=$($ex.status)" -ForegroundColor DarkGray }
        $ok = $ex -and ($ex.status -eq 'success') -and ($drafts -ge 1) -and ($answers -ge 1)
    } catch {
        # $ok bleibt $false -> unten zaehlt der Fall genau einmal als rot
        Write-CaseAbort -ErrorRecord $_ -CaseId 'draft-fail' -Cleanup { Clear-CaseLeftovers }
    } finally { try { Set-MockDraftFail $false } catch { } }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] Antwort fehlt oder Execution nicht success, wenn der Platzhalter scheitert" -ForegroundColor Red }
}

# --- Chat-Speicher ohne Denkbloecke: mehr Tool-Runden als das Memory-Fenster, der Mock prueft die Signaturen wie die API ---
if ($isOrch -and -not $Discover -and @($cases).Count -gt 0) {
    $extra++
    Write-Host ""
    Write-Host "  [memory-thinking] 7 Nachrichten mit Tool-Runde ueber das Fenster hinaus -> jede beantwortet, kein Denkblock gespeichert"
    $ok = $false
    try {
        Test-ForceAbort 'memory-thinking' $ForceAbortId
        [long]$chatId = $PairedUid
        Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
        Clear-MockTelegramRequests -Container $Container
        $ok = $true
        foreach ($turn in 1..7) {
            $base = Get-MaxExecId -WfId $TargetWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
            Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $chatId -FromUid $PairedUid -Text '__mock_thinking_binding__' | Out-Null
            $ex = Wait-ExecResolvingGates -WfId $TargetWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $Timeout
            if (-not $ex -or $ex.status -ne 'success') { $ok = $false; Write-Host "    FEHLER: Nachricht $turn endet mit Status $($ex.status)" -ForegroundColor Red; break }
        }
        $answers = @(Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'sendMessage' -and [string]$_.body.chat_id -eq "$chatId" -and [string]$_.body.text -like '*Bindung ok*' }).Count
        $rows = [int](Invoke-ScalarSql "SELECT count(*) FROM agent.orchestrator_chat_memory WHERE session_id = '$chatId';")
        $hasType = "EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(message->'content') = 'array' THEN message->'content' END) b WHERE b->>'type' IN"
        $toolRows = [int](Invoke-ScalarSql "SELECT count(*) FROM agent.orchestrator_chat_memory WHERE session_id = '$chatId' AND $hasType ('tool_use'));")
        # Ganzer Zeilentext statt nur content: auch eine Kopie in additional_kwargs/response_metadata waere ein Fund.
        $thinkRows = [int](Invoke-ScalarSql "SELECT (SELECT count(*) FROM agent.orchestrator_chat_memory WHERE message::text LIKE '%signature%') + (SELECT count(*) FROM agent.finance_chat_memory WHERE message::text LIKE '%signature%');")
        if ($Verbose) { Write-Host "    Antworten=$answers  Zeilen=$rows  mitTool=$toolRows  mitDenkblock=$thinkRows" -ForegroundColor DarkGray }
        $ok = $ok -and ($answers -eq 7) -and ($rows -gt 20) -and ($toolRows -ge 7) -and ($thinkRows -eq 0)
    } catch {
        $ok = $false
        Write-CaseAbort -ErrorRecord $_ -CaseId 'memory-thinking' -Cleanup { Clear-CaseLeftovers }
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] Chat-Speicher: Antwort fehlt, Denkblock gespeichert oder Tool-Runde verloren" -ForegroundColor Red }
}

# --- Schrittlimit des Orchestrators: der Nutzer bekommt einen Hinweis, kein stilles Ende -----------------------------
# Mock-Szenario __mock_step_limit__ laesst den Router siebenmal einen Agenten rufen (maxIterations 6). Die Agent-Node
# wirft "Max iterations (6) reached"; ihr Fehler-Ausgang fuehrt in die normale Zustell-Kette (Hinweis core.orch.step_limit)
# und danach in "Agent error alert" (Stop and Error -> Owner-Alarm). Erwartet: Hinweis im Chat (Sprache des Absenders),
# kein Sticker/keine Reaktion, "Denkt nach"-Schalter weg, Execution status=error mit der Limit-Meldung.
if ($isOrch -and -not $Discover -and @($cases).Count -gt 0) {
    $extra++
    Write-Host ""
    Write-Host "  [step-limit] Schrittlimit erreicht -> fester Hinweis an den Nutzer, Owner-Alarm bleibt"
    $ok = $false
    try {
        Test-ForceAbort 'step-limit' $ForceAbortId
        [long]$chatId = $PairedUid
        Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
        Clear-MockTelegramRequests -Container $Container
        $base = Get-MaxExecId -WfId $TargetWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
        Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $chatId -FromUid $PairedUid -Text '__mock_step_limit__' | Out-Null
        $ex = Wait-ExecResolvingGates -WfId $TargetWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $Timeout
        $reqs = @(Get-MockTelegramRequests -Container $Container)
        $texts = @($reqs | Where-Object { $_.method -eq 'sendMessage' -and [string]$_.body.chat_id -eq "$chatId" } | ForEach-Object { [string]$_.body.text })
        $hinted = @($texts | Where-Object { Test-TextHasKey -Text $_ -Key 'core.orch.step_limit' }).Count
        $errMsg = ''; try { $errMsg = [string]$ex.data.resultData.error.message } catch { }
        $lastNode = ''; try { $lastNode = [string]$ex.data.resultData.lastNodeExecuted } catch { }
        if ($Verbose) { Write-Host "    Execution=$($ex.status)  letzter Knoten=$lastNode  Meldung=$errMsg  Hinweise=$hinted  Texte=$($texts.Count)" -ForegroundColor DarkGray }
        $ok = $ex -and ($ex.status -eq 'error') -and ($lastNode -eq 'Agent error alert') -and ($hinted -eq 1)
        if ($ok -and -not (Test-ThinkingAfterAnswer $chatId)) { $ok = $false }
        if ($ok) {
            $emoji = @($reqs | Where-Object { $_.method -in @('sendSticker', 'setMessageReaction') }).Count
            if ($emoji -gt 0) { $ok = $false; Write-Host "    FEHLER: Sticker/Reaktion neben dem Limit-Hinweis" -ForegroundColor Red }
        }
    } catch {
        Write-CaseAbort -ErrorRecord $_ -CaseId 'step-limit' -Cleanup { Clear-CaseLeftovers }
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] Schrittlimit: Hinweis fehlt, doppelt, oder Owner-Alarm (Agent error alert) bleibt aus" -ForegroundColor Red }
}

# --- "Bot denkt nach" lebt bis zur Antwort (Schleife core.sub_show_thinking, 5-s-Takt) ------------------------------
# Mock-Szenario __mock_slow_answer_long__ antwortet erst nach 25 s. Zeitplan ab dem Schalter (agent.thinking_lease):
# bei ~7 s eine offene Karte fuer den Chat (agent.hitl_pending) -> Pause; bei ~16 s Karte weg -> wieder Anzeige.
# Erwartet: Draft vor der Karte, keiner waehrend der Karte (1 s Toleranz fuer einen schon unterwegs befindlichen),
# wieder einer danach, keiner nach der Antwort (7 s nachbeobachtet), Schalter weg, Execution success.
if ($isOrch -and -not $Discover -and @($cases).Count -gt 0) {
    $extra++
    Write-Host ""
    Write-Host "  [thinking-keepalive] Anzeige bis zur Antwort, Pause bei offener Karte (~40 s)"
    $ok = $false
    $card = 'mock-thinking-card'
    try {
        [long]$chatId = $PairedUid
        Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
        Clear-MockTelegramRequests -Container $Container
        $base = Get-MaxExecId -WfId $TargetWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
        Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $chatId -FromUid $PairedUid -Text '__mock_slow_answer_long__' | Out-Null
        $leaseSeen = $null; $s = Get-Date
        while (-not $leaseSeen -and ((Get-Date) - $s).TotalSeconds -lt 15) {
            if ((Invoke-ScalarSql "SELECT count(*) FROM agent.thinking_lease WHERE chat_id = $chatId;") -ne '0') { $leaseSeen = Get-Date }
            else { Start-Sleep -Milliseconds 300 }
        }
        if (-not $leaseSeen) { throw "kein Schalter in agent.thinking_lease nach 15 s" }
        # Gegenprobe fuer Test-NoThinkingLoopRunning: WAEHREND die Antwort aussteht, muss die API die Schleife als
        # running zeigen -- sonst waere "keine laeuft mehr" nach der Antwort nichtssagend.
        Start-Sleep -Milliseconds 2000
        $loopSeen = @(Get-RunningThinkingLoop).Count -ge 1
        if (-not $loopSeen) { Write-Host "    FEHLER: laufende 'Denkt nach'-Schleife ist ueber die API nicht sichtbar (Ende-Pruefung waere nichtssagend)" -ForegroundColor Red }
        Start-Sleep -Milliseconds ([int][Math]::Max(0, 7000 - ((Get-Date) - $leaseSeen).TotalMilliseconds))
        $cardOn = [double](Invoke-ScalarSql "WITH i AS (INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES ($chatId, '$card', now() + interval '5 minutes') RETURNING 1) SELECT extract(epoch FROM clock_timestamp()) FROM i;")
        Start-Sleep -Milliseconds ([int][Math]::Max(0, 16000 - ((Get-Date) - $leaseSeen).TotalMilliseconds))
        $cardOff = [double](Invoke-ScalarSql "WITH d AS (DELETE FROM agent.hitl_pending WHERE execution_id = '$card' RETURNING 1) SELECT extract(epoch FROM clock_timestamp()) FROM d;")
        $ex = Wait-ExecResolvingGates -WfId $TargetWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $Timeout
        Start-Sleep -Seconds 7
        $tl = Get-ThinkingTimeline $chatId
        $before = @($tl.Drafts | Where-Object { $_.at -lt $cardOn }).Count
        $during = @($tl.Drafts | Where-Object { $_.at -gt ($cardOn + 1) -and $_.at -lt $cardOff }).Count
        $after  = @($tl.Drafts | Where-Object { $_.at -gt $cardOff -and ($null -eq $tl.Answer -or $_.at -lt $tl.Answer) }).Count
        Write-Host "    Drafts: vor der Karte=$before  waehrend=$during  danach bis zur Antwort=$after  Antwort=$([bool]$tl.Answer)  Execution=$($ex.status)" -ForegroundColor DarkGray
        $ok = $ex -and ($ex.status -eq 'success') -and ($null -ne $tl.Answer) -and ($before -ge 1) -and ($during -eq 0) -and ($after -ge 1)
        if (-not (Test-ThinkingAfterAnswer $chatId)) { $ok = $false }
        if (-not $loopSeen -or -not (Test-NoThinkingLoopRunning)) { $ok = $false }
    } catch {
        Write-Host "    FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        try { $null = Invoke-ScalarSql "DELETE FROM agent.hitl_pending WHERE execution_id = '$card'; SELECT 1;" } catch { }
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] 'Denkt nach'-Anzeige lebt nicht bis zur Antwort bzw. pausiert nicht bei offener Karte" -ForegroundColor Red }
}

# --- Frei-SQL ohne query-Argument (Befund 2026-10-24, Execution 732) -------------------------------------------
# Paket-neutral: jedes Agent-Ziel mit postgres_select. Szenario __mock_select_no_query__ ruft postgres_select mit {}.
# Erwartet: Execution success und das Tool-Ergebnis ist die Guard-Zeile {ok:false, error} (New-PostgresSelectToolNode),
# kein n8n-interner Fehler ("Cannot read properties of undefined (reading 'match')").
if (-not $isOrch -and -not $Discover -and @($cases).Count -gt 0 -and ($wfDetail.nodes | Where-Object { $_.name -eq 'postgres_select' })) {
    $extra++
    Write-Host ""
    Write-Host "  [sql-guard] postgres_select ohne query -> {ok:false, error} statt Absturz"
    $ok = $false
    try {
        [long]$chatId = $PairedUid
        Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
        Set-TestHouseholdOnboarding -Container $Container -Status 'completed'
        Set-TestPackageOnboarding -Container $Container -Sections $null
        $base = Get-MaxExecId -WfId $TargetWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
        $payload = @{ task = '__mock_select_no_query__'; chat_id = "$chatId"; call_depth = 0 } | ConvertTo-Json -Compress
        try {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
                -TimeoutSec 8 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
        } catch {
            if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) { throw }
        }
        $ex = Wait-ExecResolvingGates -WfId $TargetWfId -AfterId $base -Approve $false -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $Timeout
        $out = ''
        if ($ex) { $out = ($ex.data.resultData.runData.postgres_select | ConvertTo-Json -Depth 20 -Compress) }
        if ($Verbose) { Write-Host "    Execution=$($ex.status)  postgres_select=$out" -ForegroundColor DarkGray }
        $ok = $ex -and ($ex.status -eq 'success') -and ($out -match 'query argument is missing') -and ($out -notmatch "reading 'match'")
    } catch {
        Write-Host "    FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] postgres_select ohne query liefert keine Guard-Zeile bzw. Execution nicht success" -ForegroundColor Red }
}

# "Denkt nach"-Schleifen enden nach dem Loeschen des Schalters: nach ALLEN Faellen laeuft keine mehr (ein einziger
# Sammel-Check statt bis zu 10 s je Fall).
if ($isOrch -and -not $Discover -and @($cases).Count -gt 0) {
    $extra++
    Write-Host ""
    Write-Host "  [thinking-loop-end] keine 'Denkt nach'-Schleife laeuft nach den Antworten weiter"
    $loopEnded = $false
    try { $loopEnded = Test-NoThinkingLoopRunning } catch { Write-Host "    FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
    if ($loopEnded) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green }
    else { $failed++; Write-Host "    [FAIL] 'Denkt nach'-Schleife endet nicht nach dem Loeschen des Schalters" -ForegroundColor Red }
}

# Haengende Gate-/Ziel-Executions aufraeumen (falls ein Case abbrach, bevor das Gate aufgeloest war).
try { (Invoke-N8nGet "executions?workflowId=$TargetWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }

Write-Host ""
Write-Host ("-" * 64)
if ($Discover) { Write-Host "Discovery-Lauf beendet (keine Wertung)." -ForegroundColor Cyan; exit 0 }
$failed += Assert-ForceAbortFired $ForceAbortId
Write-AbortedCases
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$(@($cases).Count + $extra) Tests bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
