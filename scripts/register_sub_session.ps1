#Requires -Version 5.1
# Traegt Sessions fuer die Leitungs-Hooks ein. Beide Dateien liegen gitignored im Haupt-Checkout; -Clear loescht beide am Sprint-Ende.
# Die Hooks wirken ab dem naechsten Tool-Aufruf der betroffenen Session, sofern sie beim Start der Session schon im Stand ihres
# Checkouts lagen.
#   -Id      Unter-Session (direkt nach start_session): fragt den Owner danach nicht mehr direkt, ihre Fragen laufen ueber die
#            Leitung (Hook .claude/hooks/enforce_sub_session_questions.ps1). Der erste Eintrag gibt der Leitung Unteragenten frei.
#   -Lead    die aufrufende Session ist Leitung (Kennung aus CLAUDE_CODE_HOST_SESSION_ID): Bis zur ersten Unter-Session sperrt
#            .claude/hooks/enforce_lead_start_first.ps1 ihre Unteragenten, weil deren Meldung jeden start_session blockiert.
#   -NoStarts  Sprint ohne Unter-Sessions: gibt der Leitung Unteragenten frei.
#
# Usage:  .\scripts\register_sub_session.ps1 -Lead
#         .\scripts\register_sub_session.ps1 -Id local_...
#         .\scripts\register_sub_session.ps1 -NoStarts
#         .\scripts\register_sub_session.ps1 -Clear
param(
    [string]$Id,
    [switch]$Lead,
    [switch]$NoStarts,
    [switch]$Clear
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$common = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
$dir = Join-Path (Split-Path $common -Parent) '.claude'
$file = Join-Path $dir 'sub_sessions.txt'
$leadFile = Join-Path $dir 'lead_session.txt'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($Clear) {
    foreach ($f in $file, $leadFile) { if (Test-Path $f) { Remove-Item $f -Force } }
    Write-Host 'Unter-Sessions und Leitung ausgetragen.' -ForegroundColor Green
    exit 0
}
if ($Lead) {
    $self = $env:CLAUDE_CODE_HOST_SESSION_ID
    if ($self -notmatch '^local_[0-9a-f-]+$') { throw "Keine Session-Kennung in CLAUDE_CODE_HOST_SESSION_ID ('$self'); nur aus einer Claude-Session aufrufen." }
    [System.IO.File]::WriteAllLines($leadFile, [string[]]@($self), $Utf8NoBom)
    Write-Host "Leitung eingetragen: $self" -ForegroundColor Green
    exit 0
}
if ($NoStarts) {
    if (-not (Test-Path $leadFile)) { throw 'Keine Leitung eingetragen (erst -Lead).' }
    $lines = @([System.IO.File]::ReadAllLines($leadFile, $Utf8NoBom))
    if ($lines -notcontains 'no-starts') { [System.IO.File]::WriteAllLines($leadFile, [string[]]($lines + 'no-starts'), $Utf8NoBom) }
    Write-Host 'Leitung ohne Unter-Sessions: Unteragenten frei.' -ForegroundColor Green
    exit 0
}
if ($Id -notmatch '^local_[0-9a-f-]+$') { throw "Unerwartete Session-Kennung '$Id' (erwartet local_...)." }

$known = @()
if (Test-Path $file) { $known = @([System.IO.File]::ReadAllLines($file, $Utf8NoBom)) }
if ($known -notcontains $Id) { [System.IO.File]::WriteAllLines($file, [string[]]($known + $Id), $Utf8NoBom) }
Write-Host "Unter-Session eingetragen: $Id" -ForegroundColor Green
