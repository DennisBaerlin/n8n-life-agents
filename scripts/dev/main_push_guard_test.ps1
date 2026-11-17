#Requires -Version 5.1
# main_push_guard_test.ps1 -- Regressionstest der main-Push-Sperre: Urteil (scripts/lib/main_push.ps1) an erfundenen
# Workflow-Texten und Lauf-Listen, scripts/main_push_guard.ps1 und sein Einsatz in .claude/hooks/dev_cycle_guard.ps1 als
# Kopie in einem Wegwerf-Repo. Das Remote traegt eine GitHub-Adresse, die git per insteadOf auf ein Wegwerf-Remote umlenkt;
# die Lauf-Liste kommt aus einer Datei. Kein Netz, kein Token, kein Substrat; alle Werte erfunden.
# Usage:  .\scripts\dev\main_push_guard_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$u8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
. (Join-Path $PSScriptRoot '..\lib\ci_wait.ps1')
. (Join-Path $PSScriptRoot '..\lib\main_push.ps1')
Clear-GitEnvironment
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$failed = 0
function Assert-True([string]$Name, [bool]$Ok, [string]$Got = '') {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name $Got" -ForegroundColor Red; $script:failed++ }
}

$ciYaml = "name: ci`non:`n  push:`n    branches: [main]`n  pull_request:`n  workflow_dispatch:`njobs: {}`n"
$pathsYaml = "name: genericity`non:`n  workflow_dispatch:   # Handstart`n  push:`n    branches: [main]`n    paths:`n      - 'provisioning/**'`n      - 'packages/**'`n  pull_request:`n    paths:`n      - 'andere/**'`njobs: {}`n"
$ignoreYaml = "name: free-gates`non:`n  workflow_dispatch:`n  push:`n    branches: [main]`n    paths-ignore:`n      - '*.md'`n      - '**/CLAUDE.md'`n      - 'docs/**'`n      - '.claude/**'`njobs: {}`n"

Write-Host 'Pfad-Filter lesen:'
$fCi = Get-WorkflowPushFilter $ciYaml
$fPaths = Get-WorkflowPushFilter $pathsYaml
$fIgnore = Get-WorkflowPushFilter $ignoreYaml
Assert-True 'ohne Filter: beide Listen leer' ($fCi.Paths.Count -eq 0 -and $fCi.Ignore.Count -eq 0)
Assert-True 'paths: nur der push-Block zaehlt' ($fPaths.Paths.Count -eq 2 -and $fPaths.Paths -notcontains 'andere/**') "$($fPaths.Paths -join ',')"
Assert-True 'paths-ignore: vier Muster' ($fIgnore.Ignore.Count -eq 4 -and $fIgnore.Paths.Count -eq 0) "$($fIgnore.Ignore -join ',')"
$threw = $false
try { $null = Get-WorkflowPushFilter "on:`n  push:`n    paths: ['a/**']`n" } catch { $threw = $true }
Assert-True 'Inline-Liste wirft (nicht still zu wenig verlangen)' $threw

Write-Host 'Wuerde der Push den Workflow starten:'
Assert-True 'ohne Filter immer' (Test-WorkflowTriggered $fCi @('docs/package-contract.md'))
Assert-True 'paths: Datei im Ordner startet' (Test-WorkflowTriggered $fPaths @('docs/package-contract.md', 'provisioning/lib/update_runner.sh'))
Assert-True 'paths: nur fremde Dateien starten nicht' (-not (Test-WorkflowTriggered $fPaths @('docs/package-contract.md', 'scripts/check_ci_status.ps1')))
Assert-True 'paths-ignore: nur Ausnahmen starten nicht' (-not (Test-WorkflowTriggered $fIgnore @('README.md', 'scripts/CLAUDE.md', 'docs/reference/sessions.md', '.claude/skills/x/SKILL.md')))
Assert-True 'paths-ignore: eine andere Datei startet' (Test-WorkflowTriggered $fIgnore @('README.md', 'scripts/check_ci_status.ps1'))
Assert-True 'paths-ignore: *.md gilt nur im Wurzelordner' (Test-WorkflowTriggered $fIgnore @('tests/fixtures/README.md'))

