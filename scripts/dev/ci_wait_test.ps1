#Requires -Version 5.1
# Urteil des Warte-Modus von scripts/check_ci_status.ps1 (-Wait) an erfundenen Lauf-Listen: gruen, rot, laeuft noch,
# kein Lauf fuer den Stand, neuer Anlauf nach rotem Lauf, grosse Lauf-Nummer bleibt ganzzahlig; dazu die Ampel ohne -Wait
# (Get-CiLatestMainRuns: juengster Lauf je Workflow-Datei auf main). Kein Netz, kein Token.
# Usage: .\scripts\dev\ci_wait_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\ci_wait.ps1')
$fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Got) {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green } else { Write-Host "  FAIL $Name ($Got)" -ForegroundColor Red; $script:fails++ }
}
function Run([string]$Name, [string]$Sha, [string]$Status, [string]$Conclusion, [string]$Created, [long]$Id = 1) {
    return [pscustomobject]@{ name = $Name; path = ".github/workflows/$Name.yml"; head_sha = $Sha; status = $Status
        conclusion = $Conclusion; created_at = $Created; id = $Id; html_url = "https://example.invalid/runs/$Id" }
}
$sha = 'aaaaaaa1111111111111111111111111111111111'
$other = 'bbbbbbb2222222222222222222222222222222222'

$v = Get-CiWaitVerdict -Runs @(Run 'genericity' $sha 'completed' 'success' '2026-01-01T10:00:00Z') -Workflow 'genericity' -Sha 'aaaaaaa'
Check 'abgeschlossen + success = green' ($v.verdict -eq 'green') $v.verdict
$v = Get-CiWaitVerdict -Runs @(Run 'genericity' $sha 'completed' 'failure' '2026-01-01T10:00:00Z') -Workflow 'genericity' -Sha $sha
Check 'abgeschlossen + failure = red' ($v.verdict -eq 'red') $v.verdict
$v = Get-CiWaitVerdict -Runs @(Run 'genericity' $sha 'completed' 'cancelled' '2026-01-01T10:00:00Z') -Workflow 'genericity' -Sha $sha
Check 'abgebrochen = red' ($v.verdict -eq 'red') $v.verdict
foreach ($end in 'skipped', 'neutral', 'timed_out') {
    $v = Get-CiWaitVerdict -Runs @(Run 'ci' $sha 'completed' $end '2026-01-01T10:00:00Z') -Workflow 'ci' -Sha $sha
    Check "abgeschlossen + $end = red (gruen ist nur success: ein uebersprungener Lauf hat nichts geprueft)" ($v.verdict -eq 'red') $v.verdict
}
$v = Get-CiWaitVerdict -Runs @(Run 'genericity' $sha 'in_progress' '' '2026-01-01T10:00:00Z') -Workflow 'genericity' -Sha $sha
Check 'laeuft noch = pending' ($v.verdict -eq 'pending') $v.verdict
$v = Get-CiWaitVerdict -Runs @(Run 'genericity' $other 'completed' 'success' '2026-01-01T10:00:00Z') -Workflow 'genericity' -Sha $sha
Check 'Lauf nur auf anderem Stand = none' ($v.verdict -eq 'none') $v.verdict
$v = Get-CiWaitVerdict -Runs @(Run 'ci' $sha 'completed' 'success' '2026-01-01T10:00:00Z') -Workflow 'genericity' -Sha $sha
Check 'anderer Workflow zaehlt nicht' ($v.verdict -eq 'none') $v.verdict
$v = Get-CiWaitVerdict -Runs @(
    (Run 'release' $sha 'completed' 'failure' '2026-01-01T10:00:00Z' 5),
    (Run 'release' $sha 'queued' '' '2026-01-01T11:00:00Z' 6)) -Workflow 'release' -Sha $sha
