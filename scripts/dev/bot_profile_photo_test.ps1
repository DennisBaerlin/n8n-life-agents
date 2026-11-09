#Requires -Version 5.1
# bot_profile_photo_test.ps1 — DETERMINISTISCHER, GRATIS Test des Bot-Profilbilds beim Installieren und Aktualisieren.
# Kopiert provisioning/ DIESES Checkouts + den Mock (tests/mock_telegram/) in den Container und faehrt dort
# tests/mock_telegram/profile_photo_cases.sh gegen den echten Lib-Code (bootstrap_owner.sh _ensure_bot_profile_photo):
#   - ein vorhandenes Bild bleibt, eine unklare Antwort aendert nichts, ein Fehler ist nur eine Warnung;
#   - ohne Bild genau ein gueltiger Upload (static, attach://, JPEG), einmal je Bot; ein selbst geloeschtes Bild bleibt weg;
#   - Aus-Schalter BOT_PROFILE_PHOTO=0, kein Bot-Schluessel in Ausgabe oder Protokoll;
#   - das committete Bild (JPEG, 640 x 640) und, im Substrat, die mitgelieferte Datei im installierten Baum.
# Faehrt zusaetzlich tests/mock_telegram/bot_username_cases.sh (_sync_bot_username, Bot-Name aus getMe) und
# app_intro_cases.sh (_app_intro_announce, einmalige Ankuendigung der Uebersicht).
# Belegt NICHT das Verhalten des echten Telegram (Bot API: setMyProfilePhoto, getUserProfilePhotos mit eigener Kennung).
# Dazu prueft es, dass das Test-Substrat den Schritt abschaltet: es installiert mit einem echten Test-Bot-Schluessel.
# Braucht kein n8n, kein Netz und keine enable_mock_*: nur einen laufenden Container mit bash, curl, jq und node.
# Usage:  .\scripts\dev\bot_profile_photo_test.ps1 [-Container <name>] [-Port 8082] [-Verbose]   (ohne -Container: das Substrat)
# Exit-Code = Anzahl Fehler.
param([string]$Container, [int]$Port = 8082, [switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
if (-not $Container) {
    . "$PSScriptRoot\test_n8n_state.ps1"
    $Container = (Get-TestN8nConnection).Container
}

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { "$_" }) }
}

Write-Host ""
Write-Host "Bot-Profilbild (Installer-Schritt) gegen Mock-Telegram — Container $Container"
Write-Host ("-" * 64)

$failed = 0
# Das Substrat installiert mit dem echten TEST_TELEGRAM_BOT_TOKEN -> ohne Schalter bekaeme der Test-Bot bei jedem -Reset ein Bild.
$bootstrap = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts\dev\bootstrap_test_n8n.ps1'), [System.Text.UTF8Encoding]::new($false))
if ($bootstrap -notmatch "envLines\.Add\('BOT_PROFILE_PHOTO=0'\)") {
    $failed++
    Write-Host "    [FAIL] bootstrap_test_n8n.ps1 setzt BOT_PROFILE_PHOTO=0 nicht" -ForegroundColor Red
}

# Frischer Stand im Container: alten Test-Baum leeren (docker cp MERGT sonst), dann provisioning/ + Mock kopieren.
$root = '/opt/bot_profile_photo_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
$pairs = @(@('provisioning', 'provisioning'), @('tests\mock_telegram', 'mock_telegram'))
if (Test-Path (Join-Path $RepoRoot 'packages\core\build\bot_profile')) { $pairs += , @('packages\core\build\bot_profile', 'bot_profile') }
foreach ($pair in $pairs) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$passed = 0
foreach ($cases in 'profile_photo_cases.sh', 'bot_username_cases.sh', 'app_intro_cases.sh') {
    $r = Invoke-Native docker @('exec', $Container, 'bash', "$root/mock_telegram/$cases", $root, "$Port")
    $lines = @($r.Output)
    foreach ($l in $lines) {
        if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
        elseif ($l -match '^SKIP ') { Write-Host "    [SKIP] $($l.Substring(5))" -ForegroundColor Yellow }
        elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
        elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
    }
    $thisPassed = @($lines | Where-Object { $_ -match '^PASS ' }).Count
    $caseFails = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
    $passed += $thisPassed
    $failed += $caseFails
    # Abbruch des Runners ohne FAIL-Zeile (Setup, Syntax) zaehlt als Fehler.
    if ($r.Code -ne 0 -and $caseFails -eq 0) { $failed++; Write-Host "    [FAIL] $cases brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
    if ($thisPassed -eq 0 -and $caseFails -eq 0) { $failed++; Write-Host "    [FAIL] $cases lieferte keine Faelle" -ForegroundColor Red }
}

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "bot_profile_photo_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "bot_profile_photo_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
