#Requires -Version 5.1
# Selbsttest des -Suites-Filters von run_free_gates.ps1: ein Filter fahren nur die genannten Suiten (frueher liefen trotz Filter alle).
# Kein Substrat, keine Kosten: -ListPlan gibt den Plan aus, ohne etwas zu starten.
# Usage:  .\scripts\dev\run_free_gates_filter_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$gates = Join-Path $repo 'scripts\dev\run_free_gates.ps1'
$env:N8NTEST_CONTAINER = 'rfg-filter-test'; $env:N8NTEST_PORT = '1'; $env:DBTEST_CONTAINER = 'rfg-filter-test-db'; $env:DBTEST_PG_PORT = '1'
$failed = 0
function Assert-That([bool]$Cond, [string]$Name) {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}
# PS 5.1: ConvertFrom-Json gibt ein JSON-Array als EIN Objekt in die Pipeline -> erst zuweisen.
function ConvertFrom-JsonList([string]$t) { $o = $t.Trim() | ConvertFrom-Json; @($o) }
function Get-Plan([hashtable]$Splat) { ConvertFrom-JsonList (& $gates -ListPlan @Splat | Out-String) }

$all = ConvertFrom-JsonList (& $gates -ListSuites | Out-String)
$plan = @(Get-Plan @{})
Assert-That ($plan.Count -eq $all.Count) 'ohne Filter: alle Suiten'
$plan = @(Get-Plan @{ Suites = 'mr_estate,hitl_gate' })
Assert-That ($plan.Count -eq 2 -and $plan[0] -eq 'mr_estate' -and $plan[1] -eq 'hitl_gate') '-Suites mr_estate,hitl_gate: genau diese zwei'
$plan = @(Get-Plan @{ Suites = 'infra' })
Assert-That ($plan.Count -eq 1 -and $plan[0] -eq 'infra') '-Suites infra: nur infra'
$threw = $false; try { [void](& $gates -ListPlan -Suites nope) } catch { $threw = $true }
Assert-That $threw 'unbekannte Suite wirft'
$threw = $false; try { [void](& $gates -ListPlan -Suites infra -Parallel) } catch { $threw = $true }
Assert-That $threw '-Suites mit -Parallel wirft'
exit $failed