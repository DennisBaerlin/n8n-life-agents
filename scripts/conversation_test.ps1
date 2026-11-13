#Requires -Version 5.1
# Durchspiel-Werkzeug: fuehrt Gespraeche wie ein Mensch ueber den echten Telegram-Eingang des Orchestrators
# (Freitext, /befehl, Knopf-Tipp; Absender Owner oder Mitglied) und schreibt jede Bot-Ausgabe je Runde auf:
# Text, Knoepfe, Sticker, Reaktion, Knopf-Quittung, dazu welcher Agent lief, HITL-Karten und Kosten der Runde.
# Es bewertet nichts von selbst; optionale Pruefungen je Runde (expect_texts / forbid_texts / expect_agent) sind fuer
# die feste Vorher/Nachher-Abnahme gedacht. Faelle: tests/agent/cross/conversation_cases.json.
#
# Eingang wie real_ingress_test (Webhook + Secret zur Laufzeit aus dem Orchestrator-Workflow). Anders als dort kann ein
# Fall mehrere Runden fahren, ohne das Gedaechtnis dazwischen zu leeren (einmal je Fall), und der Lauf laeuft auch mit dem
# echten Modell. Anders als multiturn_test trifft er den Orchestrator, nicht den Harness eines Agenten.
#
# Fall: { id, name, sender: owner|member, start: onboarding_done|member_confirmed|no_cash_account, hitl: decline|approve (Default decline),
#         turns: [ { text: "hallo" } | { tap: "<callback_data>" }, optional expect_texts, forbid_texts, expect_agent ] }
# Ein /befehl ist ein Text mit fuehrendem Schraegstrich. Startzustand: alle Onboarding-Abschnitte completed, keine
# Berater-Plaene, Owner (Fixture-Person) und Mitglied (Fixture-Person Lena) gepairt, Sprache de, Persona neutral.
# no_cash_account = wie onboarding_done, aber ohne aktives Geldkonto (die Fixture-Konten sind nur waehrend des Falls
# geschlossen; Wiederherstellung auch nach Abbruch, Mechanik beim Pfad $ClosedAccountsFile unten). Ein Fall, der Konten
# anlegt, nennt sie mit __E2E__-Praefix, sonst raeumt agent.fn_clear_e2e_data sie nicht weg.
#
# Usage:  .\scripts\conversation_test.ps1 [-Id s1,s2] [-Timeout 120] [-OutDir <Ordner>] [-Verbose]       # gratis, Mock-Modell
#         -MaxCostUsd 2.0 (nur -Real): haelt den Lauf vor der naechsten Runde an, sobald die Summe darueber liegt
#         .\scripts\conversation_test.ps1 -Real [-Id s2]                                                   # kostet LLM-Credits
# Beispiel-Runden der Faelle: "hallo", "und jetzt?", "kannst du mich beraten?", "wie viel Geld haben wir?", "/help",
# "da sind gerade 1.200 Euro drauf", "Das Gehalt sind 3000 netto, das kommt am 1." (Mock-Szenarien matchen woertlich, mock_lint C2).
# Voraussetzung: Substrat (bootstrap_test_n8n.ps1) + enable_mock_telegram.ps1; ohne -Real zusaetzlich enable_mock_llm.ps1,
# mit -Real das Gegenteil (Assert-LlmGatewayUpstream prueft den tatsaechlichen Upstream); -Real sperrt der Owner-Fenster-Hook.
# Ausgabe: .local/conversation_runs/<Zeit>-<mock|real>.md (lesbar) + .json (maschinenlesbar), Pfad am Ende.
# Exit-Code = Anzahl Fehler (Execution nicht success/Timeout, Setup-Fehler, verletzte expect_*/forbid_*).
param(
    [string[]]$Id,
    [switch]$Real,
    [int]$Timeout = 120,
    [double]$MaxCostUsd = 2.0,
    [string]$CasesFile,
    [string]$OutDir,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn      = Get-TestN8nConnection
$N8nUrl    = $conn.Url
$ApiKey    = $conn.ApiKey
$Container = $conn.Container

$state = Get-TestN8nState
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (die Antworten des Bots werden dort aufgefangen). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
if ($Real) { Assert-LlmGatewayUpstream -Container $Container -Expect real }
else {
    if (-not $state.mock_llm) { throw "Mock-LLM nicht aktiv. Zuerst: .\scripts\dev\enable_mock_llm.ps1 (oder -Real fuer das echte Modell)" }
    Assert-LlmGatewayUpstream -Container $Container -Expect mock
}
$mode = if ($Real) { 'real' } else { 'mock' }

$ingress     = Resolve-OrchestratorIngress -BridgeUrl $N8nUrl -ApiKey $ApiKey
$OrchWfId    = $ingress.OrchWfId
$routeAgents = Get-TestRouteAgent
$prices      = Get-LlmPriceTable -RepoRoot $RepoRoot
$MemberUid   = 880055200   # Fixture-Person Lena; Uid wie real_ingress_test (Fixture-Konstante, kein echter Wert)

if (-not $CasesFile) { $CasesFile = Join-Path $RepoRoot 'tests\agent\cross\conversation_cases.json' }
$rawCases = [System.IO.File]::ReadAllText($CasesFile, $Utf8NoBom) | ConvertFrom-Json
# Erst in die Variable, dann filtern: ConvertFrom-Json liefert das Array in PS 5.1 als EIN Pipeline-Objekt.
$allCases = @($rawCases | Where-Object { $_.PSObject.Properties.Name -contains 'id' })
$cases    = @(if ($Id) { $allCases | Where-Object { $_.id -in $Id } } else { $allCases })
$missing  = @(foreach ($one in @($Id)) { if ($one -and $one -notin @($allCases.id)) { $one } })
if ($missing.Count) { throw "Fall nicht gefunden: $($missing -join ', ')." }
if (-not $cases) { throw "Keine Faelle in $CasesFile." }

# Sichtbare Telegram-Aufrufe; alles andere (Tipp-Anzeige, Menue-Setup ...) wird nur gezaehlt.
$VisibleMethods = @('sendMessage', 'sendSticker', 'sendAnimation', 'sendPhoto', 'sendDocument', 'setMessageReaction',
                    'answerCallbackQuery', 'editMessageText', 'editMessageReplyMarkup', 'deleteMessage')

# Start no_cash_account: schliesst die aktiven Fixture-Geldkonten voruebergehend. Die Merkdatei haelt id+Name der
# geschlossenen Konten; sie wird VOR dem Schliessen geschrieben und heilt jeden Abbruch (Ctrl-C, Absturz, Kill) beim
# naechsten Lauf. Wiederoeffnet wird nur, wenn id UND Name noch passen und das Konto geschlossen ist (ein neu
# aufgebautes Substrat vergibt dieselben ids an andere Konten). Bis zur Heilung fehlen allen anderen Suiten dieses
# Substrats die Geldkonten; ein Kill ohne Folgelauf bleibt daher sichtbar: Restore-ClosedAccounts laeuft zu Beginn jedes
# Durchspiels, Hand-Heilung = einmal .\scripts\conversation_test.ps1 -Id s1.
$ClosedAccountsFile = Join-Path $RepoRoot ".local\conversation_closed_accounts.$Container.json"

# SQL mit JSON geht als Datei: docker exec verliert in -c die doppelten Anfuehrungszeichen (psql meldet dann einen Rollen-Namen als Fehler).
function Invoke-SqlViaFile([string]$Sql) {
    $tmp = Join-Path $RepoRoot ".local\conversation_sql.$Container.sql"
    [System.IO.Directory]::CreateDirectory((Split-Path $tmp)) | Out-Null
    [System.IO.File]::WriteAllText($tmp, $Sql, $Utf8NoBom)
    try { return Invoke-TestN8nPsqlFile -Container $Container -HostFile $tmp -PsqlArgs @('-q') }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Restore-ClosedAccounts {
    if (-not (Test-Path $ClosedAccountsFile)) { return }
    $saved = [System.IO.File]::ReadAllText($ClosedAccountsFile, $Utf8NoBom)
    $json = $saved.Replace("'", "''")
    $sql = "UPDATE finance.accounts a SET status = 'active' FROM jsonb_to_recordset('$json'::jsonb) AS x(id text, name text) WHERE a.id::text = x.id AND a.name = x.name AND a.status = 'closed'; SELECT agent.fn_clear_e2e_data();"
    $r = Invoke-SqlViaFile $sql
    if ($r.Code -ne 0) { throw "Geschlossene Geldkonten wieder oeffnen fehlgeschlagen (Merkdatei $ClosedAccountsFile bleibt): $($r.Output -join ' ')" }
    Remove-Item -LiteralPath $ClosedAccountsFile -Force
}

function Close-CashAccounts {
    $sel = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "SELECT coalesce(json_agg(json_build_object('id', id::text, 'name', name)), '[]'::json) FROM finance.accounts WHERE account_type = 'cash' AND status = 'active' AND name NOT LIKE '\_\_E2E%';")
    if ($sel.Code -ne 0) { throw "Geldkonten lesen fehlgeschlagen: $($sel.Output -join ' ')" }
    $list = (@($sel.Output) -join '').Trim()
    [System.IO.Directory]::CreateDirectory((Split-Path $ClosedAccountsFile)) | Out-Null
    [System.IO.File]::WriteAllText($ClosedAccountsFile, $list, $Utf8NoBom)
    $json = $list.Replace("'", "''")
    $sql = "UPDATE finance.accounts a SET status = 'closed' FROM jsonb_to_recordset('$json'::jsonb) AS x(id text, name text) WHERE a.id::text = x.id AND a.name = x.name AND a.status = 'active';"
    $u = Invoke-SqlViaFile $sql
    if ($u.Code -ne 0) { throw "Geldkonten schliessen fehlgeschlagen: $($u.Output -join ' ')" }
    $left = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "SELECT count(*) FROM finance.accounts WHERE account_type = 'cash' AND status = 'active';")
    if ((@($left.Output) -join '').Trim() -ne '0') { throw "Nach dem Schliessen gibt es noch aktive Geldkonten: $($left.Output -join ' ')" }
}

