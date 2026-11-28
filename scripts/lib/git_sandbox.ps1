# git_sandbox.ps1 -- Sicherung fuer Tests, die ein Wegwerf-Repo anlegen. Im Commit-Hook setzt git GIT_DIR, GIT_INDEX_FILE & Co.:
# mit ihnen trifft jeder git-Aufruf das echte Repo, auch mit 'git -C <temp>' (ein git init schreibt so core.worktree in
# die gemeinsame .git/config, ein git add ersetzt den Index). Darum: zuerst Clear-GitEnvironment, dann Initialize-GitSandbox.
# Selbsttest: scripts/dev/git_sandbox_test.ps1 (Hook-Umgebung inkl. Worktree, gemeinsame Config, Aufrufer) und
# scripts/dev/privacy_lint_test.ps1 (Abschnitt Sandbox), gegen ein Wegwerf-"echtes" Repo.

function Clear-GitEnvironment {
    foreach ($n in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' } | ForEach-Object { $_.Name })) {
        [Environment]::SetEnvironmentVariable($n, $null)
    }
}

# Legt in $Dir ein Repo an und bricht ab, wenn git danach woanders arbeitet. Weitere Schritte schreiben erst nach dieser Pruefung.
# Gesetzte Variablen, die git auf ein anderes Repo lenken (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_COMMON_DIR, GIT_OBJECT_DIRECTORY,
# GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_NAMESPACE), brechen schon vor dem `git init` ab: Die Pruefung unten kaeme zu spaet, das init
# hat dann core.worktree in die gemeinsame Config des echten Repos geschrieben (unter prek: Worktree-Pfad, alle Worktrees treffen ihn).
function Initialize-GitSandbox([string]$Dir) {
    $redirect = 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE'
    $set = $redirect | Where-Object { [Environment]::GetEnvironmentVariable($_) }
    if ($set) { throw "Initialize-GitSandbox: $($set -join ', ') gesetzt (Commit-Hook) -- vor dem Wegwerf-Repo Clear-GitEnvironment aufrufen." }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Dir init -q -b main *> $null } finally { $ErrorActionPreference = $prev }
    $top = [string](& git -C $Dir rev-parse --show-toplevel)
    $want = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Dir).Path).TrimEnd('\', '/')
    if (-not $top -or [System.IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ne $want) { throw "git arbeitet nicht im Wegwerf-Repo: $top" }
}

# Invoke-SandboxGit <args> [-Dir] -> git im Wegwerf-Repo (Standard: $sandbox des Aufrufers), wirft bei Exit-Code != 0.
function Invoke-SandboxGit([string[]]$GitArgs, [string]$Dir = $sandbox) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Dir -c user.name=Test -c user.email=test@example.com -c core.autocrlf=false @GitArgs *> $null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') fehlgeschlagen" }
}

# Write-SandboxFile <relativer Pfad> <Text> -> schreibt UTF-8 ohne BOM nach $sandbox des Aufrufers (legt Ordner an).
function Write-SandboxFile([string]$Rel, [string]$Text) {
    $path = Join-Path $sandbox $Rel
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
