#Requires -Version 5.1
# release_fetch_test.ps1 — deterministischer, gratis Test des Release-Downloads (immer anonym, oeffentliches Repo).
# Kopiert den Download-Code dieses Checkouts (provisioning/) + den GitHub-Mock (tests/mock_github/) in den laufenden
# Substrat-Container und faehrt dort tests/mock_github/cases.sh: provisioning/install.sh (Bootstrap) und
# lib/fetch_release.sh (`lifeagents update`) gegen den Mock (PROVISION_GH_API-Override, nur Test):
#   - latest + --version, nie ein Auth-Header (auch mit altem GH_TOKEN in der Env), Asset ueber den Redirect;
#   - Repo nicht oeffentlich / kein stabiles Release / falsches Tag: Klartext-Meldung, keine Frage;
#   - Abfragelimit, Netzfehler, nach den Headern abgebrochener Download (nicht "manipuliert"), manipuliertes Asset
#     (Abbruch vor dem Entpacken); Arbeitsverzeichnis nach Abbruch weg; drop_legacy_repo_token (Altbestand-Token);
#   - Release-Signatur: die Fake-Releases sind mit einem kurzlebigen Test-Schluessel signiert (LIFEAGENTS_RELEASE_KEYRING);
#     ohne Bund gilt das SHA256-Sidecar; der echte Projekt-Schluessel lehnt die Test-Unterschrift ab.
# Braucht kein n8n, kein Netz und keine enable_mock_*: nur den laufenden Container (bash, curl, jq, node, script).
# Usage:  .\scripts\dev\release_fetch_test.ps1 [-Port 8093] [-Verbose]   (belegt Port und Port+1; 8095-8099 + 8102/8103 = llm_gateway_test)
# Exit-Code = Anzahl Fehler.
param([int]$Port = 8093, [switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\test_n8n_state.ps1"
. "$PSScriptRoot\..\lib\test_common.ps1"
# classic: das Substrat; N8NTEST_RUNTIME=compose: Wegwerf-Container aus dem master-Abbild (kein laufender Verbund nötig).
# Das Abbild setzt LIFEAGENTS_RUNTIME=compose; die Fälle prüfen den klassischen Update-Weg (cases.sh setzt die Variable nicht selbst:
# im compose-Zweig verlangt `update` ein master-Image in der compose.yml des Releases), also läuft der Container wie das Substrat.
$target = Resolve-TestSuiteContainer -Suite 'release_fetch_test' -RepoRoot $RepoRoot -Env ([ordered]@{ LIFEAGENTS_RUNTIME = 'systemd' })
$Container = $target.Container

Write-Host ""
Write-Host "Release-Download (install.sh + lifeagents update) gegen Mock-GitHub — Container $Container"
Write-Host ("-" * 64)

try {
# Frischer Stand im Container: alten Test-Baum leeren (docker cp MERGT sonst), dann provisioning/ + Mock kopieren.
$root = '/opt/release_fetch_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('tests\mock_github', 'mock_github'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/mock_github/cases.sh", $root, "$Port")
} finally { Remove-TestSuiteScratch $target }
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

Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host "release_fetch_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "release_fetch_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
