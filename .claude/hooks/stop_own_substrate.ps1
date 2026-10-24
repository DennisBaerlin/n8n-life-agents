# SessionEnd-Hook: raeumt das n8n-Test-Substrat DIESES Worktrees ab (nie im Haupt-Checkout), wenn die Session endet (je Substrat 1-1,5 GB
# RAM; liegengebliebene Substrate liessen den 16-GB-Host auslagern). Trifft NUR Container mit den Labels
# lifeagents.substrate=n8n UND lifeagents.worktree=<dieser Checkout> (gesetzt von bootstrap_test_n8n.ps1) ->
# nie das Substrat einer anderen Session, nie Alt-Container ohne Label. db_test-Container bleiben (je ~50 MB).
# Opt-out: $env:LIFEAGENTS_KEEP_SUBSTRATE=1 (z. B. Owner-Fenster-Suiten nach Session-Ende).
# Fehlertolerant + still: ein Hook-Fehler darf das Session-Ende nie stoeren. ASCII-only.
$ErrorActionPreference = 'Stop'
try {
    if ($env:LIFEAGENTS_KEEP_SUBSTRATE -eq '1') { exit 0 }
    $cwd = $null
    try { $cwd = ([Console]::In.ReadToEnd() | ConvertFrom-Json).cwd } catch { }
    if (-not $cwd) { $cwd = (Get-Location).Path }
    $repo = (git -C $cwd rev-parse --show-toplevel 2>$null)
    if (-not $repo) { exit 0 }
    $repo = "$repo".Trim()
    # Nur in einem eigenen Worktree aufraeumen: den Haupt-Checkout teilen sich mehrere Sessions (die Leitung faehrt
    # dort nach dem Worktree-Abbau die Schluss-Gates). 2026-10-23 loeschte das Session-Ende einer fertigen Session
    # so das laufende Substrat der Leitung. Im Haupt-Checkout raeumt jede Session ihr Substrat selbst ab (-Down).
    $gitDir = "$(git -C $cwd rev-parse --absolute-git-dir 2>$null)".Trim()
    $common = "$(git -C $cwd rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
    if (-not $gitDir -or $gitDir -eq $common) { exit 0 }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { exit 0 }
    $ids = @(docker ps -a -q --filter 'label=lifeagents.substrate=n8n' --filter "label=lifeagents.worktree=$repo" 2>$null)
    foreach ($id in ($ids | Where-Object { $_ })) { docker rm -f $id 2>$null | Out-Null }
    if ($ids.Count -gt 0) {
        $state = Join-Path $repo '.local/n8ntest_state.json'
        if (Test-Path $state) { Remove-Item $state -Force }
    }
} catch { }
exit 0
