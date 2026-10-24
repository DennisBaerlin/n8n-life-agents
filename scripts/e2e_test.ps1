#Requires -Version 5.1
# E2E-Write-Tests -- Tier 5 der TDD-Infrastruktur (ECHTE Writes, kein Mock).
# Feuert die Faelle aus tests\agent\finance\e2e_cases.json gegen den Finance-Agenten. Im Unterschied
# zu n8n_test.ps1 (Routing-Tier: das echte Gate wird ueber Mock-Telegram DECLINEd -> KEIN Write)
# wird hier das echte Send-and-Wait-Gate ueber Mock-Telegram APPROVED -> der Write laeuft ECHT
# durch agent.fn_* in die DB (Weg C/Phase 8: kein test_-Gate-Bypass mehr; der 'test_e2e'-chat_id-
# Prefix dient nur noch dem Advisor/Monitor-Sentinel-Domain-Switch). Damit wird verifiziert, dass
# das Agent-Payload Schema, Trigger und CHECKs tatsaechlich passiert (die "Mock-Falle" geschlossen).
#
# Ablauf je Case: CLEAN -> optional setup_sql (Voraussetzungen per <pkg>.fn_*) -> Harness-POST ->
#   agent.finance-Execution bis success pollen -> verify_sql (read-only) ausfuehren -> Skalar gegen 'expect' pruefen;
#   jeder Case muss status=success enden (C3 negativ, C4 positiv).
#
# CLEANUP (zweistufig, beides hart codiert):
#   - Pre-/Per-Case: VOR jedem Case agent.fn_clear_e2e_data() -> isoliert den Case UND raeumt
#     Reste eines zuvor abgestuerzten Laufs (das eigentliche Sicherheitsnetz; finally faengt keinen
#     harten Abbruch wie Ctrl+C/Prozess-Kill).
#   - Post-Flight: im finally-Block nach allen Cases (Best-Effort fuer den Normal-/Fehlerfall).
#   Geloescht wird NUR ueber die geguardete agent.fn_clear_e2e_data() (Sentinel '__E2E__', Pre-/
#   Post-Assertion in der Function) -> kein unqualifizierter DELETE-Pfad.
#
# Concurrency-Grenze: fester '__E2E__'-Marker -> nur fuer SEQUENTIELLE Single-User-Laeufe.
#   Parallele Laeufe wuerden kollidieren (Saldo-/COUNT-Drift).
#   A5: agent.fn_clear_e2e_data(p_runid) UNTERSTUETZT bereits run-scoped Cleanup (getestet:
#   test_fn_clear_e2e_data.sql). NICHT in die Agent-Namen verdrahtet, weil das Injizieren eines
#   Run-ID-Tokens in den agent-generierten Entitaetsnamen die LLM-Namensgebung perturbiert
#   (Agent nimmt den Token als kompletten Namen, laesst den beschreibenden Teil weg -> verify_sql
#   matcht nicht mehr; verifiziert). Strukturelle Sicherheit gegen "loescht echte Daten" liefern
#   die Cleanup-Guards der fn selbst (GUARD 1: jede Loesch-ID traegt den Marker; GUARD 2: keine
#   Sentinel-Zeile bleibt) -- ein DB-Constraint, der '__E2E__' verboete, ist NICHT moeglich, weil
#   die E2E-Writes durch denselben Prod-fn-Pfad laufen und den Marker legitim erzeugen muessen.
#
# Usage:
#   .\scripts\e2e_test.ps1                 # alle E2E-Faelle
#   .\scripts\e2e_test.ps1 -Id e2e03       # nur einen Fall
#   .\scripts\e2e_test.ps1 -Timeout 90     # Polling-Timeout (Default 75 s; Multi-Write dauert laenger)
#   .\scripts\e2e_test.ps1 -Verbose        # Agent-runData + Cleanup-Counts anzeigen
#
# Exit-Code = Anzahl fehlgeschlagener Tests.
# Voraussetzungen: Docker-Test-Substrat hochgefahren (scripts\dev\bootstrap_test_n8n.ps1 — bringt
#   agent.finance + Harness + agent.fn_clear_e2e_data mit) + scripts\dev\enable_mock_telegram.ps1 (das Gate wird
#   ueber Mock-Telegram approved; Mock-LLM darf NICHT aktiv sein); .env: TEST_HARNESS_SECRET. N8N-Verbindung +
#   Container-DB-Zugriff (verify/cleanup) kommen aus dem Substrat-State, nicht aus Prod-.env.
param(
    [string]$Id,
    [int]$Timeout = 75,
    # Anderen Agenten testen (gleicher Harness-Mechanismus), z. B. den Advisor:
    #   -TargetWorkflow agent.finance_advisor -WebhookPath advisor-test -CasesFile tests\agent\finance\advisor_e2e_cases.json
    [string]$TargetWorkflow = 'agent.finance',
    [string]$WebhookPath = 'finance-test',
    [string]$CasesFile = 'tests\agent\finance\e2e_cases.json',
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot  = git -C $PSScriptRoot rev-parse --show-toplevel

# .env laden (TEST_HARNESS_SECRET); N8N + Container-DB-Zugriff kommen aus dem Docker-Test-Substrat
# (raus aus Prod). Die ECHTEN Writes UND die Verifikation/Cleanup treffen dieselbe ephemere Instanz-DB
# ('n8n') — Zugriff ueber docker exec runuser-psql (kein Prod-PG_* mehr).
Get-Content "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') {
        Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
    }
}
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn        = Get-TestN8nConnection
$N8N_URL     = $conn.Url
$N8N_API_KEY = $conn.ApiKey
$Container   = $conn.Container
if ([string]::IsNullOrEmpty($TEST_HARNESS_SECRET)) { throw "TEST_HARNESS_SECRET ist nicht gesetzt in .env" }

