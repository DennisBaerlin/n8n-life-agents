#Requires -Version 5.1
# post_merge_regenerate.ps1 -- git-Hook (prek, Stage post-merge und post-commit): erzeugt nach einem Merge/Pull die generierten Dateien neu, wenn
# deren Quellen im Merge geaendert wurden (sonst steht der erzeugte Block veraltet da und ui_token_lint wird rot).
#   Quellen Tokens  config/ui.*, scripts/lib/ui_tokens.ps1, scripts/lib/ui_art.ps1, scripts/build_ui_tokens.ps1 -> build_ui_tokens.ps1
#   Quellen Site    docs/site/{content,layouts,static,data,hugo.toml}, scripts/build_site.ps1                    -> build_site.ps1
# Das Ergebnis bleibt als Aenderung im Arbeitsbaum stehen (kein Auto-Commit); der Merge-Commit selbst bleibt unberuehrt.
# Zwei Ausloeser, ein Skript:
#   post-merge  (Stage post-merge)   sauber durchgelaufener Merge/Pull; geaenderte Dateien = ORIG_HEAD..HEAD. Fehlt ORIG_HEAD, passiert nichts.
#   post-commit (Schalter -Commit)   Abschluss eines von Hand aufgeloesten Konflikt-Merges: git ruft dann KEIN post-merge (Test:
#                                    scripts/dev/post_merge_regenerate_test.ps1). Nur wenn HEAD ein Merge-Commit ist (zwei Eltern), sonst sofort Ende;
#                                    geaenderte Dateien = HEAD^1..HEAD.
# Fehlt Hugo oder scheitert ein Generator, steht das als Warnung samt Befehl zum Nachholen da: Ein Kind-Exit-Code ungleich 0 wirft in PS 5.1 nicht,
# ohne Pruefung bliebe die Site still veraltet (sichtbar erst beim Push als site-verify rot). Ein Fehler hier bricht nie den Merge (Exit immer 0).
# Git je Worktree nur nacheinander: Merge, Checkout und dieser Hook duerfen nicht gleichzeitig im selben Worktree laufen.
# Usage:  .\scripts\post_merge_regenerate.ps1            # normal per Hook (post-merge)
#         .\scripts\post_merge_regenerate.ps1 -Commit    # Variante fuer den post-commit-Hook
#         .\scripts\post_merge_regenerate.ps1 -Files a,b # nur die Auswahl-Logik fuer diese Dateiliste zeigen (Test, baut nichts)
#         .\scripts\post_merge_regenerate.ps1 [-Commit] -Plan   # Auswahl fuer den echten Git-Stand zeigen (Test, baut nichts)
# Test: scripts/dev/post_merge_regenerate_test.ps1.
param([string[]]$Files, [switch]$Commit, [switch]$Plan)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-RegenerateTargets([string[]]$Changed) {
    $norm = @($Changed | Where-Object { $_ } | ForEach-Object { $_ -replace '\\', '/' })
    $tokens = @($norm | Where-Object { $_ -match '^(config/ui\.|scripts/lib/ui_(tokens|art)\.ps1$|scripts/build_ui_tokens\.ps1$)' }).Count -gt 0
    $site = @($norm | Where-Object { $_ -match '^(docs/site/(content|layouts|static|data)/|docs/site/hugo\.toml$|scripts/build_site\.ps1$)' }).Count -gt 0
    # build_ui_tokens schreibt auch ins Site-Partial: nach einem Token-Lauf ist die Site mit zu bauen
    return [pscustomobject]@{ Tokens = $tokens; Site = ($site -or $tokens) }
}

# Geaenderte Dateien des Merges; $null = nichts zu tun (kein ORIG_HEAD, kein Merge-Commit im -Commit-Modus).
function Get-MergeChangedFiles([string]$Root, [bool]$AfterCommit) {
    if ($AfterCommit) {
        git -C $Root rev-parse -q --verify 'HEAD^2' *> $null
        if ($LASTEXITCODE -ne 0) { return $null }
        $range = @('HEAD^1', 'HEAD')
    } else {
        $range = @('ORIG_HEAD', 'HEAD')
    }
    $changed = @(git -C $Root diff --name-only @range 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $changed.Count) { return $null }
    return $changed
}

# Ein Generator als Kindprozess; Rueckgabe $true bei Erfolg. Ein Exit-Code ungleich 0 wird NICHT von $ErrorActionPreference gefangen.
# Out-Host: Die Ausgabe des Kindes darf nicht in den Rueckgabewert laufen (ein Array aus Zeilen + $false waere als Bedingung wahr).
function Invoke-Generator([string]$PowerShellExe, [string]$Root, [string]$Script) {
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\$Script") | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "post-merge: $Script ist fehlgeschlagen (Exit $LASTEXITCODE) - die erzeugten Dateien sind veraltet. Von Hand nachholen: .\scripts\$Script" -ForegroundColor Yellow
        return $false
    }
    return $true
}

if ($PSBoundParameters.ContainsKey('Files')) {
    $t = Get-RegenerateTargets $Files
    Write-Output ("Tokens={0} Site={1}" -f $t.Tokens, $t.Site)
    return
}

try {
    $root = (git rev-parse --show-toplevel).Trim()
    $changed = Get-MergeChangedFiles $root $Commit.IsPresent
    if (-not $changed) { exit 0 }
    $t = Get-RegenerateTargets $changed
    if ($Plan) { Write-Output ("Tokens={0} Site={1}" -f $t.Tokens, $t.Site); exit 0 }
    $ps = (Get-Process -Id $PID).Path
    $ok = $true
    if ($t.Tokens) {
        Write-Host 'post-merge: Quellen der UI-Tokens geaendert -> build_ui_tokens.ps1' -ForegroundColor Cyan
        $ok = (Invoke-Generator $ps $root 'build_ui_tokens.ps1') -and $ok
    }
    if ($t.Site) {
        Write-Host 'post-merge: Quellen der Site geaendert -> build_site.ps1' -ForegroundColor Cyan
        $ok = (Invoke-Generator $ps $root 'build_site.ps1') -and $ok
    }
    if (($t.Tokens -or $t.Site) -and $ok) { Write-Host 'post-merge: Ergebnis steht als Aenderung im Arbeitsbaum (git status), nicht committet.' }
} catch {
    Write-Host "post-merge: Regenerieren uebersprungen ($($_.Exception.Message))" -ForegroundColor Yellow
}
exit 0