function Initialize-ConversationState($Tc) {
    Restore-ClosedAccounts   # Rest eines frueheren Falls/Abbruchs, bevor der Fixture-Seed laeuft
    Initialize-AgentTestState -Container $Container -RepoRoot $RepoRoot
    $pairSql = @"
UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,persons}',
  (SELECT jsonb_agg(
     CASE WHEN p->>'person_id' = 'owner' THEN (p - 'persona') || jsonb_build_object('telegram_user_id', ${script:TestOwnerTelegramUid}::bigint, 'language', 'de')
          WHEN p->>'person_id' = 'lena'  THEN (p - 'persona') || jsonb_build_object('telegram_user_id', ${MemberUid}::bigint, 'language', 'de')
          ELSE p END)
   FROM jsonb_array_elements(metadata->'facts'->'persons') p))
WHERE name = 'family';
"@
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $pairSql)
    if ($r.Code -ne 0) { throw "Pairing (Container-DB) fehlgeschlagen: $($r.Output -join ' ')" }
    if ("$($Tc.start)" -notin @('onboarding_done', 'member_confirmed', 'no_cash_account')) { throw "Unbekannter start '$($Tc.start)' (onboarding_done|member_confirmed|no_cash_account)." }
    Set-TestHouseholdOnboarding -Container $Container -Status 'completed'
    Set-TestPackageOnboarding -Container $Container -Sections $null
    Clear-TestNextStepOffers -Container $Container   # Gruss-/Lebenszeichen-Knopf je Fall frisch (fruehere Suiten verbrauchen den Tagesmerker)
    $p = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', 'DELETE FROM agent.advisor_plans;')
    if ($p.Code -ne 0) { throw "Berater-Plaene leeren fehlgeschlagen: $($p.Output -join ' ')" }
    if ("$($Tc.start)" -eq 'no_cash_account') { Close-CashAccounts }
}

