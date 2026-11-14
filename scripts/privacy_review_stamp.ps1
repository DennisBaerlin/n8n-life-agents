#Requires -Version 5.1
# privacy_review_stamp.ps1 -- schreibt den Pruefstempel der Modell-Pruefung (Skill /privacy-review) fuer genau einen Push nach
# .local/privacy_review_stamps/<hash>.json im Haupt-Checkout. Der Hash kommt aus scripts/privacy_outgoing.ps1, je Hash eine Datei:
# parallele Sessions ueberschreiben sich nicht. Die Sperre .claude/hooks/dev_cycle_guard.ps1 und prek pre-push verlangen ihn.
# Der Stempel enthaelt nur Hash, Commit und Zeitpunkt, nie einen Fund. Das Skript prueft, was es pruefen kann: Der Arbeitsbaum ist
# sauber (bis auf ungestagte Vorschau-Eintraege in .claude/launch.json), privacy_lint und owner_fact_lint sind gruen.
# Ob die Pruefung wirklich gelaufen ist, kann es nicht sehen; der Skill schreibt vor, wann es laufen darf.
# Mit -AllTags gilt der Stempel auch fuer denselben Push ohne Tags (prek sieht --tags nicht; der Text ist eine Teilmenge des Gepruefften).
# Usage:  .\scripts\privacy_review_stamp.ps1 [-Ref <ref>] [-Remote <name>] [-DestRef <zielname>] [-AllTags]
# Exit 0 = Stempel gesetzt oder nichts Neues ausgehend; 1 = kein Stempel (Stand nicht aufloesbar, Arbeitsbaum nicht sauber, Lint rot,
# Ausgehendes nicht bestimmbar).
param([string]$Ref = 'HEAD', [string]$Remote = 'origin', [string]$DestRef, [switch]$AllTags)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$MainRoot = Split-Path ([string](& git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir)) -Parent

$sha =[string](& git -C $RepoRoot rev-parse --verify "$Ref^{commit}")
if ($LASTEXITCODE -ne 0 -or -not $sha) { Write-Host "Kein Stempel: Stand '$Ref' nicht aufloesbar." -ForegroundColor Red; exit 1 }
# Ausnahme: ungestagte Vorschau-Eintraege in .claude/launch.json (Worktree-Vorschauen stehen absichtlich uncommittet im
# Haupt-Checkout); der Push enthaelt sie nicht, privacy_lint liest die Datei im Arbeitsbaum trotzdem mit.
$dirty = @(& git -C $RepoRoot status --porcelain | Where-Object { $_ -and $_ -cne ' M .claude/launch.json' })
if ($dirty.Count -gt 0) { Write-Host "Kein Stempel: Der Arbeitsbaum ist nicht sauber ($($dirty[0]))." -ForegroundColor Red; exit 1 }
foreach ($lint in 'privacy_lint.ps1', 'owner_fact_lint.ps1') {
    & (Join-Path $PSScriptRoot $lint)
    if ($LASTEXITCODE -ne 0) { Write-Host "Kein Stempel: $lint ist rot." -ForegroundColor Red; exit 1 }
}

$outgoing = Join-Path $PSScriptRoot 'privacy_outgoing.ps1'
$target = @{ Ref = $Ref; Remote = $Remote }
if ($DestRef) { $target.DestRef = $DestRef }
$hashes = @(& $outgoing @target -AllTags:$AllTags)
if ($LASTEXITCODE -ne 0) { Write-Host 'Kein Stempel: Das Ausgehende ist nicht bestimmbar.' -ForegroundColor Red; exit 1 }
if ($AllTags) {
    $hashes += @(& $outgoing @target)
    if ($LASTEXITCODE -ne 0) { Write-Host 'Kein Stempel: Das Ausgehende ist nicht bestimmbar.' -ForegroundColor Red; exit 1 }
}
$hashes = @($hashes | Where-Object { $_ -match '^[0-9a-f]{64}$' } | Sort-Object -Unique)
if ($hashes.Count -eq 0) { Write-Host 'Kein Stempel noetig: Nichts Neues ausgehend.' -ForegroundColor Green; exit 0 }

$dir = Join-Path $MainRoot '.local\privacy_review_stamps'
New-Item -ItemType Directory -Force $dir | Out-Null
foreach ($hash in $hashes) {
    $body = @{ hash = $hash; commit = $sha; reviewed_at = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $dir "$hash.json"), $body, $u8)
}
Write-Host "Pruefstempel gesetzt fuer $($sha.Substring(0, 8))." -ForegroundColor Green
exit 0