$Headers    = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }
$AuthHeader = 'X-Test-Auth'
$WebhookUrl = "$N8N_URL/webhook/$WebhookPath"

# WEG C (Phase 8): KEIN test_e2e-Gate-Bypass mehr -> der Write laeuft durch das ECHTE Send-and-Wait-Gate,
# das ueber das abgefangene Mock-Telegram APPROVED wird (Wait-ExecResolvingGates -Approve $true; ein
# Multi-Write-Lauf hat mehrere Gates -> alle approven). Der chat_id-Prefix `test_e2e` bleibt (KEIN
# Routing-/Gate-Zweig haengt mehr daran): er schaltet nur noch den Advisor/Monitor-Sentinel-Domain-Switch
# (__e2e_finance__/__e2e_monitor__) -> die echte Plan-/Trigger-Kette wird nie beruehrt. Finance isoliert
# ueber den __E2E__-Namens-Sentinel. Mock-Telegram muss aktiv sein.
$state = [System.IO.File]::ReadAllText((Join-Path $RepoRoot '.local\n8ntest_state.json'), $Utf8NoBom) | ConvertFrom-Json
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (fuer die Gate-Approve-Mechanik noetig). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
# Echte Claude-Antworten noetig (Gateway-Upstream = API, nicht Mock) + Start-Marke fuer die Kostenuebersicht.
Assert-LlmGatewayUpstream -Container $Container -Expect real
$llmCursor = Get-LlmUsageCursor -Container $Container

# -------------------------------------------------------
# n8n-Helfer (analog n8n_test.ps1)
# -------------------------------------------------------
function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8N_URL/api/v1/$Path" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) {
    try { Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
}
function Get-ExecDetail([string]$ExecId) { Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId`?includeData=true" -Headers $Headers -Method Get }
# Tool-Calls + finaler Output (nur fuer Diagnose, v. a. Negativ-Faelle: zeigt den ok:false-Pfad)
function Format-AgentRunData([object]$RunData, [string]$AgentNodeName) {
    if ($null -eq $AgentNodeName -or -not $RunData.PSObject.Properties.Name.Contains($AgentNodeName)) { return '(kein Agent-runData)' }
    $lines = @()
    foreach ($run in $RunData.$AgentNodeName) {
        $actions = $null; try { $actions = $run.metadata.subNodeExecutionData.actions } catch { }
        foreach ($a in $actions) {
            $nn = $null; try { $nn = $a.action.nodeName } catch { }
            $inp = ''; try { $inp = ($a.action.input | ConvertTo-Json -Depth 4 -Compress) } catch { }
            if ($nn) { $lines += "tool-call: $nn  input=$inp" }
        }
        $txt = $null; try { $txt = $run.data.main[0][0].json.output } catch { }
        if ($txt) { $lines += "output: $txt" }
    }
    if ($lines.Count -eq 0) { return '(keine Tool-Calls/Output)' }
    return ($lines -join "`n             ")
}

