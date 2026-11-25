#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/gate_wiring_lint.ps1 in einem Wegwerf-Baum (-Root): ein Test ohne Gate und ohne Marker, ein
# Marker ohne Grund und ein Marker neben einem Gate muessen rot werden; Gate (Commit-Hook, freie Suiten, Workflow) und Marker mit
# Grund gruen. Kein Docker, kein git.
# Usage: .\scripts\dev\gate_wiring_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\gate_wiring_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

function New-Tree([hashtable]$Files) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('gwl_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
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
$D = 'scripts/dev'
$T = "$D/neu_test.ps1"
$hook = "- id: neu-test`n  entry: powershell -File $T`n"
Test-Case 'Test ohne Gate und ohne Marker ist rot' @{ $T = "# Kopf`n" } $true 'neu_test.ps1'
Test-Case 'Commit-Hook ist ein Gate' @{ $T = "# Kopf`n"; '.pre-commit-config.yaml' = $hook } $false ''
Test-Case 'freie Suiten sind ein Gate' @{ $T = "# Kopf`n"; "$D/run_free_gates.ps1" = "neu = @{ Script = '$T' }`n" } $false ''
Test-Case 'Workflow ist ein Gate' @{ $T = "# Kopf`n"; '.github/workflows/x.yml' = "run: ./$T`n" } $false ''
Test-Case 'Marker mit Grund ist gruen' @{ $T = "# Kopf`n# gate: manual (echter Schluessel noetig)`n" } $false ''
Test-Case 'Marker ohne Grund ist rot' @{ $T = "# Kopf`n# gate: manual`n" } $true 'ohne Grund'
Test-Case 'Marker mit leerer Klammer ist rot' @{ $T = "# Kopf`n# gate: manual ()`n" } $true 'ohne Grund'
Test-Case 'Marker neben einem Gate ist rot' @{ $T = "# gate: manual (alt)`n"; '.pre-commit-config.yaml' = $hook } $true 'Marker'
Test-Case 'aehnlicher Name ist kein Gate' @{ $T = "# Kopf`n"; '.pre-commit-config.yaml' = "entry: $D/xneu_test.ps1`n" } $true 'neu_test.ps1'
Test-Case 'Marker unterhalb der Kopfzeilen zaehlt nicht' @{ $T = ((1..45 | ForEach-Object { '# z' }) -join "`n") + "`n# gate: manual (zu spaet)`n" } $true 'haengt an keinem Gate'

if ($fails -eq 0) { Write-Host 'PASS gate_wiring_lint_test' -ForegroundColor Green } else { Write-Host "FAIL gate_wiring_lint_test ($fails)" -ForegroundColor Red }
exit $fails
