#Requires -Version 5.1
# git_sandbox_test.ps1 -- Test fuer scripts/lib/git_sandbox.ps1: Initialize-GitSandbox darf das "echte" Repo nie anfassen, auch nicht
# dessen gemeinsame .git/config. Unter prek zeigt GIT_DIR auf .git/worktrees/<name> und GIT_WORK_TREE auf den Worktree; ein
# `git init` fuer ein Wegwerf-Repo schriebe dann core.worktree in die gemeinsame Config und lenkte alle Worktrees auf einen Ordner.
# Alles laeuft in Wegwerf-Repos im Temp-Ordner (Repo mit Worktree), nie im echten Repo. Kein Docker, kein Netz, keine Kosten.
# Zweiter Teil (statisch): jede Datei unter scripts/, die Initialize-GitSandbox aufruft, ruft vorher Clear-GitEnvironment.
# Usage:  .\scripts\dev\git_sandbox_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
$SandboxLib = Join-Path $repo 'scripts\lib\git_sandbox.ps1'
. $SandboxLib
Clear-GitEnvironment   # dieser Test laeuft selbst im Commit-Hook: erst jetzt zeigt git nicht mehr aufs echte Repo
$failed = 0
function Assert-That($name, [bool]$ok, $detail = '') {
    if ($ok) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name $detail" -ForegroundColor Red; $script:failed++ }
}
function Invoke-TestGit([string]$Dir, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Dir -c user.name=Test -c user.email=test@example.com @GitArgs *> $null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') fehlgeschlagen" }
}
function Get-Hash([string]$Path) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    -join ($md5.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') })
}

$box = Join-Path ([System.IO.Path]::GetTempPath()) ('gst_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$real = Join-Path $box 'real'; $wt = Join-Path $box 'wt'; $target = Join-Path $box 'target'
try {
    New-Item -ItemType Directory -Force $real, $target | Out-Null
    Initialize-GitSandbox $real
    Invoke-TestGit $real @('commit', '-q', '--allow-empty', '-m', 'init')
    Invoke-TestGit $real @('worktree', 'add', '-q', '-b', 'wt', $wt)
    $common = Join-Path $real '.git'
    $admin = Join-Path $common 'worktrees\wt'
    $envs = [ordered]@{
        'prek (GIT_DIR=Worktree-Verwaltung, GIT_WORK_TREE, GIT_INDEX_FILE)' = @{ GIT_DIR = $admin; GIT_WORK_TREE = $wt; GIT_INDEX_FILE = (Join-Path $admin 'index') }
        'nur GIT_DIR'        = @{ GIT_DIR = $admin }
        'nur GIT_WORK_TREE'  = @{ GIT_WORK_TREE = $wt }
        'nur GIT_INDEX_FILE' = @{ GIT_INDEX_FILE = (Join-Path $admin 'index') }
        'nur GIT_COMMON_DIR' = @{ GIT_COMMON_DIR = $common }
        'nur GIT_OBJECT_DIRECTORY' = @{ GIT_OBJECT_DIRECTORY = (Join-Path $common 'objects') }
        'nur GIT_NAMESPACE'  = @{ GIT_NAMESPACE = 'fremd' }
    }
    $envNames = @($envs.Values | ForEach-Object { $_.Keys } | Sort-Object -Unique)
    Write-Host 'Initialize-GitSandbox mit gesetzter Hook-Umgebung bricht ab, bevor etwas geschrieben wird:'
    foreach ($case in $envs.Keys) {
        $cfgBefore = Get-Hash (Join-Path $common 'config'); $headBefore = Get-Hash (Join-Path $admin 'HEAD')
        $log = Join-Path $box 'probe.log'
        $saved = @{}; foreach ($k in $envNames) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
        foreach ($k in $envs[$case].Keys) { [Environment]::SetEnvironmentVariable($k, $envs[$case][$k]) }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            Set-Location $wt
            & powershell -NoProfile -ExecutionPolicy Bypass -Command "`$ErrorActionPreference = 'Stop'; . '$SandboxLib'; Initialize-GitSandbox '$target'" *> $log
            $code = $LASTEXITCODE
        } finally {
            Set-Location $repo
            $ErrorActionPreference = $prev
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        $msg = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
        $cw = & git config --file (Join-Path $common 'config') --get core.worktree
        Assert-That "${case}: Abbruch (Exit != 0)" ($code -ne 0) "(Exit $code)"
        Assert-That "${case}: Meldung nennt Clear-GitEnvironment" ($msg -match 'Clear-GitEnvironment')
        Assert-That "${case}: gemeinsame Config unveraendert, kein core.worktree" ((Get-Hash (Join-Path $common 'config')) -eq $cfgBefore -and -not $cw)
        Assert-That "${case}: HEAD des Worktrees unveraendert" ((Get-Hash (Join-Path $admin 'HEAD')) -eq $headBefore)
        Assert-That "${case}: kein Repo im Zielordner angelegt" (-not (Test-Path (Join-Path $target '.git')))
    }

    Write-Host 'Ohne GIT_*-Variablen (nach Clear-GitEnvironment) entsteht das Wegwerf-Repo, das echte bleibt unberuehrt:'
    $cfgBefore = Get-Hash (Join-Path $common 'config')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & powershell -NoProfile -ExecutionPolicy Bypass -Command "`$ErrorActionPreference = 'Stop'; . '$SandboxLib'; Clear-GitEnvironment; Initialize-GitSandbox '$target'" *> $null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    Assert-That 'Initialize-GitSandbox nach Clear-GitEnvironment: Exit 0, Repo im Zielordner' ($code -eq 0 -and (Test-Path (Join-Path $target '.git\config')))
    Assert-That 'echte gemeinsame Config unveraendert' ((Get-Hash (Join-Path $common 'config')) -eq $cfgBefore)
} finally {
    Set-Location $repo
    Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Aufrufer: Clear-GitEnvironment steht vor dem ersten Initialize-GitSandbox:'
$callers = @(Get-ChildItem (Join-Path $repo 'scripts') -Recurse -Filter *.ps1 |
    Where-Object { $_.FullName -ne $SandboxLib -and $_.Name -ne 'git_sandbox_test.ps1' } |
    ForEach-Object {
        # Ganzzeilen-Kommentare zaehlen nicht: ein Kopf, der die Namen nur erwaehnt, ruft nichts auf.
        $code = ([System.IO.File]::ReadAllLines($_.FullName) | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        [pscustomobject]@{ File = $_; Text = $code }
    } |
    Where-Object { $_.Text -match 'Initialize-GitSandbox' })
Assert-That 'Aufrufer gefunden (der Test sieht die Dateien)' ($callers.Count -ge 1) "(gefunden: $($callers.Count))"
foreach ($c in $callers) {
    $clear = $c.Text.IndexOf('Clear-GitEnvironment', [StringComparison]::Ordinal)
    $init = $c.Text.IndexOf('Initialize-GitSandbox', [StringComparison]::Ordinal)
    Assert-That "$($c.File.Name): Clear-GitEnvironment vor Initialize-GitSandbox" ($clear -ge 0 -and $clear -lt $init)
}

Write-Host "git_sandbox_test: $failed Fehler."
exit $failed
