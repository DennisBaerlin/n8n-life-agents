#Requires -Version 5.1
# real_ingress_test.ps1 — DETERMINISTISCHER, GRATIS Real-Ingress-Test (Teststrategie Phase 7).
# Anders als die uebrigen Tier-Harnesses (orch/finance/... feuern an einem TEST-Webhook vorbei am
# echten Eingang) feuert dieser Treiber eine TELEGRAM-FOERMIGE Update mit NUMERISCHER chat_id an den
# ECHTEN Telegram-Trigger-Webhook des Orchestrators (Produktivpfad) und prueft die Execution.
#
# Damit fallen die zwei bekannten, bisher nie ueber den echten Eingang bewiesenen Vertraege:
#   (1) chat_id number->string: produktiv kommt eine ZAHL; das String()-Wrapping im Orchestrator ist
#       verankert, war aber nie ueber den echten Eingang geprueft -> ri01 verifiziert, dass die
#       Sub-Agent-Execution (agent.finance) chat_id als JSON-STRING erhaelt (PowerShell-Typ-Check).
#   (2) HITL-Format-Vertrag: ri02 treibt ueber den echten Eingang ein finance-Write-Tool bis ins
#       echte Send-and-Wait-Gate, faengt die Nachricht im Mock-Telegram ab und loest sie ueber die
#       signierte Resume-URL auf (= Format-/Signatur-Vertrag).
#   (3) Sender-Gate: ri03 (ungepairter Sender) muss in den Knock/Ack-Pfad laufen, NICHT zum Agenten.
#
# GRATIS + deterministisch: kombiniert mit enable_mock_llm (Claude-Stub) + enable_mock_telegram
# spricht der ganze Real-Ingress-Pfad mit Mocks (kein echtes Modell, kein echtes Telegram) -> eigener
# Tier wie mock_route_test, NICHT vom PreToolUse-deny-Hook erfasst.
#
# Routing-Asserts sind DETERMINISTISCH aus dem Execution-Log (kein LLM-Judge fuers Routing).
#
# Voraussetzung: laufendes Substrat + enable_mock_llm.ps1 + enable_mock_telegram.ps1 liefen.
# Usage:  .\scripts\dev\real_ingress_test.ps1 [-Id ri01] [-Timeout 90] [-Verbose]
# Exit-Code = Anzahl Fehler.
param(
    [string]$Id,
    [int]$Timeout = 90,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# Kein .env-Load (anders als hitl_gate_test/mock_route_test): der ECHTE Telegram-Ingress nimmt KEINE
# .env-Werte (kein TEST_HARNESS_SECRET) — die Webhook-URL + der Secret-Token werden zur Laufzeit aus dem
# Orchestrator-Workflow abgeleitet; Verbindung kommt aus dem Substrat-State.
. "$PSScriptRoot\test_n8n_state.ps1"
$conn      = Get-TestN8nConnection
$N8nUrl    = $conn.Url
$ApiKey    = $conn.ApiKey
$Container = $conn.Container
$Headers   = @{ 'X-N8N-API-KEY' = $ApiKey }

# --- Beide Mocks muessen aktiv sein (State-Bloecke) --------------------------------------------------
$state = [System.IO.File]::ReadAllText((Join-Path $RepoRoot '.local\n8ntest_state.json'), $Utf8NoBom) | ConvertFrom-Json
if (-not $state.mock_llm) {
    throw "Mock-LLM nicht aktiv (kein mock_llm-Block im State). Zuerst: .\scripts\dev\enable_mock_llm.ps1"
}
if (-not $state.mock_telegram) {
    throw "Mock-Telegram nicht aktiv (kein mock_telegram-Block im State). Zuerst: .\scripts\dev\enable_mock_telegram.ps1"
}
# Tatsaechlichen Gateway-Upstream pruefen (das Laufzeit-Drop-in ueberlebt keinen Container-Neustart) — sonst Credits.
Assert-LlmGatewayUpstream -Container $Container -Expect mock

function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8nUrl/api/v1/$Path" -Headers $Headers -Method Get }
function Get-ExecDetail([string]$ExecId) { Invoke-RestMethod -Uri "$N8nUrl/api/v1/executions/$ExecId`?includeData=true" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) {
    try { Invoke-RestMethod -Uri "$N8nUrl/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
}
# Hoechste bestehende Execution-id eines Workflows (n8n vergibt monotone Integer-ids). Vor dem Feuern
# aufnehmen -> die eigene Execution ist danach die EINZIGE mit id > diesem Wert (race-frei, kein
# Zeitfenster: ein knapp vorher terminierter Vorlauf wird nie faelschlich gegriffen).
function Get-MaxExecId([string]$WfId) {
    try {
        $d = (Invoke-N8nGet "executions?workflowId=$WfId&limit=1").data
        if ($d -and @($d).Count -gt 0) { return [int]$d[0].id }
    } catch { }
    return 0
}
# Auf die NEUE Execution (id > $AfterId) warten und dann auf einen Terminalstatus (success/error).
# Single-User-sequenziell -> genau eine neue Execution; die kleinste id > AfterId ist die eigene.
function Wait-NewExecTerminal([string]$WfId, [int]$AfterId, [int]$TimeoutSec) {
    $start = Get-Date; $cand = $null
    while ($true) {
        try {
            $list = (Invoke-N8nGet "executions?workflowId=$WfId&limit=20").data
            $cand = $list | Where-Object { [int]$_.id -gt $AfterId } | Sort-Object { [int]$_.id } | Select-Object -First 1
        } catch { $cand = $null }
        if ($cand -and $cand.status -ne 'running' -and $cand.status -ne 'new' -and $cand.status -ne 'waiting') {
            return Get-ExecDetail $cand.id
        }
        if (((Get-Date) - $start).TotalSeconds -ge $TimeoutSec) {
            if ($cand) { return Get-ExecDetail $cand.id } else { return $null }
        }
        Start-Sleep -Milliseconds 1200
    }
}
# Tool-/Knoten-Namen, die im Orchestrator-runData ausgefuehrt wurden (Top-Level-Knoten).
function Get-RunNodes([object]$Exec) {
    $rd = $null; try { $rd = $Exec.data.resultData.runData } catch { }
    if (-not $rd) { return @() }
    return @($rd.PSObject.Properties.Name)
}

# Ausgabe (main-json aller Items, alle Runs) eines Knotens als ein JSON-String — fuer expected_output_contains.
function Get-NodeOutputText([object]$Exec, [string]$Node) {
    $runs = $null; try { $runs = $Exec.data.resultData.runData.$Node } catch { }
    if (-not $runs) { return '' }
    $items = @(foreach ($r in @($runs)) { foreach ($out in @($r.data.main)) { foreach ($it in @($out)) { if ($it) { $it.json } } } })
    return ($items | ConvertTo-Json -Depth 20 -Compress)
}

# --- Echten Telegram-Trigger-Webhook des Orchestrators aufloesen (robust gegen Rebuild) -------------
$wfList = Invoke-N8nGet 'workflows?limit=200'
$orchWf = $wfList.data | Where-Object { $_.name -eq 'agent.orchestrator.main_route' } | Select-Object -First 1
if (-not $orchWf) { throw "Workflow 'agent.orchestrator.main_route' nicht gefunden (Substrat deployt?)." }
$OrchWfId = $orchWf.id
$dispatchWfId = ($wfList.data | Where-Object { $_.name -eq 'agent.sub_dispatch_agent' } | Select-Object -First 1).id
# Fix C: Reste der Karte-offen-Sperre (gestoppte Laeufe frueherer Suiten) wuerden jeden Owner-Fall in 'Reply card open'
# laufen lassen -> vorab leeren (und am Ende erneut).
Clear-HitlPending -Container $Container
Clear-ThinkingLease -Container $Container
$orchDetail = Invoke-N8nGet "workflows/$OrchWfId"
$tgTrigger = $orchDetail.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.telegramTrigger' } | Select-Object -First 1
if (-not $tgTrigger -or -not $tgTrigger.webhookId) { throw "Telegram-Trigger-Node (mit webhookId) im Orchestrator nicht gefunden." }
# n8n registriert die Produktiv-URL als {webhookId}/webhook (verifiziert ueber webhook_entity).
$IngressUrl = "$N8nUrl/webhook/$($tgTrigger.webhookId)/webhook"
# Der Telegram-Trigger validiert den Header X-Telegram-Bot-Api-Secret-Token gegen `{workflowId}_{nodeId}`
# (n8n GenericFunctions.getSecretToken, non-[A-Za-z0-9_-] gestrippt) — den Wert setzt n8n beim Aktivieren
# als setWebhook(secret_token). Ohne Header: 403 "Provided secret is not valid". So bleibt der Pfad echt.
$IngressSecret = ("{0}_{1}" -f $OrchWfId, $tgTrigger.id) -replace '[^a-zA-Z0-9_\-]+', ''
if ($Verbose) { Write-Host "  Ingress: $IngressUrl" -ForegroundColor DarkGray }

# Finance-Sub-Workflow + dessen Trigger-Node-Name (fuer den chat_id-Typ-Check in ri01).
$finWf = $wfList.data | Where-Object { $_.name -eq 'agent.finance' } | Select-Object -First 1
if (-not $finWf) { throw "Workflow 'agent.finance' nicht gefunden." }
$FinWfId = $finWf.id
$finDetail = Invoke-N8nGet "workflows/$FinWfId"
$finTrigger = $finDetail.nodes | Where-Object { $_.type -eq 'n8n-nodes-base.executeWorkflowTrigger' } | Select-Object -First 1
$FinTriggerName = if ($finTrigger) { $finTrigger.name } else { 'Start agent.finance' }

# --- Routing-Fixtures in die Container-DB seeden (idempotent) ---------------------------------------
# Der HITL-Case (ri02) treibt ein finance-Write-Tool, das eine BESTEHENDE Entitaet (DKB Giro) aufloesen
# muss, um ins Gate zu gelangen — ohne Fixtures faellt der Tool-Call mit {ok:false} VOR dem Gate. Dasselbe
# Seed nutzt n8n_test (Tier 2). Haengt Lena an + legt DKB Giro & Co. an; beruehrt die Owner-Person nicht.
$seed = Invoke-TestN8nPsqlFile -Container $Container -HostFile "$RepoRoot\tests\fixtures\util_seed_test_fixtures.sql"
if ($seed.Code -ne 0) { throw "Fixture-Seed (Container-DB) fehlgeschlagen: $($seed.Output -join "`n")" }

# --- Owner + (P2b-2) 2. Person Lena deterministisch pairen: telegram_user_id in die family-Facts ----
# Ohne gepairten Sender laeuft der numerische Pfad in den Knock/Pairing-Zweig (fn_resolve_sender
# liefert found=false). Idempotent; der Validierungs-Trigger akzeptiert numerisch+unique — das Fixture-Seed
# vergibt KEINE telegram_user_id (haengt Lena ohne tg-id an), daher kein Unique-Konflikt.
# P2b-2: Lena (person_id=lena, partner) bekommt eine EIGENE tg-id (880055200) -> der per-Person-Isolations-Case
# (ri16) feuert als Lena; sie ist career-NICHT-onboarded (ihre career.onboarding_state-Zeilen existieren nicht),
# der Owner IST career-onboarded (util_seed_test_fixtures) -> das Gate greift PRO PERSON.
$PairedUid     = $TestOwnerTelegramUid
$PairedUidLena = 880055200
# Textkatalog Phase B: feste Sprachen je Person (Owner = de, Lena = ko) -> die Text-Asserts (expect_texts) pruefen,
# dass jeder Empfaenger seine Sprache bekommt. Bot-Persona: beide starten neutral (Key entfernt; Faelle setzen sie selbst).
$pairSql = @"
UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,persons}',
  (SELECT jsonb_agg(
     CASE WHEN p->>'person_id' = 'owner' THEN (p - 'persona') || jsonb_build_object('telegram_user_id', ${PairedUid}::bigint, 'language', 'de')
          WHEN p->>'person_id' = 'lena'  THEN (p - 'persona') || jsonb_build_object('telegram_user_id', ${PairedUidLena}::bigint, 'language', 'ko')
          ELSE p END)
   FROM jsonb_array_elements(metadata->'facts'->'persons') p))
WHERE name = 'family';
"@
$pair = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $pairSql)
if ($pair.Code -ne 0) { throw "Owner/Lena-Pairing (Container-DB) fehlgeschlagen: $($pair.Output -join "`n")" }
# Route-Agenten aus den Manifesten — die Routing-Pruefungen unten nutzen Get-RoutedAgent (Node-Namensformat an EINER Adresse).
$routeAgents = Get-TestRouteAgent

# --- Cases laden ------------------------------------------------------------------------------------
$tcFile = Join-Path $RepoRoot 'tests\agent\core\real_ingress_cases.json'
# Erst zuweisen, dann ueber die VARIABLE filtern: `ConvertFrom-Json` emittiert das Array in PS 5.1 als EIN
# Pipeline-Objekt -> `| Where-Object` in derselben Pipeline filtert das ganze Array als ein Item; ueber die
# Variable enumeriert PowerShell hingegen elementweise (wie die Geschwister-Skripte). Das fuehrende
# _comment-Objekt (ohne id-Property) faellt ueber den expliziten Property-Check raus.
$rawCases = [System.IO.File]::ReadAllText($tcFile, $Utf8NoBom) | ConvertFrom-Json
$allCases = $rawCases | Where-Object { $_.PSObject.Properties.Name -contains 'id' }
$cases = if ($Id) { $allCases | Where-Object { $_.id -eq $Id } } else { $allCases }
if (-not $cases) { throw "Testfall '$Id' nicht gefunden in real_ingress_cases.json." }

# Telegram-Update-Form bauen + an den echten Webhook POSTen. Liefert die Fire-Zeit (UTC).
function Send-TelegramUpdate([long]$ChatId, [long]$FromUid, [string]$Text, [string]$VoiceFileId = '', [string]$LanguageCode = '') {
    $from = @{ id = $FromUid; is_bot = $false; first_name = 'IngressTest' }
    if ($LanguageCode) { $from['language_code'] = $LanguageCode }   # Telegram-App-Sprache (Pairing-Vorschlag, Phase B)
    $msg = @{
        message_id = [int](Get-Random -Minimum 1000 -Maximum 99999)
        date       = [long][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        from       = $from
        chat       = @{ id = $ChatId; type = 'private' }
    }
    # Sprachnachricht (optional, Case-Feld voice_file_id): Telegram schickt dann message.voice statt message.text.
    if ($VoiceFileId) { $msg['voice'] = @{ file_id = $VoiceFileId; file_unique_id = 'ingress'; duration = 2; mime_type = 'audio/ogg' } }
    else { $msg['text'] = $Text }
    $update = @{
        update_id = New-TestUpdateId
        message   = $msg
    }
    $body = $update | ConvertTo-Json -Depth 6 -Compress
    $fire = (Get-Date).ToUniversalTime()
    try {
        Invoke-RestMethod -Uri $IngressUrl -Method Post -TimeoutSec 8 `
            -Headers @{ 'X-Telegram-Bot-Api-Secret-Token' = $IngressSecret } `
            -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    } catch {
        # Telegram-Trigger antwortet i. d. R. sofort; ein Client-Timeout ist KEIN Fehler (Execution
        # laeuft serverseitig weiter, wie bei den uebrigen Harnesses).
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) {
            throw
        }
    }
    return $fire
}
# callback_query-Update bauen + an den echten Webhook POSTen (WS-5d Block/Unblock-Buttons). Anders als
# Send-TelegramUpdate traegt es KEIN top-level message -> der Orchestrator-Pre-Router 'Update type' routet
# es in den deterministischen Callback-Handler. from.id MUSS der gepairte Owner sein (sonst verwirft der
# 'Callback owner?'-Gate).
function Send-TelegramCallback([long]$FromUid, [long]$OwnerChatId, [string]$Data) {
    $update = @{
        update_id = New-TestUpdateId
        callback_query = @{
            id   = "$([int](Get-Random -Minimum 100000 -Maximum 999999))"
            from = @{ id = $FromUid; is_bot = $false; first_name = 'OwnerTap' }
            message = @{
                message_id = [int](Get-Random -Minimum 1000 -Maximum 99999)
                date = [long][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                chat = @{ id = $OwnerChatId; type = $(if ($OwnerChatId -lt 0) { 'group' } else { 'private' }) }   # Telegram: negative chat_id = Gruppe
                text = 'knock notice'
            }
            data = $Data
        }
    }
    $body = $update | ConvertTo-Json -Depth 8 -Compress
    try {
        Invoke-RestMethod -Uri $IngressUrl -Method Post -TimeoutSec 8 `
            -Headers @{ 'X-Telegram-Bot-Api-Secret-Token' = $IngressSecret } `
            -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
    } catch {
        if (-not ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)) { throw }
    }
}

# --- Burst-Helfer (Eingangs-Buendelung) -----------------------------------------------------------------------
# Updates eines burst-Falls bauen: je Eintrag type text|doc|photo (+ text/caption/file_id, forward=true ->
# forward_origin wie eine weitergeleitete Datei, from_uid = anderer Absender, same_as = Index eines Eintrags,
# dessen Update UNVERAENDERT erneut geschickt wird = Webhook-Retry). message_id/update_id aufsteigend in
# Listenreihenfolge, gleiches date (wie Telegram bei Weiterleiten mit Kommentar).
function Build-BurstUpdates($Tc, [long]$ChatId, [long]$FromUid) {
    $baseMsg = [int](Get-Random -Minimum 100000 -Maximum 900000)
    $baseUpd = New-TestUpdateId
    $date = [long][System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $chatType = if ($ChatId -lt 0) { 'group' } else { 'private' }
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($u in @($Tc.updates)) {
        if ($null -ne $u.same_as) { $out.Add($out[[int]$u.same_as]); $i++; continue }
        $uid = if ($u.from_uid) { [long]$u.from_uid } else { $FromUid }
        $msg = [ordered]@{
            message_id = $baseMsg + $i
            date       = $date
            from       = @{ id = $uid; is_bot = $false; first_name = 'BurstTest' }
            chat       = @{ id = $ChatId; type = $chatType }
        }
        switch ("$($u.type)") {
            'text'  { $msg['text'] = "$($u.text)" }
            'doc'   { $msg['document'] = @{ file_id = "$($u.file_id)"; file_unique_id = "u$($u.file_id)"; file_name = 'beleg.pdf'; mime_type = 'application/pdf' } }
            'photo' { $msg['photo'] = @( @{ file_id = "$($u.file_id)_s"; file_unique_id = 's'; width = 90; height = 90 }, @{ file_id = "$($u.file_id)"; file_unique_id = 'l'; width = 1280; height = 1280 } ) }
            default { throw "burst: unbekannter Update-Typ '$($u.type)'" }
        }
        if ($u.caption) { $msg['caption'] = "$($u.caption)" }
        if ($u.forward) { $msg['forward_origin'] = @{ type = 'hidden_user'; sender_user_name = 'Bank'; date = $date - 3600 } }
        $out.Add((@{ update_id = $baseUpd + $i; message = $msg } | ConvertTo-Json -Depth 8 -Compress))
        $i++
    }
    return ,$out.ToArray()
}
# Alle Updates GLEICHZEITIG an den echten Webhook (HttpClient.SendAsync, dann auf alle warten) — sequentielle
# Invoke-RestMethod-Aufrufe laegen > 0,4 s auseinander und testeten das Rennen nicht.
function Send-TelegramBurst([string[]]$Bodies) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    try {
        $tasks = foreach ($b in $Bodies) {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $IngressUrl)
            $req.Headers.Add('X-Telegram-Bot-Api-Secret-Token', $IngressSecret)
            $req.Content = New-Object System.Net.Http.StringContent($b, [System.Text.Encoding]::UTF8, 'application/json')
            $client.SendAsync($req)
        }
        [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks))
        foreach ($t in $tasks) { if (-not $t.Result.IsSuccessStatusCode) { throw "burst: Webhook antwortete $([int]$t.Result.StatusCode)" } }
    } finally { $client.Dispose() }
}
# Auf $Count neue Executions (id > $AfterId) warten, bis keine mehr laeuft; liefert die Details.
function Wait-NewExecsTerminal([string]$WfId, [int]$AfterId, [int]$Count, [int]$TimeoutSec) {
    $start = Get-Date
    while ($true) {
        $list = @()
        try { $list = @((Invoke-N8nGet "executions?workflowId=$WfId&limit=50").data | Where-Object { [int]$_.id -gt $AfterId }) } catch { }
        $busy = @($list | Where-Object { $_.status -in @('running', 'new', 'waiting') })
        if (($list.Count -ge $Count -and $busy.Count -eq 0) -or ((Get-Date) - $start).TotalSeconds -ge $TimeoutSec) {
            return @($list | Sort-Object { [int]$_.id } | ForEach-Object { Get-ExecDetail $_.id })
        }
        Start-Sleep -Milliseconds 1200
    }
}
# fail-open-Probe: die DIREKTEN EXECUTE-Grants der claim-fn (ACL, nicht has_function_privilege: geerbte Rechte liessen
# sich so nicht entziehen) den Nicht-Superusern entziehen (der Claim-Knoten scheitert dann wie bei einem echten
# DB-Fehler) und danach exakt diesen Rollen zurueckgeben.
function Revoke-IngressClaim([string]$Container) {
    $q = "SELECT string_agg(r.rolname, ',') FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a JOIN pg_roles r ON r.oid = a.grantee WHERE p.oid = 'agent.fn_claim_ingress_burst(jsonb)'::regprocedure AND a.privilege_type = 'EXECUTE' AND NOT r.rolsuper;"
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', $q)
    $roles = @("$($r.Output -join '')".Trim() -split ',' | Where-Object { $_ })
    if (-not $roles) { throw 'burst: keine Rolle mit EXECUTE auf fn_claim_ingress_burst gefunden.' }
    foreach ($role in $roles) {
        $rv = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "REVOKE EXECUTE ON FUNCTION agent.fn_claim_ingress_burst(jsonb) FROM `"$role`";")
        if ($rv.Code -ne 0) { throw "burst: REVOKE fehlgeschlagen: $($rv.Output -join ' ')" }
    }
    return $roles
}
function Grant-IngressClaim([string]$Container, [string[]]$Roles) {
    foreach ($role in @($Roles)) {
        Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "GRANT EXECUTE ON FUNCTION agent.fn_claim_ingress_burst(jsonb) TO `"$role`";") | Out-Null
    }
}