function New-Run([string]$Name, [string]$Sha, [string]$Status = 'completed', [string]$Conclusion = 'success') {
    return [pscustomobject]@{ name = $Name; path = ".github/workflows/$Name.yml"; head_sha = $Sha; status = $Status
        conclusion = $Conclusion; created_at = '2026-01-01T10:00:00Z'; id = 1; html_url = 'https://example.invalid/runs/1' }
}
function New-Runs([string]$Sha, [string[]]$Names) { return @($Names | ForEach-Object { New-Run $_ $Sha }) }
$all = @('ci', 'free-gates', 'genericity')
$shaA = 'a' * 40

Write-Host 'Urteil je Workflow:'
Assert-True 'alle gruen: frei' (@(Get-MainPushProblems $all (New-Runs $shaA $all) $shaA).Count -eq 0)
$p = @(Get-MainPushProblems $all @((New-Run 'ci' $shaA), (New-Run 'free-gates' $shaA 'completed' 'failure'), (New-Run 'genericity' $shaA 'in_progress' '')) $shaA)
Assert-True 'rot und laufend werden genannt' ($p.Count -eq 2 -and ($p -join ';') -eq 'free-gates: rot;genericity: laeuft noch') ($p -join ';')
$p = @(Get-MainPushProblems $all (New-Runs ('b' * 40) $all) $shaA)
Assert-True 'Laeufe auf anderem Stand zaehlen nicht' ($p.Count -eq 3 -and $p[0] -eq 'ci: kein Lauf') ($p -join ';')

$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$sandbox = Join-Path $env:TEMP "main_push_guard_$id"
$bare = Join-Path $env:TEMP "main_push_remote_$id"
$runsFile = Join-Path $env:TEMP "main_push_runs_$id.json"
New-Item -ItemType Directory -Force $sandbox, $bare | Out-Null
$fakeUrl = 'https://github.com/beispiel/repo.git'
$guard = Join-Path $sandbox 'scripts\main_push_guard.ps1'
$hook = Join-Path $sandbox '.claude\hooks\dev_cycle_guard.ps1'

function Set-Runs([object[]]$Runs) {
    $json = if ($Runs.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($Runs) -Depth 4 }
    [System.IO.File]::WriteAllText($runsFile, $json, $u8)
}
function Get-Sha([string]$Rev) { return [string](& git -C $sandbox rev-parse $Rev) }
# Neuer Zweig vom veroeffentlichten Stand mit einem Commit je Datei; liefert den Hash.
function New-Scenario([string]$Branch, [string[]]$Files, [string]$From = 'origin/main') {
    Invoke-SandboxGit @('checkout', '-q', '-B', $Branch, $From)
    foreach ($f in $Files) { Add-Content -LiteralPath (Join-Path $sandbox $f) -Value "zeile $Branch" -Encoding UTF8 }
    Invoke-SandboxGit @('add', '-A')
    Invoke-SandboxGit @('commit', '-q', '-m', "aendert $($Files -join ' ')")
    return Get-Sha 'HEAD'
}
function Invoke-Guard([string[]]$ScriptArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $guard @ScriptArgs -RunsFile $runsFile); return $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
}
function Assert-Exit([string]$Name, [int]$Expect, [int]$Got) { Assert-True $Name ($Got -eq $Expect) "(erwartet Exit $Expect, got $Got)" }
# Hook-Entscheidung: 'main' (main-Push-Sperre), 'deny' (andere Sperre, z. B. Pruefstempel), 'free'.
function Get-HookVerdict([string]$Command) {
    $payload = @{ tool_name = 'Bash'; tool_input = @{ command = $Command }; cwd = $sandbox } | ConvertTo-Json -Compress -Depth 5
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.WorkingDirectory = $sandbox
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    if ($out -match '"permissionDecision":"deny"' -and $out -match 'MAIN-PUSH GESPERRT') { return 'main' }
    if ($out -match '"permissionDecision":"deny"') { return 'deny' }
    return 'free'
}
function Assert-Hook([string]$Name, [bool]$ExpectMain, [string]$Command) {
    $v = Get-HookVerdict $Command
    Assert-True $Name (($v -eq 'main') -eq $ExpectMain) "(erwartet main-Sperre=$ExpectMain, got $v)"
}
$publish = 'git ' + 'push origin'