# -------------------------------------------------------
# DB-Helfer (psql direkt -- e2e_test ist selbst ein offizielles Skript, wie db_test/db_query)
# -------------------------------------------------------
# Cleanup: NUR ueber die geguardete Function (in der Container-DB). Wirft bei Guard-Verletzung.
function Invoke-Clean {
    $res = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-t', '-A', '-c', 'SELECT agent.fn_clear_e2e_data();')
    if ($res.Code -ne 0) { throw "Cleanup (fn_clear_e2e_data) fehlgeschlagen: $(($res.Output | Where-Object { $_ }) -join ' ')" }
    if ($Verbose) { Write-Host "      clean: $(($res.Output | Where-Object { $_ -is [string] -and $_ }) -join ' ')" -ForegroundColor DarkGray }
}
# Setup (optional je Case, Feld setup_sql): legt die VORAUSSETZUNGEN direkt per <pkg>.fn_* an (gleiche Write-Pfade wie
# die Tools, DB-Gesetze greifen), damit der Agent nur den EINEN geprueften Schritt macht. Grund (bezahlter Lauf
# 2026-10-23): 4-5 Writes in EINER Nachricht sprengten die 8 Agent-Schritte, obwohl jeder Fall nur ein Werkzeug prueft.
# Helfer (session-lokal, pg_temp, paketneutral): ok(label, res) macht {ok:false} zum harten Fehler; ids per Subselect im Case.
# Nur einfache Hochkommas im SQL (doppelte verliert die docker-exec-Argumentuebergabe unter PS 5.1).
$SetupPrelude = @'
CREATE FUNCTION pg_temp.ok(p_label text, p_res jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$ BEGIN IF COALESCE((p_res->>'ok')::boolean, TRUE) = FALSE THEN RAISE EXCEPTION 'e2e setup: % fehlgeschlagen: %', p_label, COALESCE(p_res->>'reason', p_res::text); END IF; RETURN p_res; END $f$;
'@
function Invoke-Setup([string]$Sql) {
    $res = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-t', '-A', '-c', ($SetupPrelude + $Sql))
    if ($res.Code -ne 0) { throw "setup_sql fehlgeschlagen: $(($res.Output | Where-Object { $_ }) -join ' ')" }
}
# Verify: read-only erzwungen (versehentliche Writes brechen ab). Liefert den letzten Skalar als [int] (oder $null).
# Hinweis: der SET-Befehl gibt keine Zeile aus; der SELECT-Wert steht am Ende -> -Last 1.
function Invoke-Verify([string]$Sql) {
    $res = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-t', '-A', '-c', "SET default_transaction_read_only = on; $Sql")
    if ($res.Code -ne 0) { throw "verify_sql fehlgeschlagen: $(($res.Output | Where-Object { $_ }) -join ' ')" }
    $val = ($res.Output | Where-Object { $_ -is [string] -and $_ -ne '' } | Select-Object -Last 1)
    $n = 0
    if ([int]::TryParse(("$val").Trim(), [ref]$n)) { return $n }
    return $null
}

# -------------------------------------------------------
# Setup
# -------------------------------------------------------
Write-Host "Suche Workflows ($TargetWorkflow + $TargetWorkflow.test_harness) ..."
$wfList   = Invoke-N8nGet 'workflows?limit=200'
$financeWf = $wfList.data | Where-Object { $_.name -eq $TargetWorkflow } | Select-Object -First 1
$harnessWf = $wfList.data | Where-Object { $_.name -eq "$TargetWorkflow.test_harness" } | Select-Object -First 1
if (-not $financeWf) { throw "Workflow '$TargetWorkflow' nicht gefunden." }
if (-not $harnessWf) { throw "Workflow '$TargetWorkflow.test_harness' nicht gefunden (build.ps1 -Only '*test_harness*' -> bootstrap_test_n8n.ps1 -Reset)." }
$FinanceWfId = $financeWf.id
if (-not $harnessWf.active) { Write-Host "  [WARN] Harness INAKTIV -> Webhook nicht registriert (Harness bauen + pushen)." -ForegroundColor Yellow }

$AgentNodeName = $null
$wfDef = Invoke-N8nGet "workflows/$FinanceWfId"
foreach ($node in $wfDef.nodes) { if ($node.type -match 'langchain.agent') { $AgentNodeName = $node.name; break } }
if (-not $AgentNodeName) { throw "Kein AI-Agent-Node (langchain.agent) in '$TargetWorkflow' gefunden." }

$tcFile   = if ([System.IO.Path]::IsPathRooted($CasesFile)) { $CasesFile } else { Join-Path $RepoRoot $CasesFile }
$allCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$cases    = if ($Id) { $allCases | Where-Object { $_.id -eq $Id } } else { $allCases }
if (-not $cases) { throw "Testfall '$Id' nicht gefunden." }

Write-Host ""
Write-Host "E2E-Write-Tests (Tier 5) -- $($cases.Count) Fall(e)  ECHTE Writes  (Webhook: $WebhookUrl)"
Write-Host ("-" * 64)
Write-Host "WARNUNG: schreibt echt in die Test-Instanz-DB ($Container:n8n, Sentinel '__E2E__', Cleanup pro Case + finally)." -ForegroundColor Yellow

# WS-5b Test-Identitaets-Riegel: bricht VOR dem ersten (teuren) LLM-Call ab, falls der Substrat-Owner nicht
# der fiktive Golden-Owner 'Erika' ist -> die e2e-Faelle erfassen Konten fuer 'Erika'; ein abweichender
# (evtl. ECHTER) Owner laesst jeden Create-Fall scheitern und verbrennt die Suite (real: 21/32 Fails).
Assert-GoldenHousehold -Container $Container

# Dieselbe Vorbereitung wie n8n_test/mock_route_test (Initialize-AgentTestState: Owner pairen + Fixture-Seed,
# idempotent). Einzelne Write-Faelle brauchen Referenzdaten der Fixtures (me01: EUR/KRW-Kurs in finance.fx_rates);
# ohne Seed hingen sie davon ab, ob vorher zufaellig ein anderer Treiber lief (real 2026-10-20: me01 PASS nach
# mock_route_test, FAIL auf frischem -Reset-Substrat). Die Sentinel-Verifikation zaehlt nur __E2E__-Zeilen.
Initialize-AgentTestState -Container $Container -RepoRoot $RepoRoot

# WS-3: das immer-an Core-first-Gate am Paket-Agent-Eingang (finance/advisor) blockt JEDEN Write VOR dem echten
# Schreiben, solange das Core-Onboarding (Haushalt) nicht 'completed' ist -> hier einmalig das Onboarding der
# Container-DB (Haushalt + jedes Paket) auf 'completed' ziehen. fn_clear_e2e_data bleibt reines Cleanup.
# Phase B: generisch ueber die <pkg>.onboarding_state-Konvention (vorher finance fest + ungeguardet, estate fehlte).
$obSeed = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c',
    'DO $$ DECLARE v text; BEGIN UPDATE agent.guide_onboarding_state SET status=''completed'' WHERE status<>''completed''; FOR v IN SELECT DISTINCT package FROM core.schema_version WHERE package<>''core'' LOOP IF to_regclass(format(''%I.onboarding_state'', v)) IS NOT NULL THEN EXECUTE format(''UPDATE %I.onboarding_state SET status=%L WHERE status<>%L'', v, ''completed'', ''completed''); END IF; END LOOP; END $$;')
