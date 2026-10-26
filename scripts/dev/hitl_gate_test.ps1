#Requires -Version 5.1
# hitl_gate_test.ps1 — deterministischer HITL-Gate-Test ueber den ECHTEN Telegram-Pfad (Teststrategie
# Phase 5). KEIN LLM, kostet keine Credits: feuert das Gate mit einer NUMERISCHEN chat_id (kein test_-
# Prefix -> echtes Send-and-Wait), faengt die ausgehende Nachricht im Mock-Telegram ab, loest das
# Gate ueber die abgefangene SIGNIERTE Resume-URL (Schema+Host auf die socat-Bruecke umgeschrieben) und
# prueft, dass approved == erwartet — fuer Approve UND Decline.
#
# WS-5b MEMBER-PFAD-ABSICHERUNG: das Dual-Control-Gate hat drei MEMBER-Zweige (owner_info Selbst-
# bestaetigung, owner_approval Vier-Augen, owner_only harter Block), die ein ungepairter Owner-Sender NIE
# betritt. Dieser Test seedet deshalb eine GEPAIRTE Partnerin (880055200, role=partner; Muster
# real_ingress_test) und feuert die Member-Tiers mit deren chat_id + explizitem approval_tier durch den
# Gate-Test-Harness (inputMap traegt approval_tier). Geprueft: (a) owner_info -> Member bestaetigt selbst,
# approved=true + Einweg-Info an den Owner; (b) owner_only -> Block, approved=false, KEIN Send; (c)
# owner_approval -> Member+Owner-Vier-Augen -> true, Member-Decline (Stufe 1) ODER Owner-Veto (Stufe 2)
# -> false. SICHERHEITS-INVARIANTE
# mitgeprueft: der Member-Send adressiert die aufgeloeste, verifizierte Partner-chat_id (nicht den Owner);
# owner_only erzeugt NULL button-tragende Sends (der Block darf nicht senden).
#
# BESTAETIGEN IM CHAT: alle Faelle laufen in beiden Knopf-Modi (Link = signierte Resume-URL per GET; Chat =
# callback_data -> das callback_query-Update per POST an /webhook-waiting-telegram, wie der Orchestrator-Trigger es
# weiterreicht). Sendet das Substrat Chat-Knoepfe (bootstrap_test_n8n.ps1 -HitlChatApproval), laufen zusaetzlich
# hitlC1-3: fremder Tipper + gefaelschte Signatur blockiert, Replay des Stufe-1-Tipps beantwortet Stufe 2 nicht,
# Text mit Markdown-Entity geht durch.
#
# KARTE-OFFEN-SPERRE (Fix C): je Send prueft der Test VOR dem Tipp die Zeile in agent.hitl_pending (Ursprungs-Chat
# des Falls, diese Execution, offen, Ablauf <= 16 Min) und NACH dem Lauf, dass sie freigegeben ist (Gnadenfrist; loeschen
# tut erst der Orchestrator nach seiner Antwort); hitl11 = Sentinel ohne Zeile.
#
# Beweist die Phase-5-Mechanik (Mock-Interception + HITL-Resume) und ist das Fundament fuer den
# Real-Ingress-Treiber (Phase 7). Vorbedingung: scripts/dev/enable_mock_telegram.ps1 lief
# (Mock aktiv + baseUrl umgebogen).
#
# Usage:  .\scripts\dev\hitl_gate_test.ps1 [-Timeout 30] [-Verbose]
# Exit-Code = Anzahl Fehler.
param(
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
. "$PSScriptRoot\test_n8n_state.ps1"
$conn      = Get-TestN8nConnection
$N8nUrl    = $conn.Url
$ApiKey    = $conn.ApiKey
$Container = $conn.Container
if ([string]::IsNullOrWhiteSpace($TEST_HARNESS_SECRET)) { throw "TEST_HARNESS_SECRET fehlt in .env." }

# Mock-Telegram muss aktiv sein (State-Block von enable_mock_telegram.ps1).
$state = Get-TestN8nState
if (-not $state.mock_telegram) {
    throw "Mock-Telegram nicht aktiv (kein mock_telegram-Block im State). Zuerst: .\scripts\dev\enable_mock_telegram.ps1"
}

$Headers    = @{ 'X-N8N-API-KEY' = $ApiKey }
$AuthHeader = 'X-Test-Auth'
$HarnessPath = 'gate-test'
$GateName    = 'agent.tool_human_approval'

function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8nUrl/api/v1/$Path" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) {
    try { Invoke-RestMethod -Uri "$N8nUrl/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
}
function Get-ExecDetail([string]$ExecId) { Invoke-RestMethod -Uri "$N8nUrl/api/v1/executions/$ExecId`?includeData=true" -Headers $Headers -Method Get }

# Gate-Workflow-id (Laufzeit == getrackte id, import:workflow behaelt sie; trotzdem dynamisch via Name).
$wfList = Invoke-N8nGet 'workflows?limit=200'
$gateWfId = ($wfList.data | Where-Object { $_.name -eq $GateName } | Select-Object -First 1).id
if (-not $gateWfId) { throw "Workflow '$GateName' nicht gefunden (Substrat deployt?)." }

# --- Member-Pfad-Absicherung (WS-5): eine GEPAIRTE Partnerin ins Substrat seeden, damit
# fn_resolve_sender(880055200) role=partner liefert -> die Member-Zweige des Gates (owner_info/owner_only/
# owner_approval) real durchlaufen (statt des Owner-Default-Pfads beim ungepairten Sender). Muster 1:1 aus
# real_ingress_test.ps1 (util_seed_test_fixtures haengt Lena an; das Pairing setzt die tg-ids). Idempotent.
$MemberChatId   = '880055200'   # Lena (role=partner) — der ueberlebende Partner-Fall (Break-Glass)
$PairedUidOwner = $TestOwnerTelegramUid
$seed = Invoke-TestN8nPsqlFile -Container $Container -HostFile "$RepoRoot\tests\fixtures\util_seed_test_fixtures.sql"
if ($seed.Code -ne 0) { throw "Fixture-Seed (Container-DB) fehlgeschlagen: $($seed.Output -join "`n")" }
$pairSql = @"
UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,persons}',
  (SELECT jsonb_agg(
     CASE WHEN p->>'person_id' = 'owner' THEN p || jsonb_build_object('telegram_user_id', ${PairedUidOwner}::bigint)
          WHEN p->>'person_id' = 'lena'  THEN p || jsonb_build_object('telegram_user_id', ${MemberChatId}::bigint, 'language', 'ko')
          ELSE p END)
   FROM jsonb_array_elements(metadata->'facts'->'persons') p))
WHERE name = 'family';
"@
$pair = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $pairSql)
if ($pair.Code -ne 0) { throw "Owner/Lena-Pairing (Container-DB) fehlgeschlagen: $($pair.Output -join "`n")" }

# --- Karte-offen-Sperre (Fix C, agent.hitl_pending): vor JEDEM Resume muss eine Zeile fuer den URSPRUNGS-Chat
# des Falls (= chat_id des Gate-Aufrufs, auch im Vier-Augen-Pfad fuer BEIDE Stufen) mit dieser Execution und
# expires_at ~ jetzt + WAIT_MIN + 6 existieren; nach dem Lauf darf fuer die Execution keine Zeile bleiben.
# Nicht-numerische chat_id (Sentinel) -> nie eine Zeile. Reste frueherer (gestoppter) Laeufe vorab leeren.
Clear-HitlPending -Container $Container
Clear-ThinkingLease -Container $Container
function Get-PendingRows([string]$ExecId) {
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc',
        "SELECT chat_id || '|' || round(extract(epoch FROM expires_at - now()) / 60) || '|' || (released_at IS NOT NULL) FROM agent.hitl_pending WHERE execution_id = '$ExecId';")
    if ($r.Code -ne 0) { throw "hitl_pending-Abfrage fehlgeschlagen: $($r.Output -join "`n")" }
    @($r.Output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
}
function Test-PendingOpen($Case, [string]$ExecId) {
    $rows = @(Get-PendingRows $ExecId)
    if ($Case.chat_id -notmatch '^[0-9]+$') {
        if ($rows.Count) { return "Sentinel-chat_id, aber Sperr-Zeile(n): $($rows -join ', ')" }
        return $null
    }
    if ($rows.Count -ne 1) { return "erwartet genau 1 Sperr-Zeile fuer Execution $ExecId, got [$($rows -join ', ')]" }
    $parts = $rows[0].Split('|')
    if ($parts[0] -ne $Case.chat_id) { return "Sperr-Zeile fuer chat_id=$($parts[0]) statt Ursprungs-Chat $($Case.chat_id)" }
    # Zeile entsteht VOR dem Send, gelesen wird erst nach dem Abfangen (Telegram-Haenger) -> grosszuegige Untergrenze.
    if ([int]$parts[1] -lt 5 -or [int]$parts[1] -gt 16) { return "Sperr-Zeile laeuft in $($parts[1]) Min ab (erwartet <= 16)" }
    if ($parts[2] -ne 'false') { return 'Sperr-Zeile ist schon freigegeben, obwohl die Karte offen ist' }
    return $null
}

# sends = geordnete Liste der abzufangenden+aufzuloesenden Send-and-Waits je Tier (t=member|owner, ok=Entscheid);
# leere Liste = KEIN Send (owner_only-Block -> Korrelation ueber den Summary-Marker in den runData).
$cases = @(
    [pscustomobject]@{ id='hitl01'; name='Owner Approve -> true';                       chat_id='999000111';    tier='';               sends=@(@{t='owner'; ok=$true});                    expected=$true  }
    [pscustomobject]@{ id='hitl02'; name='Owner Decline -> false';                      chat_id='999000111';    tier='';               sends=@(@{t='owner'; ok=$false});                   expected=$false }
    [pscustomobject]@{ id='hitl03'; name='owner_info: Member bestaetigt selbst -> true'; chat_id=$MemberChatId; tier='owner_info';     sends=@(@{t='member'; ok=$true});                   expected=$true;  assertOwnerInfo=$true }
    [pscustomobject]@{ id='hitl04'; name='owner_only: Member-Block -> false (kein Send)'; chat_id=$MemberChatId; tier='owner_only';     sends=@();                                          expected=$false; expectReason='owner_only' }
    [pscustomobject]@{ id='hitl05'; name='owner_approval: Vier-Augen Member+Owner -> true'; chat_id=$MemberChatId; tier='owner_approval'; sends=@(@{t='member'; ok=$true}, @{t='owner'; ok=$true}); expected=$true }
    [pscustomobject]@{ id='hitl06'; name='owner_approval: Member-Decline (Stufe 1) -> false'; chat_id=$MemberChatId; tier='owner_approval'; sends=@(@{t='member'; ok=$false});               expected=$false }
    [pscustomobject]@{ id='hitl07'; name='owner_approval: Owner-Veto (Stufe 2) -> false';  chat_id=$MemberChatId; tier='owner_approval'; sends=@(@{t='member'; ok=$true}, @{t='owner'; ok=$false}); expected=$false }
    # self: eigene per_user-Daten (agent.tool_set_own_context_facts) -> nur das Mitglied bestaetigt, KEIN Owner-Send
    # (auch keine Info: sie truege private Profildaten zum Owner) — assertNoOwnerSend prueft das hart.
    [pscustomobject]@{ id='hitl08'; name='self: Member bestaetigt eigene Daten -> true, kein Owner-Send'; chat_id=$MemberChatId; tier='self'; sends=@(@{t='member'; ok=$true});  expected=$true;  assertNoOwnerSend=$true }
    [pscustomobject]@{ id='hitl09'; name='self: Member lehnt ab -> false, kein Owner-Send';                 chat_id=$MemberChatId; tier='self'; sends=@(@{t='member'; ok=$false}); expected=$false; assertNoOwnerSend=$true }
    # Textkatalog: STRUKTURIERTES Summary (New-HitlSummary-Form) — Mitglied (ko) und Owner (de) bekommen Titel, Betrag
    # und Datum in IHRER Sprache/Formatierung; ein kaputter Betrag (LLM-Tippfehler) legt das Gate nicht lahm (Rohwert).
    [pscustomobject]@{ id='hitl10'; name='Textkatalog: strukturiertes Summary je Empfaenger-Sprache'; chat_id=$MemberChatId; tier='owner_approval'
        sends=@(@{t='member'; ok=$true}, @{t='owner'; ok=$true}); expected=$true; structured=$true
        expectMember=@('계획 게시', '€1,234.50', '2026. 12. 31.', 'xyz'); expectOwner=@('Mitglied Lena', 'Plan veröffentlichen', '1.234,50', '31.12.2026', 'xyz') }
    # Fix C: nicht-numerische Sentinel-chat_id -> Owner-Pfad, aber KEINE Karte-offen-Sperr-Zeile (Test-Pfade sperren nie).
    [pscustomobject]@{ id='hitl11'; name='Sentinel-chat_id: Owner-Pfad ohne Sperr-Zeile';   chat_id='test_hitl11'; tier='';               sends=@(@{t='owner'; ok=$false});                   expected=$false }
    # Lange Karten (Telegram-Limit 4096): das Gate sendet die vorderen Teile ("Teil n/N") VOR der Karte an denselben
    # Empfaenger, jede Nachricht <= 4096, die Knoepfe an der letzten. Das Summary traegt eine Zeile ueber dem Limit
    # (wird gekuerzt) und den Fall-Marker am ENDE (steht so im letzten Teil = der Karte). parts = Empfaenger mit Teilen.
    [pscustomobject]@{ id='hitl12'; name='Lange Karte Owner: Teile vor der Karte, je <= 4096'; chat_id='999000111'; tier=''; sends=@(@{t='owner'; ok=$true}); expected=$true; long=$true; parts=@('owner') }
    [pscustomobject]@{ id='hitl13'; name='Lange Karte Vier-Augen: Teile an Mitglied und Owner (Stufe 2)'; chat_id=$MemberChatId; tier='owner_approval'
        sends=@(@{t='member'; ok=$true}, @{t='owner'; ok=$true}); expected=$true; long=$true; parts=@('member', 'owner'); ownerPart1='Lena' }
    [pscustomobject]@{ id='hitl14'; name='Lange Karte owner_info: Teile an Mitglied, Owner-Info geteilt'; chat_id=$MemberChatId; tier='owner_info'
        sends=@(@{t='member'; ok=$true}); expected=$true; long=$true; parts=@('member', 'owner'); assertOwnerInfo=$true }
)
# Teil-Praefix je Empfaenger-Sprache (core.hitl.part): Owner de "Teil n/N", Mitglied Lena ko "n/N부".
$PartRx = @{ owner = '^Teil (\d+)/(\d+)\n'; member = '^(\d+)/(\d+)부\n' }
$AnyPartRx = '^(Teil|Part) \d+/\d+\n|^\d+/\d+부\n'
function New-LongSummary([string]$Id) {
    $l = @("HITL probe $Id (lange Karte)")
    for ($i = 1; $i -le 140; $i++) { $l += "Zeile ${i}: " + ('x' * 40) }
    $l += ('y' * 5000)
    $l += "marker $Id"
    $l -join "`n"
}

# Sprache je Empfaenger (Textkatalog): Lena (Mitglied) = ko, Owner = de. Erwartete Knopf-Texte + ein Hinweis-Fragment
# je Sprache; jeder abgefangene Button-Send wird darauf geprueft (nicht nur hitl08).
$LangExpect = @{
    member = @{ approve = '✅ 확인'; cancel = '❌ 취소'; hint = '버튼으로' }
    owner  = @{ approve = '✅ Bestätigen'; cancel = '❌ Abbrechen'; hint = 'Bitte über die Knöpfe' }
}
function Get-ButtonTexts($Msg) {
    $kb = $Msg.body.reply_markup
    if ($kb -is [string]) { try { $kb = $kb | ConvertFrom-Json } catch { } }
    @($kb.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { [string]$_.text })
}

Write-Host ""
Write-Host "HITL-Gate-Test (echter Telegram-Pfad ueber Mock) -- $($cases.Count) Gate-Faelle + 3 Fakten-Write-Faelle"
Write-Host ("-" * 64)
$passed = 0; $failed = 0

foreach ($tc in $cases) {
    Write-Host ""
    Write-Host "  [$($tc.id)] $($tc.name)"
    Clear-MockTelegramRequests -Container $Container

    # chat_id je Case: 999000111 = ungepairt -> Owner-Pfad; 880055200 = gepairte Partnerin -> Member-Pfad.
    $sum = "HITL probe $($tc.id): bitte bestaetigen."
    if ($tc.long) { $sum = New-LongSummary $tc.id }
    if ($tc.structured) {
        $sum = [ordered]@{ title = 'core.hitl.publish_plan'; lines = @(
            [ordered]@{ label = 'core.label.amount'; kind = 'money'; value = 1234.5; currency = 'EUR' }
            [ordered]@{ label = 'core.label.date'; kind = 'date'; value = '2026-12-31' }
            [ordered]@{ label = 'core.label.note'; kind = 'text'; value = "marker $($tc.id)" }
            [ordered]@{ label = 'core.label.amount'; kind = 'money'; value = 'xyz'; currency = 'EUR' }
        ) }
    }
    $payload = (@{ chat_id = $tc.chat_id; summary = $sum; approval_tier = $tc.tier } | ConvertTo-Json -Compress -Depth 6)

    # Gate-Floor VOR dem POST (n8n vergibt global monotone ids): die Execution DIESES Falls hat danach
    # id > $gateBase. Der owner_only-Zweig (kein Send -> Marker-Scan) braucht das zwingend — sonst matcht der
    # per-Lauf-KONSTANTE Marker eine gleich-markierte Execution eines FRUEHEREN Laufs (Substrat-Reuse ohne
    # -Reset ist der endorste Normalfall), und eine Regression (Block wird faelschlich zum Send -> die aktuelle
    # Execution suspendiert) bliebe still ein False-PASS auf der alten success-Zeile.
    $gateBase = Get-MaxExecId -WfId $gateWfId -BridgeUrl $N8nUrl -ApiKey $ApiKey

    # POST blockiert bis zum Gate-Resume (responseMode=lastNode); Client-Timeout ist KEIN Fehler — die
    # Execution laeuft serverseitig weiter (wie infra_test).
    try {
        Invoke-RestMethod -Uri "$N8nUrl/webhook/$HarnessPath" -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
            -TimeoutSec 6 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
    } catch {
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) {
            Write-Host "    [FAIL] Webhook-POST fehlgeschlagen: $_" -ForegroundColor Red
            Write-Host "    DIAGNOSE: Harness aktiv? Secret korrekt? URL: $N8nUrl/webhook/$HarnessPath" -ForegroundColor Yellow
            $failed++; continue
        }
    }

    # --- je Send-and-Wait des Tiers (in Reihenfolge): abfangen (Ziel-chat_id verifizieren) + Resume feuern.
    # Korreliert ueber den eindeutigen Summary-Marker ($tc.id) im Text PLUS die Ziel-chat_id (member vs owner),
    # sodass im Vier-Augen-Pfad der Member- und der Owner-Send auseinandergehalten werden. Die exakte
    # Gate-Execution-id steckt im Resume-URL-Pfad (/webhook-waiting/{execId}/{nodeId}) = GENAU diese Execution.
    $execId = $null; $sendFail = $false
    foreach ($snd in $tc.sends) {
        $isMemberSend = ($snd.t -eq 'member')
        $msg = $null; $start = Get-Date
        while ($true) {
            $reqs = Get-MockTelegramRequests -Container $Container
            $msg  = $reqs | Where-Object {
                $_.method -eq 'sendMessage' -and $_.body.reply_markup -and ([string]$_.body.text).Contains($tc.id) -and `
                ( ($isMemberSend -and ([string]$_.body.chat_id -eq $MemberChatId)) -or `
                  ((-not $isMemberSend) -and ([string]$_.body.chat_id -ne $MemberChatId)) )
            } | Select-Object -Last 1
            if ($msg) { break }
            if (((Get-Date) - $start).TotalSeconds -ge $Timeout) { break }
            Start-Sleep -Milliseconds 700
        }
        if (-not $msg) {
            Write-Host "    [FAIL] Erwarteter $($snd.t)-Send (Buttons, Marker $($tc.id)) nicht abgefangen." -ForegroundColor Red
            $sendFail = $true; break
        }
        # SICHERHEITS-INVARIANTE: der Member-Send adressiert die AUFGELOESTE, verifizierte Partner-chat_id
        # (sender.chat_id aus fn_resolve_sender = 880055200) und NICHT den Owner -- ein Send an den Owner statt
        # das Mitglied waere der Multi-Member-Auth-Bruch. (Bei einem legitimen Mitglied ist die aufgeloeste
        # chat_id == die Eingangs-id; die Pruefung sichert daher 'an die verifizierte Partnerin, nicht den Owner'.)
        if ($isMemberSend -and ([string]$msg.body.chat_id -ne $MemberChatId)) {
            Write-Host "    [FAIL] Member-Send ging an chat_id=$($msg.body.chat_id) statt an die Partnerin $MemberChatId (Leak!)." -ForegroundColor Red
            $sendFail = $true; break
        }
        if ($Verbose) { Write-Host "    $($snd.t)-Send abgefangen an chat_id=$($msg.body.chat_id) (approve=$($snd.ok))" -ForegroundColor DarkGray }
        # Textkatalog: Knoepfe + Hinweis in der Sprache DIESES Empfaengers; bei hitl08 zusaetzlich Titel/Betrag/Datum.
        $le = $LangExpect[$snd.t]; $btn = Get-ButtonTexts $msg; $txt = [string]$msg.body.text
        $langBad = @()
        if ($btn -notcontains $le.approve -or $btn -notcontains $le.cancel) { $langBad += "Knoepfe [$($btn -join ' | ')]" }
        if (-not $txt.Contains($le.hint)) { $langBad += "Hinweis fehlt ('$($le.hint)')" }
        $want = if ($snd.t -eq 'member') { $tc.expectMember } else { $tc.expectOwner }
        foreach ($w in @($want)) { if ($w -and -not $txt.Contains($w)) { $langBad += "Text ohne '$w'" } }
        if ($langBad.Count) {
            Write-Host "    [FAIL] $($snd.t)-Send nicht in der Empfaenger-Sprache: $($langBad -join '; ')" -ForegroundColor Red
            Write-Host "      Text: $txt" -ForegroundColor DarkGray
            $sendFail = $true; break
        }
        try {
            $resumeUrl = Get-HitlResumeUrl -Request $msg -Approved $snd.ok -BridgeUrl $N8nUrl
            $eid = Get-HitlExecId -Url $resumeUrl; if ($eid) { $execId = $eid }
            # Karte offen -> Sperr-Zeile fuer den Ursprungs-Chat (vor dem Tipp).
            $pendBad = Test-PendingOpen $tc $eid
            if ($pendBad) {
                Write-Host "    [FAIL] Karte-offen-Sperre ($($snd.t)-Send): $pendBad" -ForegroundColor Red
                $sendFail = $true; Invoke-HitlResume -Url $resumeUrl | Out-Null; break
            }
            Invoke-HitlResume -Url $resumeUrl | Out-Null
        } catch {
            Write-Host "    [FAIL] Resume ($($snd.t)) fehlgeschlagen: $_" -ForegroundColor Red
            $sendFail = $true; break
        }
    }
    if ($sendFail) { $failed++; continue }

    # owner_only: KEIN Send -> die Gate-Execution ueber den Summary-Marker in den runData des Start-Nodes finden.
    # FLOOR id > $gateBase (nur DIESER Lauf -> kein Stale-Match auf eine gleich-markierte alte Execution) und
    # KEIN status-Filter: eine faelschlich SENDENDE Regression suspendiert die Execution (status=waiting) ->
    # sie wird trotzdem gefunden, und der Success-Check unten schlaegt fehl (statt still auf eine alte
    # success-Zeile auszuweichen = der False-Green, den Cold-Eyes fand).
    if ($tc.sends.Count -eq 0) {
        $start = Get-Date
        while (-not $execId) {
            foreach ($e in (Invoke-N8nGet "executions?workflowId=$gateWfId&limit=20").data) {
                if ([long]$e.id -le [long]$gateBase) { continue }
                $d = $null; try { $d = Get-ExecDetail $e.id } catch { }
                $s = $null; try { $s = [string]$d.data.resultData.runData.'Start'[0].data.main[0][0].json.summary } catch { }
                if ($s -and $s.Contains($tc.id)) { $execId = $e.id; break }
            }
            if ($execId -or (((Get-Date) - $start).TotalSeconds -ge $Timeout)) { break }
            Start-Sleep -Milliseconds 700
        }
        # 'KEIN Send'-Invariante HART pruefen (Cold-Eyes MINOR): owner_only darf NULL button-tragende Sends mit
        # dem Marker erzeugt haben — ein Leak (auch an die Partnerin) waere genau der Multi-Member-Auth-Bruch,
        # den dieser Fall garantiert. Der Mock-Log ist seit Case-Start (Clear oben) leer.
        $leak = Get-MockTelegramRequests -Container $Container | Where-Object {
            $_.method -eq 'sendMessage' -and $_.body.reply_markup -and ([string]$_.body.text).Contains($tc.id)
        } | Select-Object -First 1
        if ($leak) {
            Write-Host "    [FAIL] owner_only: unerwarteter Button-Send an chat_id=$($leak.body.chat_id) (der Block darf NICHT senden)." -ForegroundColor Red
            $failed++; continue
        }
    }
    if (-not $execId) { Write-Host "    [FAIL] Keine Gate-Execution-id ermittelt (kein Send/Marker > gateBase gefunden?)." -ForegroundColor Red; $failed++; continue }

    # GENAU diese Gate-Execution einsammeln (warten -> success) und Return.approved pruefen.
    $ex = $null; $start = Get-Date
    while ($true) {
        try { $cand = Get-ExecDetail $execId } catch { $cand = $null }
        if ($cand -and $cand.status -eq 'success') { $ex = $cand; break }
        if (((Get-Date) - $start).TotalSeconds -ge $Timeout) { $ex = $cand; break }
        Start-Sleep -Milliseconds 700
    }
    if (-not $ex) { Write-Host "    [FAIL] Gate-Execution $execId nicht abrufbar." -ForegroundColor Red; $failed++; continue }

    # WS-5b: das Dual-Control-Gate hat MEHRERE Terminal-Returns (Return owner / Return co-approval /
    # Return info / Return blocked / Return declined) statt eines einzigen 'Return' -> den approved-Wert (+
    # reason bei owner_only) aus dem tatsaechlich gelaufenen Return*-Node ziehen (name-agnostisch).
    $approved = $null; $reason = $null
    try {
        foreach ($nodeName in $ex.data.resultData.runData.PSObject.Properties.Name) {
            if ($nodeName -notlike 'Return*') { continue }
            $rj = $ex.data.resultData.runData.$nodeName[0].data.main[0][0].json
            if ($null -ne $rj.approved) { $approved = $rj.approved; $reason = $rj.reason; break }
        }
    } catch { }

    # owner_info: der Einweg-Owner-Info-Send (KEIN reply_markup) MUSS an den Owner (nicht die Partnerin) gehen —
    # beweist, dass der Owner bei der Member-Selbstbestaetigung informiert wird (Maker-Checker-Transparenz).
    $ownerInfoOk = $true
    if ($tc.assertOwnerInfo) {
        $info = $null; $start = Get-Date
        while ($true) {
            $info = Get-MockTelegramRequests -Container $Container | Where-Object {
                $_.method -eq 'sendMessage' -and (-not $_.body.reply_markup) -and `
                ([string]$_.body.text).Contains($tc.id) -and ([string]$_.body.chat_id -ne $MemberChatId)
            } | Select-Object -Last 1
            if ($info -or (((Get-Date) - $start).TotalSeconds -ge 10)) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $info) { $ownerInfoOk = $false; Write-Host "    [FAIL] owner_info: kein Einweg-Owner-Info-Send an den Owner abgefangen." -ForegroundColor Red }
        elseif ($Verbose) { Write-Host "    Owner-Info-Send abgefangen an chat_id=$($info.body.chat_id)" -ForegroundColor DarkGray }
    }
    # self: KEIN einziger Send mit dem Marker an jemand anderen als das Mitglied (weder Buttons noch Info).
    if ($tc.assertNoOwnerSend) {
        $ownerLeak = Get-MockTelegramRequests -Container $Container | Where-Object {
            $_.method -eq 'sendMessage' -and ([string]$_.body.text).Contains($tc.id) -and ([string]$_.body.chat_id -ne $MemberChatId)
        } | Select-Object -First 1
        if ($ownerLeak) { $ownerInfoOk = $false; Write-Host "    [FAIL] self: unerwarteter Send an chat_id=$($ownerLeak.body.chat_id) (Owner darf nichts bekommen)." -ForegroundColor Red }
    }
    # Lange Karten: je erwartetem Empfaenger >= 1 Vor-Teil (ohne Knoepfe, "Teil i/N" in seiner Sprache), lueckenlos
    # nummeriert bis zur letzten Nachricht; JEDE Nachricht <= 4096 Zeichen. Kurze Karten: nie ein Teil-Praefix.
    $reqsAll = @(Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'sendMessage' })
    if ($tc.long) {
        foreach ($who in $tc.parts) {
            $toMember = ($who -eq 'member')
            $mine = @($reqsAll | Where-Object { (([string]$_.body.chat_id -eq $MemberChatId) -eq $toMember) -and ([string]$_.body.text) -match $PartRx[$who] })
            $nums = @($mine | ForEach-Object { [void](([string]$_.body.text) -match $PartRx[$who]); "$($Matches[1])/$($Matches[2])" })
            $total = if ($nums.Count) { [int]($nums[0].Split('/')[1]) } else { 0 }
            $long = @($mine | Where-Object { ([string]$_.body.text).Length -gt 4096 })
            if ($total -lt 2 -or $nums.Count -ne $total -or $long.Count) {
                $ownerInfoOk = $false
                Write-Host "    [FAIL] Lange Karte ($who): Teile [$($nums -join ', ')], ueber 4096: $($long.Count)" -ForegroundColor Red
            } elseif ($who -eq 'owner' -and $tc.ownerPart1 -and -not (@($mine | Where-Object { ([string]$_.body.text) -match '^Teil 1/' } | Select-Object -Last 1).body.text).Contains($tc.ownerPart1)) {
                $ownerInfoOk = $false; Write-Host "    [FAIL] Lange Karte: Owner-Teil 1 ohne Kopf ('$($tc.ownerPart1)')" -ForegroundColor Red
            } elseif ($Verbose) { Write-Host "    $who-Teile: $($nums -join ', ')" -ForegroundColor DarkGray }
        }
    } elseif (@($reqsAll | Where-Object { ([string]$_.body.text) -match $AnyPartRx }).Count) {
        $ownerInfoOk = $false; Write-Host "    [FAIL] Kurze Karte, aber Teil-Nachricht gesendet." -ForegroundColor Red
    }
    # removeButtons statt showOutcome: n8n darf die fest englische Zeile "Approved by ..." nie anhaengen.
    $outcome = Get-MockTelegramRequests -Container $Container | Where-Object { ([string]$_.body.text) -match 'Approved by|Declined by' } | Select-Object -First 1
    if ($outcome) { Write-Host "    [FAIL] englische Outcome-Zeile gesendet ($($outcome.method))." -ForegroundColor Red; $ownerInfoOk = $false }
    $reasonOk = (-not $tc.expectReason) -or ($reason -eq $tc.expectReason)
    if (-not $reasonOk) { Write-Host "    [FAIL] Erwartete reason=$($tc.expectReason), got '$reason'." -ForegroundColor Red }
    # Nach dem Lauf (Tipp/Block) ist jede Sperr-Zeile dieser Execution FREIGEGEBEN (Close pending lief) und laeuft binnen
    # der Gnadenfrist (2 Min) ab; geloescht wird sie erst vom Orchestrator nach seiner Antwort (hier gibt es keinen).
    $leftover = @(Get-PendingRows ([string]$ex.id) | Where-Object { $rp = $_.Split('|'); ($rp[2] -ne 'true') -or ([int]$rp[1] -gt 2) })
    if ($leftover.Count) { $ownerInfoOk = $false; Write-Host "    [FAIL] Karte-offen-Sperre nach dem Lauf nicht freigegeben: $($leftover -join ', ')" -ForegroundColor Red }

    Write-Host "    Execution id=$($ex.id) status=$($ex.status)  ->  approved=$approved (erwartet $($tc.expected))"
    if ($ex.status -eq 'success' -and $approved -eq $tc.expected -and $ownerInfoOk -and $reasonOk) {
        $passed++; Write-Host "    [PASS]" -ForegroundColor Green
    } else {
        $failed++; Write-Host "    [FAIL] $($tc.name)" -ForegroundColor Red
    }
}

# --- hitl15: lange Karte, ein Vor-Teil scheitert (Mock-Schalter /__fail: sendMessage -> HTTP 400 wie die Bot-API) ->
# fail-closed: KEINE Karte mit Knoepfen, der Gate-Lauf endet nicht erfolgreich (kein approved:true -> kein Write), die
# Karte-offen-Sperre bleibt nicht offen (core.sub_error_notify 'Clear card lock' bzw. keine Zeile). Mock danach wieder an.
Write-Host ""
Write-Host "  [hitl15] Lange Karte: Vor-Teil scheitert -> keine Karte, kein approved"
Clear-MockTelegramRequests -Container $Container
$mockPort = if ($state.mock_telegram.port) { $state.mock_telegram.port } else { 8089 }
function Set-MockSendFail([bool]$On) {
    $q = if ($On) { 'method=sendMessage' } else { 'method=sendMessage&off=1' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker exec $Container sh -c "curl -s 'http://127.0.0.1:$mockPort/__fail?$q'" 2>$null | Out-Null
    $ErrorActionPreference = $prev
}
$failExec = $null
$gateBase = Get-MaxExecId -WfId $gateWfId -BridgeUrl $N8nUrl -ApiKey $ApiKey
try {
    Set-MockSendFail $true
    $payload = (@{ chat_id = '999000111'; summary = (New-LongSummary 'hitl15'); approval_tier = '' } | ConvertTo-Json -Compress)
    try {
        Invoke-RestMethod -Uri "$N8nUrl/webhook/$HarnessPath" -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
            -TimeoutSec 6 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
    } catch { }
    $start = Get-Date
    while (-not $failExec -and ((Get-Date) - $start).TotalSeconds -lt ($Timeout + 15)) {
        $failExec = (Invoke-N8nGet "executions?workflowId=$gateWfId&limit=20").data |
            Where-Object { [long]$_.id -gt [long]$gateBase -and $_.status -in @('error', 'crashed', 'success') } | Select-Object -First 1
        if (-not $failExec) { Start-Sleep -Milliseconds 700 }
    }
} finally { Set-MockSendFail $false }
$card = Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'sendMessage' -and $_.body.reply_markup -and ([string]$_.body.text).Contains('hitl15') } | Select-Object -First 1
Start-Sleep -Seconds 3
$openRows = if ($failExec) { @(Get-PendingRows ([string]$failExec.id) | Where-Object { $_.Split('|')[2] -ne 'true' }) } else { @() }
if ($failExec -and $failExec.status -ne 'success' -and -not $card -and -not $openRows.Count) {
    $passed++; Write-Host "    Execution id=$($failExec.id) status=$($failExec.status), keine Karte, Sperre frei" ; Write-Host "    [PASS]" -ForegroundColor Green
} else {
    $failed++
    Write-Host "    [FAIL] Execution=$($failExec.id) status=$($failExec.status) Karte=$([bool]$card) offene Sperr-Zeilen=[$($openRows -join ', ')]" -ForegroundColor Red
}
$cases += [pscustomobject]@{ id = 'hitl15'; name = 'Lange Karte: Vor-Teil scheitert -> keine Karte' }

# --- Phase A: Approve-Zweig des EINEN Fakten-Schreibwegs bis in die DB (Schema-Fidelity Payload -> fn -> Zeile).
# Ueber den facts-test-Harness (agent.tool_set_context_facts) mit der UNGEPAIRTEN Owner-chat_id (owner_only-Gate
# -> ein Tap). Je Fall: Summary abfangen (Marker + erwartetes Label), approve, danach den geschriebenen Probe-Key
# in der Container-DB pruefen und wieder entfernen. hitlF2 belegt zusaetzlich den Fakten-Titel aus dem Textkatalog
# des besitzenden Pakets ('Finanzprofil' = finance.facts.finance_profile.title).
$factCases = @(
    [pscustomobject]@{ id='hitlF1'; ctx='family';          label='Haushalt aktualisieren' }
    [pscustomobject]@{ id='hitlF2'; ctx='finance_profile'; label='Finanzprofil aktualisieren' }
)
foreach ($fc in $factCases) {
    Write-Host ""
    Write-Host "  [$($fc.id)] Fakten-Write $($fc.ctx): Approve -> Zeile in der DB"
    Clear-MockTelegramRequests -Container $Container
    $persons = (ConvertTo-Json -Compress -InputObject @(@{ person_id = 'owner'; hitl_probe = $fc.id }))
    $payload = (@{ chat_id = '999000111'; context_name = $fc.ctx; persons = $persons; scope = 'household' } | ConvertTo-Json -Compress)
    try {
        Invoke-RestMethod -Uri "$N8nUrl/webhook/facts-test" -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
            -TimeoutSec 6 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
    } catch {
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) {
            Write-Host "    [FAIL] Webhook-POST fehlgeschlagen: $_" -ForegroundColor Red; $failed++; continue
        }
    }
    $msg = $null; $start = Get-Date
    while (-not $msg -and ((Get-Date) - $start).TotalSeconds -lt $Timeout) {
        $msg = Get-MockTelegramRequests -Container $Container | Where-Object {
            $_.method -eq 'sendMessage' -and $_.body.reply_markup -and ([string]$_.body.text).Contains($fc.id) } | Select-Object -Last 1
        if (-not $msg) { Start-Sleep -Milliseconds 700 }
    }
    if (-not $msg) { Write-Host "    [FAIL] Bestaetigungs-Send (Marker $($fc.id)) nicht abgefangen." -ForegroundColor Red; $failed++; continue }
    if (-not ([string]$msg.body.text).Contains($fc.label)) {
        Write-Host "    [FAIL] Summary traegt nicht das Label '$($fc.label)': $($msg.body.text)" -ForegroundColor Red; $failed++; continue
    }
    try { Invoke-HitlResume -Url (Get-HitlResumeUrl -Request $msg -Approved $true -BridgeUrl $N8nUrl) | Out-Null }
    catch { Write-Host "    [FAIL] Resume fehlgeschlagen: $_" -ForegroundColor Red; $failed++; continue }
    $q = "SELECT p->>'hitl_probe' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') p WHERE c.name = '$($fc.ctx)' AND p->>'person_id' = 'owner';"
    $got = $null; $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
        $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', $q)
        $got = (@($r.Output) | Where-Object { "$_".Trim() } | Select-Object -First 1)
        if ("$got".Trim() -eq $fc.id) { break }
        Start-Sleep -Milliseconds 700
    }
    $clean = "UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', (SELECT jsonb_agg(p - 'hitl_probe') FROM jsonb_array_elements(metadata->'facts'->'persons') p)) WHERE name = '$($fc.ctx)';"
    Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $clean) | Out-Null
    if ("$got".Trim() -eq $fc.id) { $passed++; Write-Host "    [PASS] persons-Merge in '$($fc.ctx)' geschrieben (Probe-Key wieder entfernt)" -ForegroundColor Green }
    else { $failed++; Write-Host "    [FAIL] Probe-Key nicht in '$($fc.ctx)' gefunden (got '$got')." -ForegroundColor Red }
}
$cases += $factCases

# --- Textkatalog (E3): eine NEUE Person ohne Sprache -> nach dem bestaetigten Write schickt agent.tool_set_context_facts
# dem Owner die Sprach-Picker-Karte (core.sub_send_language_picker): Frage auf Deutsch (Owner-Sprache), ein Knopf je
# unterstuetzter Sprache, callback_data lang:<person_id>:<code>. Danach Person wieder entfernen.
Write-Host ""
Write-Host "  [hitlF3] Neue Person ohne Sprache -> Sprach-Picker-Karte an den Owner"
Clear-MockTelegramRequests -Container $Container
# WP3: eine NEUE Person traegt keine person_id (die vergibt die DB auf dem Chat-Pfad, agent.fn_person_slug) -> die
# vergebene id wird nach dem Write aus family gelesen. Ein Rest aus einem abgebrochenen Lauf wird vorher entfernt
# (sonst faende der Name-Treffer ihn und es entstuende keine neue Person, also kein Picker).
$probeSql = "SELECT pp->>'person_id' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp WHERE c.name = 'family' AND pp->>'first_name' = 'Sora' AND pp->>'last_name' = 'Probe' LIMIT 1;"
$leftPid = "$((Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', $probeSql)).Output | Select-Object -First 1)".Trim()
if ($leftPid) { Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', "SELECT agent.fn_remove_household_person(jsonb_build_object('person_id', '$leftPid'));") | Out-Null }
$probePid = ''
$persons = (ConvertTo-Json -Compress -InputObject @(@{ first_name = 'Sora'; last_name = 'Probe'; birth_date = '2015-01-01'; role = 'child' }))
$payload = (@{ chat_id = '999000111'; context_name = 'family'; persons = $persons; scope = 'household' } | ConvertTo-Json -Compress)
$f3ok = $false
try {
    Invoke-RestMethod -Uri "$N8nUrl/webhook/facts-test" -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
        -TimeoutSec 6 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
} catch { }
$msg = $null; $start = Get-Date
while (-not $msg -and ((Get-Date) - $start).TotalSeconds -lt $Timeout) {
    $msg = Get-MockTelegramRequests -Container $Container | Where-Object {
        $_.method -eq 'sendMessage' -and $_.body.reply_markup -and ([string]$_.body.text).Contains('Sora Probe') } | Select-Object -Last 1
    if (-not $msg) { Start-Sleep -Milliseconds 700 }
}
if (-not $msg) { Write-Host "    [FAIL] Bestaetigungs-Send fuer die neue Person nicht abgefangen." -ForegroundColor Red }
else {
    try { Invoke-HitlResume -Url (Get-HitlResumeUrl -Request $msg -Approved $true -BridgeUrl $N8nUrl) | Out-Null } catch { }
    $card = $null; $start = Get-Date
    while (-not $card -and ((Get-Date) - $start).TotalSeconds -lt $Timeout) {
        $card = Get-MockTelegramRequests -Container $Container | Where-Object {
            $_.method -eq 'sendMessage' -and ([string]$_.body.text).Contains('In welcher Sprache soll Sora') } | Select-Object -Last 1
        if (-not $card) { Start-Sleep -Milliseconds 700 }
    }
    $probePid = "$((Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', $probeSql)).Output | Select-Object -First 1)".Trim()
    if (-not $card) { Write-Host "    [FAIL] Keine Sprach-Picker-Karte an den Owner abgefangen." -ForegroundColor Red }
    else {
        $kb = $card.body.reply_markup; if ($kb -is [string]) { $kb = $kb | ConvertFrom-Json }
        $btns = @($kb.inline_keyboard | ForEach-Object { $_ })
        $data = @($btns | ForEach-Object { [string]$_.callback_data })
        $texts = @($btns | ForEach-Object { [string]$_.text })
        # Textkatalog Phase B: im Modus 'other' (Owner waehlt fuer eine Person) gibt es keinen Vorschlag -> kein 👉-Knopf
        # (der Modus 'self' mit Vorschlag ist im Real-Ingress-Test ri31/ri37 abgedeckt).
        if (($data -contains "lang:${probePid}:ko") -and ($data -contains "lang:${probePid}:de") -and ($texts -contains '한국어') -and -not (($texts -join ' ').Contains('👉'))) { $f3ok = $true }
        else { Write-Host "    [FAIL] Picker-Knoepfe falsch: $($texts -join ' | ') / $($data -join ' | ')" -ForegroundColor Red }
    }
}
# jsonb_build_object statt JSON-Literal: PS 5.1 entfernt eingebettete " aus nativen Argumenten -> das Literal kam als
# {person_id:...} an, das Aufraeumen scheiterte still und der naechste Lauf fand die Person schon vor (kein Picker).
if ($probePid) { Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', "SELECT agent.fn_remove_household_person(jsonb_build_object('person_id', '$probePid'));") | Out-Null }
if ($f3ok) { $passed++; Write-Host "    [PASS] Picker-Karte mit Knoepfen je Sprache (lang:<person>:<code>) beim Owner (Person wieder entfernt)" -ForegroundColor Green }
else { $failed++ }
$cases += [pscustomobject]@{ id = 'hitlF3' }

# --- hitlW1: Wartegrenze wirkt. Eine offene Karte muss nach WAIT_MIN (human_approval.ps1) ablaufen, nicht nie:
# n8n liest die Grenze NUR unter options.limitWaitTime (configureWaitTillDate, Default 'options') — top-level wird still
# ignoriert -> waitTill = WAIT_INDEFINITELY (3000-01-01), die ganze Aufrufer-Kette parkt fuer immer (Live-Befund
# 2026-10-22). Geprueft: waitTill der wartenden Gate-Execution liegt 5..15 Min in der Zukunft; danach Decline (Aufraeumen).
Write-Host ""
Write-Host "  [hitlW1] Offene Karte laeuft nach der Wartegrenze ab (waitTill ~ +10 Min, nicht 3000)"
Clear-MockTelegramRequests -Container $Container
$wPayload = (@{ chat_id = '999000111'; summary = 'HITL probe hitlW1: bitte nicht tippen.'; approval_tier = '' } | ConvertTo-Json -Compress)
try {
    Invoke-RestMethod -Uri "$N8nUrl/webhook/$HarnessPath" -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
        -TimeoutSec 4 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($wPayload)) | Out-Null
} catch { }
$wOk = $false; $wDetail = 'kein Button-Send abgefangen'
$msg = $null; $start = Get-Date
while (-not $msg -and ((Get-Date) - $start).TotalSeconds -lt $Timeout) {
    $msg = Get-MockTelegramRequests -Container $Container | Where-Object {
        $_.method -eq 'sendMessage' -and $_.body.reply_markup -and ([string]$_.body.text).Contains('hitlW1') } | Select-Object -Last 1
    if (-not $msg) { Start-Sleep -Milliseconds 700 }
}
if ($msg) {
    $wUrl = Get-HitlResumeUrl -Request $msg -Approved $false -BridgeUrl $N8nUrl; $wEid = Get-HitlExecId -Url $wUrl
    $wt = $null; $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
        try { $d = Get-ExecDetail $wEid; if ($d.status -eq 'waiting' -and $d.waitTill) { $wt = [datetime]$d.waitTill; break } } catch { }
        Start-Sleep -Milliseconds 700
    }
    if (-not $wt) { $wDetail = "Execution $wEid ohne waitTill" }
    else {
        $mins = ($wt.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalMinutes
        $wOk = ($mins -ge 5 -and $mins -le 15)
        $wDetail = "waitTill=$($wt.ToUniversalTime().ToString('u')) (in $([math]::Round($mins, 1)) Min)"
    }
    try { Invoke-HitlResume -Url $wUrl | Out-Null } catch { }
}
if ($wOk) { $passed++; Write-Host "    [PASS] $wDetail" -ForegroundColor Green }
else { $failed++; Write-Host "    [FAIL] hitlW1: $wDetail" -ForegroundColor Red }
$cases += [pscustomobject]@{ id = 'hitlW1' }

# --- Bestaetigen im Chat (nur wenn das Substrat Chat-Knoepfe sendet: bootstrap_test_n8n.ps1 -HitlChatApproval).
# Die Faelle oben laufen in BEIDEN Modi (Get-HitlResumeUrl/Invoke-HitlResume sind modus-neutral); hier die
# Sicherheits-Eigenschaften, die es nur bei callback_data gibt: fremder Tipper, gefaelschte Signatur, Replay des
# Stufe-1-Tipps im Vier-Augen-Pfad, Markdown-Entities im Text.
function Start-GateCase([string]$Marker, [string]$ChatId, [string]$Tier, [string]$Summary) {
    $p = (@{ chat_id = $ChatId; summary = $Summary; approval_tier = $Tier } | ConvertTo-Json -Compress)
    try {
        Invoke-RestMethod -Uri "$N8nUrl/webhook/$HarnessPath" -Method Post -Headers @{ $AuthHeader = $TEST_HARNESS_SECRET } `
            -TimeoutSec 4 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($p)) | Out-Null
    } catch { }
}
function Wait-ButtonSend([string]$Marker, [string]$ToChat, [int]$Skip = 0) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
        $all = @(Get-MockTelegramRequests -Container $Container | Where-Object {
            $_.method -eq 'sendMessage' -and $_.body.reply_markup -and ([string]$_.body.text).Contains($Marker) -and `
            ((-not $ToChat) -or ([string]$_.body.chat_id -eq $ToChat)) })
        if ($all.Count -gt $Skip) { return $all[$Skip] }
        Start-Sleep -Milliseconds 700
    }
    return $null
}
function Get-ExecStatus([int]$Id) { try { return [string](Get-ExecDetail $Id).status } catch { return '' } }
function Test-StillWaiting([int]$Id) { Start-Sleep -Seconds 3; return ((Get-ExecStatus $Id) -eq 'waiting') }

Clear-MockTelegramRequests -Container $Container
Start-GateCase 'hitlC0' '999000111' '' 'HITL probe hitlC0: Modus-Erkennung.'
$probe = Wait-ButtonSend 'hitlC0' ''
$chatMode = $probe -and (@($probe.body.reply_markup.inline_keyboard | ForEach-Object { $_ } | Where-Object { [string]$_.callback_data -like 'nhitl1|*' }).Count -gt 0)
if ($probe) { try { Invoke-HitlResume -Url (Get-HitlResumeUrl -Request $probe -Approved $false -BridgeUrl $N8nUrl) | Out-Null } catch { } }
Write-Host ""
if (-not $chatMode) {
    Write-Host "  Bestaetigen im Chat: Substrat sendet Link-Knoepfe -> Chat-Faelle uebersprungen (bootstrap_test_n8n.ps1 -HitlChatApproval fuer den Chat-Modus)." -ForegroundColor DarkGray
} else {
    Write-Host "  Bestaetigen im Chat: Substrat sendet callback_data-Knoepfe -> Sicherheits-Faelle"
    $chatCases = @()

    # hitlC1: fremder Tipper + gefaelschte Signatur setzen NICHT fort; danach der Owner -> true.
    $chatCases += 'hitlC1'; Write-Host ""; Write-Host "  [hitlC1] Chat: fremder Tipper / falsche Signatur blockiert, Owner gibt frei"
    Clear-MockTelegramRequests -Container $Container
    Start-GateCase 'hitlC1' '999000111' '' 'HITL probe hitlC1: bitte bestaetigen.'
    $m = Wait-ButtonSend 'hitlC1' ''
    $ok = $false
    if ($m) {
        $url = Get-HitlResumeUrl -Request $m -Approved $true -BridgeUrl $N8nUrl; $eid = Get-HitlExecId -Url $url
        try { Invoke-HitlResume -Url $url -FromId $MemberChatId | Out-Null } catch { }
        $foreignBlocked = Test-StillWaiting $eid
        # Signatur faelschen: letztes Hex-Zeichen der callback_data-HMAC kippen (Rest identisch).
        $cbEsc = if ($url -match '[?&]cb=([^&]+)') { $Matches[1] } else { '' }
        $cbRaw = [uri]::UnescapeDataString($cbEsc)
        $last  = $cbRaw.Substring($cbRaw.Length - 1)
        $cbBad = $cbRaw.Substring(0, $cbRaw.Length - 1) + $(if ($last -eq '0') { '1' } else { '0' })
        $forged = $url.Replace("cb=$cbEsc", 'cb=' + [uri]::EscapeDataString($cbBad))
        $forgedRejected = $false
        try { Invoke-HitlResume -Url $forged | Out-Null } catch { $forgedRejected = $true }
        $forgedBlocked = $forgedRejected -and (Test-StillWaiting $eid)
        try { Invoke-HitlResume -Url $url | Out-Null } catch { }
        Start-Sleep -Seconds 2
        $final = Get-ExecStatus $eid
        if ($Verbose) { Write-Host "    fremd blockiert=$foreignBlocked  falsche Signatur blockiert=$forgedBlocked  danach=$final" -ForegroundColor DarkGray }
        $ok = $foreignBlocked -and $forgedBlocked -and ($final -eq 'success')
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] hitlC1 (Send gefunden=$([bool]$m))" -ForegroundColor Red }

    # hitlC2: Vier-Augen — das Mitglied wiederholt seinen Stufe-1-Tipp, waehrend Stufe 2 (Owner) wartet -> bleibt wartend.
    $chatCases += 'hitlC2'; Write-Host ""; Write-Host "  [hitlC2] Chat: Replay des Stufe-1-Tipps beantwortet Stufe 2 nicht"
    Clear-MockTelegramRequests -Container $Container
    Start-GateCase 'hitlC2' $MemberChatId 'owner_approval' 'HITL probe hitlC2: bitte bestaetigen.'
    $ok = $false
    $m1 = Wait-ButtonSend 'hitlC2' $MemberChatId
    if ($m1) {
        $u1 = Get-HitlResumeUrl -Request $m1 -Approved $true -BridgeUrl $N8nUrl; $eid = Get-HitlExecId -Url $u1
        # Der OWNER tippt auf den Member-Send -> darf Stufe 1 nicht beantworten (approverIds = nur das Mitglied).
        try { Invoke-HitlResume -Url $u1 -FromId ([string]$OWNER_CHAT_ID) | Out-Null } catch { }
        $ownerOnMemberBlocked = Test-StillWaiting $eid
        try { Invoke-HitlResume -Url $u1 | Out-Null } catch { }
        $m2 = Wait-ButtonSend 'hitlC2' ''  -Skip 1
        if ($m2 -and -not $ownerOnMemberBlocked) { Write-Host "    Owner-Tipp auf den Member-Send wurde NICHT blockiert" -ForegroundColor Red; $m2 = $null }
        if ($m2) {
            try { Invoke-HitlResume -Url $u1 | Out-Null } catch { }        # Replay: Mitglied, Stufe-1-Daten
            $replayBlocked = Test-StillWaiting $eid
            try { Invoke-HitlResume -Url (Get-HitlResumeUrl -Request $m2 -Approved $false -BridgeUrl $N8nUrl) | Out-Null } catch { }
            $ex = $null; $start = Get-Date
            while (((Get-Date) - $start).TotalSeconds -lt $Timeout) { try { $ex = Get-ExecDetail $eid } catch { }; if ($ex.status -eq 'success') { break }; Start-Sleep -Milliseconds 700 }
            $ap = $null; try { $ap = $ex.data.resultData.runData.'Return co-approval'[0].data.main[0][0].json.approved } catch { }
            if ($Verbose) { Write-Host "    Replay blockiert=$replayBlocked  Owner-Veto -> approved=$ap" -ForegroundColor DarkGray }
            $ok = $replayBlocked -and ($ex.status -eq 'success') -and ($ap -eq $false)
        }
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] hitlC2" -ForegroundColor Red }

    # hitlC3: Markdown-Entities im Text (Unterstrich) — das Bearbeiten der Nachricht nach dem Tipp ist upstream reiner
    # Text + best-effort; die Freigabe muss trotzdem durchgehen.
    $chatCases += 'hitlC3'; Write-Host ""; Write-Host "  [hitlC3] Chat: Text mit Unterstrich -> Freigabe geht durch"
    Clear-MockTelegramRequests -Container $Container
    Start-GateCase 'hitlC3' '999000111' '' 'HITL probe hitlC3: Konto giro_konto_alt umbenennen.'
    $ok = $false
    $m = Wait-ButtonSend 'hitlC3' ''
    if ($m) {
        $url = Get-HitlResumeUrl -Request $m -Approved $true -BridgeUrl $N8nUrl; $eid = Get-HitlExecId -Url $url
        try { Invoke-HitlResume -Url $url | Out-Null } catch { }
        $ex = $null; $start = Get-Date
        while (((Get-Date) - $start).TotalSeconds -lt $Timeout) { try { $ex = Get-ExecDetail $eid } catch { }; if ($ex.status -eq 'success') { break }; Start-Sleep -Milliseconds 700 }
        $ap = $null; try { $ap = $ex.data.resultData.runData.'Return owner'[0].data.main[0][0].json.approved } catch { }
        $edit = Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -like 'editMessage*' } | Select-Object -First 1
        if ($Verbose) { Write-Host "    approved=$ap  Nachricht bearbeitet=$([bool]$edit)" -ForegroundColor DarkGray }
        $ok = ($ex.status -eq 'success') -and ($ap -eq $true) -and $edit
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] hitlC3" -ForegroundColor Red }

    # hitlC4: Doppel-Tipp im Cron-Dialog (New-StaleTapGuard). agent.finance.cron_remind_interest fragt je offener
    # Zinsgutschrift "so gutgeschrieben?" und nach Ablehnen "morgen erneut?" — in EINER Execution. Ein zweiter Tipp auf
    # "Ablehnen" der ersten Frage darf die zweite NICHT beantworten (sonst: ungesehen uebersprungen). Fixture:
    # offene Zins-Vorkommen aus util_seed_test_fixtures (Tagesgeld Plus; die erste Frage zaehlt; seit dem Monats-Check gibt es keine taegliche Dauerauftrags-Frage mehr). Der Zeitplan
    # wird kurz auf jede Minute gestellt und danach zurueckgesetzt (die CLI spielt die finance-Workflows dabei neu
    # ein -> Chat-Knoepfe per Env erzwingen, wie bootstrap_test_n8n -HitlChatApproval).
    $chatCases += 'hitlC4'; Write-Host ""; Write-Host "  [hitlC4] Chat: Doppel-Tipp im Cron-Dialog beantwortet die Folgefrage nicht"
    $cronWf = ($wfList.data | Where-Object { $_.name -eq 'agent.finance.cron_remind_interest' } | Select-Object -First 1).id
    function Set-CronSchedule([string]$Verb, [string]$Value) {
        $a = @('exec', '-e', 'LIFEAGENTS_HITL_CHAT_APPROVAL=true', $Container, 'lifeagents', 'config', $Verb, 'schedule', 'remind_interest')
        if ($Value) { $a += $Value }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & docker @a 2>&1 | Out-Null
        $ErrorActionPreference = $prev
    }
    function Get-SkipCount { [int]("$((Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', 'SELECT count(*) FROM finance.interest_skips;')).Output | Select-Object -First 1)".Trim()) }
    $ok = $false; $detail = ''; $skipsBefore = Get-SkipCount
    Clear-MockTelegramRequests -Container $Container
    Set-CronSchedule 'set' '* * * * *'
    try {
        $start = Get-Date; $ask = $null
        while (-not $ask -and ((Get-Date) - $start).TotalSeconds -lt 150) {
            $ask = Get-MockTelegramRequests -Container $Container | Where-Object {
                $_.method -eq 'sendMessage' -and $_.body.reply_markup -and (Test-TextHasKey -Text ([string]$_.body.text) -Key 'finance.dialog.interest_ask') } | Select-Object -First 1
            if (-not $ask) { Start-Sleep -Seconds 2 }
        }
        Set-CronSchedule 'reset' ''   # keine weiteren Laeufe; die wartende Execution laeuft mit ihrem Stand weiter
        if (-not $ask) { $detail = 'keine Zins-Frage abgefangen' }
        else {
            $dec = Get-HitlResumeUrl -Request $ask -Approved $false -BridgeUrl $N8nUrl; $eid = Get-HitlExecId -Url $dec
            try { Invoke-HitlResume -Url $dec | Out-Null } catch { }
            Start-Sleep -Seconds 2
            try { Invoke-HitlResume -Url $dec | Out-Null } catch { }       # der Doppel-Tipp (dieselbe Nachricht)
            Start-Sleep -Seconds 3
            $mine = @(Get-MockTelegramRequests -Container $Container | Where-Object {
                $_.method -eq 'sendMessage' -and $_.body.reply_markup -and (Test-TextHasKey -Text ([string]$_.body.text) -Key 'finance.dialog.interest_defer') -and `
                (@($_.body.reply_markup.inline_keyboard | ForEach-Object { $_ } | Where-Object { [string]$_.callback_data -like "nhitl1|$eid|*" }).Count -gt 0) })
            $skips = (Get-SkipCount) - $skipsBefore
            $status = Get-ExecStatus $eid
            if ($Verbose) { Write-Host "    'morgen erneut?'-Fragen=$($mine.Count) (erwartet 2: Frage + nach Doppel-Tipp neu gestellt)  Skips=$skips  Execution=$status" -ForegroundColor DarkGray }
            $ok = ($mine.Count -eq 2) -and ($skips -eq 0) -and ($status -eq 'waiting')
            if (-not $ok) { $detail = "Fragen=$($mine.Count) Skips=$skips Status=$status" }
            if ($mine.Count -ge 1) { try { Invoke-HitlResume -Url (Get-HitlResumeUrl -Request $mine[-1] -Approved $true -BridgeUrl $N8nUrl) | Out-Null } catch { } }
            Start-Sleep -Seconds 2
        }
    } finally {
        Set-CronSchedule 'reset' ''
        if ($cronWf) { try { (Invoke-N8nGet "executions?workflowId=$cronWf&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { } }
    }
    if ($ok) { $passed++; Write-Host "    [PASS]" -ForegroundColor Green } else { $failed++; Write-Host "    [FAIL] hitlC4 ($detail)" -ForegroundColor Red }

    $cases += $chatCases
}

# Haengende Gate-Executions aufraeumen (gestoppte Laeufe erreichen 'Close pending' nie -> Sperr-Zeilen mit leeren).
try { (Invoke-N8nGet "executions?workflowId=$gateWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }
Clear-HitlPending -Container $Container
Clear-ThinkingLease -Container $Container

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($cases.Count) Faelle bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
