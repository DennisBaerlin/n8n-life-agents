# git_sandbox.ps1 -- Sicherung fuer Tests, die ein Wegwerf-Repo anlegen. Im Commit-Hook setzt git GIT_DIR, GIT_INDEX_FILE & Co.:
# mit ihnen trifft jeder git-Aufruf das echte Repo, auch mit 'git -C <temp>' (ein git init schreibt so core.worktree in
# die gemeinsame .git/config, ein git add ersetzt den Index). Darum: zuerst Clear-GitEnvironment, dann Initialize-GitSandbox.
# Selbsttest: scripts/dev/privacy_lint_test.ps1 (Abschnitt Sandbox), gegen ein Wegwerf-"echtes" Repo.

function Clear-GitEnvironment {
    foreach ($n in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' } | ForEach-Object { $_.Name })) {
        [Environment]::SetEnvironmentVariable($n, $null)
    }
}

# Legt in $Dir ein Repo an und bricht ab, wenn git danach woanders arbeitet. Weitere Schritte schreiben erst nach dieser Pruefung.
function Initialize-GitSandbox([string]$Dir) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Dir init -q -b main *> $null } finally { $ErrorActionPreference = $prev }
    $top = [string](& git -C $Dir rev-parse --show-toplevel)
    $want = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Dir).Path).TrimEnd('\', '/')
    if (-not $top -or [System.IO.Path]::GetFullPath($top).TrimEnd('\', '/') -ne $want) { throw "git arbeitet nicht im Wegwerf-Repo: $top" }
}
