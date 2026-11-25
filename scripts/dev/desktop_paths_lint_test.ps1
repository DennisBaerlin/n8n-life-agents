#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/desktop_paths_lint.ps1 in einem Wegwerf-Baum (-Root): Eine Datei ausserhalb von
# provisioning/desktop, die die Start-App einliest, muss in beiden paths:-Listen von desktop.yml stehen; sonst wird
# der Lint rot. Kein Docker, kein git.
# Usage: .\scripts\dev\desktop_paths_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\desktop_paths_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

function New-Tree([hashtable]$Files) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('dpl_' + [guid]::NewGuid().ToString('N'))
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        [System.IO.File]::WriteAllText($p, $Files[$rel], $u8)
    }
    return $root
}

function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText) {
    $root = New-Tree $Files
    try {
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root) -join "`n"
        $red = $LASTEXITCODE -ne 0
        $ok = ($red -eq $ExpectRed) -and (-not $ExpectText -or $out -match [regex]::Escape($ExpectText))
        if ($ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL $Name (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $root }
}

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$D = 'provisioning/desktop'; $L = 'packages/core/locales'; $T = 'tests/backup/fixtures'
$compose = 'provisioning/compose/compose.yml'; $mark = 'docs/site/layouts/partials/mark.html'

function New-Workflow([string[]]$Push, [string[]]$Pr) {
    $y = "name: desktop`non:`n  push:`n    branches-ignore: [main]`n    paths:`n"
    foreach ($p in $Push) { $y += "      - '$p'`n" }
    $y += "  pull_request:`n    paths:`n"
    foreach ($p in $Pr) { $y += "      - '$p'`n" }
    $y + "  workflow_dispatch:`n"
}

# Der gruene Grundbaum: die App liest Textkatalog, Notfallblatt-Fixture und compose.yml ein, der Bau liest das Zeichen.
$all = @("$D/**", "$L/**", $compose, "$T/notfallblatt-token.txt", $mark, 'config/ui.tokens.json', '.github/workflows/desktop.yml', '.github/workflows/desktop-build.yml')
$base = @{
    '.github/workflows/desktop.yml'       = New-Workflow $all $all
    '.github/workflows/desktop-build.yml' = "name: desktop-build`njobs:`n  app:`n    steps:`n      - run: |`n          Get-Zeichen '$mark'`n          Get-FileHash '$compose'`n"
    "$D/core/src/texts.rs"                = "static DE: &str = include_str!(`"../../../../$L/de.json`");`n"
    "$D/core/src/backup.rs"               = "fn t() { let s = include_str!(`"../../../../$T/notfallblatt-token.txt`"); }`n"
    "$D/app/tauri.conf.json"              = "{ `"bundle`": { `"resources`": { `"../../compose/compose.yml`": `"compose.yml`" } } }`n"
    "$L/de.json"                          = "{}`n"
    "$T/notfallblatt-token.txt"           = "x`n"
    $compose                              = "x`n"
    $mark                                 = "x`n"
}
function With([hashtable]$Over) { $h = $base.Clone(); foreach ($k in $Over.Keys) { $h[$k] = $Over[$k] }; $h }

Test-Case 'alle eingelesenen Dateien stehen in beiden Listen: gruen' $base $false ''

$noFix = $all | Where-Object { $_ -ne "$T/notfallblatt-token.txt" }
Test-Case 'include_str-Datei fehlt in beiden Listen: rot' (With @{ '.github/workflows/desktop.yml' = New-Workflow $noFix $noFix }) $true "notfallblatt-token.txt"
Test-Case 'include_str-Datei fehlt nur im pull_request: rot' (With @{ '.github/workflows/desktop.yml' = New-Workflow $all $noFix }) $true 'pull_request'
Test-Case 'Datei fehlt nur im push: rot' (With @{ '.github/workflows/desktop.yml' = New-Workflow $noFix $all }) $true 'push'

$noMark = $all | Where-Object { $_ -ne $mark }
Test-Case 'Datei aus dem Bau-Schritt von desktop-build.yml fehlt: rot' (With @{ '.github/workflows/desktop.yml' = New-Workflow $noMark $noMark }) $true 'mark.html'

$noCompose = $all | Where-Object { $_ -ne $compose }
$resOnly = With @{
    '.github/workflows/desktop.yml'       = New-Workflow $noCompose $noCompose
    '.github/workflows/desktop-build.yml' = "name: desktop-build`n"
}
Test-Case 'Datei aus bundle.resources fehlt: rot' $resOnly $true 'compose.yml'

$noWf = $all | Where-Object { $_ -ne '.github/workflows/desktop-build.yml' }
Test-Case 'desktop-build.yml selbst fehlt in den Listen: rot' (With @{ '.github/workflows/desktop.yml' = New-Workflow $noWf $noWf }) $true 'desktop-build.yml'

Test-Case 'nur Wildcard-Eintrag deckt die Datei (Textkatalog): gruen' (With @{ "$L/ko.json" = "{}`n"; "$D/core/src/texts.rs" = "static K: &str = include_str!(`"../../../../$L/ko.json`");`n" }) $false ''

Test-Case 'include_str auf eine Datei im Desktop-Ordner braucht keinen Eintrag: gruen' (With @{ "$D/core/src/lib.rs" = "const A: &str = include_str!(`"admin.rs`");`n"; "$D/core/src/admin.rs" = "x`n" }) $false ''

Test-Case 'include_str auf eine fehlende Datei: rot' (With @{ "$D/core/src/texts.rs" = "static X: &str = include_str!(`"../../../../$L/fehlt.json`");`n" }) $true 'fehlt.json'

if ($fails -eq 0) { Write-Host "desktop_paths_lint_test: OK" -ForegroundColor Green } else { Write-Host "desktop_paths_lint_test: $fails Fehler" -ForegroundColor Red }
exit $fails