# Chat-Memory der numerischen Session leeren -> geteilter Helfer Clear-ChatSessionMemory
# (test_n8n_state.ps1; findet die lazy entstehenden <agent>_chat_memory-Tabellen per pg_tables).

# --- Text-Asserts (Textkatalog Phase B): was hat die Telegram-Attrappe in DIESEM Fall gesendet? ----------------
# Case-Felder (alle optional): expect_texts = Teilstrings, die in einem gesendeten Text/Knopf/Toast vorkommen MUESSEN;
# forbid_texts = duerfen in KEINEM vorkommen; text_chat = nur Sends an diese chat_id betrachten (Empfaenger-Sprache).
# Die Attrappe wird zu Beginn jedes Falls geleert; Texte = alle String-Blaetter der Request-Bodies (inkl. reply_markup,
# auch wenn n8n es als JSON-String schickt).
function Get-StringLeaves($Obj) {
    if ($null -eq $Obj) { return }
    if ($Obj -is [string]) {
        $Obj
        if ($Obj.TrimStart().StartsWith('{') -or $Obj.TrimStart().StartsWith('[')) { try { Get-StringLeaves ($Obj | ConvertFrom-Json) } catch { } }
        return
    }
    if ($Obj -is [System.Collections.IEnumerable]) { foreach ($x in $Obj) { Get-StringLeaves $x }; return }
    if ($Obj -is [psobject]) { foreach ($p in $Obj.PSObject.Properties) { Get-StringLeaves $p.Value } }
}
function Test-CaseTexts($Tc) {
    if (-not $Tc.expect_texts -and -not $Tc.forbid_texts) { return $true }
    $reqs = @(Get-MockTelegramRequests -Container $Container)
    if ($Tc.text_chat) { $reqs = @($reqs | Where-Object { "$($_.body.chat_id)" -eq "$($Tc.text_chat)" }) }
    $hay = (@(foreach ($r in $reqs) { Get-StringLeaves $r.body }) -join "`n")
    $ok = $true
    foreach ($t in @($Tc.expect_texts)) { if ($t -and -not $hay.Contains("$t")) { $ok = $false; Write-Host "    Text fehlt: '$t'" -ForegroundColor Red } }
    foreach ($t in @($Tc.forbid_texts)) { if ($t -and $hay.Contains("$t")) { $ok = $false; Write-Host "    Text darf nicht vorkommen: '$t'" -ForegroundColor Red } }
    if (-not $ok -and $Verbose) { Write-Host "    gesendet: $($hay.Substring(0, [Math]::Min(600, $hay.Length)))" -ForegroundColor DarkGray }
    return $ok
}

