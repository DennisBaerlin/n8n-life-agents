#Requires -Version 5.1
# main_push_guard.ps1 -- Sperre fuer den Push auf main: Der Stand braucht einen gruenen GitHub-Lauf jedes Workflows
# (ci, free-gates, genericity), den dieser Push auf main ausloesen wuerde (Pfad-Filter aus .github/workflows/<name>.yml).
# Gruen wird ein Stand ueber den Integrations-Branch: pushen, 'gh workflow run <name>.yml --ref <branch>', warten mit
# scripts/check_ci_status.ps1 -Wait. Regel: Skill /coordinate Abschnitt 3 *Push-Regeln*.
# Ausnahme Pin-Commit: aendert der Stand gegenueber seinem einen Elternteil nur provisioning/compose/compose.yml, zaehlen
# die Laeufe des Elternteils (der Pin entsteht erst aus dem gruenen Stand, docs/reference/provisioning.md *Docker-Verbund*).
# Aufrufer: .claude/hooks/dev_cycle_guard.ps1 (git push). Gilt nur auf der Owner-Maschine und nur fuer ein GitHub-Remote;
# ein Push des Owners im Terminal laeuft nicht durch den Hook und bleibt frei (Ausweg, wenn GitHub nicht abrufbar ist).
# Usage:
#   .\scripts\main_push_guard.ps1 [-Ref <ref>] [-Remote <name>] [-DestRef <zielname>]
#   ... -RunsFile <json>   Lauf-Liste aus einer Datei statt von GitHub (Test; auch ueber MAIN_PUSH_GUARD_RUNS_FILE,
#                          weil der Hook das Skript ohne Parameter startet)
# Ohne Parameter gelten PRE_COMMIT_TO_REF, PRE_COMMIT_REMOTE_NAME, PRE_COMMIT_REMOTE_BRANCH, sonst HEAD und origin.
# Exit 0 = frei oder kein main-Push, 1 = Lauf fehlt oder nicht gruen, 2 = nicht pruefbar.
param(
    [string]$Ref,
    [string]$Remote,
    [string]$DestRef,
    [string]$RunsFile
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] GitHub-Laeufe nicht pruefbar: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $PSScriptRoot 'lib\owner_machine.ps1')
. (Join-Path $PSScriptRoot 'lib\ci_wait.ps1')
. (Join-Path $PSScriptRoot 'lib\main_push.ps1')
. (Join-Path $PSScriptRoot 'lib\github_runs.ps1')
$u8 = New-Object System.Text.UTF8Encoding($false)
$Workflows = @('ci', 'free-gates', 'genericity')
$PinFile = 'provisioning/compose/compose.yml'

if (-not $Ref) { $Ref = if ($env:PRE_COMMIT_TO_REF) { $env:PRE_COMMIT_TO_REF } else { 'HEAD' } }
if (-not $Remote) { $Remote = if ($env:PRE_COMMIT_REMOTE_NAME) { $env:PRE_COMMIT_REMOTE_NAME } else { 'origin' } }
if (-not $DestRef) { $DestRef = if ($env:PRE_COMMIT_REMOTE_BRANCH) { $env:PRE_COMMIT_REMOTE_BRANCH } else { 'HEAD' } }
if (-not $RunsFile) { $RunsFile = $env:MAIN_PUSH_GUARD_RUNS_FILE }

$dest = $DestRef -replace '^refs/heads/', ''
if ($dest -eq 'HEAD') { $dest = [string](& git -C $RepoRoot symbolic-ref --short -q HEAD) }
if ($dest -ne 'main') { exit 0 }
if (-not (Test-OwnerMachine (Get-MainCheckoutRoot $RepoRoot))) {
    Write-Host '  [skip] keine Owner-Maschine -> keine Pruefung der GitHub-Laeufe' -ForegroundColor DarkGray
    exit 0
}
# Rohe URL aus der Konfiguration: 'git remote get-url' wendet insteadOf-Umschreibungen an.
$url = [string](& git -C $RepoRoot config --get "remote.$Remote.url")
if ($url -notmatch 'github\.com[:/]') { exit 0 }

$tip = [string](& git -C $RepoRoot rev-parse --verify -q "$Ref^{commit}")
if (-not $tip) { Write-Host "  [FAIL] Stand '$Ref' nicht aufloesbar" -ForegroundColor Red; exit 2 }
$remoteMain = [string](& git -C $RepoRoot rev-parse --verify -q "refs/remotes/$Remote/main^{commit}")
if ($remoteMain) {
    & git -C $RepoRoot merge-base --is-ancestor $tip $remoteMain
    if ($LASTEXITCODE -eq 0) { exit 0 }   # nichts Neues fuer main
}

# Geaenderte Dateien gegen das bekannte Remote-main; ohne diesen Stand gilt jeder Workflow als verlangt.
function Get-RequiredWorkflows([string]$From, [string]$To) {
    if (-not $From) { return $Workflows }
    $files = @(& git -C $RepoRoot -c core.quotepath=off diff --name-only --no-renames $From $To)
    if ($LASTEXITCODE -ne 0) { throw "git diff $From $To fehlgeschlagen" }
    $need = @()
    foreach ($wf in $Workflows) {
        $text = (& git -C $RepoRoot show "${To}:.github/workflows/$wf.yml") -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Workflow-Datei $wf.yml fehlt im Stand" }
        if (Test-WorkflowTriggered (Get-WorkflowPushFilter $text) $files) { $need += $wf }
    }
    return $need
}
function Get-Runs([string]$Sha) {
    if ($RunsFile) { return @([System.IO.File]::ReadAllText($RunsFile, $u8) | ConvertFrom-Json) }
    return @(Get-WorkflowRuns "per_page=100&head_sha=$Sha")
}

$required = @(Get-RequiredWorkflows $remoteMain $tip)
if ($required.Count -eq 0) { Write-Host '  [OK] dieser Push loest keinen der Workflows aus' -ForegroundColor Green; exit 0 }
$problems = @(Get-MainPushProblems $required (Get-Runs $tip) $tip)
if ($problems.Count -eq 0) { Write-Host "  [OK] GitHub-Laeufe gruen: $($required -join ', ')" -ForegroundColor Green; exit 0 }

$parents = @(([string](& git -C $RepoRoot rev-list --parents -n 1 $tip)) -split '\s+' | Select-Object -Skip 1)
if ($parents.Count -eq 1) {
    $changed = @(& git -C $RepoRoot -c core.quotepath=off diff --name-only --no-renames $parents[0] $tip)
    if ($changed.Count -eq 1 -and $changed[0] -eq $PinFile) {
        $parentNeed = @(Get-RequiredWorkflows $remoteMain $parents[0])
        if (@(Get-MainPushProblems $parentNeed (Get-Runs $parents[0]) $parents[0]).Count -eq 0) {
            Write-Host '  [OK] Pin-Commit auf gruenem Stand' -ForegroundColor Green; exit 0
        }
    }
}
$short = $tip.Substring(0, 8)
Write-Host "  [FAIL] Stand $short ohne gruene GitHub-Laeufe ($($problems -join ', ')). Zuerst den Integrations-Branch pushen, je Workflow 'gh workflow run <name>.yml --ref <branch>', warten mit scripts/check_ci_status.ps1 -Wait <name> -Sha $short" -ForegroundColor Red
exit 1
