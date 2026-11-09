#Requires -Version 5.1
# n8n_patch_test.ps1 — gratis Test der n8n-Korrektur hitl-chat-no-link-fallback gegen das im Substrat installierte n8n
# (tests/mock_n8n_patch/): Fingerabdruck und Status bei fremder Fassung, Wiederholung, Stopp statt Link-Knopf, chatApproval=false.
# Ein n8n-Pin-Wechsel ohne angepassten Patch wird hier rot. Braucht nur den laufenden Container.
# Usage:  .\scripts\dev\n8n_patch_test.ps1 [-Verbose]
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

$root = '/opt/n8n_patch_test'
$r = Invoke-Native docker @('exec', $Container, 'sh', '-c', "rm -rf $root && mkdir -p $root")
if ($r.Code -ne 0) { throw "Test-Verzeichnis im Container nicht anlegbar: $($r.Output -join ' | ')" }
foreach ($pair in @(@('provisioning', 'provisioning'), @('tests\mock_n8n_patch', 'mock_n8n_patch'))) {
    $r = Invoke-Native docker @('cp', (Join-Path $RepoRoot $pair[0]), "${Container}:$root/$($pair[1])")
    if ($r.Code -ne 0) { throw "docker cp $($pair[0]) fehlgeschlagen: $($r.Output -join ' | ')" }
}

$r = Invoke-Native docker @('exec', $Container, 'bash', "$root/mock_n8n_patch/cases.sh", $root)
foreach ($l in $r.Output) {
    if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
    elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
    elseif ($Verbose) { Write-Host "    $l" -ForegroundColor DarkGray }
}
$passed = @($r.Output | Where-Object { $_ -match '^PASS ' }).Count
$failed = @($r.Output | Where-Object { $_ -match '^FAIL ' }).Count
if ($failed -eq 0 -and ($r.Code -ne 0 -or $passed -eq 0)) { $failed = 1; Write-Host "    [FAIL] cases.sh brach ab (exit $($r.Code)): $($r.Output -join ' | ')" -ForegroundColor Red }

if ($failed -eq 0) { Write-Host "n8n_patch_test: OK ($passed Faelle)" -ForegroundColor Green }
else { Write-Host "n8n_patch_test: $failed Fehler ($passed ok)" -ForegroundColor Red }
exit $failed
