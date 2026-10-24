#Requires -Version 5.1
# Oeffnet das OWNER-FENSTER (Default 30 Min) fuer die Aktionen, die der PreToolUse-Hook
# .claude/hooks/enforce_owner_window.ps1 sonst hart blockt: die 5 LLM-kostenden Test-Suiten
# (n8n_test/orch_test/e2e_test/judge_eval/multiturn_test) und reset_dev_instance.ps1 (zerstoert die
# Dev-Instanz-Daten, kein Backup).
#
# MAKER-CHECKER: NUR der Owner fuehrt dieses Skript aus, im Terminal. Der Hook verweigert es Claude
# immer -- ein Hook-'ask' (Rueckfrage) wuerde in der VS-Code-Erweiterung still durchgewinkt, deshalb
# gibt es keinen Chat-Freigabe-Pfad mehr. 30 Min decken n8n_test + orch_test + einen -Id-Nachlauf
# eines flaky Cases bzw. eine Install-Test-Schleife mit /reset-dev.
#
# Usage:  .\scripts\grant_owner_window.ps1 [-Minutes 30]
param([int]$Minutes = 30)

$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$grant = Join-Path $RepoRoot '.claude\owner_grant.txt'

$until = [datetime]::UtcNow.AddMinutes($Minutes)
$body  = $until.ToString('o') + "`r`n# Owner-Fenster bis $($until.ToLocalTime().ToString('HH:mm:ss')) lokal; gesetzt $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
[System.IO.File]::WriteAllText($grant, $body, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Owner-Fenster offen fuer $Minutes Min (bis $($until.ToLocalTime().ToString('HH:mm:ss'))): LLM-Suiten + reset_dev_instance." -ForegroundColor Green
Write-Host "Datei: $grant (gitignored; der Hook loescht sie nach Ablauf selbst)." -ForegroundColor DarkGray
