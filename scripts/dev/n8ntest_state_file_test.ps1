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

    # Unterbau-Feld: der klassische Bootstrap schreibt kein runtime (fehlt = classic); der Verbund schreibt runtime + project.
    . (Join-Path $wt 'scripts\lib\n8ntest_state_file.ps1')
    Assert-That ((Get-TestN8nRuntime -State ([System.IO.File]::ReadAllText($want) | ConvertFrom-Json)) -eq 'classic') 'State ohne runtime = classic'
    Write-TestN8nState -Runtime compose -Project 'nsf-probe' -Url 'http://127.0.0.1:57501' -ApiKey 'invented-key' -Container 'nsf-probe-master' -ContainerId 'abc'
    $s = [System.IO.File]::ReadAllText($want) | ConvertFrom-Json
    Assert-That ($s.runtime -eq 'compose' -and $s.project -eq 'nsf-probe' -and $s.url -eq 'http://127.0.0.1:57501' -and $s.api_key -eq 'invented-key' -and $s.container -eq 'nsf-probe-master' -and $s.container_id -eq 'abc' -and $s.built_at) 'Write-TestN8nState schreibt alle Felder in die Datei des Containers'
    Assert-That ((Get-TestN8nRuntime -State $s) -eq 'compose') 'State mit runtime=compose = compose'
    $bad = $false; try { Write-TestN8nState -Runtime 'lxc' -Project 'x' -Url 'u' -ApiKey 'k' -Container 'c' } catch { $bad = $true }
    Assert-That $bad 'unbekannter Unterbau beim Schreiben = Abbruch'
    $bad = $false; try { Get-TestN8nRuntime -State ([pscustomobject]@{ runtime = 'lxc' }) | Out-Null } catch { $bad = $true }
    Assert-That $bad 'unbekannter Unterbau beim Lesen = Abbruch'
    $raw = [System.IO.File]::ReadAllBytes($want)
    Assert-That (-not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB)) 'State-Datei ohne BOM'
} finally {
    $env:N8NTEST_CONTAINER = $savedContainer
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git -C $main worktree remove --force $wt *> $null
    $ErrorActionPreference = $prev
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}
Write-Host "n8ntest_state_file_test: $failed Fehler."
exit $failed
