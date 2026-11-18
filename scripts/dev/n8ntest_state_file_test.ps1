#Requires -Version 5.1
# n8ntest_state_file_test.ps1 -- die Zustandsdatei des Test-Substrats (URL + API-Schluessel) gehoert zum Container, nicht zum Worktree:
# Aus jedem Worktree desselben Repos zeigt Get-TestN8nStateFile auf .local/n8ntest_state.<container>.json im Haupt-Checkout, und der
# Datums-Bezugstag (scripts/lib/date_placeholder.ps1) liest dieselbe Datei. Sonst liest ein zweiter Worktree einen alten Schluessel
# (Symptom: 401 Unauthorized gegen ein laufendes Substrat).
# Wegwerf-Repo mit Worktree, kein Docker, kein Netz.
# Usage:  .\scripts\dev\n8ntest_state_file_test.ps1     Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\lib\git_sandbox.ps1')
$failed = 0
function Assert-That([bool]$Ok, [string]$Name) {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}
function Get-Full([string]$Path) { [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }

Clear-GitEnvironment
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('nsf_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$main = Join-Path $sandbox 'main'; $wt = Join-Path $sandbox 'wt'
$savedContainer = $env:N8NTEST_CONTAINER
try {
    New-Item -ItemType Directory -Force $main | Out-Null
    Initialize-GitSandbox $main
    # Die Skripte liegen im Wegwerf-Repo, damit ihr git -C $PSScriptRoot dort fragt und nicht im echten Repo.
    New-Item -ItemType Directory -Force (Join-Path $main 'scripts\dev') | Out-Null
    Copy-Item (Join-Path $repo 'scripts\dev\test_n8n_state.ps1') (Join-Path $main 'scripts\dev')
    New-Item -ItemType Directory -Force (Join-Path $main 'scripts\lib') | Out-Null
    Copy-Item (Join-Path $repo 'scripts\lib\*.ps1') (Join-Path $main 'scripts\lib')
    Invoke-SandboxGit @('add', '-A') $main
    Invoke-SandboxGit @('commit', '-q', '-m', 'init') $main
    Invoke-SandboxGit @('worktree', 'add', '-q', '-b', 'wt', $wt) $main

    $env:N8NTEST_CONTAINER = 'nsf-probe'
    $want = Get-Full (Join-Path $main '.local\n8ntest_state.nsf-probe.json')
    . (Join-Path $wt 'scripts\dev\test_n8n_state.ps1')
    Assert-That ((Get-Full (Get-TestN8nStateFile)) -eq $want) 'aus dem Worktree: Zustandsdatei liegt im Haupt-Checkout'
    . (Join-Path $main 'scripts\dev\test_n8n_state.ps1')
    Assert-That ((Get-Full (Get-TestN8nStateFile)) -eq $want) 'aus dem Haupt-Checkout: dieselbe Datei'

    # Bezugstag aus dem Worktree ohne -StateFile: liest die Datei im Haupt-Checkout.
    New-Item -ItemType Directory -Force (Split-Path $want) | Out-Null
    [System.IO.File]::WriteAllText($want, '{"url":"http://x","container":"nsf-probe","mock_llm":{"today":"2026-03-01"}}', (New-Object System.Text.UTF8Encoding($false)))
    . (Join-Path $wt 'scripts\lib\date_placeholder.ps1')
    $day = Get-DatePlaceholderReferenceDay 3> $null
    Assert-That ($day.ToString('yyyy-MM-dd') -eq '2026-03-01') 'Bezugstag aus dem Worktree liest dieselbe Zustandsdatei'
} finally {
    $env:N8NTEST_CONTAINER = $savedContainer
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git -C $main worktree remove --force $wt *> $null
    $ErrorActionPreference = $prev
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}
Write-Host "n8ntest_state_file_test: $failed Fehler."
exit $failed
