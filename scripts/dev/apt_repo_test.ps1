#Requires -Version 5.1
# apt_repo_test.ps1 -- Test der frischen Debian-Maschine (Netz noetig, kein Substrat, kein n8n), je Fall-Datei ein eigener
# debian:12-Wegwerf-Container mit echtem apt:
#   tests/util/apt_repo/cases.sh             apt-Quellen des Installers (add_apt_key/add_apt_source, Tunnel-Schritt) ohne gnupg: kein
#                                       Schluessel-Fehler, keine Quelle ohne Schluesselbund (sonst bricht jedes spaetere apt-get update).
#   tests/util/apt_repo/first_step_cases.sh  der dokumentierte erste Schritt (Einzeiler im Kopf von provisioning/setup.sh) ohne curl.
# Usage:  $env:APT_TEST_CONTAINER = 'apt-probe'; .\scripts\dev\apt_repo_test.ps1 [-Verbose]
# Container: Name aus APT_TEST_CONTAINER (Standard apt-repo-test); ein vorhandener Container gleichen Namens wird vorher entfernt, am
# Ende jeder Datei wieder. Exit-Code = Anzahl Fehler.
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\..\lib\test_common.ps1"
$Container = if ($env:APT_TEST_CONTAINER) { $env:APT_TEST_CONTAINER } else { 'apt-repo-test' }
$Image = 'debian:12'

Write-Host ""
Write-Host "Frisches $Image -- Container $Container"
Write-Host ("-" * 64)

$passed = 0; $failed = 0
foreach ($caseFile in @('cases.sh', 'first_step_cases.sh')) {
    $r = $null
    try {
        Invoke-Native docker @('rm', '-fv', $Container) | Out-Null
        $r = Invoke-Native docker @('run', '-d', '--name', $Container, $Image, 'sleep', '3600')
        if ($r.Code -ne 0) { throw "Container nicht startbar: $($r.Output -join ' | ')" }
        $r = Invoke-Native docker @('exec', $Container, 'mkdir', '-p', '/opt/t', '/srv')
        foreach ($pair in @(@('provisioning', 'provisioning'), @('tests\util\apt_repo', 'apt_repo'))) {
            $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:/opt/t/$($pair[1])")
            if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
        }
        $r = Invoke-Native docker @('exec', $Container, 'bash', "/opt/t/apt_repo/$caseFile", '/opt/t')
    } finally {
        Invoke-Native docker @('rm', '-fv', $Container) | Out-Null
    }
    $lines = @($r.Output)
    foreach ($l in $lines) {
        if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
        elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
        elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
    }
    $p = @($lines | Where-Object { $_ -match '^PASS ' }).Count
    $f = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
    if ($r.Code -ne 0 -and $f -eq 0) { $f = 1; Write-Host "    [FAIL] $caseFile brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
    if ($p -eq 0 -and $f -eq 0) { $f = 1; Write-Host "    [FAIL] $caseFile lieferte keine Faelle" -ForegroundColor Red }
    $passed += $p; $failed += $f
}

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "apt_repo_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "apt_repo_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
