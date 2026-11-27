#Requires -Version 5.1
# scheduled_task_check.ps1 -- prueft, ob jede geplante Aufgabe dieses Repos auf den gemeinsamen Schlussschritt
# verweist (docs/reference/sessions.md *Geplante Aufgaben*). Eine Aufgabe ist ein Ordner <TasksRoot>\<taskId> mit
# SKILL.md (Wrapper der Desktop-App); zum Repo gehoert sie, wenn ihr Text einen Pfad mit dem Ordnernamen des
# Haupt-Checkouts nennt (Pfadgrenze: ein Geschwister-Ordner <name>-alt zaehlt nicht).
# Befund je Aufgabe: kein Verweis auf _gemeinsam/schlussschritt.md, oder ein kopierter alter Meldeblock, erkannt an
# der Ueberschrift "Meldewege" oder an den Werkzeugnamen set_remote_control, PushNotification, set_unread (diese Wege
# scheitern in unbeaufsichtigten Laeufen). Liest nur, aendert nichts.
#
# Usage:  .\scripts\dev\scheduled_task_check.ps1 -TaskId <alle taskIds aus list_scheduled_tasks>
#         Ohne -TaskId zaehlt jeder Ordner, auch Einmal-Aufgaben ohne Zeitplan, die list_scheduled_tasks nicht mehr
#         zeigt. Fremde Aufgaben in -TaskId werden uebersprungen; eine taskId ohne Ordner ist ein Befund.
#         TasksRoot ist ~\.claude\scheduled-tasks; den Repo-Namen liefert git (rev-parse --git-common-dir, git im PATH).
#         (-TasksRoot/-RepoName nur fuer den Test: scripts/dev/scheduled_task_check_test.ps1)
# Exit-Code = Anzahl Befunde (eine fehlende _gemeinsam/schlussschritt.md zaehlt als einer); 255 = Skriptfehler.
param([string[]]$TaskId, [string]$TasksRoot, [string]$RepoName)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Exit 255 trennt einen Skriptfehler von der Befund-Anzahl; ungefangen gaebe er Exit 1, also einen scheinbaren Befund.
trap { Write-Host "FEHLER  $_" -ForegroundColor Red; exit 255 }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $TasksRoot) { $TasksRoot = Join-Path $env:USERPROFILE '.claude\scheduled-tasks' }
if (-not $RepoName) {
    # Haupt-Checkout auch aus einem Worktree: --git-common-dir zeigt auf <Haupt-Checkout>\.git.
    $common = (git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir).Trim()
    $RepoName = Split-Path -Leaf (Split-Path -Parent $common)
}
# powershell -File reicht "a,b,c" als einen String durch.
if ($TaskId) { $TaskId = @($TaskId | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$repoRx = '[\\/]' + [regex]::Escape($RepoName) + '(?![\w-])'
$oldRx = '(?m)^#+\s*Meldewege|set_remote_control|PushNotification|set_unread'

$bad = 0
if (-not (Test-Path (Join-Path $TasksRoot '_gemeinsam\schlussschritt.md'))) {
    Write-Host 'FEHLT  _gemeinsam\schlussschritt.md' -ForegroundColor Red; $bad++
}

$dirs = @(Get-ChildItem $TasksRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_gemeinsam' })
if ($TaskId) {
    foreach ($id in $TaskId) {
        if (-not (Test-Path (Join-Path $TasksRoot "$id\SKILL.md"))) { Write-Host "FEHLT  ${id}: kein Ordner mit SKILL.md" -ForegroundColor Red; $bad++ }
    }
    $dirs = @($dirs | Where-Object { $TaskId -contains $_.Name })
}
$checked = 0
foreach ($d in $dirs) {
    $file = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $file)) { continue }
    $text = [IO.File]::ReadAllText($file, $Utf8NoBom)
    if ($text -notmatch $repoRx) { continue }
    $checked++
    $problems = @()
    if ($text -notmatch '_gemeinsam[\\/]+schlussschritt\.md') { $problems += 'kein Verweis auf den Schlussschritt' }
    $old = @([regex]::Matches($text, $oldRx) | ForEach-Object { $_.Value.TrimStart('#', ' ') } | Select-Object -Unique)
    if ($old.Count) { $problems += "alter Meldeweg: $($old -join ', ')" }
    if ($problems) { Write-Host ('FEHLT  {0}: {1}' -f $d.Name, ($problems -join '; ')) -ForegroundColor Red; $bad++ }
    else { Write-Host ('ok     {0}' -f $d.Name) }
}
Write-Host ('{0} Aufgaben des Repos geprueft, {1} Befund(e).' -f $checked, $bad)
exit $bad
