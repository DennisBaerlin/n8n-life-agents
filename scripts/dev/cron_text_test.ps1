#Requires -Version 5.1
# cron_text_test.ps1 — DETERMINISTISCHER, GRATIS Test der Cron-Sends (Textkatalog Phase C, docs/package-contract.md §3.11).
# Jede Erinnerung/jeder Bericht, den der Bot VON SICH AUS schickt, kommt in der Sprache des Empfaengers. Dieser Treiber
# loest jeden Cron im Substrat echt aus und prueft das abgefangene Telegram (Mock) gegen den getrackten Katalog:
#   * expect_keys    — die festen Teilstuecke des Katalog-Texts in der Empfaenger-Sprache stehen im Send, die deutschen
#                      (>= 4 Zeichen) NICHT (Owner ko); Kontrollfall owner_lang de prueft die Gegenrichtung.
#   * expect_buttons — ein Knopf traegt genau den Katalog-Text.
#   * llm_expect     — Crons mit Umformulier-/Extraktions-Modell: der Mock-LLM-Request enthaelt die festen Stuecke der
#                      Keys (Grundtext in Empfaenger-Sprache) und die Sprachangabe '<code> (' (Mock antwortet 'done').
#   * taps           — Bestaetigungs-Fragen: Tipp simulieren (Invoke-HitlResume), Folge-Frage/Ergebnis-Zeile pruefen.
# Paket-neutral: Faelle aus tests/agent/<pkg>/cron_text_cases.json (kind cron_text). Je Fall NACHEINANDER: reset_sql ->
# seed_sql -> ggf. cron_enable an -> Zeitplan '* * * * *' (die CLI spielt die Paket-Workflows neu ein) -> auf die neue
# Execution warten -> Zeitplan zurueck -> pruefen -> finally: wartende Executions stoppen, cron_enable zurueck, reset_sql.
# So laufen nie zwei Crons gleichzeitig (die Berater-Crons teilen Latches) und kein Netz-Cron wird angefasst.
# Zusaetzlich (einmal): Datums-Paritaet core.fn_fmt_date (SQL-Dokumente) == Intl (Workflows) je Katalogsprache.
#
# Voraussetzung: Substrat (bootstrap_test_n8n.ps1 -Reset -HitlChatApproval) + enable_mock_llm.ps1 + enable_mock_telegram.ps1.
# Dauer ~2 Min je Fall (Umplanen = Workflow-Neueinspielung + Warten auf die naechste Minute) -> gezielt, nicht im Pre-Push.
# Usage:  .\scripts\dev\cron_text_test.ps1 [-Id ctf01] [-Timeout 150] [-Verbose]
# Exit-Code = Anzahl Fehler.
param(
    [string]$Id,
    [int]$Timeout = 150,
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
$Headers   = @{ 'X-N8N-API-KEY' = $ApiKey }

$state = Get-TestN8nState
if (-not $state.mock_llm)      { throw "Mock-LLM nicht aktiv. Zuerst: .\scripts\dev\enable_mock_llm.ps1" }
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv. Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
Assert-LlmGatewayUpstream -Container $Container -Expect mock
if ([string]::IsNullOrWhiteSpace($TEST_HARNESS_SECRET)) { throw "TEST_HARNESS_SECRET fehlt in .env." }

$OwnerUid  = [string]$script:TestOwnerTelegramUid
$LenaUid   = '880055200'
$Recipient = @{ 'owner' = $OwnerUid; 'person:lena' = $LenaUid }

function Invoke-N8nGet([string]$Path) { Invoke-RestMethod -Uri "$N8nUrl/api/v1/$Path" -Headers $Headers -Method Get }
function Stop-Exec([string]$ExecId) {
    try { Invoke-RestMethod -Uri "$N8nUrl/api/v1/executions/$ExecId/stop" -Headers $Headers -Method Post -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
}
# SQL ueber eine Datei, nicht per -c: PS 5.1 verstuemmelt eingebettete Anfuehrungszeichen (JSON-Literale) beim
# Uebergeben an docker. Leere Fall-Felder (kein reset_sql) sind ein No-op.
function Invoke-Sql([string]$Sql) {
    if ([string]::IsNullOrWhiteSpace($Sql)) { return @() }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "crontext_$([guid]::NewGuid().ToString('N')).sql"
    try {
        [System.IO.File]::WriteAllText($tmp, $Sql, $Utf8NoBom)
        $r = Invoke-TestN8nPsqlFile -Container $Container -HostFile $tmp -PsqlArgs @('-q', '-tA')
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    if ($r.Code -ne 0) { throw "SQL fehlgeschlagen: $Sql`n$($r.Output -join "`n")" }
    return @($r.Output | ForEach-Object { "$_" })
}
function Invoke-LifeagentsConfig([string[]]$CmdArgs) {
    $a = @('exec', '-e', 'LIFEAGENTS_HITL_CHAT_APPROVAL=true', $Container, 'lifeagents', 'config') + $CmdArgs
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & docker @a 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { throw "lifeagents config $($CmdArgs -join ' ') fehlgeschlagen: $($out -join "`n")" }
}
function Set-OwnerLanguage([string]$Lang) {
    Invoke-Sql @"
UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}',
  (SELECT jsonb_agg(CASE WHEN p->>'person_id' = 'owner' THEN p || jsonb_build_object('language', '$Lang') ELSE p END)
   FROM jsonb_array_elements(metadata->'facts'->'persons') p))
WHERE name = 'family';
"@ | Out-Null
}
# Text eines Mock-Telegram-Requests (Text/Caption + alle Knopf-Texte), Legacy-Markdown-Escape zurueckgenommen.
function Get-RequestText($Req) {
    $parts = @([string]$Req.body.text, [string]$Req.body.caption)
    foreach ($row in @($Req.body.reply_markup.inline_keyboard)) { foreach ($b in @($row)) { if ($b) { $parts += [string]$b.text } } }
    ConvertFrom-TgEscaped ($parts -join "`n")
}
function Get-Buttons($Reqs) { @($Reqs | ForEach-Object { foreach ($row in @($_.body.reply_markup.inline_keyboard)) { foreach ($b in @($row)) { if ($b) { [string]$b.text } } } }) }
function Get-Sends([string]$ChatId) {
    @(Get-MockTelegramRequests -Container $Container | Where-Object {
        $_.method -in @('sendMessage', 'sendDocument') -and [string]$_.body.chat_id -eq $ChatId })
}
# Prueft Keys/Knoepfe in einer Menge Requests; liefert Fehlertexte.
function Test-Sends($Reqs, [string[]]$Keys, [string[]]$Buttons, [string]$Lang) {
    $errs = @()
    $text = ($Reqs | ForEach-Object { Get-RequestText $_ }) -join "`n"
    foreach ($k in @($Keys | Where-Object { $_ })) {
        $missing = @(Get-CatalogFragments $k $Lang | Where-Object { -not $text.Contains($_) })
        if ($missing.Count) { $errs += "Key $k ($Lang): fehlt '$($missing -join "' | '")'" }
        if ($Lang -ne 'de') {
            $own = @(Get-CatalogFragments $k $Lang)
            $de = @(Get-CatalogFragments $k 'de' -MinLength 4 | Where-Object { $own -notcontains $_ -and $text.Contains($_) })
            if ($de.Count) { $errs += "Key ${k}: deutscher Text im $Lang-Send: '$($de -join "' | '")'" }
        }
    }
    $btns = Get-Buttons $Reqs
    foreach ($k in @($Buttons | Where-Object { $_ })) {
        $want = Get-CatalogText $k $Lang
        if ($btns -notcontains $want) { $errs += "Knopf $k ($Lang) '$want' fehlt (Knoepfe: $($btns -join ' | '))" }
    }
    return $errs
}
# Mock-LLM-Szenario zur Laufzeit ergaenzen (das Repo-scenarios.json bleibt unberuehrt -> mock_lint unberuehrt).
$ScnInC = '/opt/mock_llm/scenarios.json'
function Add-MockScenario($Scenario) {
    $raw = (& docker exec $Container cat $ScnInC) -join "`n"
    $list = @($raw | ConvertFrom-Json) + @($Scenario)
    $tmp = Join-Path $env:TEMP "cron_text_scn_$PID.json"
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $list -Depth 10), $Utf8NoBom)
    & docker cp $tmp "${Container}:$ScnInC" | Out-Null
    Remove-Item $tmp -Force
    return $raw
}
function Restore-MockScenarios([string]$Raw) {
    $tmp = Join-Path $env:TEMP "cron_text_scn_$PID.json"
    [System.IO.File]::WriteAllText($tmp, $Raw, $Utf8NoBom)
    & docker cp $tmp "${Container}:$ScnInC" | Out-Null
    Remove-Item $tmp -Force
}
function Resolve-Sql([object[]]$Lines) { @($Lines | ForEach-Object { ([string]$_).Replace('__OWNER_UID__', $OwnerUid) }) }

