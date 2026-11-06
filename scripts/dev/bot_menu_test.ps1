#Requires -Version 5.1
# bot_menu_test.ps1 — DETERMINISTISCHER, GRATIS Test des Telegram-Befehlsmenues je Sprache (Textkatalog Phase B).
# Faehrt im laufenden Substrat-Container den ECHTEN Installer-Code (provisioning/lib/deploy_workflows.sh
# _set_bot_command_menus aus dem installierten Baum) gegen den Mock-Telegram (Basis-URL-Override
# LIFEAGENTS_TELEGRAM_API, nur Test) und prueft die aufgezeichneten setMyCommands-Aufrufe:
#   - je Katalogsprache (Core-Manifest languages.list) ein Default-Menue mit language_code + ein Default ohne
#     language_code (Fallback = Owner-Sprache); ist der Owner verbunden, dieselben vier Owner-Chat-Menues;
#   - die Beschreibungen kommen aus dem Textkatalog der jeweiligen Sprache (<pkg>.cmd.<name>);
#   - der Sofort-Verify (getMyCommands je Scope + Sprache; der Mock speichert wie die Bot-API) meldet jedes Menue
#     als gesetzt;
#   - der Mini-App-Knopf „Übersicht“ (setChatMenuButton) nur pro Chat, bei audience=owner nur fuer den Owner, Text aus
#     dem Katalog, URL https + /webhook/app-<uuid>; nie als Standard-Knopf.
#   - Menue-Auftrag (core.menu_refresh): ein Wechsel von app.audience legt ihn an, der minuetliche Runner
#     (`lifeagents update --run-requested`) setzt NUR die Knoepfe (keine Befehlsmenues) fuer alle gekoppelten Personen
#     und schliesst ihn; Zweitlauf ruft Telegram nicht; scheitert Telegram, bleibt er offen mit Wartezeit; ein
#     normaler Menue-Lauf (Install/Update) schliesst einen offenen Auftrag mit. Der echte Timer pausiert dafuer kurz.
# Voraussetzung: laufendes Substrat + enable_mock_telegram.ps1. Kein LLM, kein echtes Telegram.
# Usage:  .\scripts\dev\bot_menu_test.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$Container = $conn.Container
$state = Get-TestN8nState
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (kein mock_telegram-Block im State). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
$MockPort = "$($state.mock_telegram.port)"
if (-not $MockPort) { $MockPort = '8089' }

$failed = 0
function Fail($m) { Write-Host "    [FAIL] $m" -ForegroundColor Red; $script:failed++ }

# Erwartete Texte direkt aus dem getrackten Katalog (Datei = Wahrheit).
function Get-Loc([string]$Pkg, [string]$Lang) { [System.IO.File]::ReadAllText((Join-Path $RepoRoot "packages\$Pkg\locales\$Lang.json"), $Utf8NoBom) | ConvertFrom-Json }
$core = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $Utf8NoBom) | ConvertFrom-Json
$langs = @($core.languages.list | Sort-Object { [int]$_.ord } | ForEach-Object { [string]$_.code })

