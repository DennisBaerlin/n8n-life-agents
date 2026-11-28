#Requires -Version 5.1
# runtime_test.ps1 — deterministischer, gratis Test der Betriebsart-Naht des Installers (systemd | Docker-Verbund).
# Kopiert provisioning/ dieses Checkouts, den Fall-Runner (tests/mock_runtime/) und seine Daten (core-Locales, Paket-Manifeste,
# tests/mock_llm, tests/backup) in den laufenden Substrat-Container und
# faehrt dort tests/mock_runtime/cases.sh gegen den echten Lib-Code (common.sh -> runtime.sh, release_inputs.sh):
#   - Antwort-Datei fuer --unattended wird gelesen, nie ausgefuehrt ('…', $(), Backticks, Zeilenumbruch, gesperrte Schluessel);
#   - Wrapper: systemd-Zweig = runuser/systemctl-Aufrufe, compose-Zweig = docker exec mit festem Container
#     (stdin nur, wenn psql liest), Compose-Aufrufe nur mit festem Projekt; Volumes nur mit eigenem Label;
#   - Telegram-Pruefung vor der Aktivierung (frei / eigener / fremder Webhook / Long-Polling / nicht pruefbar);
#   - Daten-Seed (tests/mock_runtime/seed_pipe_cases.sh): keine Pipe mit fruehem Leser, die unter pipefail mit 141 abbricht.
#   - Daten-Seed (tests/mock_runtime/seed_cron_disable_cases.sh): der Install-Schalter CRON_DISABLE der Test-Installationen.
# docker, systemctl und runuser sind dort Attrappen (PATH): nichts wird wirklich gestartet. Braucht kein n8n und kein Netz.
# N8NTEST_RUNTIME=compose: statt des Substrats ein Wegwerf-Container aus dem master-Abbild des Arbeitsstands (baut das Abbild;
# $env:N8NTEST_CONTAINER = eigener Projektname ist Pflicht; Container am Ende abgebaut).
# Usage:  .\scripts\dev\runtime_test.ps1 [-Verbose]
# Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\test_n8n_state.ps1"
. "$PSScriptRoot\..\lib\test_common.ps1"
# classic: das Substrat; N8NTEST_RUNTIME=compose: Wegwerf-Container aus dem master-Abbild (kein laufender Verbund nötig).
$target = Resolve-TestSuiteContainer -Suite 'runtime_test' -RepoRoot $RepoRoot
$Container = $target.Container

Write-Host ""
Write-Host "Betriebsart-Naht (Antwort-Datei, Wrapper systemd/compose, Telegram-Prüfung) + Daten-Seed ohne Pipe-Abbruch — Container $Container"
Write-Host ("-" * 64)

$passed = 0; $failed = 0
try {
$root = '/opt/runtime_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root/packages/core $root/tests")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
# tests/mock_llm = die echte KI-Attrappe fuer den Fall L.echter-weg; die Paket-Manifeste lesen die Paket-Fragen und -Antworten (Faelle P.*).
$manifestPairs = @()
foreach ($d in Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory) {
    if ($d.Name -eq 'core' -or -not (Test-Path (Join-Path $d.FullName 'manifest.json'))) { continue }
    $r = Invoke-Native docker @('exec', $Container, 'mkdir', '-p', "$root/packages/$($d.Name)")
    if ($r.Code -ne 0) { throw "Paket-Verzeichnis $($d.Name) nicht anlegbar: $($r.Output -join ' | ')" }
    $manifestPairs += , @("packages\$($d.Name)\manifest.json", "packages/$($d.Name)/manifest.json")
}
# tests/backup: altes Notfallblatt (fixtures/) und sein Erzeuger old_sheet_lib.sh fuer die Schluessel-Faelle B.*.
foreach ($pair in (@(@('provisioning', 'provisioning'), @('packages\core\locales', 'packages/core/locales'), @('tests\mock_llm', 'tests/mock_llm'), @('tests\mock_runtime', 'mock_runtime'), @('tests\backup', 'backup')) + $manifestPairs)) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

# cases.sh = die Betriebsart-Naht; seed_pipe_cases.sh = der Daten-Seed bricht an keiner Pipe mit fruehem Leser ab (141).
foreach ($caseFile in @('cases.sh', 'seed_pipe_cases.sh', 'seed_cron_disable_cases.sh')) {
    $r = Invoke-Native docker @('exec', $Container, 'bash', "$root/mock_runtime/$caseFile", $root)
    $lines = @($r.Output)
    foreach ($l in $lines) {
        if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
        elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
        elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
    }
    $p = @($lines | Where-Object { $_ -match '^PASS ' }).Count
    $f = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
    # Abbruch des Runners ohne FAIL-Zeile (Setup, Syntax) zaehlt als Fehler.
    if ($r.Code -ne 0 -and $f -eq 0) { $f = 1; Write-Host "    [FAIL] $caseFile brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
    if ($p -eq 0 -and $f -eq 0) { $f = 1; Write-Host "    [FAIL] $caseFile lieferte keine Faelle" -ForegroundColor Red }
    $passed += $p; $failed += $f
}
Invoke-Native docker @('exec', $Container, 'rm', '-rf', $root) | Out-Null
} finally { Remove-TestSuiteScratch $target }

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "runtime_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "runtime_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