# n8n schickt reply_markup teils als JSON-String.
function Get-ButtonList($Markup) {
    if ($Markup -is [string]) { try { $Markup = $Markup | ConvertFrom-Json } catch { return @() } }
    $out = @()
    foreach ($row in @($Markup.inline_keyboard)) {
        foreach ($b in @($row)) {
            $target = if ($b.callback_data) { "cb:$($b.callback_data)" } elseif ($b.url) { "url:$($b.url)" } elseif ($b.web_app) { 'web_app' } else { '' }
            $out += [pscustomobject]@{ label = "$($b.text)"; target = $target }
        }
    }
    return $out
}

function ConvertTo-BotOutputs($Reqs) {
    $outs = @(); $other = 0
    foreach ($r in @($Reqs)) {
        $m = "$($r.method)"
        if ($m -eq '__start' -or $m -eq '') { continue }
        if ($VisibleMethods -notcontains $m) { $other++; continue }
        $b = $r.body
        $o = [ordered]@{ method = $m; chat = "$($b.chat_id)"; text = ''; buttons = @(); sticker = ''; reaction = ''; card = $false }
        $t = if ($b.text) { "$($b.text)" } elseif ($b.caption) { "$($b.caption)" } else { '' }
        $o.text = $t
        if ($b.reply_markup) { $o.buttons = @(Get-ButtonList $b.reply_markup) }
        # Persona-Sticker kommen als Upload (body.sticker_file = Dateiname) oder per file_id (body.sticker).
        if ($b.sticker_file) { $o.sticker = "$($b.sticker_file)" } elseif ($b.sticker) { $o.sticker = "$($b.sticker)" }
        if ($m -eq 'setMessageReaction') { $o.reaction = (@($b.reaction | ForEach-Object { "$($_.emoji)" }) -join ' ') }
        if ($m -eq 'answerCallbackQuery') { $o.text = "$($b.text)" }
        # HITL-Karte: Knoepfe mit Freigabe-Callback (Bestaetigen im Chat) oder Resume-Link
        $o.card = [bool](@($o.buttons | Where-Object { $_.target -match '^cb:nhitl1\|' -or $_.target -match 'webhook-waiting' }).Count)
        $outs += [pscustomobject]$o
    }
    return [pscustomobject]@{ outputs = $outs; other = $other }
}

