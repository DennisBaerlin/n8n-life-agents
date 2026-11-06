#Requires -Version 5.1
# Oeffnet das APP-FENSTER (Default 60 Min): solange darf Claude die Mini-App aendern, die der PreToolUse-Hook
# .claude/hooks/enforce_app_window.ps1 sonst hart sperrt (Owner-Regel 2026-11-01: die Darstellung ist immer ein eigener Plan).
# Getrennt vom Owner-Fenster der LLM-Suiten (grant_owner_window.ps1): Testkosten freizugeben ist keine Zustimmung zu einer
# App-Aenderung.
#
# MAKER-CHECKER: NUR der Owner fuehrt dieses Skript aus, im Terminal. Der Hook verweigert es Claude immer.
# Die Datei liegt immer im Haupt-Checkout, damit das Fenster auch fuer Sessions in einem Worktree gilt.
#
# Usage:  .\scripts\grant_app_window.ps1 [-Minutes 60]
param([int]$Minutes = 60)

$ErrorActionPreference = 'Stop'
$common = git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir
$grant = Join-Path (Split-Path $common -Parent) '.claude\app_grant.txt'

$until = [datetime]::UtcNow.AddMinutes($Minutes)
$body  = $until.ToString('o') + "`r`n# App-Fenster bis $($until.ToLocalTime().ToString('HH:mm:ss')) lokal; gesetzt $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
[System.IO.File]::WriteAllText($grant, $body, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "App-Fenster offen fuer $Minutes Min (bis $($until.ToLocalTime().ToString('HH:mm:ss'))): Claude darf die Mini-App aendern." -ForegroundColor Green
Write-Host "Datei: $grant (gitignored; der Hook loescht sie nach Ablauf selbst)." -ForegroundColor DarkGray
