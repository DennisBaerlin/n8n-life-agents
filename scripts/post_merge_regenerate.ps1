#Requires -Version 5.1
# post_merge_regenerate.ps1 -- git-Hook (prek, Stage post-merge): erzeugt nach einem Merge/Pull die generierten Dateien neu, wenn
# deren QUELLEN im Merge geaendert wurden (sonst steht der erzeugte Block veraltet da und ui_token_lint wird rot).
#   Quellen Tokens  config/ui.*, scripts/lib/ui_tokens.ps1, scripts/lib/ui_art.ps1, scripts/build_ui_tokens.ps1 -> build_ui_tokens.ps1
#   Quellen Site    docs/site/{content,layouts,static,data,hugo.toml}, scripts/build_site.ps1                    -> build_site.ps1
# Das Ergebnis bleibt als Aenderung im Arbeitsbaum stehen (kein Auto-Commit); der Merge-Commit selbst bleibt unberuehrt.
# Geaenderte Dateien = ORIG_HEAD..HEAD (git setzt ORIG_HEAD bei Merge und Pull). Fehlt es, passiert nichts. Fehlt Hugo, meldet das
# Skript es und laesst die Site aus. Ein Fehler hier bricht nie den Merge (Exit immer 0).
# Git je Worktree nur nacheinander: Merge, Checkout und dieser Hook duerfen nicht gleichzeitig im selben Worktree laufen.
# Usage:  .\scripts\post_merge_regenerate.ps1            # normal per Hook
#         .\scripts\post_merge_regenerate.ps1 -Files a,b # nur die Auswahl-Logik fuer diese Dateiliste zeigen (Test, baut nichts)
# Test: scripts/dev/post_merge_regenerate_test.ps1.
param([string[]]$Files)
$ErrorActionPreference = 'Stop'

function Get-RegenerateTargets([string[]]$Changed) {
    $norm = @($Changed | Where-Object { $_ } | ForEach-Object { $_ -replace '\\', '/' })
    $tokens = @($norm | Where-Object { $_ -match '^(config/ui\.|scripts/lib/ui_(tokens|art)\.ps1$|scripts/build_ui_tokens\.ps1$)' }).Count -gt 0
    $site = @($norm | Where-Object { $_ -match '^(docs/site/(content|layouts|static|data)/|docs/site/hugo\.toml$|scripts/build_site\.ps1$)' }).Count -gt 0
    # build_ui_tokens schreibt auch ins Site-Partial: nach einem Token-Lauf ist die Site mit zu bauen
    return [pscustomobject]@{ Tokens = $tokens; Site = ($site -or $tokens) }
}

if ($PSBoundParameters.ContainsKey('Files')) {
    $t = Get-RegenerateTargets $Files
    Write-Output ("Tokens={0} Site={1}" -f $t.Tokens, $t.Site)
    return
}

try {
    $root = (git rev-parse --show-toplevel).Trim()
    $changed = @(git -C $root diff --name-only ORIG_HEAD HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $changed.Count) { exit 0 }
    $t = Get-RegenerateTargets $changed
    $ps = (Get-Process -Id $PID).Path
    if ($t.Tokens) {
        Write-Host 'post-merge: Quellen der UI-Tokens geaendert -> build_ui_tokens.ps1' -ForegroundColor Cyan
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build_ui_tokens.ps1')
    }
    if ($t.Site) {
        Write-Host 'post-merge: Quellen der Site geaendert -> build_site.ps1' -ForegroundColor Cyan
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build_site.ps1')
    }
    if ($t.Tokens -or $t.Site) { Write-Host 'post-merge: Ergebnis steht als Aenderung im Arbeitsbaum (git status), nicht committet.' }
} catch {
    Write-Host "post-merge: Regenerieren uebersprungen ($($_.Exception.Message))" -ForegroundColor Yellow
}
exit 0
