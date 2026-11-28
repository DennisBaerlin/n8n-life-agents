# SessionEnd-Hook: raeumt das n8n-Test-Substrat dieses Worktrees ab (nie im Haupt-Checkout), wenn die Session endet
# (liegengebliebene Substrate fressen RAM). Trifft nur Container mit den Labels
# lifeagents.substrate=n8n und lifeagents.worktree=<dieser Checkout> (gesetzt von bootstrap_test_n8n.ps1) ->
# nie das Substrat einer anderen Session, nie Alt-Container ohne Label. db_test-Container bleiben (je ~50 MB).
# Docker-Verbund: scripts/lib/substrate_reservations.ps1 (Get-WorktreeComposeTargets), Test scripts/dev/substrate_reservation_test.ps1.
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
    # dort nach dem Worktree-Abbau die Schluss-Gates). Sonst loescht das Session-Ende einer fertigen Session
    # das laufende Substrat der Leitung. Im Haupt-Checkout raeumt jede Session ihr Substrat selbst ab (-Down).
    $gitDir = "$(git -C $cwd rev-parse --absolute-git-dir 2>$null)".Trim()
    $common = "$(git -C $cwd rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
    if (-not $gitDir -or $gitDir -eq $common) { exit 0 }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { exit 0 }
    # 'Continue' um die Docker-Aufrufe: unter 'Stop' macht PowerShell 5.1 aus einer stderr-Zeile trotz 2>$null einen Abbruch, und das
    # aeussere catch uebersprange die uebrigen Container, die Zustandsdateien und den Verbund-Abbau.
    $ErrorActionPreference = 'Continue'
    $names = @(docker ps -a --format '{{.Names}}' --filter 'label=lifeagents.substrate=n8n' --filter "label=lifeagents.worktree=$repo" 2>$null | Where-Object { $_ })
    # -v: das Image deklariert VOLUME; ohne -v bliebe je Container ein namenloses Volume verwaist liegen.
    foreach ($n in $names) { docker rm -fv $n 2>$null | Out-Null }
    $ErrorActionPreference = 'Stop'
    # Zustandsdatei je Container liegt im Haupt-Checkout (scripts/lib/n8ntest_state_file.ps1) und wird von allen Worktrees
    # geteilt: nur die der eben abgebauten Container loeschen, nie per Muster.
    $mainLocal = Join-Path (Split-Path $common -Parent) '.local'
    foreach ($n in $names) { Remove-Item -LiteralPath (Join-Path $mainLocal "n8ntest_state.$n.json") -Force -ErrorAction SilentlyContinue }
    # Docker-Verbund (compose-Unterbau): Auswahl und Abbau stehen in der Bibliothek (eine Quelle mit stop_test_containers.ps1).
    # Aus dem Checkout des Hakens geladen, nicht aus $repo: $repo kann ein fremdes Repo ohne scripts/ sein.
    $lib = Join-Path $PSScriptRoot '..\..\scripts\lib\substrate_reservations.ps1'
    if (Test-Path -LiteralPath $lib) {
        . $lib
        Remove-WorktreeComposeSubstrates -Worktree $repo -StateDir $mainLocal | Out-Null
    }
} catch { }
exit 0
