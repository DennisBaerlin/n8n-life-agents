#Requires -Version 5.1
# Fall-Tests von scripts/prop_test_lint.ps1 (Bausteine scripts/lib/prop_test_coverage.ps1) in einem Wegwerf-Baum:
# welche fn gilt als aendernd, was zaehlt als Aufruf in einem Eigenschafts-Test, Abgleich mit der schrumpfenden
# Ausnahmeliste, und der Lint selbst gegen den Baum (Exit-Code).
# Kein Docker, kein git. Usage: .\scripts\dev\prop_test_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\prop_test_coverage.ps1')
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:fails++ }
}
function New-Tree([hashtable]$Files) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ptl_' + [guid]::NewGuid().ToString('N'))
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        [System.IO.File]::WriteAllText($p, $Files[$rel], $u8)
    }
    return $root
}
function Invoke-Lint([string]$Root) {
    # dieselbe PowerShell wie der Aufrufer (5.1 lokal, pwsh auf dem Linux-Runner); eigener Prozess, weil der Lint mit exit endet
    $null = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot '..\prop_test_lint.ps1') -Root $Root
    return $LASTEXITCODE
}
function Fn([string]$Name, [string]$Body) {
    return "-- Kopf: nennt UPDATE finance.loans nur im Kommentar`nCREATE OR REPLACE FUNCTION $Name(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS `$`$`nBEGIN`n  $Body`n  RETURN '{}'::jsonb;`nEND;`n`$`$;`n"
}

$M = 'packages/finance/db/migrations'; $TD = 'tests/db/finance'; $AL = 'tests/util/prop_test_allowlist.json'
$tree = New-Tree @{
    "$M/R__fn_set_a.sql"  = (Fn 'finance.fn_set_a'  'UPDATE finance.recurring_payments SET amount = 1 WHERE id = 1;')
    "$M/R__fn_set_b.sql"  = (Fn 'finance.fn_set_b'  'UPDATE finance.savings_goals SET target_date = NULL WHERE id = 1;')
    "$M/R__fn_read_c.sql" = (Fn 'finance.fn_read_c' 'PERFORM 1 FROM finance.recurring_payments;')
    "$M/R__fn_set_d.sql"  = (Fn 'finance.fn_set_d'  'UPDATE finance.accounts SET name = NULL WHERE id = 1;')
    "$TD/test_prop_a.sql" = "BEGIN;`nDO `$`$ BEGIN`n  PERFORM finance.fn_set_a('{}'::jsonb);`n  -- finance.fn_set_b( steht nur im Kommentar`nEND `$`$;`nROLLBACK;`n"
    "$TD/test_fn_set_b.sql" = "BEGIN;`nDO `$`$ BEGIN PERFORM finance.fn_set_b('{}'::jsonb); END `$`$;`nROLLBACK;`n"
}
try {
    $watched = Get-PropWatchedFns -Root $tree
    Check 'aendernd = UPDATE auf eine beobachtete Tabelle im Code (Lese-fn, andere Tabelle und Kommentar zaehlen nicht)' ((@($watched.Keys | Sort-Object) -join ',') -eq 'finance.fn_set_a,finance.fn_set_b') (@($watched.Keys | Sort-Object) -join ',')

    $tested = @(Get-PropTestedFns -Root $tree)
    Check 'getestet = Aufruf in test_prop_*.sql (Kommentar und test_fn_*.sql zaehlen nicht)' (($tested -join ',') -eq 'finance.fn_set_a') ($tested -join ',')

    $r = Compare-PropGap -Watched $watched -Tested $tested -Allow @{}
    Check 'ohne Liste: aendernde fn ohne Eigenschafts-Test ist ein Fehler' ((@($r.Errors).Count -eq 1) -and ((@($r.Errors) -join '|') -match 'finance\.fn_set_b')) (@($r.Errors) -join '|')
    Check 'Lint gegen den Baum: rot' ((Invoke-Lint $tree) -eq 1)

    $r = Compare-PropGap -Watched $watched -Tested $tested -Allow @{ 'finance.fn_set_b' = 'Grund' }
    Check 'mit Eintrag samt Grund: gruen' (@($r.Errors).Count -eq 0) (@($r.Errors) -join '|')

    $r = Compare-PropGap -Watched $watched -Tested $tested -Allow @{ 'finance.fn_set_b' = ' ' }
    Check 'Eintrag ohne Grund ist ein Fehler' ((@($r.Errors) -join '|') -match 'ohne Grund') (@($r.Errors) -join '|')

    $r = Compare-PropGap -Watched $watched -Tested $tested -Allow @{ 'finance.fn_set_b' = 'Grund'; 'finance.fn_set_a' = 'Grund' }
    Check 'Eintrag fuer eine fn mit Test ist ein Fehler (Liste schrumpft nur)' ((@($r.Errors) -join '|') -match 'finance\.fn_set_a') (@($r.Errors) -join '|')

    $r = Compare-PropGap -Watched $watched -Tested $tested -Allow @{ 'finance.fn_set_b' = 'Grund'; 'finance.fn_read_c' = 'Grund' }
    Check 'Eintrag fuer eine fn ohne beobachtetes UPDATE ist ein Fehler' ((@($r.Errors) -join '|') -match 'finance\.fn_read_c') (@($r.Errors) -join '|')

    [System.IO.File]::WriteAllText((New-Item -ItemType File -Force -Path (Join-Path $tree $AL)).FullName, '[{"fn":"finance.fn_set_b","reason":"Grund"}]', $u8)
    Check 'Lint liest die Ausnahmeliste: gruen' ((Invoke-Lint $tree) -eq 0)
} finally { Remove-Item -Recurse -Force $tree -ErrorAction SilentlyContinue }

if ($fails -eq 0) { Write-Host 'PASS prop_test_lint_test' -ForegroundColor Green } else { Write-Host "prop_test_lint_test: $fails Fehler" -ForegroundColor Red }
exit $fails
