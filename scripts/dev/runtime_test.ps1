#Requires -Version 5.1
# runtime_test.ps1 — deterministischer, gratis Test der Betriebsart-Naht des Installers (systemd | Docker-Verbund).
# Kopiert provisioning/ dieses Checkouts + den Fall-Runner (tests/mock_runtime/) in den laufenden Substrat-Container und
# faehrt dort tests/mock_runtime/cases.sh gegen den echten Lib-Code (common.sh -> runtime.sh, release_inputs.sh):
#   - Antwort-Datei fuer --unattended wird gelesen, nie ausgefuehrt ('…', $(), Backticks, Zeilenumbruch, gesperrte Schluessel);
#   - Wrapper: systemd-Zweig = runuser/systemctl-Aufrufe, compose-Zweig = docker exec mit festem Container
#     (stdin nur, wenn psql liest), Compose-Aufrufe nur mit festem Projekt; Volumes nur mit eigenem Label;
#   - Telegram-Pruefung vor der Aktivierung (frei / eigener / fremder Webhook / Long-Polling / nicht pruefbar).
# docker, systemctl und runuser sind dort Attrappen (PATH): nichts wird wirklich gestartet. Braucht kein n8n und kein Netz.
# Usage:  .\scripts\dev\runtime_test.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$Container = $conn.Container

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { "$_" }) }
}

Write-Host ""
Write-Host "Betriebsart-Naht (Antwort-Datei, Wrapper systemd/compose, Telegram-Prüfung) — Container $Container"
Write-Host ("-" * 64)

$root = '/opt/runtime_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('tests\mock_runtime', 'mock_runtime'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/mock_runtime/cases.sh", $root)
$lines = @($r.Output)
foreach ($l in $lines) {
    if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
    elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
    elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
}
$passed = @($lines | Where-Object { $_ -match '^PASS ' }).Count
$failed = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
# Abbruch des Runners ohne FAIL-Zeile (Setup, Syntax) zaehlt als Fehler.
if ($r.Code -ne 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] cases.sh brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
if ($passed -eq 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] cases.sh lieferte keine Faelle" -ForegroundColor Red }
Invoke-Native docker @('exec', $Container, 'rm', '-rf', $root) | Out-Null

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "runtime_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "runtime_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
