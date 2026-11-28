#Requires -Version 5.1
# Selbsttest von run_free_gates.ps1: ein -Suites-Filter faehrt nur die genannten Suiten, die CI-Matrix (-ListJobs) traegt jede Suite genau einmal, und der Grund einer abgebrochenen Suite steht lesbar im Log.
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
# PS 5.1: ConvertFrom-Json gibt ein JSON-Array als ein Objekt in die Pipeline -> erst zuweisen.
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

# Bricht eine Suite mit throw ab, muss der Grund lesbar im Suite-Log stehen (Windows PowerShell 5.1 ohne Profil schreibt `*>` als
# UTF-16; ein Anhang in anderer Kodierung waere Zeichensalat). Invoke-Gate kommt aus dem Skript selbst (AST), ohne dass es laeuft.
$u8 = New-Object System.Text.UTF8Encoding($true)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($gates, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Invoke-Gate' }, $true)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rfg_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    [System.IO.File]::WriteAllText((Join-Path $tmp 'boom.ps1'), "Write-Host 'Zeile davor'`nthrow 'Substrat nicht erreichbar'`n", $u8)
    $child = "`$ErrorActionPreference = 'Stop'`n`$RepoRoot = '$tmp'`n`$env:TEMP = '$tmp'`n`$results = New-Object System.Collections.Generic.List[object]`n" +
        $fn.Extent.Text + "`nInvoke-Gate 'boom' 'boom.ps1'`nexit `$results[-1].Exit`n"
    [System.IO.File]::WriteAllText((Join-Path $tmp 'child.ps1'), $child, $u8)
    $null = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'child.ps1')
    Assert-That ($LASTEXITCODE -eq 99) 'Suite mit throw: Exit 99'
    $log = Join-Path $tmp 'free_gate_rfg-filter-test_boom.log'
    Assert-That ([bool](Select-String -Path $log -Pattern 'Substrat nicht erreichbar' -ErrorAction SilentlyContinue)) 'Suite mit throw: Grund steht lesbar im Log'
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
exit $failed