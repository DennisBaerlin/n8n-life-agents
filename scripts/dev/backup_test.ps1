#Requires -Version 5.1
# backup_test.ps1 — GRATIS Ende-zu-Ende-Test von Notfallblatt und Schluessel-Uebernahme (lifeagents backup) gegen das
# echte PostgreSQL des laufenden Substrats. Kopiert provisioning/ + packages/ dieses Checkouts und den Fall-Runner
# (tests/backup/) in den Container und faehrt dort tests/backup/cases.sh mit der CLI dieses Baums:
#   - Export: Dateiname mit Schluessel-ID + Version, backup.state;
#   - Restore auf einem "neuen Rechner": ohne Eingabe, falscher Schluessel, Tippfehler, beschaedigte Datei, gescheiterte TX
#     -> nichts geaendert; mit Notfallblatt -> Daten da, Blatt-Schluessel aktiv, bisheriger als prev;
#   - backup key (Terminal/--file/stdout), Rueckweg nach Update, Leck-Probe (Ausgaben, /proc, tmpfs).
# Veraendert die Substrat-DB nur voruebergehend: core.backup_key steht danach wie vorher, die Nutzerdaten sind die eigene
# Sicherung (Restore derselben Daten). Braucht kein n8n-Aufruf, kein LLM, kein Netz.
# Usage:  .\scripts\dev\backup_test.ps1 [-Verbose]
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
Write-Host "Sicherung: Notfallblatt, Schlüssel-Übernahme, Leck-Probe — Container $Container"
Write-Host ("-" * 64)

$root = '/opt/backup_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root && chmod 0700 $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('packages', 'packages'), @('tests\backup', 'backup'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/backup/cases.sh", $root)
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
if ($failed -eq 0) { Write-Host "backup_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "backup_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed