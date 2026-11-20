#Requires -Version 5.1
# retire_test.ps1 — GRATIS Test von `lifeagents retire` (Umzug: stilllegen, exportieren, zurueck) auf dem echten Weg im
# klassischen Substrat: echtes systemd, n8n, PostgreSQL; Telegram ist die Attrappe des Substrats (enable_mock_telegram.ps1), an der
# auch n8n haengt: so sieht der Test, dass n8n den Bot nach dem Rueckweg selbst wieder anmeldet.
# Kopiert provisioning/ + packages/ dieses Checkouts und den Fall-Runner (tests/backup/retire_cases.sh) in den Container und faehrt dort
# retire_cases.sh mit der CLI dieses Baums:
#   - Lauf: Bot geloest, n8n, Gateway und Timer aus und deaktiviert, PostgreSQL an, Umzugs-Ordner vollstaendig und pruefbar;
#   - Sperre: update/config set enden mit Satz, systemctl start n8n bleibt wirkungslos, doctor zeigt den Ruhezustand gruen;
#   - Rueckweg: fremder Webhook -> nichts; --undo --restore -> Daten, Gedaechtnis, Wasserstand zurueck, alles wieder an, Bot wieder hier.
# Haelt n8n im Substrat voruebergehend an -> nur im EIGENEN Container laufen lassen ($env:N8NTEST_CONTAINER/N8NTEST_PORT);
# am Ende laeuft alles wieder wie vorher. Voraussetzung: enable_mock_telegram.ps1 (aktuelle Attrappe). Kein LLM, kein echtes Telegram.
# Usage:  $env:N8NTEST_CONTAINER='s4b1-n8ntest'; $env:N8NTEST_PORT='57900'; .\scripts\dev\retire_test.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$Container = $conn.Container
$state = Get-TestN8nState
if (-not $state.mock_telegram) { throw "Mock-Telegram nicht aktiv (kein mock_telegram-Block im State). Zuerst: .\scripts\dev\enable_mock_telegram.ps1" }
$MockPort = "$($state.mock_telegram.port)"
$MockLog = "$($state.mock_telegram.log)"

. "$PSScriptRoot\..\lib\test_common.ps1"

Write-Host ""
Write-Host "Umzug: lifeagents retire (Stilllegen, Export, Rückweg) — Container $Container"
Write-Host ("-" * 64)

$root = '/opt/retire_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root && chmod 0700 $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('packages', 'packages'), @('tests\backup', 'backup'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/backup/retire_cases.sh", $root, "$MockPort", "$MockLog")
$lines = @($r.Output)
foreach ($l in $lines) {
    if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
    elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
    elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
}
$passed = @($lines | Where-Object { $_ -match '^PASS ' }).Count
$failed = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
# Abbruch des Runners ohne FAIL-Zeile (Setup, Syntax) zaehlt als Fehler.
if ($r.Code -ne 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] retire_cases.sh brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
if ($passed -eq 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] retire_cases.sh lieferte keine Faelle" -ForegroundColor Red }
Invoke-Native docker @('exec', $Container, 'rm', '-rf', $root) | Out-Null

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "retire_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "retire_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
