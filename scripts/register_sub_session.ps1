#Requires -Version 5.1
# Traegt eine von der Leitung gestartete Session ein: Sie kann den Owner danach nicht mehr direkt fragen, ihre Fragen laufen ueber
# die Leitung (Hook .claude/hooks/enforce_sub_session_questions.ps1, wirkt ab dem naechsten Tool-Aufruf dieser Session, sofern der
# Hook beim Start der Session schon im Stand ihres Checkouts lag).
# Die Leitung faehrt das direkt nach start_session. Die Liste liegt gitignored im Haupt-Checkout; -Clear leert sie am Sprint-Ende.
#
# Usage:  .\scripts\register_sub_session.ps1 -Id local_...
#         .\scripts\register_sub_session.ps1 -Clear
param(
    [string]$Id,
    [switch]$Clear
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$common = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
$file = Join-Path (Split-Path $common -Parent) '.claude\sub_sessions.txt'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($Clear) {
    if (Test-Path $file) { Remove-Item $file -Force }
    Write-Host 'Liste der Unter-Sessions geleert.' -ForegroundColor Green
    exit 0
}
if ($Id -notmatch '^local_[0-9a-f-]+$') { throw "Unerwartete Session-Kennung '$Id' (erwartet local_...)." }

$known = @()
if (Test-Path $file) { $known = @([System.IO.File]::ReadAllLines($file, $Utf8NoBom)) }
if ($known -notcontains $Id) { [System.IO.File]::WriteAllLines($file, [string[]]($known + $Id), $Utf8NoBom) }
Write-Host "Unter-Session eingetragen: $Id" -ForegroundColor Green
