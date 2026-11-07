#Requires -Version 5.1
# Test der Auswahl in scripts/post_merge_regenerate.ps1: welche Quellen-Dateien welchen Generator anstossen. Baut nichts.
# Usage:  .\scripts\dev\post_merge_regenerate_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
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
Write-Host "post_merge_regenerate_test: $failed Fehler."
exit $failed
