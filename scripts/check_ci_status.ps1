#Requires -Version 5.1
# check_ci_status.ps1 — CI-Ampel: ist der letzte Lauf jedes GitHub-Workflows auf main (Release: der letzte Tag-Lauf)
# gruen? Ein Handstart mit Suiten-Auswahl zaehlt nicht (Test-CiPartialRun, scripts/lib/ci_wait.ps1). Genutzt vom
# SessionStart-Hook .claude/hooks/check_ci_status.ps1 (-Hook: knapper Kontext-Text, still bei gruen/Fehler) und manuell. Read-only gegen die GitHub-API; Token aus dem Git-Credential-Store (GCM,
# derselbe Weg wie git push), nie interaktiv. Exit-Code ohne -Wait = Anzahl roter Workflows (Fehler beim Abfragen -> 0 + Hinweis).
#
# -Wait <workflow> wartet auf den Lauf dieses Workflows auf einem Stand (-Sha, sonst HEAD) und endet laut: Exit 0 gruen,
# 1 rot, 2 nicht entschieden (Zeitgrenze -TimeoutMin, kein Lauf nach 10 Minuten, GitHub mehrfach nicht abrufbar). Als
# Hintergrund-Befehl gedacht: das Ende weckt die wartende Session, auch bei Gruen.
#
# Usage:  .\scripts\check_ci_status.ps1 [-Hook]
#         .\scripts\check_ci_status.ps1 -Wait genericity [-Sha <hash>] [-TimeoutMin 90] [-PollSeconds 30]
param([switch]$Hook, [string]$Wait, [string]$Sha, [int]$TimeoutMin = 90, [int]$PollSeconds = 30)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'lib\ci_wait.ps1')
. (Join-Path $PSScriptRoot 'lib\github_runs.ps1')

if ($Wait) {
    if (-not $Sha) { $Sha = 'HEAD' }
    # Voller Hash: der API-Filter head_sha kennt keine Kurzform, und ohne Filter faellt ein aelterer Lauf aus der Liste.
    $full = git -C $PSScriptRoot rev-parse --verify --quiet "$Sha^{commit}"
    if ($LASTEXITCODE -ne 0 -or -not $full) { Write-Host "NICHT ENTSCHIEDEN: Stand '$Sha' ist in diesem Checkout unbekannt (git fetch?)" -ForegroundColor Yellow; exit 2 }
    $Sha = "$full".Trim()
    $start = Get-Date; $errors = 0; $last = ''
    Write-Host "Warte auf '$Wait' fuer $($Sha.Substring(0, [Math]::Min(7, $Sha.Length))) (hoechstens $TimeoutMin min)"
    while ($true) {
        $v = $null
        try { $v = Get-CiWaitVerdict -Runs @(Get-WorkflowRuns "per_page=100&head_sha=$Sha") -Workflow $Wait -Sha $Sha; $errors = 0 }
        catch {
            $errors++
            if ($errors -ge 5) { Write-Host "NICHT ENTSCHIEDEN: GitHub fuenfmal nicht abrufbar ($($_.Exception.Message))" -ForegroundColor Yellow; exit 2 }
        }
        if ($v) {
            $line = Format-CiWaitLine $v
            if ($line -ne $last) { Write-Host $line; $last = $line }
            if ($v.verdict -eq 'green') { Write-Host "GRUEN: $Wait" -ForegroundColor Green; exit (Get-CiWaitExitCode $v.verdict) }
            if ($v.verdict -eq 'red') { Write-Host "ROT: $Wait (Logs: gh run view $(([long]$v.run.id).ToString()) --log-failed)" -ForegroundColor Red; exit (Get-CiWaitExitCode $v.verdict) }
            if ($v.verdict -eq 'none' -and ((Get-Date) - $start).TotalMinutes -ge 10) {
                Write-Host "NICHT ENTSCHIEDEN: nach 10 Minuten kein Lauf von '$Wait' auf diesem Stand (Name oder Hash falsch, oder der Workflow laeuft hier nicht von selbst; ein Handstart mit Suiten-Auswahl zaehlt nie als Lauf des Stands)" -ForegroundColor Yellow; exit 2
            }
        }
        if (((Get-Date) - $start).TotalMinutes -ge $TimeoutMin) { Write-Host "NICHT ENTSCHIEDEN: Zeitgrenze $TimeoutMin min erreicht, letzter Stand: $last" -ForegroundColor Yellow; exit 2 }
        Start-Sleep -Seconds $PollSeconds
    }
}

try {
    # Gezielt statt "die juengsten Laeufe aller Branches": in einer gemischten Liste verdraengen Branch- und PR-Laeufe den letzten
    # main-Lauf eines Workflows, und ein roter Stand fiele still aus der Ampel. Release-Laeufe haengen am Tag, darum eigens.
    $runs = @(Get-WorkflowRuns 'per_page=100&branch=main')
} catch {
    if (-not $Hook) { Write-Host "CI-Status nicht abrufbar: $($_.Exception.Message)" -ForegroundColor Yellow }
    exit 0
}
# Eigener Versuch: scheitert nur der Release-Abruf (Zeitgrenze, Datei umbenannt), bleibt das Ergebnis fuer main stehen.
try { $runs += @(Get-WorkflowRuns 'per_page=20' -Workflow 'release.yml') }
catch { if (-not $Hook) { Write-Host "Release-Laeufe nicht abrufbar: $($_.Exception.Message)" -ForegroundColor Yellow } }

# Je Workflow-Datei der juengste abgeschlossene Lauf (Get-CiLatestMainRuns; ohne Dependabot-Hintergrundlaeufe, die keine Datei haben).
$red = @()
foreach ($row in @(Get-CiLatestMainRuns $runs)) {
    $latest = $row.Run
    $title = ("$($latest.display_title)" -split "`r?`n")[0]   # ein Lauf-Titel aus der Commit-Message kann mehrzeilig sein
    if (-not $Hook) {
        $c = if ($row.Ok) { 'Green' } else { 'Red' }
        Write-Host ("{0,-18} {1,-9} {2} {3}  {4}" -f $row.Workflow, $latest.conclusion, $latest.head_sha.Substring(0, 7), ([datetime]$latest.created_at).ToLocalTime().ToString('dd.MM. HH:mm'), $title) -ForegroundColor $c
    }
    if (-not $row.Ok) { $red += [pscustomobject]@{ Workflow = $row.Workflow; Run = $latest; Title = $title } }
}

if ($Hook -and $red.Count) {
    $parts = $red | ForEach-Object { "$($_.Workflow) ($($_.Run.conclusion), $($_.Run.head_sha.Substring(0,7)) '$($_.Title)', Run $(([long]$_.Run.id).ToString()))" }
    $ctx = 'CI ROT auf GitHub: ' + ($parts -join '; ') + '. Zuerst die Ursache klaeren und beheben, bevor neue Arbeit gepusht wird ' +
           '(Logs: gh run view <Run> --log-failed, GH_TOKEN aus git credential fill). Dem Owner in einem Satz melden.'
    Write-Output (@{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5)
}
exit $red.Count