# --- Fixtures + Pairing (Muster hitl_gate_test/real_ingress_test) ----------------------------------------------------
$seed = Invoke-TestN8nPsqlFile -Container $Container -HostFile "$RepoRoot\tests\fixtures\util_seed_test_fixtures.sql"
if ($seed.Code -ne 0) { throw "Fixture-Seed fehlgeschlagen: $($seed.Output -join "`n")" }
Invoke-Sql @"
UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,persons}',
  (SELECT jsonb_agg(
     CASE WHEN p->>'person_id' = 'owner' THEN p || jsonb_build_object('telegram_user_id', ${OwnerUid}::bigint)
          WHEN p->>'person_id' = 'lena'  THEN p || jsonb_build_object('telegram_user_id', ${LenaUid}::bigint, 'language', 'ko')
          ELSE p END)
   FROM jsonb_array_elements(metadata->'facts'->'persons') p))
WHERE name = 'family';
"@ | Out-Null
$ownerLangBefore = (Invoke-Sql "SELECT COALESCE((SELECT pp->>'language' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp WHERE c.name = 'family' AND pp->>'role' = 'owner' LIMIT 1), 'de');" | Select-Object -First 1)

$cases = @()
foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'tests\agent\*\cron_text_cases.json') | Sort-Object FullName)) {
    $cases += @(([System.IO.File]::ReadAllText($f.FullName, $Utf8NoBom) | ConvertFrom-Json) | Where-Object { $_.kind -eq 'cron_text' })
}
if ($Id) { $cases = @($cases | Where-Object { $_.id -eq $Id }) }
if ($cases.Count -eq 0) { throw "Keine cron_text-Faelle gefunden (Filter '$Id')." }
$wfList = Invoke-N8nGet 'workflows?limit=250'

# Schnellweg-Vorbereitung (2026-10-26): Crons senden an die Owner-chat_id, die der Deploy beim Einspielen einsetzt
# (__OWNER_CHAT_ID__ -> DB-Owner nach dem Pairing, sonst die .env). Der alte Weg spielte je Fall neu ein und trug so den
# gepairten Test-Owner nach; der Schnellweg spielt nichts ein -> EINMAL vorab: Test-Owner pairen + je betroffenem Paket
# ein Redeploy (config reset schedule <ein Key des Pakets>), statt zwei Redeploys je Fall.
$viaHarnessAll = $null -ne ($wfList.data | Where-Object { $_.name -eq 'core.cron_run.test_harness' -and $_.active })
if ($viaHarnessAll) {
    Set-OwnerTelegramPairing -Container $Container
    $keyPkg = @{}
    foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
        $m = [System.IO.File]::ReadAllText($mf.FullName, $Utf8NoBom) | ConvertFrom-Json
        if ($m.config -and $m.config.schedule) {
            foreach ($k in $m.config.schedule.PSObject.Properties.Name) { if ($k -notlike '_*') { $keyPkg[$k] = $mf.Directory.Name } }
        }
    }
    $redeployKeys = @{}
    foreach ($c in $cases) {
        $k = [string]$c.schedule_key
        if ($k -and $keyPkg.ContainsKey($k) -and -not $redeployKeys.ContainsKey($keyPkg[$k])) { $redeployKeys[$keyPkg[$k]] = $k }
    }
    foreach ($pkg in $redeployKeys.Keys) { Invoke-LifeagentsConfig @('reset', 'schedule', $redeployKeys[$pkg]) }
}

$passed = 0; $failed = 0
Write-Host ''
Write-Host "cron_text_test — $($cases.Count) Fall/Faelle gegen $N8nUrl"
Write-Host ('-' * 64)

# --- Datums-Paritaet: core.fn_fmt_date (SQL-Dokumente) == Fmt-DateJs-Intl (Workflows) je Katalogsprache --------------
if (-not $Id) {
    $errs = @()
    foreach ($row in (Invoke-Sql "SELECT code || '|' || locale || '|' || core.fn_fmt_date(DATE '2026-03-05', code) FROM core.ui_languages ORDER BY ord;")) {
        $p = $row.Split('|'); if ($p.Count -lt 3) { continue }
        $js = "console.log(new Date(Date.UTC(2026,2,5)).toLocaleDateString('$($p[1])',{timeZone:'UTC',year:'numeric',month:'2-digit',day:'2-digit'}))"
        $intl = ((& docker exec $Container node -e $js) -join '').Trim()
        if ($intl -ne $p[2]) { $errs += "$($p[0]): SQL '$($p[2])' != Intl '$intl'" }
    }
    Write-Host "  [ctd00] Datums-Paritaet core.fn_fmt_date == Intl"
    if ($errs.Count -eq 0) { $passed++; Write-Host '    [PASS]' -ForegroundColor Green }
    else { $failed++; Write-Host "    [FAIL] $($errs -join '; ')" -ForegroundColor Red }
}

try {
    foreach ($c in $cases) {
        Write-Host ''
        Write-Host "  [$($c.id)] $($c.name)"
        $lang = if ($c.owner_lang) { [string]$c.owner_lang } else { 'ko' }
        $chat = $Recipient[[string]$c.recipient]
        if (-not $chat) { throw "$($c.id): unbekannter recipient '$($c.recipient)'" }
        $recLang = if ([string]$c.recipient -eq 'owner') { $lang } else { 'ko' }
        $errs = @(); $wfId = $null; $scnBackup = $null
        try {
            Set-OwnerLanguage $lang
            foreach ($s in (Resolve-Sql $c.reset_sql)) { Invoke-Sql $s | Out-Null }
            foreach ($s in (Resolve-Sql $c.seed_sql))  { Invoke-Sql $s | Out-Null }
            if ($c.mock_llm_scenario) { $scnBackup = Add-MockScenario $c.mock_llm_scenario }
            if ($c.cron_enable) { Invoke-LifeagentsConfig @('set', 'cron_enable', [string]$c.cron_enable, 'true') }
            Clear-MockTelegramRequests -Container $Container
            Clear-MockLlmRequests -Container $Container

            if ($c.harness) {
                $body = @{}; foreach ($p in $c.harness_body.PSObject.Properties) { $body[$p.Name] = $p.Value }
                # harness_actor: wer den Schritt ausloest, wenn das nicht der Empfaenger ist (z. B. der Owner schliesst den
                # Haushalt, das Mitglied bekommt "Es kann losgehen"); Default = der Empfaenger selbst.
                $body['chat_id'] = if ($c.harness_actor) { $Recipient[[string]$c.harness_actor] } else { $chat }
                Invoke-RestMethod -Uri "$N8nUrl/webhook/$($c.harness)" -Method Post -Headers @{ 'X-Test-Auth' = $TEST_HARNESS_SECRET } `
                    -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 5))) | Out-Null
                Start-Sleep -Seconds 2
            } else {
                $wfId = ($wfList.data | Where-Object { $_.name -eq $c.workflow } | Select-Object -First 1).id
                if (-not $wfId) { throw "Workflow '$($c.workflow)' nicht gefunden." }
                $maxId = Get-MaxExecId -WfId $wfId -BridgeUrl $N8nUrl -ApiKey $ApiKey
                # Schnellweg (2026-10-26): der Test-Eingang core.cron_run.test_harness startet den Cron sofort ueber
                # seinen 'Test run'-Einstieg (Build-Workflow). Rueckfall auf den alten Weg (Zeitplan auf jede Minute,
                # 2 Redeploys + Warten) nur auf einem Substrat ohne diesen Eingang.
                $viaHarness = $viaHarnessAll
                if ($viaHarness) {
                    # responseMode=lastNode: der POST kehrt erst nach dem Lauf zurueck; ein waitender Cron (HITL-Frage)
                    # antwortet trotzdem (Execute Workflow wartet nicht auf die Freigabe).
                    Invoke-RestMethod -Uri "$N8nUrl/webhook/cron-run-test" -Method Post -Headers @{ 'X-Test-Auth' = $TEST_HARNESS_SECRET } `
                        -ContentType 'application/json; charset=utf-8' -TimeoutSec $Timeout `
                        -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ workflow_id = $wfId } | ConvertTo-Json))) | Out-Null
                } else {
                    Invoke-LifeagentsConfig @('set', 'schedule', [string]$c.schedule_key, '* * * * *')
                }
                $ex = $null; $start = Get-Date
                try {
                    while (((Get-Date) - $start).TotalSeconds -lt $Timeout) {
                        try { $ex = @((Invoke-N8nGet "executions?workflowId=$wfId&limit=10").data | Where-Object { [int]$_.id -gt $maxId -and $_.status -in @('success', 'waiting', 'error', 'crashed') } | Sort-Object { [int]$_.id } | Select-Object -First 1) } catch { $ex = @() }
                        if ($ex.Count) { break }
                        Start-Sleep -Seconds $(if ($viaHarness) { 1 } else { 3 })
                    }
                } finally { if (-not $viaHarness) { Invoke-LifeagentsConfig @('reset', 'schedule', [string]$c.schedule_key) } }
                if (-not $ex -or $ex.Count -eq 0) { throw "keine neue Execution von $($c.workflow) binnen $Timeout s" }
                if ($ex[0].status -in @('error', 'crashed')) { $errs += "Execution $($ex[0].id) endete mit $($ex[0].status)" }
                Start-Sleep -Seconds 3
            }

            $sends = @(Get-Sends $chat)
            if ($sends.Count -eq 0) { $errs += "kein Send an $($c.recipient) ($chat)" }
            $errs += @(Test-Sends $sends @($c.expect_keys) @($c.expect_buttons) $recLang)
            if ($c.llm_expect) {
                $tasks = (@(Get-MockLlmRequests -Container $Container) | ForEach-Object { [string]$_.task }) -join "`n"
                foreach ($k in @($c.llm_expect.keys | Where-Object { $_ })) {
                    $missing = @(Get-CatalogFragments $k $recLang | Where-Object { -not $tasks.Contains($_) })
                    if ($missing.Count) { $errs += "LLM-Request: Grundtext $k ($recLang) fehlt '$($missing -join "' | '")'" }
                }
                if ($c.llm_expect.language -and -not $tasks.Contains("$recLang (")) { $errs += "LLM-Request ohne Sprachangabe '$recLang ('" }
            }

            # Tipps nacheinander: jeweils die zuletzt gesendete Bestaetigungs-Frage beantworten, danach die neuen Sends pruefen.
            foreach ($tap in @($c.taps | Where-Object { $_ })) {
                $ask = @($sends | Where-Object { $_.body.reply_markup -and (@($_.body.reply_markup.inline_keyboard | ForEach-Object { $_ } | Where-Object { [string]$_.callback_data -like 'nhitl1|*' -or [string]$_.url })).Count -gt 0 }) | Select-Object -Last 1
                if (-not $ask) { $errs += 'Tipp: keine Bestaetigungs-Frage zum Antippen'; break }
                $before = $sends.Count
                Invoke-HitlResume -Url (Get-HitlResumeUrl -Request $ask -Approved ([bool]$tap.approved) -BridgeUrl $N8nUrl) | Out-Null
                $t0 = Get-Date; $new = @()
                while (((Get-Date) - $t0).TotalSeconds -lt 30) {
                    $all = @(Get-Sends $chat)
                    $new = @($all | Select-Object -Skip $before)
                    if ($new.Count -ge @($tap.expect_keys).Count) { Start-Sleep -Seconds 2; $all = @(Get-Sends $chat); $new = @($all | Select-Object -Skip $before); break }
                    Start-Sleep -Seconds 1
                }
                if ($new.Count -eq 0) { $errs += "Tipp (approved=$($tap.approved)): keine Folge-Nachricht"; break }
                $errs += @(Test-Sends $new @($tap.expect_keys) @($tap.expect_buttons) $recLang | ForEach-Object { "Tipp: $_" })
                $sends = $all
            }
        } catch {
            $errs += "Abbruch: $($_.Exception.Message)"
        } finally {
            if ($wfId) { try { (Invoke-N8nGet "executions?workflowId=$wfId&status=waiting&limit=20").data | ForEach-Object { Stop-Exec $_.id } } catch { } }
            if ($c.cron_enable) { try { Invoke-LifeagentsConfig @('reset', 'cron_enable', [string]$c.cron_enable) } catch { } }
            if ($null -ne $scnBackup) { try { Restore-MockScenarios $scnBackup } catch { } }
            foreach ($s in (Resolve-Sql $c.reset_sql)) { try { Invoke-Sql $s | Out-Null } catch { } }
        }
        if ($Verbose) { Get-Sends $chat | ForEach-Object { Write-Host "    > $((Get-RequestText $_) -replace "`n", ' / ')" -ForegroundColor DarkGray } }
        if ($errs.Count -eq 0) { $passed++; Write-Host '    [PASS]' -ForegroundColor Green }
        else { $failed++; Write-Host '    [FAIL]' -ForegroundColor Red; $errs | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow } }
    }
} finally {
    try { Set-OwnerLanguage $ownerLangBefore } catch { }
}

Write-Host ''
Write-Host ('-' * 64)
Write-Host "cron_text_test: $passed bestanden, $failed fehlgeschlagen."
exit $failed