function Get-OutputText($Outs) {
    (@(foreach ($o in $Outs) { $o.text; foreach ($b in $o.buttons) { $b.label } }) | Where-Object { $_ }) -join "`n"
}

function Invoke-Round($Tc, $Turn, [int]$N, [long]$Uid) {
    Clear-MockTelegramRequests -Container $Container
    Clear-HitlPending -Container $Container
    Clear-ThinkingLease -Container $Container
    $base   = Get-MaxExecId -WfId $OrchWfId -BridgeUrl $N8nUrl -ApiKey $ApiKey
    $cursor = Get-LlmUsageCursor -Container $Container
    $t0 = Get-Date
    $kind = 'text'; $input = ''
    if ($Turn.PSObject.Properties['tap'] -and $Turn.tap) {
        $kind = 'tap'; $input = "$($Turn.tap)"
        Send-TelegramCallbackIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $Uid -FromUid $Uid -Data $input
    } elseif ($Turn.PSObject.Properties['text'] -and $Turn.text) {
        $input = "$($Turn.text)"
        Send-TelegramIngress -IngressUrl $ingress.Url -Secret $ingress.Secret -ChatId $Uid -FromUid $Uid -Text $input | Out-Null
    } else { throw "Runde $N von $($Tc.id): weder text noch tap." }
    $approve = ("$($Tc.hitl)" -eq 'approve')
    $ex = Wait-ExecResolvingGates -WfId $OrchWfId -AfterId $base -Approve $approve -Container $Container -BridgeUrl $N8nUrl -ApiKey $ApiKey -TimeoutSec $Timeout
    Start-Sleep -Milliseconds 1500   # Relay-/Reaktions-Sends und das Gateway-Journal brauchen einen Atemzug nach dem Lauf-Ende
    $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

    $nodes = @()
    if ($ex) { try { $nodes = @($ex.data.resultData.runData.PSObject.Properties.Name) } catch { } }
    $agents = @(Get-RoutedAgent -Tools $nodes -RouteAgents $routeAgents)
    $conv = ConvertTo-BotOutputs (Get-MockTelegramRequests -Container $Container)

    $usage = @(Get-LlmUsage -Container $Container -AfterCursor $cursor)
    $cost = 0.0; $unpriced = 0
    foreach ($u in $usage) { $c = Get-LlmRequestCost -Row $u -Prices $prices; if ($c) { $cost += $c.Cost } else { $unpriced++ } }
    $models = @($usage | Group-Object { "$($_.model)" } | ForEach-Object { "$($_.Name) x$($_.Count)" })

    $status = if ($ex) { "$($ex.status)" } else { 'timeout' }
    $fails = @()
    if ($status -ne 'success') { $fails += "Execution-Status '$status' (erwartet success)" }
    $hay = Get-OutputText $conv.outputs
    foreach ($e in @($Turn.expect_texts)) { if ($e -and -not $hay.Contains("$e")) { $fails += "Text fehlt: '$e'" } }
    foreach ($e in @($Turn.forbid_texts)) { if ($e -and $hay.Contains("$e")) { $fails += "Text darf nicht vorkommen: '$e'" } }
    if ($Turn.PSObject.Properties['expect_agent'] -and $Turn.expect_agent -and $agents -notcontains "$($Turn.expect_agent)") {
        $fails += "Agent '$($Turn.expect_agent)' nicht gerufen (gerufen: $($agents -join ', '))"
    }
    return [pscustomobject]@{
        n = $N; kind = $kind; input = $input; status = $status; seconds = $secs; execution = $(if ($ex) { "$($ex.id)" } else { '' })
        agents = $agents; cards = @($conv.outputs | Where-Object { $_.card }).Count; card_decision = $(if ($approve) { 'angenommen' } else { 'abgelehnt' })
        outputs = $conv.outputs; other_calls = $conv.other
        usage = [pscustomobject]@{ requests = $usage.Count; cost_usd = [Math]::Round($cost, 4); unpriced = $unpriced; models = $models }
        nodes = $nodes; failures = $fails
    }
}