if ($obSeed.Code -ne 0) { throw "Onboarding-Seed (Core-first-Gate) fehlgeschlagen: $(($obSeed.Output | Where-Object { $_ }) -join ' ')" }

$passed = 0; $failed = 0

try {
    foreach ($tc in $cases) {
        Write-Host ""
        Write-Host "  [$($tc.id)] $($tc.name)"
        Write-Host "    Task: '$($tc.task)'"

        # Pre-/Per-Case-Cleanup (isoliert + raeumt Reste eines abgestuerzten Laufs)
        Invoke-Clean
        if ($tc.PSObject.Properties['setup_sql'] -and $tc.setup_sql) {
            try { Invoke-Setup ([string]$tc.setup_sql) }
            catch { Write-Host "    [FAIL] Vorbereitung: $_" -ForegroundColor Red; $failed++; continue }
        }

        # Per-Case-Override timeout_s (langsame Multi-Write-/Advisor-Cases).
        $caseTimeout = if ($tc.PSObject.Properties['timeout_s'] -and $tc.timeout_s) { [int]$tc.timeout_s } else { $Timeout }
        # Die test_e2e…-chat_id ist je Case fest -> ohne Leeren saehe der Agent die Turns frueherer Laeufe.
        Clear-ChatSessionMemory -Container $Container -SessionId ([string]$tc.chat_id)
        Clear-MockTelegramRequests -Container $Container
        $base = Get-MaxExecId -WfId $FinanceWfId -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY
        $payload = @{ task = $tc.task; chat_id = $tc.chat_id; call_depth = 0 } | ConvertTo-Json -Compress
        try {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
                -TimeoutSec 8 `
                -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
        } catch {
            if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) {
                Write-Host "    [FAIL] Webhook-POST fehlgeschlagen: $_" -ForegroundColor Red
                $failed++; continue
            }
        }

        # agent.finance-Execution zum Terminalstatus treiben + jedes Gate APPROVEn (Write laeuft echt durch).
        $ex = Wait-ExecResolvingGates -WfId $FinanceWfId -AfterId $base -Approve $true -Container $Container -BridgeUrl $N8N_URL -ApiKey $N8N_API_KEY -TimeoutSec $caseTimeout
        if (-not $ex) { Write-Host "    [FAIL] Keine agent.finance-Execution gefunden (Timeout $caseTimeout s)." -ForegroundColor Red; $failed++; continue }
        Write-Host "    Execution: id=$($ex.id)  status=$($ex.status)"
        if ($ex.status -eq 'waiting') { Stop-Exec $ex.id }   # sollte nach Approve nicht passieren

        # Verifikation gegen die DB
        $actual = Invoke-Verify $tc.verify_sql
        $exp    = [int]$tc.expect
        $kind   = if ($tc.is_negative) { 'NEG' } else { 'POS' }
        Write-Host "    Verify ($kind): erwartet=$exp  erhalten=$actual"

        # B2 (strengeres verify): wenn der Case eine erwartete Sentinel-Konten-Zahl deklariert,
        # MUSS die Gesamtzahl angelegter '__E2E__'-Konten exakt stimmen. Faengt unter-spezifizierte
        # Skalar-Verifies (z. B. OR-count == 2 spurious erfuellt) UND vom Agenten angelegte
        # Streu-/Extra-Konten, die der eigentliche verify_sql nicht sieht.
        $strictOk = $true
        if ($null -ne $tc.sentinel_accounts) {
            $sentCnt = Invoke-Verify "SELECT count(*) FROM finance.accounts WHERE name LIKE '\_\_E2E\_\_%';"
            $sentExp = [int]$tc.sentinel_accounts
            if ($sentCnt -ne $sentExp) {
                $strictOk = $false
                Write-Host "    STRICT FAIL: Sentinel-Konten erwartet=$sentExp erhalten=$sentCnt (Streu-/Extra-Konto?)" -ForegroundColor Red
            } else {
                Write-Host "    Strict: Sentinel-Konten=$sentCnt (==erwartet)" -ForegroundColor DarkGreen
            }
        }

        # C3: Negativ-Case muss GRACEFUL ablehnen ({ok:false} als Daten) -> Execution endet 'success'.
        # status=error/canceled bedeutet die fn hat ge-RAISEt (oder ein Crash) statt strukturiert
        # abzulehnen -> ein "silent crash" waere sonst von einem echten Guard ununterscheidbar.
        if ($tc.is_negative -and $ex.status -ne 'success') {
            $strictOk = $false
            Write-Host "    C3 FAIL: Negativ-Case endete status=$($ex.status) (erwartet 'success' = graceful {ok:false}); moeglicher silent crash statt sauberem Guard." -ForegroundColor Red
        }
        # C4 (2026-10-23): auch ein POSITIVER Case muss 'success' enden. status=error trotz korrekter Daten heisst: der
        # Nutzer bekaeme eine Fehlermeldung statt einer Antwort (real: maxIterations nach allen Writes).
        if (-not $tc.is_negative -and $ex.status -ne 'success') {
            $strictOk = $false
            Write-Host "    C4 FAIL: Lauf endete status=$($ex.status) - der Nutzer bekaeme eine Fehlermeldung statt einer Antwort." -ForegroundColor Red
        }

        if ($actual -eq $exp -and $strictOk) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
            if ($Verbose) { Write-Host "    runData: $(Format-AgentRunData $ex.data.resultData.runData $AgentNodeName)" -ForegroundColor DarkGray }
        } else {
            $failed++
            Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
            Write-Host "    --- AI-Agent runData (Diagnose) ---" -ForegroundColor Yellow
            Write-Host "    $(Format-AgentRunData $ex.data.resultData.runData $AgentNodeName)" -ForegroundColor Yellow
            Write-Host "    -----------------------------------" -ForegroundColor Yellow
        }
    }
}
finally {
    # Post-Flight-Cleanup (Best-Effort; Pre-/Per-Case-Clean ist das eigentliche Netz gegen harte Abbrueche)
    Write-Host ""
    Write-Host "Post-Flight-Cleanup ..."
    try { Invoke-Clean } catch { Write-Host "  [WARN] Post-Flight-Cleanup: $_" -ForegroundColor Yellow }

    # verwaiste wartende Harness-Executions stoppen
    try {
        $hWf = (Invoke-N8nGet 'workflows?limit=200').data | Where-Object { $_.name -eq "$TargetWorkflow.test_harness" } | Select-Object -First 1
        if ($hWf) { (Invoke-N8nGet "executions?workflowId=$($hWf.id)&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } }
    } catch { }
}

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($cases.Count) E2E-Tests bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-LlmCostReport -Usage (Get-LlmUsage -Container $Container -AfterCursor $llmCursor) -Label 'e2e_test' -RepoRoot $RepoRoot
Write-Host ""

exit $failed