Write-Host ""
Write-Host "Real-Ingress-Test (echter Telegram-Webhook des Orchestrators) -- $($cases.Count) Fall/Faelle"
Write-Host ("-" * 64)
$passed = 0; $failed = 0

$personaDirty = $null   # Person, deren Persona der vorige Fall gesetzt hat (ein fruehes continue ueberspringt den Reset)
foreach ($tc in $cases) {
    if ($personaDirty) { [void](Set-TestPersonaFact -Container $Container -PersonId $personaDirty -Code ''); $personaDirty = $null }
    if ($tc.persona_person) { $personaDirty = "$($tc.persona_person)" }
    Write-Host ""
    Write-Host "  [$($tc.id)] $($tc.name)"
    [long]$chatId = [long]$tc.chat_id
    [long]$fromUid = [long]$tc.from_uid
    Clear-ChatSessionMemory -Container $Container -SessionId "$chatId"
    Clear-MockTelegramRequests -Container $Container   # Text-Asserts sehen nur die Sends DIESES Falls

    # ================= ROUTE: chat_id number->string + Routing-Entscheidung =================
    if ($tc.kind -eq 'route') {
        $orchBase = Get-MaxExecId $OrchWfId
        $finBase  = Get-MaxExecId $FinWfId
        Send-TelegramUpdate $chatId $fromUid $tc.text | Out-Null
        $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
        if (-not $orch) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }
        $nodes = Get-RunNodes $orch
        $routed = @(Get-RoutedAgent -Tools $nodes -RouteAgents $routeAgents) -contains [string]$tc.expected_route

        # Sub-Execution (agent.finance) finden + chat_id-INPUT-Typ pruefen (das ist der number->string-Beweis).
        $fin = Wait-NewExecTerminal $FinWfId $finBase $Timeout
        $chatIdVal = $null
        if ($fin) { try { $chatIdVal = $fin.data.resultData.runData.$FinTriggerName[0].data.main[0][0].json.chat_id } catch { } }
        $isString = ($null -ne $chatIdVal) -and ($chatIdVal -is [string])
        $valOk = $isString -and ([string]$chatIdVal -eq [string]$chatId)
        $typeName = if ($null -ne $chatIdVal) { $chatIdVal.GetType().Name } else { '<null>' }

        Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) routed=$routed"
        Write-Host "    Sub-Agent chat_id: '$chatIdVal' (Typ $typeName)  erwartet String == '$chatId'"
        if ($orch.status -eq 'success' -and $routed -and $valOk) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
        } else {
            $failed++; Write-Host "    [FAIL] status/routing/chat_id-Typ stimmt nicht (status=$($orch.status), routed=$routed, isString=$isString, valOk=$valOk)" -ForegroundColor Red
        }
        continue
    }

    # ================= HITL: echtes Gate ueber abgefangene, signierte Resume-URL =================
    if ($tc.kind -eq 'hitl') {
        $orchBase = Get-MaxExecId $OrchWfId
        $dispBase = if ($dispatchWfId) { Get-MaxExecId $dispatchWfId } else { 0 }   # Fix C: Vermittler-Lauf DIESES Falls (ids sind global)
        Clear-MockTelegramRequests -Container $Container
        Send-TelegramUpdate $chatId $fromUid $tc.text | Out-Null

        # Auf die abgefangene Gate-Nachricht (sendMessage mit inline_keyboard) warten.
        $msg = $null; $start = Get-Date
        while ($true) {
            $msg = Get-MockTelegramRequests -Container $Container |
                   Where-Object { $_.method -eq 'sendMessage' -and $_.body.reply_markup } | Select-Object -Last 1
            if ($msg) { break }
            if (((Get-Date) - $start).TotalSeconds -ge $Timeout) { break }
            Start-Sleep -Milliseconds 800
        }
        if (-not $msg) {
            Write-Host "    [FAIL] Keine abgefangene Gate-Nachricht mit Buttons (Routing bis ins Gate? Mocks aktiv?)." -ForegroundColor Red
            $failed++; continue
        }

        # Signierte Resume-URL (decline) ziehen, Host->Bruecke, als GET feuern. Get-HitlResumeUrl wirft,
        # wenn das reply_markup-/approved-Format nicht stimmt -> IST der HITL-Format-/Signatur-Check.
        $approved = ($tc.gate_decision -eq 'approve')
        try {
            $resumeUrl = Get-HitlResumeUrl -Request $msg -Approved $approved -BridgeUrl $N8nUrl
            if ($Verbose) { Write-Host "    Resume: $resumeUrl" -ForegroundColor DarkGray }
        } catch {
            Write-Host "    [FAIL] HITL-Resume-URL nicht ziehbar (Format/Signatur?): $_" -ForegroundColor Red
            $failed++; continue
        }
        # Korrelation: die Gate-Execution-id steckt im Resume-Pfad (/webhook-waiting/{execId}/{nodeId}). Sie
        # MUSS > orchBase sein -> beweist, dass die abgefangene Nachricht zu einer in DIESEM Fall erzeugten
        # (Gate-)Execution gehoert, nicht zu einem alten reply_markup-Send (Schutz gegen False-PASS).
        $gateExecId = Get-HitlExecId -Url $resumeUrl
        if ($gateExecId -le $orchBase) {
            Write-Host "    [FAIL] Gate-Execution-id ($gateExecId) nicht > orchBase ($orchBase) -> abgefangene Nachricht nicht diesem Fall zuordenbar." -ForegroundColor Red
            $failed++; continue
        }

        # Fix C (Karte-offen-Sperre): solange die Karte offen ist, traegt agent.hitl_pending eine Zeile fuer den
        # Ursprungs-Chat; probe_card_open schickt dann eine ZWEITE Nachricht in denselben Chat -> fester Hinweis
        # ('Reply card open'), KEIN Agent-Lauf (der echte Vorfall vom 2026-10-22, End-to-End ueber den Webhook).
        $extraOk = $true; $extraInfo = @()
        $pr = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "SELECT chat_id FROM agent.hitl_pending WHERE execution_id = '$gateExecId' AND expires_at > now();")
        $pendChat = ($pr.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 1)
        if ("$pendChat" -ne "$chatId") { $extraOk = $false; $extraInfo += "Sperr-Zeile chat_id='$pendChat' statt $chatId" }
        if ($tc.probe_card_open) {
            $probeBase = Get-MaxExecId $OrchWfId
            Send-TelegramUpdate $chatId $fromUid "$($tc.probe_card_open)" | Out-Null
            $probe = Wait-NewExecTerminal $OrchWfId $probeBase $Timeout
            $pNodes = if ($probe) { Get-RunNodes $probe } else { @() }
            if (-not ($pNodes -contains 'Reply card open') -or ($pNodes -contains 'Orchestrator agent')) {
                $extraOk = $false; $extraInfo += "Probe bei offener Karte: Reply card open=$($pNodes -contains 'Reply card open'), Orchestrator agent=$($pNodes -contains 'Orchestrator agent')"
            }
        }

        try { Invoke-HitlResume -Url $resumeUrl | Out-Null }
        catch { Write-Host "    [FAIL] HITL-Resume-GET fehlgeschlagen: $_" -ForegroundColor Red; $failed++; continue }

        # Nach dem Resume muss die Orchestrator-Execution sauber durchlaufen (success).
        $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout

        # Fix C (woertlicher task): der Vermittler agent.sub_dispatch_agent muss die Nutzernachricht UNVERAENDERT
        # bekommen (kein LLM-formulierter task mehr); danach keine Sperr-Zeile mehr fuer die Gate-Execution.
        if ($tc.expect_task_verbatim -and $dispatchWfId) {
            $dx = (Invoke-N8nGet "executions?workflowId=$dispatchWfId&limit=5").data | Where-Object { [int]$_.id -gt $dispBase } | Sort-Object { [int]$_.id } | Select-Object -First 1
            $task = $null; if ($dx) { try { $task = [string](Get-ExecDetail $dx.id).data.resultData.runData.'Start'[0].data.main[0][0].json.task } catch { } }
            if ($task -ne "$($tc.text)") { $extraOk = $false; $extraInfo += "task an den Vermittler='$task' statt woertlich '$($tc.text)'" }
        }
        $pr = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "SELECT count(*) FROM agent.hitl_pending WHERE execution_id = '$gateExecId';")
        if ((($pr.Output -join '').Trim()) -ne '0') { $extraOk = $false; $extraInfo += 'Sperr-Zeile nach dem Tipp nicht geloescht' }

        Write-Host "    Gate abgefangen + aufgeloest (decision=$($tc.gate_decision)); Orchestrator status=$($orch.status)"
        if ($orch -and $orch.status -eq 'success' -and $extraOk) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
        } else {
            $failed++; Write-Host "    [FAIL] Orchestrator-Execution nach Resume nicht success / Karte-offen-Sperre (status=$($orch.status); $($extraInfo -join '; '))" -ForegroundColor Red
        }
        continue
    }

    # ================= KNOCK: ungepairter Sender -> kein Agent-Routing =================
    if ($tc.kind -eq 'knock') {
        $orchBase = Get-MaxExecId $OrchWfId
        Send-TelegramUpdate $chatId $fromUid $tc.text | Out-Null
        $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
        if (-not $orch) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }
        $nodes = Get-RunNodes $orch
        # WS-5a: der fruehere 'Ack unknown sender'-Send ist entfernt (Fremder = STUMM); der Knock-Pfad
        # laeuft jetzt direkt Pairing router[1] -> Knock throttle (Anti-Spam) -> Owner-Notiz.
        $knockRan = $nodes -contains 'Knock throttle'
        $routedAny = @(Get-RoutedAgent -Tools $nodes -RouteAgents $routeAgents).Count -gt 0
        Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) knock=$knockRan routedAny=$routedAny"
        if ($orch.status -eq 'success' -and $knockRan -and -not $routedAny) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
        } else {
            $failed++; Write-Host "    [FAIL] erwartet Knock-Throttle ohne Agent-Routing (status=$($orch.status), knock=$knockRan, routedAny=$routedAny)" -ForegroundColor Red
        }
        continue
    }

    # ================= CALLBACK: Owner-Tap -> deterministischer Callback-Handler =================
    #   block/unblock:<uid> -> agent.access_blocks (WS-5d); cron_on/cron_off:<key> -> core.config cron_enable (WS-3).
    if ($tc.kind -eq 'callback') {
        $action = "$($tc.action)"

        # WS-3 Phase A: Waechter-Cron an/aus per Button. target = der Cron-Key (drift_check|plan_review).
        if ($action -like 'cron_*') {
            $key        = "$($tc.cron_key)"
            $expectNode = if ($action -eq 'cron_on') { 'Run cron on' } else { 'Run cron off' }
            # Self-contained: cron_on -> Key vorher AUS; cron_off -> vorher AN (damit der Toggle wirklich kippt).
            $preVal = if ($action -eq 'cron_on') { 'false' } else { 'true' }
            $prep = "INSERT INTO core.config (package, category, key, value) VALUES ('core','cron_enable','$key','$preVal') ON CONFLICT (category, key) DO UPDATE SET value = '$preVal';"
            $p = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $prep)
            if ($p.Code -ne 0) { Write-Host "    [FAIL] DB-Vorbereitung fehlgeschlagen: $($p.Output -join "`n")" -ForegroundColor Red; $failed++; continue }

            $orchBase = Get-MaxExecId $OrchWfId
            Send-TelegramCallback $PairedUid $PairedUid ('{0}:{1}' -f $action, $key)
            $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
            if (-not $orch) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }
            $ranNode = (Get-RunNodes $orch) -contains $expectNode

            $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT value FROM core.config WHERE category='cron_enable' AND key='$key';")
            $val = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -in @('true', 'false') } | Select-Object -First 1)
            $expectVal = if ($action -eq 'cron_on') { 'true' } else { 'false' }
            $dbOk = ($val -eq $expectVal)

            $txtOk = Test-CaseTexts $tc
            Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) ranNode($expectNode)=$ranNode cron_enable.$key=$val texts=$txtOk"
            if ($orch.status -eq 'success' -and $ranNode -and $dbOk -and $txtOk) {
                $passed++; Write-Host "    [PASS]" -ForegroundColor Green
            } else {
                $failed++; Write-Host "    [FAIL] cron-callback-Wiring/DB stimmt nicht (status=$($orch.status), ranNode=$ranNode, val=$val, erwartet=$expectVal)" -ForegroundColor Red
            }
            continue
        }

        # WS-2: job:<up|down>:<id> -> generischer extra-Dispatch (core.fn_dispatch_callback -> career.fn_handle_job_feedback).
        # ERSTER echter Konsument der Phase-0-Callback-Registry -> beweist die extra-Dispatch-Naht end-to-end.
        if ($action -eq 'job_feedback') {
            # Self-contained: einen job_match (sentinel external_id) seeden, id holen, status auf 'new' zuruecksetzen.
            # P2a/career:V005: job_matches.person_id ist NOT NULL + der UPSERT-Key ist (source, external_id, person_id)
            # (Multi-Source-Umbenennung refnr -> external_id). Owner-Zeile seeden (agent.fn_owner_person_id = der Sender
            # des job:up-Callbacks -> fn_handle_job_feedback matcht den Eigentuemer-Check person_id=sender).
            $seed = "INSERT INTO career.job_matches (source, external_id, person_id, title, score) VALUES ('bundesagentur','RI_JOB_FEEDBACK', agent.fn_owner_person_id(), 'RI Scrum Master',3) ON CONFLICT (source, external_id, person_id) WHERE external_id IS NOT NULL DO UPDATE SET status='new', feedback_at=NULL RETURNING id;"
            $s = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', $seed)
            $jid = ($s.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
            if ($s.Code -ne 0 -or -not $jid) { Write-Host "    [FAIL] DB-Vorbereitung (job_match) fehlgeschlagen: $($s.Output -join "`n")" -ForegroundColor Red; $failed++; continue }

            $orchBase = Get-MaxExecId $OrchWfId
            Send-TelegramCallback $PairedUid $PairedUid ('job:up:{0}' -f $jid)
            $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
            if (-not $orch) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }
            $ranNode = (Get-RunNodes $orch) -contains 'Dispatch callback'

            $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT status FROM career.job_matches WHERE id=$jid;")
            $st = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -in @('new', 'interested', 'dismissed') } | Select-Object -First 1)
            $dbOk = ($st -eq 'interested')

            Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) ranNode(Dispatch callback)=$ranNode job_match.status=$st"
            if ($orch.status -eq 'success' -and $ranNode -and $dbOk) {
                $passed++; Write-Host "    [PASS]" -ForegroundColor Green
            } else {
                $failed++; Write-Host "    [FAIL] job-Callback-Dispatch/DB stimmt nicht (status=$($orch.status), ranNode=$ranNode, job_status=$st, erwartet=interested)" -ForegroundColor Red
            }
            continue
        }

        # Member-Callback-Permeabilitaet + Owner-Admin-Lock + Fremd-Discard: ein NICHT-Owner tappt. sender_uid =
        # die Tapper-uid (gepairte Partnerin 880055200 ODER ungepairter Fremder). expect_node = die Node, die laufen
        # MUSS ('Dispatch callback' fuer ein aufgeloestes Mitglied | 'Discard non-owner callback' fuer unbekannt).
        # forbid_node (optional) = ein Owner-Admin-Node, der NICHT laufen darf (Lock). cron_key (optional) =
        # cron_enable.<key> wird auf 'true' vorgesetzt + MUSS unveraendert bleiben (Member kann nicht togglen).
        if ($action -eq 'member_route') {
            [long]$sender = [long]$tc.sender_uid
            $expectNode = "$($tc.expect_node)"
            if ($tc.cron_key) {
                $prep = "INSERT INTO core.config (package, category, key, value) VALUES ('core','cron_enable','$($tc.cron_key)','true') ON CONFLICT (category, key) DO UPDATE SET value = 'true';"
                $p = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $prep)
                if ($p.Code -ne 0) { Write-Host "    [FAIL] DB-Vorbereitung (cron_enable) fehlgeschlagen: $($p.Output -join "`n")" -ForegroundColor Red; $failed++; continue }
            }
            # Textkatalog (lang:-Picker): lang_person (optional) = deren family-Sprache vorab auf lang_before setzen, danach
            # MUSS sie expect_lang sein (eigene Sprache gesetzt bzw. fremde Person unveraendert).
            if ($tc.lang_person) {
                $prep = "UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', (SELECT jsonb_agg(CASE WHEN p->>'person_id' = '$($tc.lang_person)' THEN p || jsonb_build_object('language', '$($tc.lang_before)') ELSE p END) FROM jsonb_array_elements(metadata->'facts'->'persons') p)) WHERE name = 'family';"
                $p = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $prep)
                if ($p.Code -ne 0) { Write-Host "    [FAIL] DB-Vorbereitung (language) fehlgeschlagen: $($p.Output -join "`n")" -ForegroundColor Red; $failed++; continue }
            }
            # Bot-Persona (persona:-Picker): persona_person vorab auf persona_before, danach MUSS sie expect_persona sein.
            if ($tc.persona_person -and -not (Set-TestPersonaFact -Container $Container -PersonId "$($tc.persona_person)" -Code "$($tc.persona_before)")) {
                Write-Host "    [FAIL] DB-Vorbereitung (persona) fehlgeschlagen" -ForegroundColor Red; $failed++; continue
            }
            $orchBase = Get-MaxExecId $OrchWfId
            Send-TelegramCallback $sender $sender "$($tc.callback_data)"
            $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
            if (-not $orch) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }
            $nodes    = Get-RunNodes $orch
            $ranExpect = $nodes -contains $expectNode
            $forbidAbsent = (-not $tc.forbid_node) -or (-not ($nodes -contains "$($tc.forbid_node)"))
            if ($tc.lang_person) {
                $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT p->>'language' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') p WHERE c.name = 'family' AND p->>'person_id' = '$($tc.lang_person)';")
                $langVal = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 1)
                if ($langVal -ne "$($tc.expect_lang)") { $forbidAbsent = $false; Write-Host "    Sprache von $($tc.lang_person) = '$langVal' (erwartet $($tc.expect_lang))" -ForegroundColor Red }
            }
            if ($tc.persona_person) {
                $perVal = Get-TestPersonaFact -Container $Container -PersonId "$($tc.persona_person)"
                if ("$perVal" -ne "$($tc.expect_persona)") { $forbidAbsent = $false; Write-Host "    Persona von $($tc.persona_person) = '$perVal' (erwartet '$($tc.expect_persona)')" -ForegroundColor Red }
                [void](Set-TestPersonaFact -Container $Container -PersonId "$($tc.persona_person)" -Code '')   # self-contained: neutral hinterlassen
            }
            $cronOk = $true; $cronVal = 'n/a'
            if ($tc.cron_key) {
                $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT value FROM core.config WHERE category='cron_enable' AND key='$($tc.cron_key)';")
                $cronVal = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -in @('true', 'false') } | Select-Object -First 1)
                $cronOk = ($cronVal -eq 'true')   # unveraendert -> das Mitglied konnte den Owner-Cron NICHT umschalten
            }
            $txtOk = Test-CaseTexts $tc
            Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) ranNode($expectNode)=$ranExpect forbid($($tc.forbid_node))_absent=$forbidAbsent cron_unchanged=$cronOk($cronVal) texts=$txtOk"
            if ($orch.status -eq 'success' -and $ranExpect -and $forbidAbsent -and $cronOk -and $txtOk) {
                $passed++; Write-Host "    [PASS]" -ForegroundColor Green
            } else {
                $failed++; Write-Host "    [FAIL] member-route/lock stimmt nicht (status=$($orch.status), ran($expectNode)=$ranExpect, forbid_absent=$forbidAbsent, cron_unchanged=$cronOk)" -ForegroundColor Red
            }
            continue
        }

        [long]$target = [long]$tc.target_uid
        # 'block' | 'unblock'
        $expectNode = if ($action -eq 'block') { 'Run block knocker' } else { 'Run unblock knocker' }
        # Self-contained: block-Fall -> Ziel vorher ENT-sperren; unblock-Fall -> vorher sperren.
        $prep = if ($action -eq 'block') {
            "DELETE FROM agent.access_blocks WHERE telegram_user_id = $target;"
        } else {
            "INSERT INTO agent.access_blocks (telegram_user_id) VALUES ($target) ON CONFLICT DO NOTHING;"
        }
        $p = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-c', $prep)
        if ($p.Code -ne 0) { Write-Host "    [FAIL] DB-Vorbereitung fehlgeschlagen: $($p.Output -join "`n")" -ForegroundColor Red; $failed++; continue }

        $orchBase = Get-MaxExecId $OrchWfId
        Send-TelegramCallback $PairedUid $PairedUid ('{0}:{1}' -f $action, $target)
        $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
        if (-not $orch) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }
        $nodes   = Get-RunNodes $orch
        $ranNode = $nodes -contains $expectNode

        $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT count(*) FROM agent.access_blocks WHERE telegram_user_id = $target;")
        $cntLine = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
        $cnt = if ($q.Code -eq 0 -and $cntLine) { [int]$cntLine } else { -1 }
        $dbOk = if ($action -eq 'block') { $cnt -eq 1 } else { $cnt -eq 0 }

        Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) ranNode($expectNode)=$ranNode access_blocks_count=$cnt"
        if ($orch.status -eq 'success' -and $ranNode -and $dbOk) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
        } else {
            $failed++; Write-Host "    [FAIL] callback-Wiring/DB stimmt nicht (status=$($orch.status), ranNode=$ranNode, dbOk=$dbOk, cnt=$cnt)" -ForegroundColor Red
        }
        continue
    }

    # ================= NODE_RAN: feuert message ODER callback -> asserted welcher Top-Level-Knoten lief ====
    # Generischer Zweig fuer deterministische Orchestrator-Knoten OHNE eigene route/hitl/knock/callback-
    # Semantik (WS-1 Welcome/Help-Callback-Zweige): optional einen Onboarding-Vorzustand seeden -> Update
    # feuern (message ODER callback je `update`) -> pruefen, dass `expected_node` im runData steht UND die
    # Execution success ist. Damit fallen die deterministischen WS-1-Zweige, die kein Routing/keinen Write
    # haben (Send welcome back/new, Send help cb), ueber den ECHTEN Eingang.
    if ($tc.kind -eq 'node_ran') {
        # Optional: Onboarding-Vorzustand setzen (Welcome zurueck = completed; Welcome neu = unknown).
        # Self-contained je Case (wie die callback-Faelle ihre Sperre/Config vorbereiten).
        if ($tc.onboarding) {
            try { Set-TestHouseholdOnboarding -Container $Container -Status "$($tc.onboarding)" }
            catch { Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red; $failed++; continue }
        }
        # Fix C: optionale Karte-offen-Sperr-Zeile seeden (hitl_pending.chat = Chat der Zeile, Default der Fall-Chat;
        # expired=true -> bereits abgelaufen). Self-contained: die Zeile wird nach dem Fall wieder entfernt.
        if ($tc.hitl_pending) {
            $hpChat = if ($tc.hitl_pending.chat) { "$($tc.hitl_pending.chat)" } else { "$chatId" }
            $hpTimes = if ($tc.hitl_pending.expired) { "now() - interval '30 minutes', now() - interval '1 minute'" } else { "now(), now() + interval '15 minutes'" }
            $hpOwn = if ($tc.hitl_pending.own_card -eq $false) { 'false' } else { 'true' }
            $hp = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tAc', "INSERT INTO agent.hitl_pending (chat_id, execution_id, own_card, opened_at, expires_at) VALUES ($hpChat, 'ingress-$($tc.id)', $hpOwn, $hpTimes);")
            if ($hp.Code -ne 0) { Write-Host "    [FAIL] hitl_pending-Seed fehlgeschlagen: $($hp.Output -join "`n")" -ForegroundColor Red; $failed++; continue }
        }

        # WS-3: optionale SUB-Execution-Assertion. Der Core-first-Gate-Redirect ('Core onboarding required')
        # bzw. der durchgelassene 'Finance Agent' laufen in der finance/advisor-SUB, NICHT im Orchestrator-
        # runData (Get-RunNodes prueft Top-Level-Orchestrator-Knoten). expected_sub = Sub-Workflow-Name ->
        # dort wird expected_node geprueft (der route-Kind erreicht die Sub-Execution analog).
        $subWfId = $null; $subBase = 0
        if ($tc.expected_sub) {
            $subWf = $wfList.data | Where-Object { $_.name -eq "$($tc.expected_sub)" } | Select-Object -First 1
            if (-not $subWf) { Write-Host "    [FAIL] Sub-Workflow '$($tc.expected_sub)' nicht gefunden." -ForegroundColor Red; $failed++; continue }
            $subWfId = $subWf.id; $subBase = Get-MaxExecId $subWfId
        }

        # Bot-Persona: persona_person vorab auf persona_before setzen; expect_system_tail = Teilstring, der im Ende des
        # System-Prompts eines Mock-LLM-Aufrufs stehen MUSS (Runtime-Flag erreicht das Modell; Mock loggt system_tail).
        if ($tc.persona_person -and -not (Set-TestPersonaFact -Container $Container -PersonId "$($tc.persona_person)" -Code "$($tc.persona_before)")) {
            Write-Host "    [FAIL] DB-Vorbereitung (persona) fehlgeschlagen" -ForegroundColor Red; $failed++; continue
        }
        if ($tc.expect_system_tail) { Clear-MockLlmRequests -Container $Container }

        $orchBase = Get-MaxExecId $OrchWfId
        if ("$($tc.update)" -eq 'callback') {
            # callback_query.from.id MUSS der gepairte Owner sein (sonst verwirft 'Callback owner?'); chat_id
            # = callback_query.message.chat.id (die Welcome-Buttons sitzen in der Owner-Nachricht).
            Send-TelegramCallback $fromUid $chatId "$($tc.callback_data)"
        } else {
            Send-TelegramUpdate $chatId $fromUid $tc.text "$($tc.voice_file_id)" | Out-Null
        }
        $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
        if ($tc.hitl_pending) { Clear-HitlPending -Container $Container }
        if (-not $orch) { Write-Host "    [FAIL] Keine Orchestrator-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }

        if ($subWfId) {
            $sub = Wait-NewExecTerminal $subWfId $subBase $Timeout
            if (-not $sub) { Write-Host "    [FAIL] Keine $($tc.expected_sub)-Sub-Execution gefunden (Timeout)." -ForegroundColor Red; $failed++; continue }
            $ranNode = (Get-RunNodes $sub) -contains "$($tc.expected_node)"
            # Optional: die Knoten-Ausgabe muss einen Text enthalten bzw. darf ihn NICHT enthalten (z. B. einen
            # deterministisch angehaengten Prompt-Abschnitt; das Gegenstueck belegt, dass er nicht immer erscheint).
            $outOk = $true
            if ($tc.expected_output_contains -or $tc.expected_output_not_contains) {
                $outText = Get-NodeOutputText $sub "$($tc.expected_node)"
                if ($tc.expected_output_contains)     { $outOk = $outOk -and $outText.Contains("$($tc.expected_output_contains)") }
                if ($tc.expected_output_not_contains) { $outOk = $outOk -and $outText -ne '' -and -not $outText.Contains("$($tc.expected_output_not_contains)") }
            }
            $txtOk = Test-CaseTexts $tc
            Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status); Sub ($($tc.expected_sub)): id=$($sub.id) status=$($sub.status) ranNode($($tc.expected_node))=$ranNode outputOk=$outOk texts=$txtOk"
            if ($orch.status -eq 'success' -and $sub.status -eq 'success' -and $ranNode -and $outOk -and $txtOk) {
                $passed++; Write-Host "    [PASS]" -ForegroundColor Green
            } else {
                $failed++; Write-Host "    [FAIL] erwarteter Sub-Knoten lief nicht / Ausgabe falsch / Execution nicht success (orch=$($orch.status), sub=$($sub.status), ranNode=$ranNode, outputOk=$outOk)" -ForegroundColor Red
            }
            continue
        }

        $runNodes = Get-RunNodes $orch
        $ranNode = $runNodes -contains "$($tc.expected_node)"
        # Optional wie im Sub-Zweig: Ausgabe-Text des Knotens; dazu expected_not_node = ein Knoten, der NICHT laufen darf.
        $outOk = $true
        if ($tc.expected_output_contains -or $tc.expected_output_not_contains) {
            $outText = Get-NodeOutputText $orch "$($tc.expected_node)"
            if ($tc.expected_output_contains)     { $outOk = $outOk -and $outText.Contains("$($tc.expected_output_contains)") }
            if ($tc.expected_output_not_contains) { $outOk = $outOk -and $outText -ne '' -and -not $outText.Contains("$($tc.expected_output_not_contains)") }
        }
        $notRanOk = -not ($tc.expected_not_node -and ($runNodes -contains "$($tc.expected_not_node)"))
        $txtOk = Test-CaseTexts $tc
        if ($tc.expect_system_tail) {
            $tails = @(Get-MockLlmRequests -Container $Container | ForEach-Object { [string]$_.system_tail })
            if (-not ($tails | Where-Object { $_.Contains("$($tc.expect_system_tail)") })) {
                $outOk = $false; Write-Host "    System-Prompt-Ende ohne '$($tc.expect_system_tail)' ($($tails.Count) LLM-Aufruf(e))" -ForegroundColor Red
            }
        }
        if ($tc.persona_person) { [void](Set-TestPersonaFact -Container $Container -PersonId "$($tc.persona_person)" -Code '') }   # self-contained: neutral hinterlassen
        Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) ranNode($($tc.expected_node))=$ranNode outputOk=$outOk notRanOk=$notRanOk texts=$txtOk"
        if ($orch.status -eq 'success' -and $ranNode -and $outOk -and $notRanOk -and $txtOk) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
        } else {
            $failed++; Write-Host "    [FAIL] erwarteter Knoten lief nicht / Ausgabe falsch / verbotener Knoten lief / Execution nicht success (status=$($orch.status), ranNode=$ranNode, outputOk=$outOk, notRanOk=$notRanOk)" -ForegroundColor Red
        }
        continue
    }

    # ================= PAIRING_LANG (Textkatalog Phase B): Einladung -> Einloesen mit Telegram-language_code ->
    # Owner bestaetigt -> das neue Mitglied (noch ohne eigene Sprache) bekommt den Sprach-Picker, die App-Sprache als
    # 👉-Vorschlag markiert; family bleibt OHNE language (nie still gesetzt). Self-contained: eigene Person
    # (person_id/first_name aus dem Case), ihre telegram_user_id/language werden vorab entfernt, frischer Code je Lauf.
    if ($tc.kind -eq 'pairing_lang') {
        $pairPerson = "$($tc.person_id)"
        $code = 'RIP' + (Get-Random -Minimum 10000000 -Maximum 99999999)
        $prep = @"
DELETE FROM agent.pairing_state WHERE person_id = '$pairPerson';
SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id','$pairPerson','first_name','$($tc.first_name)','last_name','Ingress','role','partner','birth_date','1990-01-01')))));
UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', (SELECT jsonb_agg(CASE WHEN p->>'person_id' = '$pairPerson' THEN (p - 'telegram_user_id') - 'language' ELSE p END) FROM jsonb_array_elements(metadata->'facts'->'persons') p)) WHERE name = 'family';
SELECT agent.fn_arm_pairing_challenge(jsonb_build_object('role','partner','challenge','$code','person_id','$pairPerson'));
"@
        $p = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-q', '-v', 'ON_ERROR_STOP=1', '-c', $prep)
        if ($p.Code -ne 0) { Write-Host "    [FAIL] DB-Vorbereitung (Einladung) fehlgeschlagen: $($p.Output -join "`n")" -ForegroundColor Red; $failed++; continue }

        # (1) Mitglied loest den Code ein (mit Telegram-App-Sprache) -> Claim staged.
        $orchBase = Get-MaxExecId $OrchWfId
        Send-TelegramUpdate $fromUid $fromUid "/start $code" '' "$($tc.language_code)" | Out-Null
        $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
        if (-not $orch) { Write-Host "    [FAIL] Claim: keine Orchestrator-Execution (Timeout)." -ForegroundColor Red; $failed++; continue }
        $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT id || '|' || COALESCE(language_hint, '') FROM agent.pairing_state WHERE challenge = '$code';")
        $row = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+\|' } | Select-Object -First 1)
        if (-not $row) { Write-Host "    [FAIL] Claim: keine pairing_state-Zeile zum Code." -ForegroundColor Red; $failed++; continue }
        $pairId = $row.Split('|')[0]; $hint = $row.Split('|')[1]

        # (2) Owner bestaetigt -> Bestaetigt-Text + Picker an das Mitglied.
        Clear-MockTelegramRequests -Container $Container
        $orchBase = Get-MaxExecId $OrchWfId
        Send-TelegramCallback $PairedUid $PairedUid "confirm:$pairId"
        $orch = Wait-NewExecTerminal $OrchWfId $orchBase $Timeout
        if (-not $orch) { Write-Host "    [FAIL] Confirm: keine Orchestrator-Execution (Timeout)." -ForegroundColor Red; $failed++; continue }
        $ranPicker = (Get-RunNodes $orch) -contains 'Send member language picker'
        $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT COALESCE(p->>'language', '<none>') FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') p WHERE c.name = 'family' AND p->>'person_id' = '$pairPerson';")
        $famLang = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -First 1)
        $txtOk = Test-CaseTexts $tc
        $hintOk = ($hint -eq "$($tc.expect_hint)")
        Write-Host "    Orchestrator: id=$($orch.id) status=$($orch.status) language_hint=$hint ranNode(Send member language picker)=$ranPicker family.language=$famLang texts=$txtOk"
        if ($orch.status -eq 'success' -and $hintOk -and $ranPicker -and $famLang -eq '<none>' -and $txtOk) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
        } else {
            $failed++; Write-Host "    [FAIL] Pairing-Sprachvorschlag stimmt nicht (status=$($orch.status), hint=$hint erwartet $($tc.expect_hint), picker=$ranPicker, family.language=$famLang, texts=$txtOk)" -ForegroundColor Red
        }
        continue
    }

    # ================= BURST (Eingangs-Buendelung, agent.ingress_buffer): mehrere Updates GLEICHZEITIG =================
    # Wie Telegram "Weiterleiten mit Kommentar" (zwei Updates ~0,4 s) bzw. Alben liefert: alle Updates des Falls
    # parallel an den echten Webhook. Assert: genau expect_processed Laeufe erreichen 'Trigger normalize' (die
    # anderen enden nach 'Ingress action' still), alle success; expect_together = Teiltexte, die gemeinsam in der
    # Ausgabe EINES verarbeiteten Laufs stehen (das zusammengefuehrte Update). revoke_claim = fail-open-Probe.
    if ($tc.kind -eq 'burst') {
        $burstUpdates = Build-BurstUpdates $tc $chatId $fromUid
        $grantees = @()
        if ($tc.revoke_claim) { $grantees = @(Revoke-IngressClaim -Container $Container) }
        $orchBase = Get-MaxExecId $OrchWfId
        try {
            Send-TelegramBurst $burstUpdates
            $execs = @(Wait-NewExecsTerminal $OrchWfId $orchBase $burstUpdates.Count $Timeout)
        } finally {
            if ($tc.revoke_claim) { Grant-IngressClaim -Container $Container -Roles $grantees }
        }
        $processed = @($execs | Where-Object { (Get-RunNodes $_) -contains 'Trigger normalize' })
        $allOk = ($execs.Count -eq $burstUpdates.Count) -and -not ($execs | Where-Object { $_.status -ne 'success' })
        $togetherOk = $true
        if ($tc.expect_together) {
            $togetherOk = [bool]($processed | Where-Object {
                $o = Get-NodeOutputText $_ 'Trigger normalize'
                -not (@($tc.expect_together) | Where-Object { -not $o.Contains("$_") })
            })
        }
        $maxRuns = ($execs | ForEach-Object { @($_.data.resultData.runData.'Ingress claim').Count } | Measure-Object -Maximum).Maximum
        Write-Host "    Executions: $($execs.Count)/$($burstUpdates.Count) (status: $((@($execs | ForEach-Object { $_.status }) -join ','))), verarbeitet: $($processed.Count) (erwartet $($tc.expect_processed)), gemeinsam: $togetherOk, max. Claim-Runden: $maxRuns"
        if ($allOk -and $processed.Count -eq [int]$tc.expect_processed -and $togetherOk) {
            $passed++; Write-Host "    [PASS]" -ForegroundColor Green
        } else {
            $failed++; Write-Host "    [FAIL] Buendelung stimmt nicht (alle success=$allOk, verarbeitet=$($processed.Count), gemeinsam=$togetherOk)" -ForegroundColor Red
            if ($Verbose) { foreach ($e in $processed) { Write-Host "      $($e.id): $((Get-NodeOutputText $e 'Trigger normalize'))" -ForegroundColor DarkGray } }
        }
        continue
    }

    Write-Host "    [FAIL] Unbekannter Case-kind '$($tc.kind)'." -ForegroundColor Red; $failed++
}
if ($personaDirty) { [void](Set-TestPersonaFact -Container $Container -PersonId $personaDirty -Code '') }

# Haengende Orchestrator-Gates aufraeumen (falls ein hitl-Case abbrach); gestoppte Laeufe hinterlassen Sperr-Zeilen.
try { (Invoke-N8nGet "executions?workflowId=$OrchWfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { }
Clear-HitlPending -Container $Container
Clear-ThinkingLease -Container $Container

Write-Host ""
Write-Host ("-" * 64)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$passed/$($cases.Count) Faelle bestanden, $failed fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
