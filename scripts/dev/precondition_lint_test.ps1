#Requires -Version 5.1
# Selbsttest der Regel C7 (mock_lint, scripts/lib/precondition_check.ps1): ein Fall mit setup_sql ohne precondition_sql wird rot,
# eine Vorbedingung ohne DB-Lesezugriff (true, 1 = 1) belegt nichts, ein Allowlist-Eintrag befreit, ein ueberholter Eintrag wird rot.
# Aufruf: .\scripts\dev\precondition_lint_test.ps1     Exit-Code = Anzahl roter Pruefungen. Kein Docker, kein Netz.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\precondition_check.ps1')
$fails = 0
function Check([bool]$ok, [string]$msg) { if ($ok) { Write-Host "  [ok] $msg" } else { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:fails++ } }
function New-Case([string]$id, [hashtable]$p) { $o = [ordered]@{ id = $id }; foreach ($k in $p.Keys) { $o[$k] = $p[$k] }; [pscustomobject]$o }

$sel = "(SELECT count(*) FROM finance.accounts WHERE name = '__E2E__ X') = 1"
$cases = @(
    (New-Case 'a1' @{ setup_sql = 'SELECT 1;' })
    (New-Case 'a2' @{ setup_sql = 'SELECT 1;'; precondition_sql = $sel })
    (New-Case 'a3' @{ setup_sql = 'SELECT 1;'; precondition_sql = 'true' })
    (New-Case 'a4' @{ setup_sql = 'SELECT 1;'; precondition_sql = '1 = 1' })
    (New-Case 'a5' @{ setup_sql = 'SELECT 1;'; precondition_sql = '   ' })
    (New-Case 'a6' @{ task = 'ohne Vorbereitung' })
    (New-Case 'a7' @{ setup_sql = 'SELECT 1;'; precondition_sql = "EXISTS (SELECT 1 FROM agent.persons)" })
)
$f = @(Get-PreconditionFinding -Cases $cases -File 'x.json')
Check ($f.Count -eq 4) "vier rote Faelle (a1, a3, a4, a5), war $($f.Count)"
Check (($f -join ' ') -match 'x\.json\|a1 ' -and ($f -join ' ') -match 'a3' -and ($f -join ' ') -match 'a4' -and ($f -join ' ') -match 'a5') 'Fund nennt Datei|id'
Check (($f -join ' ') -notmatch 'a2|a6|a7') 'Fall mit SELECT/EXISTS und Fall ohne setup_sql bleiben gruen'

$allow = @{ 'x.json|a1' = 'Begruendung' }
$f2 = @(Get-PreconditionFinding -Cases $cases -File 'x.json' -Allow $allow)
Check ($f2.Count -eq 3 -and ($f2 -join ' ') -notmatch 'a1') 'Allowlist befreit genau den genannten Fall'

$entries = @($cases | ForEach-Object { [pscustomobject]@{ File = 'x.json'; Case = $_ } })
Check (@(Get-PreconditionAllowlistStale -Entries $entries -Allow $allow).Count -eq 0) 'Eintrag fuer einen Fall ohne Vorbedingung ist nicht ueberholt'
$stale = @(Get-PreconditionAllowlistStale -Entries $entries -Allow @{ 'x.json|a2' = 'x'; 'x.json|nope' = 'x' })
Check ($stale.Count -eq 2) 'Eintraege fuer Fall mit Vorbedingung bzw. fehlenden Fall sind ueberholt (Ratchet)'

if ($fails -eq 0) { Write-Host 'PASS precondition_lint_test' -ForegroundColor Green } else { Write-Host "precondition_lint_test: $fails rot" -ForegroundColor Red }
exit $fails
