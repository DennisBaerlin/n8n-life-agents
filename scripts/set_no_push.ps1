#Requires -Version 5.1
# Schaltet die Push-Sperre fuer Claude-Sessions (Hook .claude/hooks/enforce_no_push.ps1). Setzen (-On) darf die Leitung, aufheben
# (-Off) nur der Owner selbst im Terminal; der Hook verweigert es Claude. Die Datei liegt gitignored im Haupt-Checkout.
# Ein Push des Owners im Terminal ist von der Sperre nie betroffen.
#
# Usage:  .\scripts\set_no_push.ps1 -On
#         .\scripts\set_no_push.ps1 -Off
param(
    [switch]$On,
    [switch]$Off
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if ($On -eq $Off) { throw 'Genau einen Schalter angeben: -On oder -Off.' }
$common = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
$file = Join-Path (Split-Path $common -Parent) '.claude\no_push.txt'

if ($On) {
    $body = "Push-Sperre seit $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Push-Sperre aktiv: Claude-Sessions pushen nichts nach GitHub.' -ForegroundColor Green
} else {
    if (Test-Path $file) { Remove-Item $file -Force }
    Write-Host 'Push-Sperre aufgehoben.' -ForegroundColor Green
}
