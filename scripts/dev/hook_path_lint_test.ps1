#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/hook_path_lint.ps1 in einem Wegwerf-Baum (-Root): ein relatives, ein nicht
# verankertes oder ein auf eine fehlende Datei zeigendes Hook-Kommando muss rot werden; verankerte Pfade und
# Kommandos ohne Skriptdatei gruen. Dazu der echte Baum: seine settings.json muss gruen sein. Kein Docker, kein git.
# Usage: .\scripts\dev\hook_path_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\hook_path_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')

# Eine settings.json mit genau einem Hook-Kommando; {ROOT} wird durch den Wegwerf-Baum ersetzt.
function New-Settings([string]$Command) {
    $json = @{ hooks = @{ PreToolUse = @(@{ matcher = 'Bash'; hooks = @(@{ type = 'command'; command = $Command }) }) } } | ConvertTo-Json -Depth 8
    return $json
}

function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText, [switch]$IncludeLocal) {
    $more = @(); if ($IncludeLocal) { $more += '-IncludeLocal' }
    Test-LintCase -Lint $lint -Name $Name -Files $Files -ExpectRed $ExpectRed -ExpectText $ExpectText -LintArgs $more
}

$H = '.claude/hooks/guard.ps1'
$S = '.claude/settings.json'
$L = '.claude/settings.local.json'
$ps = 'powershell -NoProfile -ExecutionPolicy Bypass -File'
$script = 'Write-Output ok'

Test-Case 'relativer Pfad ist rot' @{
    $S = New-Settings "$ps `"$H`""
    $H = $script
} $true 'settings.json'
Test-Case 'relativer Pfad mit ./ ist rot' @{
    $S = New-Settings "$ps `"./$H`""
    $H = $script
} $true 'nicht verankert'
Test-Case 'Pfad ueber CLAUDE_PROJECT_DIR mit vorhandener Datei ist gruen' @{
    $S = New-Settings "$ps `"`$CLAUDE_PROJECT_DIR/$H`""
    $H = $script
} $false ''
Test-Case 'Pfad ueber geschweifte CLAUDE_PROJECT_DIR ist gruen' @{
    $S = New-Settings "$ps `"`${CLAUDE_PROJECT_DIR}/$H`""
    $H = $script
} $false ''
Test-Case 'verankerter Pfad auf fehlende Datei ist rot' @{
    $S = New-Settings "$ps `"`$CLAUDE_PROJECT_DIR/.claude/hooks/missing.ps1`""
} $true 'existiert nicht'
Test-Case 'Kommando ohne Skriptdatei ist gruen' @{
    $S = New-Settings 'echo hallo'
} $false ''
Test-Case 'kaputtes JSON ist rot' @{
    $S = '{ "hooks": '
} $true 'kein gueltiges JSON'
Test-Case 'fehlende settings.json ist rot' @{
    'README.md' = 'x'
} $true 'fehlt'
Test-Case 'relativer Pfad in settings.local.json ist rot (mit -IncludeLocal)' @{
    $S = New-Settings "$ps `"`$CLAUDE_PROJECT_DIR/$H`""
    $L = New-Settings "$ps `"$H`""
    $H = $script
} $true 'settings.local.json' -IncludeLocal
Test-Case 'settings.local.json zaehlt ohne -IncludeLocal nicht (nicht getrackt)' @{
    $S = New-Settings "$ps `"`$CLAUDE_PROJECT_DIR/$H`""
    $L = New-Settings "$ps `"$H`""
    $H = $script
} $false ''

# Absoluter Pfad: der Baum-Pfad steht erst nach dem Anlegen fest, darum ein eigener Fall.
$root = New-TestTree @{ $H = $script }
try {
    $abs = (Join-Path $root $H).Replace('\', '/')
    [System.IO.File]::WriteAllText((Join-Path $root $S), (New-Settings "$ps `"$abs`""), $u8)
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root) -join "`n"
    if ($LASTEXITCODE -eq 0) { Write-Host '  PASS absoluter Pfad auf vorhandene Datei ist gruen' -ForegroundColor Green }
    else { Write-Host "  FAIL absoluter Pfad auf vorhandene Datei: $out" -ForegroundColor Red; $fails++ }
} finally { Remove-Item -Recurse -Force $root }

# Der echte Baum.
$real = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint) -join "`n"
if ($LASTEXITCODE -eq 0) { Write-Host '  PASS echte settings.json ist gruen' -ForegroundColor Green }
else { Write-Host "  FAIL echte settings.json: $real" -ForegroundColor Red; $fails++ }

if ($fails -eq 0) { Write-Host 'hook_path_lint_test: OK' -ForegroundColor Green }
else { Write-Host "hook_path_lint_test: $fails Fehler" -ForegroundColor Red }
exit $fails
