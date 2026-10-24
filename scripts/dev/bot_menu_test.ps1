#Requires -Version 5.1
# bot_menu_test.ps1 — DETERMINISTISCHER, GRATIS Test des Telegram-Befehlsmenues je Sprache (Textkatalog Phase B).
# Faehrt im laufenden Substrat-Container den ECHTEN Installer-Code (provisioning/lib/deploy_workflows.sh
# _set_bot_command_menus aus dem installierten Baum) gegen den Mock-Telegram (Basis-URL-Override
# LIFEAGENTS_TELEGRAM_API, nur Test) und prueft die aufgezeichneten setMyCommands-Aufrufe:
#   - je Katalogsprache (Core-Manifest languages.list) ein Default-Menue mit language_code + ein Default ohne
#     language_code (Fallback = Owner-Sprache); ist der Owner verbunden, dieselben vier Owner-Chat-Menues;
#   - die Beschreibungen kommen aus dem Textkatalog der jeweiligen Sprache (<pkg>.cmd.<name>);
#   - der Sofort-Verify (getMyCommands je Scope + Sprache; der Mock speichert wie die Bot-API) meldet jedes Menue
#     als gesetzt.
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
$state = [System.IO.File]::ReadAllText((Join-Path $RepoRoot '.local\n8ntest_state.json'), $Utf8NoBom) | ConvertFrom-Json
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (kein mock_telegram-Block im State). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
$MockPort = "$($state.mock_telegram.port)"
if (-not $MockPort) { $MockPort = '8089' }

$failed = 0
function Fail($m) { Write-Host "    [FAIL] $m" -ForegroundColor Red; $script:failed++ }

# Erwartete Texte direkt aus dem getrackten Katalog (Datei = Wahrheit).
function Get-Loc([string]$Pkg, [string]$Lang) { [System.IO.File]::ReadAllText((Join-Path $RepoRoot "packages\$Pkg\locales\$Lang.json"), $Utf8NoBom) | ConvertFrom-Json }
$core = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $Utf8NoBom) | ConvertFrom-Json
$langs = @($core.languages.list | Sort-Object { [int]$_.ord } | ForEach-Object { [string]$_.code })

Write-Host ""
Write-Host "Telegram-Befehlsmenue je Sprache (Installer-Code gegen Mock-Telegram)"
Write-Host ("-" * 64)
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

# (3) Sofort-Verify: jedes gesetzte Menue wurde per getMyCommands verifiziert (Mock speichert je Scope + Sprache).
$verified = @($out | Where-Object { "$_" -match 'verifiziert' }).Count
if ($verified -ne $sets.Count) { Fail "Sofort-Verify: $verified von $($sets.Count) Menues verifiziert" }

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "bot_menu_test: OK ($($sets.Count) Menues, Texte je Sprache aus dem Katalog)" -ForegroundColor Green }
else { Write-Host "bot_menu_test: $failed Fehler" -ForegroundColor Red }
exit $failed
