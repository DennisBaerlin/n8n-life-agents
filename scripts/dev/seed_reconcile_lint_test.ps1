#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/seed_reconcile_lint.ps1 in einem Wegwerf-Baum (-Root): eine Tabelle, die der Seeder aufraeumt und
# der DB-Test nicht listet (und umgekehrt), muss rot werden; gleiche Mengen gruen; Definition und Kommentarzeile des Seeders zaehlen
# nicht als Aufruf. Kein Docker, kein git.
# Usage: .\scripts\dev\seed_reconcile_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\seed_reconcile_lint.ps1'
$fails = 0
. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$SEED = 'provisioning/lib/seed_data.sh'
$TEST = 'tests/db/core/test_seed_reconcile_registry_unreferenced.sql'
function Seed([string[]]$Calls) { "_seed_reconcile() {`n  :`n}`n# _seed_reconcile core.nur_kommentar x y`n" + (($Calls | ForEach-Object { "  _seed_reconcile $_ key pkg list`n" }) -join '') }
function Sql([string[]]$Tabs) { "DECLARE`n  v_tabs REGCLASS[] := ARRAY[" + (($Tabs | ForEach-Object { "'$_'" }) -join ', ') + "]::regclass[];`n" }

function Test-Case([string]$Name, [string[]]$Calls, [string[]]$Tabs, [bool]$ExpectRed, [string]$ExpectText) {
    Test-LintCase -Lint $lint -Name $Name -Files @{ $SEED = (Seed $Calls); $TEST = (Sql $Tabs) } -ExpectRed $ExpectRed -ExpectText $ExpectText
}

Test-Case 'gleiche Mengen sind gruen' @('core.a_tab', 'core.b_tab') @('core.b_tab', 'core.a_tab') $false ''
Test-Case 'Tabelle des Seeders fehlt im Test' @('core.a_tab', 'core.b_tab') @('core.a_tab') $true 'core.b_tab'
Test-Case 'Tabelle im Test, Seeder raeumt sie nicht auf' @('core.a_tab') @('core.a_tab', 'core.c_tab') $true 'core.c_tab'
Test-Case 'Kommentarzeile und Definition zaehlen nicht' @('core.a_tab') @('core.a_tab') $false ''

if ($fails -eq 0) { Write-Host 'PASS seed_reconcile_lint_test' -ForegroundColor Green } else { Write-Host "FAIL seed_reconcile_lint_test ($fails)" -ForegroundColor Red }
exit $fails
