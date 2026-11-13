#Requires -Version 5.1
# Test der Auswahl in scripts/post_merge_regenerate.ps1: welche Quellen-Dateien welchen Generator anstossen. Baut nichts.
# Usage:  .\scripts\dev\post_merge_regenerate_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$script = Join-Path $repo 'scripts\post_merge_regenerate.ps1'
$failed = 0
function Test-Case($name, [string[]]$files, $expect) {
    $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $script -Files $files) -join ''
    if ($out -eq $expect) { Write-Host "  [PASS] $name" } else { Write-Host "  [FAIL] $name (erwartet '$expect', war '$out')" -ForegroundColor Red; $script:failed++ }
}
Test-Case 'keine relevante Datei'             @('README.md', 'packages/finance/manifest.json') 'Tokens=False Site=False'
Test-Case 'Token-Quelle: Tokens und Site'    @('config/ui.tokens.json')                       'Tokens=True Site=True'
Test-Case 'Token-Skript mit Windows-Pfad'    @('scripts\build_ui_tokens.ps1')                  'Tokens=True Site=True'
Test-Case 'Site-Quelle: nur Site'            @('docs/site/layouts/partials/mark.html')                'Tokens=False Site=True'
Test-Case 'Site-Output allein loest nichts'  @('docs/site/public/index.html')                  'Tokens=False Site=False'
Test-Case 'Site-Skript'                       @('scripts/build_site.ps1')                       'Tokens=False Site=True'
# Echter Git-Ablauf im Wegwerf-Repo (-Plan baut nichts). Ohne die GIT_*-Variablen wuerde jedes git hier das Repo des Aufrufers
# treffen, wenn der Test aus einem Git-Hook laeuft.
Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' } | ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pmr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
# Git schreibt Hinweise nach stderr; unter ErrorActionPreference=Stop macht PS 5.1 daraus einen Abbruch.
function Invoke-Git {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git -C $tmp -c user.email=t@example.org -c user.name=t -c commit.gpgsign=false -c core.autocrlf=false -c core.hooksPath=NUL @args *> $null
    $ErrorActionPreference = $prev
}
function Test-Plan($name, [string[]]$extra, $expect) {
    Push-Location $tmp
    try { $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $script @extra -Plan) -join '' } finally { Pop-Location }
    if ($out -eq $expect) { Write-Host "  [PASS] $name" } else { Write-Host "  [FAIL] $name (erwartet '$expect', war '$out')" -ForegroundColor Red; $script:failed++ }
}
try {
    Invoke-Git init -q -b main
    $page = Join-Path $tmp 'docs\site\content\page.md'
    New-Item -ItemType Directory -Path (Split-Path $page) | Out-Null
    [System.IO.File]::WriteAllText($page, "eins`ntwo`ndrei`n")
    Invoke-Git add -A; Invoke-Git commit -q -m base
    Invoke-Git checkout -q -b side
    [System.IO.File]::WriteAllText($page, "eins`nside`ndrei`n"); Invoke-Git commit -qam side
    Invoke-Git checkout -q main
    [System.IO.File]::WriteAllText($page, "eins`nmain`ndrei`n"); Invoke-Git commit -qam main
    # Konflikt-Merge: git ruft post-merge nicht; nach der Aufloesung schliesst `git commit` ihn ab.
    Invoke-Git merge side
    [System.IO.File]::WriteAllText($page, "eins`nbeide`ndrei`n"); Invoke-Git add -A; Invoke-Git commit -q -m 'merge side'
    Test-Plan 'Konflikt-Merge-Commit: -Commit findet die Site-Quelle' @('-Commit') 'Tokens=False Site=True'
    # Ein gewoehnlicher Commit loest nichts aus, auch wenn ORIG_HEAD vom Merge noch auf einen Site-Stand zeigt.
    [System.IO.File]::WriteAllText((Join-Path $tmp 'notes.txt'), "x`n"); Invoke-Git add -A; Invoke-Git commit -q -m plain
    Test-Plan 'gewoehnlicher Commit: -Commit tut nichts' @('-Commit') ''
    # Sauberer Merge ohne Konflikt: der post-merge-Weg (ORIG_HEAD..HEAD) findet die Quelle.
    Invoke-Git checkout -q -b other main~1
    $layout = Join-Path $tmp 'docs\site\layouts\x.html'
    New-Item -ItemType Directory -Path (Split-Path $layout) | Out-Null
    [System.IO.File]::WriteAllText($layout, "<p>x</p>`n"); Invoke-Git add -A; Invoke-Git commit -q -m layout
    Invoke-Git checkout -q main
    Invoke-Git merge --no-ff -m 'merge other' other
    Test-Plan 'sauberer Merge: ORIG_HEAD..HEAD findet die Site-Quelle' @() 'Tokens=False Site=True'
    # Scheitert der Generator (Stand-in mit Ausgabe UND Exit 3), steht die Warnung da, nicht die Erfolgsmeldung.
    $stub = Join-Path $tmp 'scripts\build_site.ps1'
    New-Item -ItemType Directory -Path (Split-Path $stub) | Out-Null
    [System.IO.File]::WriteAllText($stub, "Write-Output 'zeile eins'`nWrite-Output 'zeile zwei'`nexit 3`n")
    Push-Location $tmp
    try { $log = (& powershell -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | Out-String) } finally { Pop-Location }
    if ($log -match 'build_site.ps1 ist fehlgeschlagen \(Exit 3\)' -and $log -notmatch 'Ergebnis steht als Aenderung') { Write-Host '  [PASS] Generator scheitert: Warnung statt Erfolgsmeldung' }
    else { Write-Host "  [FAIL] Generator scheitert: Warnung statt Erfolgsmeldung (Ausgabe: $log)" -ForegroundColor Red; $failed++ }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host "post_merge_regenerate_test: $failed Fehler."
exit $failed
