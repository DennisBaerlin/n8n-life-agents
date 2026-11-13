#Requires -Version 5.1
# Conventional-Commits-Lint (commit-msg-Hook, .pre-commit-config.yaml id conventional-commit).
# Eigene Mini-Regex statt Node-commitlint (kein Node/Python im Stack). prek uebergibt den Pfad zur
# Commit-Message-Datei als einziges Argument:  .\scripts\lint_commit_msg.ps1 <message-datei>
# Exit 0 = ok (auch ohne Datei-Argument: uebersprungen), 1 = Commit abgelehnt (BOM, leere Message, Subject passt nicht).
#
# Erlaubt: <type>(scope)!: <subject>  mit type in der Standard-Liste; plus Merge-/Revert-/fixup-/
# squash-/amend-Auto-Messages (die git/Tools selbst erzeugen). Quelle: https://www.conventionalcommits.org

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$msgPath = $args[0]
if (-not $msgPath -or -not (Test-Path $msgPath)) {
    Write-Host "commit-msg: keine Message-Datei uebergeben ($msgPath) -- uebersprungen." -ForegroundColor DarkGray
    exit 0
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# BOM vorn: ReadAllText entfernt es still (Encoding-Erkennung), git speichert es aber im Subject, also ein
# unsichtbares Zeichen vor dem type im oeffentlichen Log. Ursache meist PS 5.1 `Set-Content -Encoding utf8` (schreibt immer ein BOM).
$head = [System.IO.File]::ReadAllBytes($msgPath) | Select-Object -First 3
if ($head.Count -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
    Write-Host "COMMIT ABGELEHNT: die Message-Datei beginnt mit einem UTF-8-BOM (git uebernimmt es ins Subject)." -ForegroundColor Red
    Write-Host "  Datei ohne BOM schreiben: NEUE Datei mit dem Write-Tool (Ueberschreiben behaelt ein vorhandenes BOM) bzw. [System.IO.File]::WriteAllText(<pfad>, <text>, (New-Object System.Text.UTF8Encoding(`$false)))" -ForegroundColor Yellow
    exit 1
}
$raw = [System.IO.File]::ReadAllText($msgPath, $Utf8NoBom)
$lines = $raw -split "`r?`n"

# Subject = erste nicht-leere Zeile ohne Kommentar-Praefix
$subject = $null
foreach ($l in $lines) {
    if ($l -match '^\s*#') { continue }
    if ($l.Trim().Length -eq 0) { continue }
    $subject = $l.TrimEnd()
    break
}
if (-not $subject) {
    Write-Host "commit-msg: leere Message -- abgelehnt." -ForegroundColor Red
    exit 1
}

# Auto-Messages durchlassen (von git/Tools erzeugt)
if ($subject -match '^(Merge |Revert |fixup! |squash! |amend! )') { exit 0 }

$types = 'feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'
$pattern = "^($types)(\([a-z0-9._\-/]+\))?(!)?: .{1,}"

if ($subject -notmatch $pattern) {
    Write-Host ""
    Write-Host "COMMIT ABGELEHNT (Conventional Commits):" -ForegroundColor Red
    Write-Host "  Subject: $subject" -ForegroundColor Yellow
    Write-Host "  Erwartet: <type>(scope)?: <beschreibung>" -ForegroundColor Yellow
    Write-Host "  type in: $($types -replace '\|', ', ')" -ForegroundColor Yellow
    Write-Host "  Beispiel: feat(provisioning): prek als Hook-Runner" -ForegroundColor Yellow
    exit 1
}

exit 0