try {
    Initialize-GitSandbox $sandbox
    Invoke-SandboxGit @('init', '-q', '--bare', '-b', 'main', $bare)
    New-Item -ItemType Directory -Force (Join-Path $sandbox '.claude\hooks') | Out-Null
    Copy-Item (Join-Path $repo '.claude\hooks\dev_cycle_guard.ps1') (Join-Path $sandbox '.claude\hooks\')
    foreach ($name in 'privacy_lint.ps1', 'owner_fact_lint.ps1', 'privacy_outgoing.ps1', 'privacy_review_stamp.ps1', 'release_pin_guard.ps1', 'main_push_guard.ps1',
        'lib\owner_machine.ps1', 'lib\release_images.ps1', 'lib\ci_wait.ps1', 'lib\main_push.ps1', 'lib\github_runs.ps1') {
        $dst = Join-Path $sandbox "scripts\$name"
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item (Join-Path $repo "scripts\$name") $dst
    }
    Write-SandboxFile '.gitignore' ".local/`n.env`n"
    Write-SandboxFile '.env' "OWNER_CHAT_ID=12345678`n"
    Write-SandboxFile '.local\privacy_denylist.txt' "Zauberwort`n"
    Write-SandboxFile '.github\workflows\ci.yml' $ciYaml
    Write-SandboxFile '.github\workflows\genericity.yml' $pathsYaml
    Write-SandboxFile '.github\workflows\free-gates.yml' $ignoreYaml
    Write-SandboxFile 'provisioning\compose\compose.yml' "x-images:`n  master: neutral`n"
    Write-SandboxFile 'provisioning\a.sh' "echo a`n"
    Write-SandboxFile 'docs\d.md' "d`n"
    Invoke-SandboxGit @('add', '-A')
    Invoke-SandboxGit @('commit', '-q', '-m', 'eins')
    Invoke-SandboxGit @('remote', 'add', 'origin', $fakeUrl)
    Invoke-SandboxGit @('config', "url.$($bare -replace '\\', '/').insteadOf", $fakeUrl)
    Invoke-SandboxGit @('push', '-q', 'origin', 'main')
    $toMain = @('-Remote', 'origin', '-DestRef', 'main')

    Write-Host 'Skript, Code-Aenderung:'
    $code = New-Scenario 'code' @('provisioning\a.sh')
    Set-Runs @()
    Assert-Exit 'kein Lauf: Exit 1' 1 (Invoke-Guard (@('-Ref', 'code') + $toMain))
    Set-Runs (New-Runs $code $all)
    Assert-Exit 'alle drei gruen: Exit 0' 0 (Invoke-Guard (@('-Ref', 'code') + $toMain))
    Set-Runs @((New-Run 'ci' $code), (New-Run 'free-gates' $code), (New-Run 'genericity' $code 'in_progress' ''))
    Assert-Exit 'einer laeuft noch: Exit 1' 1 (Invoke-Guard (@('-Ref', 'code') + $toMain))
    Set-Runs @()
    Assert-Exit 'Ziel ist ein anderer Branch: Exit 0' 0 (Invoke-Guard @('-Ref', 'code', '-Remote', 'origin', '-DestRef', 'code'))
    Assert-Exit 'refs/heads/main zaehlt als main: Exit 1' 1 (Invoke-Guard @('-Ref', 'code', '-Remote', 'origin', '-DestRef', 'refs/heads/main'))
    Assert-Exit 'Stand liegt schon auf main: Exit 0' 0 (Invoke-Guard (@('-Ref', 'origin/main') + $toMain))

    Write-Host 'Skript, Pfad-Filter:'
    $doc = New-Scenario 'doku' @('docs\d.md')
    Set-Runs @()
    Assert-Exit 'nur Doku, kein Lauf: Exit 1 (ci laeuft immer)' 1 (Invoke-Guard (@('-Ref', 'doku') + $toMain))
    Set-Runs (New-Runs $doc @('ci'))
    Assert-Exit 'nur Doku, ci gruen: Exit 0' 0 (Invoke-Guard (@('-Ref', 'doku') + $toMain))
    $scr = New-Scenario 'skript' @('docs\d.md', '.gitignore')
    Set-Runs (New-Runs $scr @('ci'))
    Assert-Exit 'Datei ausserhalb der Ausnahmen, free-gates fehlt: Exit 1' 1 (Invoke-Guard (@('-Ref', 'skript') + $toMain))
    Set-Runs (New-Runs $scr @('ci', 'free-gates'))
    Assert-Exit 'ci + free-gates gruen, genericity nicht verlangt: Exit 0' 0 (Invoke-Guard (@('-Ref', 'skript') + $toMain))

    Write-Host 'Skript, Pin-Commit:'
    $base = New-Scenario 'pin' @('provisioning\a.sh')
    Add-Content -LiteralPath (Join-Path $sandbox 'provisioning\compose\compose.yml') -Value '  pin: neu' -Encoding UTF8
    Invoke-SandboxGit @('commit', '-q', '-am', 'chore(release): pin master image')
    Set-Runs (New-Runs $base $all)
    Assert-Exit 'Pin auf gruenem Stand: Exit 0' 0 (Invoke-Guard (@('-Ref', 'pin') + $toMain))
    Set-Runs (New-Runs $base @('ci', 'free-gates'))
    Assert-Exit 'Pin auf nicht gruenem Stand: Exit 1' 1 (Invoke-Guard (@('-Ref', 'pin') + $toMain))
    Add-Content -LiteralPath (Join-Path $sandbox 'provisioning\compose\compose.yml') -Value '  pin: neuer' -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $sandbox 'provisioning\a.sh') -Value 'echo c' -Encoding UTF8
    Invoke-SandboxGit @('commit', '-q', '-am', 'pin und mehr')
    Set-Runs (New-Runs (Get-Sha 'HEAD~1') $all)
    Assert-Exit 'Pin-Datei plus andere Datei: Exit 1' 1 (Invoke-Guard (@('-Ref', 'pin') + $toMain))

    Write-Host 'Hook:'
    Invoke-SandboxGit @('checkout', '-q', 'code')
    Set-Runs @()
    $env:MAIN_PUSH_GUARD_RUNS_FILE = $runsFile
    Assert-Hook 'main-Push ohne Lauf gesperrt'        $true  "$publish code:main"
    Assert-Hook 'Branch-Push: keine main-Sperre'      $false "$publish code"
    Set-Runs (New-Runs $code $all)
    Assert-Hook 'main-Push mit gruenen Laeufen: keine main-Sperre' $false "$publish code:main"

    Write-Host 'Nicht pruefbar und Grenzen:'
    Remove-Item -LiteralPath $runsFile
    Assert-Exit 'Lauf-Liste nicht lesbar: Exit 2' 2 (Invoke-Guard (@('-Ref', 'code') + $toMain))
    Assert-Hook 'Lauf-Liste nicht lesbar: gesperrt'   $true  "$publish code:main"
    Set-Runs @()
    Invoke-SandboxGit @('remote', 'set-url', 'origin', ($bare -replace '\\', '/'))
    Assert-Exit 'kein GitHub-Remote: Exit 0' 0 (Invoke-Guard (@('-Ref', 'code') + $toMain))
    Invoke-SandboxGit @('remote', 'set-url', 'origin', $fakeUrl)
    Remove-Item -LiteralPath (Join-Path $sandbox '.local\privacy_denylist.txt'), (Join-Path $sandbox '.env')
    Assert-Exit 'keine Owner-Maschine: Exit 0' 0 (Invoke-Guard (@('-Ref', 'code') + $toMain))
    Write-SandboxFile '.local\privacy_denylist.txt' "Zauberwort`n"
    Remove-Item -LiteralPath $guard
    Assert-Hook 'Skript fehlt: gesperrt'              $true  "$publish code:main"
} finally {
    $env:MAIN_PUSH_GUARD_RUNS_FILE = $null
    Remove-Item -LiteralPath $sandbox, $bare -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $runsFile -Force -ErrorAction SilentlyContinue
}
Write-Host "main_push_guard_test: $failed Fehler."
exit $failed
