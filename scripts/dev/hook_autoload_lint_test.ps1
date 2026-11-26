#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/hook_autoload_lint.ps1 in einem Wegwerf-Baum (-Root): ein Befehl, den Windows PowerShell 5.1 per Autoload holt
# (Get-FileHash, Expand-Archive, ...), muss im Hook-Skript und in einem von ihm eingebundenen Skript rot werden; ein Kommentar, eine Zeichenkette,
# ein Skript ausserhalb des Hook-Umfelds und die Ausnahme gruen. Kein Docker, kein git.
# Usage: .\scripts\dev\hook_autoload_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle. Nur in Windows PowerShell 5.1 (wie die Pruefung).
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if ($PSVersionTable.PSEdition -ne 'Desktop') { Write-Host 'hook_autoload_lint_test: [skip] nur in Windows PowerShell 5.1' -ForegroundColor DarkGray; exit 0 }
$lint = Join-Path $PSScriptRoot '..\hook_autoload_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText, [string]$ModulePath = '') {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('hal_' + [guid]::NewGuid().ToString('N'))
    try {
        foreach ($rel in $Files.Keys) {
            $p = Join-Path $root $rel
            New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
            [System.IO.File]::WriteAllText($p, $Files[$rel], $u8)
        }
        $savedMp = $env:PSModulePath; if ($ModulePath) { $env:PSModulePath = $ModulePath }
        try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root) -join "`n" } finally { $env:PSModulePath = $savedMp }
        $red = $LASTEXITCODE -ne 0
        $ok = ($red -eq $ExpectRed) -and (-not $ExpectText -or $out -match [regex]::Escape($ExpectText))
        if ($ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL $Name (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $script:fails++ }
    } finally { if (Test-Path $root) { Remove-Item -Recurse -Force $root } }
}

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$cfg = '.pre-commit-config.yaml'
$D = 'scripts'
$S = "$D/dev/neu.ps1"
$hook = "- id: x`n  entry: powershell -NoProfile -File $S`n"
$S2 = "$D/neu2.ps1"   # liegt direkt in scripts: dort ist "$PSScriptRoot\lib\x.ps1" die uebliche Einbindung, ohne ..
$hook2 = "- id: y`n  entry: powershell -NoProfile -File $S2`n"
Test-Case 'Get-FileHash im Hook-Skript ist rot' @{ $cfg = $hook; $S = "`$h = (Get-FileHash `$f).Hash`n" } $true 'Get-FileSha256'
Test-Case 'Expand-Archive im Hook-Skript ist rot (nicht nur ein Name)' @{ $cfg = $hook; $S = "Expand-Archive -Path a -DestinationPath b`n" } $true 'Expand-Archive'
Test-Case 'Get-FileHash in einem eingebundenen Skript ist rot' @{ $cfg = $hook; $S = ". (Join-Path `$PSScriptRoot '..\lib\hilfe.ps1')`n"; "$D/lib/hilfe.ps1" = "function H { Get-FileHash x }`n" } $true 'hilfe.ps1'
Test-Case 'Einbindung in Anfuehrungszeichen mit $PSScriptRoot (ohne ..) wird verfolgt' @{ $cfg = $hook2; $S2 = ". `"`$PSScriptRoot\lib\hilfe.ps1`"`n"; "$D/lib/hilfe.ps1" = "function H { Get-FileHash x }`n" } $true 'hilfe.ps1'
Test-Case 'zweite Stufe der Einbindung wird verfolgt' @{ $cfg = $hook2; $S2 = ". `"`$PSScriptRoot\lib\a.ps1`"`n"; "$D/lib/a.ps1" = ". (Join-Path `$PSScriptRoot 'b.ps1')`n"; "$D/lib/b.ps1" = "Get-FileHash x`n" } $true 'b.ps1'
Test-Case 'Get-FileHash bleibt rot, wenn der PSModulePath fremd ist (wie unter pwsh 7)' @{ $cfg = $hook; $S = "Get-FileHash x`n" } $true 'Get-FileHash' 'C:\gibt-es-nicht\Modules'
Test-Case 'eigene Funktion gleichen Namens ist gruen' @{ $cfg = $hook; $S = "function Get-FileHash { 'x' }`nGet-FileHash a`n" } $false ''
Test-Case 'Kommentar und Zeichenkette sind gruen' @{ $cfg = $hook; $S = "# Get-FileHash ist hier verboten`n`$t = 'Get-FileHash'`n" } $false ''
Test-Case 'eingebauter Befehl ist gruen' @{ $cfg = $hook; $S = "`$x = Select-String -Path a -Pattern b | ConvertTo-Json`n" } $false ''
Test-Case 'Skript ausserhalb des Hook-Umfelds ist gruen' @{ $cfg = $hook; $S = "`$x = 1`n"; "$D/andere.ps1" = "Get-FileHash x`n" } $false ''
Test-Case 'Ausnahme mit Grund ist gruen' @{ $cfg = $hook; $S = "Get-FileHash x   # hook-autoload: ok nur im 7er-Host`n" } $false ''
Test-Case 'Ausnahme ohne Grund ist rot' @{ $cfg = $hook; $S = "Get-FileHash x   # hook-autoload: ok`n" } $true 'Get-FileHash'

if ($fails -eq 0) { Write-Host 'PASS hook_autoload_lint_test' -ForegroundColor Green } else { Write-Host "FAIL hook_autoload_lint_test ($fails)" -ForegroundColor Red }
exit $fails
