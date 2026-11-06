#Requires -Version 5.1
# Traegt die Session, aus der dieses Skript laeuft, als Leit-Session des Status-Panels ein (.claude/mods/status-panel).
# Das Panel laeuft nur dort (Owner-Entscheidung); jede andere Session laesst es still und startet weder Docker noch die CI-Abfrage.
#
# Claude faehrt das Skript in der Leit-Session selbst: die Kennung kommt aus der Umgebung dieser Session, nie aus dem Repo.
# Die Datei liegt immer im Haupt-Checkout (gitignored). Eine neue Leit-Session ueberschreibt sie mit einem neuen Aufruf.
#
# Usage:  .\scripts\set_status_panel_home.ps1

$ErrorActionPreference = 'Stop'
$id = $env:CLAUDE_CODE_HOST_SESSION_ID
if (-not $id) { throw 'CLAUDE_CODE_HOST_SESSION_ID fehlt: das Skript muss aus einer Session der Desktop-App laufen.' }

$common = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
$file = Join-Path (Split-Path $common -Parent) '.claude\status_panel_home.txt'

$body = $id + "`r`n# Status-Panel laeuft in dieser Session; gesetzt $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
[System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Status-Panel eingetragen fuer $id." -ForegroundColor Green
Write-Host "Datei: $file (gitignored). Wirkt beim naechsten Start dieser Session oder per /status-panel." -ForegroundColor DarkGray