$runStart = Get-Date
$runCursor = Get-LlmUsageCursor -Container $Container
$failed = 0
$results = @()
$script:runCost = 0.0; $script:stopRun = $false

Write-Host ""
Write-Host "Durchspiel ($mode) -- $($cases.Count) Fall/Faelle  (Eingang: $($ingress.Url))"
if ($Real) { Write-Host "  KOSTET LLM-Credits." -ForegroundColor Yellow }
Write-Host ("-" * 64)

try {
Restore-ClosedAccounts   # Rest eines frueher abgebrochenen Laufs, auch wenn dieser Lauf keinen no_cash_account-Fall hat
foreach ($tc in $cases) {
    Write-Host ""
    Write-Host "  [$($tc.id)] $($tc.name)  ($(@($tc.turns).Count) Runden, Absender $($tc.sender))"
    $uid = if ("$($tc.sender)" -eq 'member') { [long]$MemberUid } else { [long]$script:TestOwnerTelegramUid }
    $res = [ordered]@{ id = "$($tc.id)"; name = "$($tc.name)"; sender = "$($tc.sender)"; start = "$($tc.start)"; hitl = $(if ("$($tc.hitl)" -eq 'approve') { 'approve' } else { 'decline' }); setup_error = ''; rounds = @() }
    try {
        Initialize-ConversationState $tc
        Clear-ChatSessionMemory -Container $Container -SessionId "$uid"   # einmal je Fall: Runden bauen aufeinander auf
    } catch {
        Write-Host "    [FAIL] Setup: $($_.Exception.Message)" -ForegroundColor Red
        $res.setup_error = $_.Exception.Message; $failed++; $results += [pscustomobject]$res; continue
    }
    $n = 0; $abortCase = $false
    foreach ($turn in @($tc.turns)) {
        $n++
        if ($Real -and $script:runCost -gt $MaxCostUsd) {
            Write-Host "    [FAIL] Kostengrenze $MaxCostUsd USD ueberschritten ($([Math]::Round($script:runCost, 3)) USD) - Lauf angehalten." -ForegroundColor Red
            $failed++; $script:stopRun = $true; break
        }
        try { $rd = Invoke-Round $tc $turn $n $uid }
        catch { Write-Host "    [FAIL] Runde ${n}: $($_.Exception.Message)" -ForegroundColor Red; $failed++; break }
        $res.rounds += $rd
        $script:runCost += $rd.usage.cost_usd
        # Zeitueberschreitung: die Execution laeuft evtl. weiter und wuerde die naechste Runde mit ihren Ausgaben vermischen.
        if ($rd.status -in @('timeout', 'running', 'new', 'waiting')) {
            try { if ($rd.execution) { Stop-Exec $rd.execution } } catch { }
            $abortCase = $true   # der Status-Fehler selbst steht in $rd.failures und wird unten gezaehlt
        }
        $line ="    Runde ${n}: '$($rd.input)' -> $($rd.status), Agent: $(if ($rd.agents.Count) { $rd.agents -join '+' } else { '(Router direkt)' }), $(@($rd.outputs).Count) Ausgabe(n), $($rd.usage.requests) Anfr., $($rd.usage.cost_usd) USD"
        if ($rd.failures.Count) { Write-Host $line -ForegroundColor Red; foreach ($f in $rd.failures) { Write-Host "      - $f" -ForegroundColor Red }; $failed += $rd.failures.Count }
        else { Write-Host $line -ForegroundColor Green }
        if ($Verbose) { foreach ($o in $rd.outputs) { Write-Host "      > [$($o.method)] $($o.text)" -ForegroundColor DarkGray } }
        if ($abortCase) { break }
    }
    $results += [pscustomobject]$res
    if ($script:stopRun) { break }
}
} finally {
    # Auch bei Ctrl-C oder Fehler: geschlossene Geldkonten wieder oeffnen, __E2E__-Konten wegraeumen.
    try { Restore-ClosedAccounts } catch { Write-Host "    [FAIL] Wiederherstellung: $($_.Exception.Message)" -ForegroundColor Red; $failed++ }
}
try { (Invoke-N8nGet "executions?workflowId=$OrchWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }
Clear-HitlPending -Container $Container

if (-not $OutDir) { $OutDir = Join-Path $RepoRoot '.local\conversation_runs' }
[System.IO.Directory]::CreateDirectory($OutDir) | Out-Null
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$base  = Join-Path $OutDir "$stamp-$mode"

$allUsage = @(Get-LlmUsage -Container $Container -AfterCursor $runCursor)
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Durchspiel ($mode) $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
[void]$md.AppendLine("")
[void]$md.AppendLine("Eingang: echter Telegram-Webhook des Orchestrators, Antworten aus dem Mock-Telegram. Modell: $(if ($Real) { 'echt (bezahlt)' } else { 'Mock (gratis, gescriptete Antworten, keine Aussage ueber echte Texte)' }).")
foreach ($r in $results) {
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## $($r.name)")
    [void]$md.AppendLine("Absender: $($r.sender), Start: $($r.start), HITL-Karten: $(if ($r.hitl -eq 'approve') { 'angenommen' } else { 'abgelehnt' })")
    if ($r.setup_error) { [void]$md.AppendLine(""); [void]$md.AppendLine("**Setup-Fehler:** $($r.setup_error)") }
    foreach ($rd in $r.rounds) {
        $who = if ($r.sender -eq 'member') { 'Mitglied' } else { 'Owner' }
        $what = if ($rd.kind -eq 'tap') { "tippt Knopf ``$($rd.input)``" } else { "schreibt: `"$($rd.input)`"" }
        [void]$md.AppendLine("")
        [void]$md.AppendLine("### Runde $($rd.n) - $who $what")
        $ag = if ($rd.agents.Count) { $rd.agents -join ' + ' } else { '(Router antwortet selbst / fester Pfad)' }
        $cost = if ($rd.usage.requests -eq 0) { 'keine Modell-Anfrage' } else { "$($rd.usage.requests) Anfr., $($rd.usage.cost_usd) USD$(if ($rd.usage.unpriced) { " ($($rd.usage.unpriced) ohne Preis)" })  [$($rd.usage.models -join '; ')]" }
        [void]$md.AppendLine("Agent: $ag | Status: $($rd.status) | $($rd.seconds) s | $cost$(if ($rd.cards) { " | Karte(n): $($rd.cards) $($rd.card_decision)" })")
        if (@($rd.outputs).Count -eq 0) { [void]$md.AppendLine(""); [void]$md.AppendLine("*(keine Telegram-Ausgabe)*") }
        foreach ($o in $rd.outputs) {
            [void]$md.AppendLine("")
            $tag = switch ($o.method) { 'sendMessage' { 'Nachricht' } 'sendSticker' { 'Sticker' } 'setMessageReaction' { 'Reaktion' } 'answerCallbackQuery' { 'Knopf-Quittung' } 'editMessageText' { 'Nachricht bearbeitet' } 'editMessageReplyMarkup' { 'Knoepfe bearbeitet' } default { $o.method } }
            if ($o.card) { $tag += ' (HITL-Karte)' }
            [void]$md.AppendLine("**$tag**$(if ($o.sticker) { " $($o.sticker)" })$(if ($o.reaction) { " $($o.reaction)" })")
            if ($o.text) { foreach ($l in ($o.text -split "`r?`n")) { [void]$md.AppendLine("> $l") } }
            if (@($o.buttons).Count) { [void]$md.AppendLine("Knoepfe: " + ((@($o.buttons) | ForEach-Object { "[$($_.label)]" }) -join ' ')) }
        }
        if ($rd.other_calls) { [void]$md.AppendLine(""); [void]$md.AppendLine("*($($rd.other_calls) weitere technische Telegram-Aufrufe)*") }
        foreach ($f in $rd.failures) { [void]$md.AppendLine(""); [void]$md.AppendLine("**Pruefung:** $f") }
    }
}
[System.IO.File]::WriteAllText("$base.md", $md.ToString(), $Utf8NoBom)
[System.IO.File]::WriteAllText("$base.json", (ConvertTo-Json -InputObject ([pscustomobject]@{ mode = $mode; started = $runStart.ToUniversalTime().ToString('o'); failures = $failed; cases = $results }) -Depth 14), $Utf8NoBom)

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$($cases.Count) Fall/Faelle gespielt, $failed Fehler." -ForegroundColor $color
Write-Host "Aufzeichnung: $base.md" -ForegroundColor Cyan
Write-Host "              $base.json" -ForegroundColor Cyan
Write-LlmCostReport -Usage $allUsage -Label "conversation_test-$mode" -RepoRoot $RepoRoot
Write-Host ""
exit $failed