function Invoke-Sql([string]$Sql) {
    $r = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', $Sql)
    return (($r.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`n")
}

Write-Host ""
Write-Host "Telegram-Befehlsmenue je Sprache (Installer-Code gegen Mock-Telegram)"
Write-Host ("-" * 64)
# Der echte Minuten-Runner wuerde einen Menue-Auftrag mit dem echten Telegram-Endpunkt abarbeiten und mit dem Test
# um den Auftrag konkurrieren -> fuer die Testdauer anhalten (am Ende wieder starten).
& docker exec $Container systemctl stop lifeagents-update-run.timer 2>$null | Out-Null
$audienceBefore = Invoke-Sql "SELECT value FROM core.config WHERE category = 'app' AND key = 'audience';"
[void](Invoke-Sql "UPDATE core.config SET value = 'owner' WHERE category = 'app' AND key = 'audience';")
Clear-MockTelegramRequests -Container $Container

$lib = '/usr/local/lib/lifeagents'
$sh = @"
set -e
export LIFEAGENTS_LIB=$lib REPO_ROOT=$lib DB_SUPERUSER=postgres LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:$MockPort
N8N_DB_NAME=`$(grep -E '^DB_POSTGRESDB_DATABASE=' /etc/n8n/n8n.env | tail -n1 | cut -d= -f2); export N8N_DB_NAME
. $lib/provisioning/lib/common.sh
. $lib/provisioning/lib/deploy_workflows.sh
_set_bot_command_menus mock-token
"@
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$out = & docker exec $Container bash -c $sh 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($Verbose) { $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
if ($code -ne 0) { Fail "_set_bot_command_menus brach ab (exit $code): $($out -join ' | ')" }

$sets = @(Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'setMyCommands' })
$owner = @($sets | Where-Object { $_.body.scope.type -eq 'chat' })
$default = @($sets | Where-Object { $_.body.scope.type -eq 'default' })
Write-Host "  setMyCommands: $($default.Count) Default-, $($owner.Count) Owner-Menue(s)"

# (1) Default-Menues: je Sprache eins mit language_code + eins ohne.
foreach ($l in $langs) {
    $m = @($default | Where-Object { "$($_.body.language_code)" -eq $l })
    if ($m.Count -ne 1) { Fail "Default-Menue fuer language_code '$l' $($m.Count)x gesetzt (erwartet 1)"; continue }
    $cmds = @($m[0].body.commands)
    $loc = Get-Loc 'core' $l
    foreach ($c in 'help', 'onboarding', 'language') {
        $hit = @($cmds | Where-Object { $_.command -eq $c })
        if ($hit.Count -ne 1) { Fail "Menue '$l': Befehl /$c fehlt"; continue }
        $want = [string]$loc."core.cmd.$c"
        if ([string]$hit[0].description -ne $want) { Fail "Menue '$l': /$c Beschreibung '$($hit[0].description)' != Katalog '$want'" }
    }
    if (@($cmds | Where-Object { $_.command -in @('sprache', 'hilfe', 'start') }).Count -gt 0) { Fail "Menue '$l': versteckter Befehl beworben" }
}
$fb = @($default | Where-Object { -not $_.body.language_code })
if ($fb.Count -ne 1) { Fail "Default-Menue ohne language_code $($fb.Count)x gesetzt (erwartet 1)" }
else {
    $q = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT agent.fn_person_lang(agent.fn_owner_person_id())->>'lang';")
    $ownerLang = ($q.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[a-z]{2}$' } | Select-Object -First 1)
    if (-not $ownerLang) { $ownerLang = 'de' }
    $want = [string](Get-Loc 'core' $ownerLang).'core.cmd.help'
    $got = [string](@($fb[0].body.commands | Where-Object { $_.command -eq 'help' })[0].description)
    if ($got -ne $want) { Fail "Fallback-Menue (ohne language_code) nicht in Owner-Sprache '$ownerLang': '$got' != '$want'" }
}

# (2) Owner-Menues nur, wenn der Owner verbunden ist (Substrat: je nach Vorlauf) — dann vollstaendig.
if ($owner.Count -gt 0) {
    foreach ($l in @($langs) + @('')) {
        $m = @($owner | Where-Object { "$($_.body.language_code)" -eq $l })
        if ($m.Count -ne 1) { Fail "Owner-Menue fuer language_code '$l' $($m.Count)x gesetzt (erwartet 1)" }
    }
} else {
    Write-Host "  (Owner nicht verbunden -> keine Owner-Menues erwartet)" -ForegroundColor DarkGray
}

# (2b) Mini-App-Knopf „Übersicht“ (docs/package-contract.md §3.12): NIE als Standard-Knopf (ohne chat_id waere er fuer
# Fremde sichtbar); web_app nur pro Chat einer berechtigten Person (Substrat-Default app.audience=owner -> nur der
# Owner), Text = core.app.menu_button in der Owner-Sprache, URL = https-WEBHOOK_URL + /webhook/app-<uuid>.
$btn = @(Get-MockTelegramRequests -Container $Container | Where-Object { $_.method -eq 'setChatMenuButton' })
if (@($btn | Where-Object { $null -eq $_.body.chat_id }).Count -gt 0) { Fail 'setChatMenuButton ohne chat_id (Standard-Knopf fuer alle, auch Fremde)' }
$web = @($btn | Where-Object { $_.body.menu_button.type -eq 'web_app' })
if ($owner.Count -gt 0) {
    $ownerChat = [string]$owner[0].body.scope.chat_id
    $mine = @($web | Where-Object { [string]$_.body.chat_id -eq $ownerChat })
    if ($mine.Count -ne 1) { Fail "Übersicht-Knopf fuer den Owner $($mine.Count)x gesetzt (erwartet 1)" }
    else {
        $q2 = Invoke-TestN8nPsql -Container $Container -PsqlArgs @('-tA', '-c', "SELECT agent.fn_person_lang(agent.fn_owner_person_id())->>'lang';")
        $ol = ($q2.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[a-z]{2}$' } | Select-Object -First 1)
        if (-not $ol) { $ol = 'de' }
        $wantBtn = [string](Get-Loc 'core' $ol).'core.app.menu_button'
        if ([string]$mine[0].body.menu_button.text -ne $wantBtn) { Fail "Übersicht-Knopf: Text '$($mine[0].body.menu_button.text)' != Katalog '$wantBtn'" }
        if ([string]$mine[0].body.menu_button.web_app.url -notmatch '^https://[^ ]+/webhook/app-[0-9a-f-]{36}$') { Fail "Übersicht-Knopf: URL '$($mine[0].body.menu_button.web_app.url)'" }
    }
    if (@($web | Where-Object { [string]$_.body.chat_id -ne $ownerChat }).Count -gt 0) { Fail 'Übersicht-Knopf bei audience=owner auch fuer Nicht-Owner gesetzt' }
    Write-Host "  setChatMenuButton: $($web.Count) Übersicht-Knopf, $($btn.Count - $web.Count) Befehlsmenü"
} elseif ($web.Count -gt 0) { Fail 'Übersicht-Knopf gesetzt, obwohl der Owner nicht verbunden ist' }

# (3) Sofort-Verify: jedes gesetzte Menue wurde per getMyCommands verifiziert (Mock speichert je Scope + Sprache).
$verified = @($out | Where-Object { "$_" -match 'verifiziert' }).Count
if ($verified -ne $sets.Count) { Fail "Sofort-Verify: $verified von $($sets.Count) Menues verifiziert" }
if ((Invoke-Sql "SELECT core.fn_menu_refresh_claim()->>'open';") -ne 'false') { Fail 'Menü-Lauf des Installers hat den offenen Menü-Auftrag nicht geschlossen' }

# (4) Menue-Auftrag ueber den Runner (Familie, Release 2): audience owner -> household. Frisches Substrat ohne
# gekoppelte Person -> fuer die Testdauer eine Test-Kopplung am Owner (sonst liefen Runner- und Fehlerfall leer).
$famPersons = @'
SELECT jsonb_agg(CASE WHEN e->>'role' = 'owner' THEN e || jsonb_build_object('telegram_user_id', 4242) ELSE e END ORDER BY o)
  FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') WITH ORDINALITY AS x(e, o) WHERE c.name = 'family'
'@
$addedTid = $false
if (-not (Invoke-Sql "SELECT 1 FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) p WHERE c.name = 'family' AND COALESCE(p->>'telegram_user_id','') ~ '^[0-9]{1,18}$' LIMIT 1;")) {
    [void](Invoke-Sql "UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', ($famPersons)) WHERE name = 'family' AND jsonb_typeof(metadata->'facts'->'persons') = 'array';")
    $addedTid = $true
}
$tids = @((Invoke-Sql "SELECT p->>'telegram_user_id' FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) p WHERE c.name = 'family' AND COALESCE(p->>'telegram_user_id','') ~ '^[0-9]{1,18}$';") -split "`n" | Where-Object { $_ })
function Invoke-Runner([string]$Api) {
    $prev2 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o = & docker exec $Container bash -c "LIFEAGENTS_TELEGRAM_API=$Api TELEGRAM_BOT_TOKEN=mock-token lifeagents update --run-requested" 2>&1
    $c = $LASTEXITCODE; $ErrorActionPreference = $prev2
    if ($Verbose) { $o | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    if ($c -ne 0) { Fail "Runner brach ab (exit $c): $($o -join ' | ')" }
}
[void](Invoke-Sql "UPDATE core.config SET value = 'household' WHERE category = 'app' AND key = 'audience';")
if ((Invoke-Sql "SELECT core.fn_menu_refresh_claim()->>'open';") -ne 'true') { Fail 'audience-Wechsel hat keinen Menü-Auftrag angelegt' }
Clear-MockTelegramRequests -Container $Container
Invoke-Runner "http://127.0.0.1:$MockPort"
$req = @(Get-MockTelegramRequests -Container $Container)
if (@($req | Where-Object { $_.method -eq 'setMyCommands' }).Count -gt 0) { Fail 'Runner hat Befehlsmenüs gesetzt (soll nur die Knöpfe setzen)' }
$web2 = @($req | Where-Object { $_.method -eq 'setChatMenuButton' -and $_.body.menu_button.type -eq 'web_app' })
if ($web2.Count -ne $tids.Count) { Fail "Runner: $($web2.Count) Übersicht-Knöpfe, erwartet $($tids.Count) (alle gekoppelten Personen bei household)" }
if ((Invoke-Sql "SELECT core.fn_menu_refresh_claim()->>'open';") -ne 'false') { Fail 'Runner hat den Menü-Auftrag nicht geschlossen' }
Clear-MockTelegramRequests -Container $Container
Invoke-Runner "http://127.0.0.1:$MockPort"
if (@(Get-MockTelegramRequests -Container $Container).Count -gt 0) { Fail 'Runner ohne offenen Auftrag hat Telegram aufgerufen' }
Write-Host "  Runner: Menü-Auftrag -> $($web2.Count) Übersicht-Knopf/Knöpfe, Zweitlauf still"

# (5) Telegram scheitert (geschlossener Port) -> Auftrag bleibt offen, Wartezeit; ein Installer-Menue-Lauf schliesst ihn
if ($tids.Count -gt 0) {
    [void](Invoke-Sql "UPDATE core.config SET value = 'owner' WHERE category = 'app' AND key = 'audience';")
    Invoke-Runner 'http://127.0.0.1:9'
    $st = Invoke-Sql "SELECT (requested_gen > done_gen)::text || '|' || (retry_after > now())::text FROM core.menu_refresh;"
    if ($st -ne 'true|true') { Fail "Fehlschlag: Auftrag muss offen bleiben mit Wartezeit, got '$st'" }
    $prev3 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o3 = & docker exec $Container bash -c $sh 2>&1
    $ErrorActionPreference = $prev3
    if ($Verbose) { $o3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    $st = Invoke-Sql "SELECT (requested_gen > done_gen)::text || '|' || (retry_after IS NULL)::text FROM core.menu_refresh;"
    if ($st -ne 'false|true') { Fail "Installer-Menü-Lauf hat den offenen Auftrag nicht geschlossen, got '$st'" }
    Write-Host "  Fehlschlag: Auftrag offen mit Wartezeit, Installer-Lauf schließt ihn"
}

# Aufraeumen: Test-Kopplung weg, audience wie vorher, Knoepfe dazu passend (Installer-Lauf), Timer wieder an
if ($addedTid) {
    [void](Invoke-Sql "UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', (SELECT jsonb_agg(e - 'telegram_user_id' ORDER BY o) FROM jsonb_array_elements(metadata->'facts'->'persons') WITH ORDINALITY AS x(e, o))) WHERE name = 'family';")
}
if ($audienceBefore) { [void](Invoke-Sql "UPDATE core.config SET value = '$audienceBefore' WHERE category = 'app' AND key = 'audience';") }
$prev4 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
[void](& docker exec $Container bash -c $sh 2>&1)
& docker exec $Container systemctl start lifeagents-update-run.timer 2>$null | Out-Null
$ErrorActionPreference = $prev4

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "bot_menu_test: OK ($($sets.Count) Menues, Texte je Sprache aus dem Katalog)" -ForegroundColor Green }
else { Write-Host "bot_menu_test: $failed Fehler" -ForegroundColor Red }
exit $failed
