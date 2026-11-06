#Requires -Version 5.1
# reachability_test.ps1 — DETERMINISTISCHER, GRATIS Test der Geraete-Erreichbarkeit (Installer + doctor, IPv4/IPv6).
# Kopiert provisioning/ DIESES Checkouts + den Mock (tests/mock_reach/) in den laufenden Substrat-Container und faehrt
# dort tests/mock_reach/cases.sh gegen den echten Lib-Code (common.sh, release_inputs.sh, owner_connect.sh):
#   - Domain-Normalisierung (https://, :443, Pfad, Rand-Leerzeichen, Schluss-Punkt) + Meldung bei anderem Port;
#   - Box-Namen-Regel <kennung>.myfritz.net (ohne Netz);
#   - Abruf je Adresse per --resolve gegen Mock-Gegenstellen (n8n / FRITZ!Box / fremder Dienst / aus / selbstsigniert);
#   - Einstufung fuer den Installer (Hairpin neutral, IPv6-Zertifikatsfehler = IPv6 woanders, Server ohne IPv6);
#   - Hinweis-Text (MyFRITZ!-Freigabe statt des alten Portfreigabe-Wegs), /etc/hosts-Pin aufraeumen, Check ohne TTY.
# Braucht kein n8n, kein Netz und keine enable_mock_*: nur den laufenden Container (bash, curl, node, openssl).
# Usage:  .\scripts\dev\reachability_test.ps1 [-Port 8084] [-Verbose]   (belegt Port und Port+1; 8086/8087 = update_chat)
# Exit-Code = Anzahl Fehler.
param([int]$Port = 8084, [switch]$Verbose)

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
Write-Host "Geräte-Erreichbarkeit (IPv4/IPv6, FritzBox-Falle) gegen Mock-Gegenstellen — Container $Container"
Write-Host ("-" * 64)

# Frischer Stand im Container: alten Test-Baum leeren (docker cp MERGT sonst), dann provisioning/ + Mock kopieren.
$root = '/opt/reachability_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('tests\mock_reach', 'mock_reach'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/mock_reach/cases.sh", $root, "$Port")
$lines = @($r.Output)
foreach ($l in $lines) {
    if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
    elseif ($l -match '^SKIP ') { Write-Host "    [SKIP] $($l.Substring(5))" -ForegroundColor Yellow }
    elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
    elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
}
$passed = @($lines | Where-Object { $_ -match '^PASS ' }).Count
$failed = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
# Abbruch des Runners ohne FAIL-Zeile (Setup, Syntax) zaehlt als Fehler.
if ($r.Code -ne 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] cases.sh brach ab (exit $($r.Code)): $($lines -join ' | ')" -ForegroundColor Red }
if ($passed -eq 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] cases.sh lieferte keine Faelle" -ForegroundColor Red }

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "reachability_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "reachability_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
