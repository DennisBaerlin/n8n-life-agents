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
$plan = @(Get-Plan @{ Suites = 'backup' })
$parts = @($all | Where-Object { $_ -match '^backup_[0-9]+$' })
Assert-That ($parts.Count -ge 2 -and ($plan -join ',') -eq ($parts -join ',')) "-Suites backup: alle Teile ($($plan -join ','))"
# CI-Matrix: jede Suite genau einmal in genau einem Job, kein leerer Job (sonst fehlte eine Suite still in der CI).
$jobs = @(ConvertFrom-JsonList (& $gates -ListJobs | Out-String))
$inJobs = @($jobs | ForEach-Object { $_ -split ',' })
Assert-That ($jobs.Count -gt 1 -and -not @($jobs | Where-Object { -not $_ }).Count) "-ListJobs: $($jobs.Count) Jobs, keiner leer"
Assert-That ((@($inJobs | Sort-Object) -join ',') -eq (@($all | Sort-Object) -join ',')) '-ListJobs: jede Suite genau einmal'
# Handstart mit Auswahl (free-gates.yml, Eingabe suites): nur Jobs mit gewaehlten Suiten, gekuerzt; Teil-Name waehlt alle Teile.
$sel = @(ConvertFrom-JsonList (& $gates -ListJobs -Suites 'mr_estate,backup' | Out-String))
$selSuites = @($sel | ForEach-Object { $_ -split ',' })
Assert-That ((@($selSuites | Sort-Object) -join ',') -eq (@(@('mr_estate') + $parts | Sort-Object) -join ',')) "-ListJobs -Suites mr_estate,backup: $($sel -join ' | ')"
$threw = $false; try { [void](& $gates -ListJobs -Suites nope) } catch { $threw = $true }
Assert-That $threw '-ListJobs mit unbekannter Suite wirft'
$threw = $false; try { [void](& $gates -ListPlan -Suites nope) } catch { $threw = $true }
Assert-That $threw 'unbekannte Suite wirft'
$threw = $false; try { [void](& $gates -ListPlan -Suites infra -Parallel) } catch { $threw = $true }
Assert-That $threw '-Suites mit -Parallel wirft'
exit $failed