Check 'juengster Lauf entscheidet (neuer Anlauf laeuft)' ($v.verdict -eq 'pending' -and $v.run.id -eq 6) "$($v.verdict) $($v.run.id)"
$v = Get-CiWaitVerdict -Runs @(Run 'ci' $sha 'completed' 'success' '2026-01-01T10:00:00Z' 19876543210) -Workflow 'ci' -Sha $sha
Check 'Lauf-Nummer bleibt ganzzahlig im Text' ((Format-CiWaitLine $v) -match '19876543210' -and (Format-CiWaitLine $v) -notmatch 'E\+') (Format-CiWaitLine $v)
$v = Get-CiWaitVerdict -Runs @() -Workflow 'ci' -Sha $sha
Check 'leere Liste = none' ($v.verdict -eq 'none') $v.verdict
Check 'Exit-Code: green 0, red 1, alles andere 2' ((Get-CiWaitExitCode 'green') -eq 0 -and (Get-CiWaitExitCode 'red') -eq 1 -and (Get-CiWaitExitCode 'pending') -eq 2 -and (Get-CiWaitExitCode 'none') -eq 2) ''
# Handstart mit Suiten-Auswahl (run-name traegt den Merker): prueft nicht den ganzen Stand, zaehlt nie.
$part = Run 'free-gates' $sha 'completed' 'success' '2026-01-01T12:00:00Z' 7
$part | Add-Member display_title 'free-gates [Auswahl] backup'; $part | Add-Member event 'workflow_dispatch'
$v = Get-CiWaitVerdict -Runs @($part) -Workflow 'free-gates' -Sha $sha
Check 'nur ein gruener Auswahl-Lauf = none' ($v.verdict -eq 'none') $v.verdict
$v = Get-CiWaitVerdict -Runs @((Run 'free-gates' $sha 'completed' 'failure' '2026-01-01T10:00:00Z' 3), $part) -Workflow 'free-gates' -Sha $sha
Check 'juengerer Auswahl-Lauf ueberdeckt den vollen roten nicht' ($v.verdict -eq 'red' -and $v.run.id -eq 3) "$($v.verdict) $($v.run.id)"
$pr = Run 'free-gates' $sha 'completed' 'success' '2026-01-01T12:00:00Z' 8
$pr | Add-Member display_title 'free-gates [Auswahl] im Titel eines PR'; $pr | Add-Member event 'pull_request'
$v = Get-CiWaitVerdict -Runs @($pr) -Workflow 'free-gates' -Sha $sha
Check 'Merker im Titel eines PR-Laufs: voller Lauf' ($v.verdict -eq 'green') $v.verdict

# Ampel (ohne -Wait): je Workflow-Datei der juengste abgeschlossene Lauf auf main. Mit run-name im Workflow traegt das Feld name den
# Titel des Laufs (bei free-gates die Commit-Message): gruppiert wird darum nach der Datei.
function MainRun([string]$Wf, [string]$Name, [string]$Conclusion, [string]$Created, [string]$Branch = 'main') {
    $r = Run $Wf $sha 'completed' $Conclusion $Created; $r.name = $Name; $r | Add-Member head_branch $Branch; return $r
}
# PR eines Forks aus dessen eigenem main: head_branch ist ebenfalls main, der Lauf gehoert aber nicht zum Stand von main.
$forkPr = MainRun 'ci' 'ci' 'failure' '2026-01-01T15:00:00Z'; $forkPr | Add-Member event 'pull_request'
$rows = @(Get-CiLatestMainRuns @(
        (MainRun 'free-gates' 'free-gates' 'success' '2026-01-01T10:00:00Z'),
        (MainRun 'free-gates' 'fix: etwas am Installer' 'failure' '2026-01-01T12:00:00Z'),
        (MainRun 'ci' 'ci' 'success' '2026-01-01T12:00:00Z'),
        (MainRun 'ci' 'ci' 'failure' '2026-01-01T13:00:00Z' 'feat/x'),
        (MainRun 'release' 'release' 'failure' '2026-01-01T09:00:00Z' 'v1.2.3'),
        (MainRun 'release' 'release' 'success' '2026-01-01T14:00:00Z' 'feat/x'),
        $forkPr))
$fg = @($rows | Where-Object { $_.Workflow -eq 'free-gates' })
Check 'Ampel: Lauf mit eigenem Titel zaehlt zu seinem Workflow (juengster free-gates-Lauf ist rot)' ($fg.Count -eq 1 -and -not $fg[0].Ok) "$($fg.Count) $($fg.Ok)"
Check 'Ampel: je Workflow-Datei genau eine Zeile' ($rows.Count -eq 3) (($rows | ForEach-Object { $_.Workflow }) -join ',')
Check 'Ampel: Branch-Lauf und PR-Lauf eines Forks zaehlen nicht fuer main' (@($rows | Where-Object { $_.Workflow -eq 'ci' })[0].Ok) ''
Check 'Ampel: release zaehlt auf dem Tag, nicht auf einem Branch' (-not @($rows | Where-Object { $_.Workflow -eq 'release' })[0].Ok) ''

if ($fails -eq 0) { Write-Host 'PASS ci_wait_test' -ForegroundColor Green } else { Write-Host "ci_wait_test: $fails Fehler" -ForegroundColor Red }
exit $fails
