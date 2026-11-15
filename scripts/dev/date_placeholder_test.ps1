#Requires -Version 5.1
# Selbsttest der Datums-Platzhalter {{date:<offset>[@<tag>]}} (Grammatik: scripts/lib/date_placeholder.ps1). Kein Substrat, keine Kosten.
# Dieselben Pruefwerte (tests/util/date_placeholder_vectors.json, u. a. Monats- und Jahreswechsel) laufen gegen die PowerShell-Seite
# und gegen den JS-Zwilling in tests/mock_llm/server.js (node lokal, sonst Docker-Image des workflow_lint).
# Usage:  .\scripts\dev\date_placeholder_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $PSScriptRoot '..\lib\date_placeholder.ps1')
$vec = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\util\date_placeholder_vectors.json'), $Utf8NoBom) | ConvertFrom-Json
$failed = 0
function Assert-That([bool]$Cond, [string]$Name) {
    if ($Cond) { Write-Host "  [PASS] $Name" -ForegroundColor Green } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}
function ConvertTo-Day([string]$s) { [datetime]::ParseExact($s, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }

Write-Host "PowerShell"
foreach ($x in @($vec.vectors)) {
    $got = Resolve-DatePlaceholder -Text "{{date:$($x.expr)}}" -Today (ConvertTo-Day $x.today)
    Assert-That ($got -eq $x.expect) "$($x.today) {{date:$($x.expr)}} = $($x.expect)  ($($x.why))"
}
foreach ($x in @($vec.text)) { Assert-That ((Resolve-DatePlaceholder -Text $x.in -Today (ConvertTo-Day $x.today)) -eq $x.expect) "Text: $($x.in)" }
foreach ($bad in @($vec.invalid)) {
    $threw = $false; try { [void](Resolve-DatePlaceholder -Text $bad -Today (ConvertTo-Day '2026-11-15')) } catch { $threw = $true }
    Assert-That $threw "wirft bei $bad"
}
foreach ($t in @($vec.lint.ok)) { Assert-That (@(Get-DatePlaceholderError $t).Count -eq 0) "Lint ok: $t" }
foreach ($t in @($vec.lint.bad)) { Assert-That (@(Get-DatePlaceholderError $t).Count -gt 0) "Lint meldet: $t" }
$obj = '{"task":"ab {{date:0d}}","expected_tool_args":{"first":"{{date:+1d}}","amount":50,"list":["{{date:+2d}}"]},"n":null}' | ConvertFrom-Json
$res = Resolve-DatePlaceholderDeep -Obj $obj -Today (ConvertTo-Day '2026-11-15')
Assert-That ($res.task -eq 'ab 2026-11-15' -and $res.expected_tool_args.first -eq '2026-11-16' -and $res.expected_tool_args.amount -eq 50 -and $res.expected_tool_args.list[0] -eq '2026-11-17') 'Deep: ganzer Testfall (task, expected_tool_args, Liste, Zahl bleibt)'

Write-Host "Feste Daten (Get-FixedDateFinding, mock_lint C5)"
$t0 = ConvertTo-Day '2026-11-15'
function Get-FixedCount([string]$Json) { @(Get-FixedDateFinding -Obj ($Json | ConvertFrom-Json) -Today $t0).Count }
Assert-That ((Get-FixedCount '{"task":"ab 2026-12-01"}') -eq 1) 'Zukunft (ISO) in task ist ein Fund'
Assert-That ((Get-FixedCount '{"task":"erste Rate am 15.12.2026"}') -eq 1) 'Zukunft (TT.MM.JJJJ) in task ist ein Fund'
Assert-That ((Get-FixedCount '{"task":"am 2024-11-16"}') -eq 1) 'knapp unter zwei Jahre zurueck ist ein Fund'
Assert-That ((Get-FixedCount '{"task":"am 2024-11-15"}') -eq 0) 'genau zwei Jahre zurueck ist kein Fund'
Assert-That ((Get-FixedCount '{"task":"am 01.07.2020 und 2019-03-04"}') -eq 0) 'laenger als zwei Jahre zurueck ist kein Fund'
Assert-That ((Get-FixedCount '{"task":"am 31.02.2027, Version 2026-13-40"}') -eq 0) 'Unmoegliche Kalenderdaten sind kein Fund'
Assert-That ((Get-FixedCount '{"task":"{{date:+30d@2}} und 0d"}') -eq 0) 'Platzhalter ist kein Fund'
Assert-That ((Get-FixedCount '{"notes":"Fund 2026-11-05","name":"x 2027-01-01","setup_sql":"SELECT 2027-01-01","_comment":"2027-01-01","task":"ohne Datum"}') -eq 0) 'notes, name, _comment und setup_sql bleiben frei'
Assert-That ((Get-FixedCount '{"task":"ab 2026-12-01","fixed_date_reason":"Stichtag ist der Testgegenstand"}') -eq 0) 'fixed_date_reason nimmt den Fall aus'
Assert-That ((Get-FixedCount '{"task":"ab 2026-12-01","fixed_date_reason":"  "}') -eq 1) 'leeres fixed_date_reason nimmt nichts aus'
Assert-That ((Get-FixedCount '{"expected_tool_args":{"d":"2027-01-02","n":5},"expected_behavior":"bis 2027-02-03"}') -eq 2) 'expected_tool_args und expected_behavior werden gelesen'
Assert-That ((Get-FixedCount '{"turns":[{"text":"am 2027-01-02"},"und 03.04.2027"]}') -eq 2) 'turns (Objekte und Strings) werden gelesen'
Assert-That ((Get-FixedCount '{"match":"x","calls":[{"tool":"t","args":{"transaction_date":"2026-06-16"}}]}') -eq 1) 'Szenario-Args (calls) werden gelesen'
Assert-That ((Get-FixedCount '{"task":"a 2027-01-02 b 2027-01-03"}') -eq 2) 'jedes Literal zaehlt einzeln'

Write-Host "JS (tests/mock_llm/server.js)"
$node = Get-Command node -ErrorAction SilentlyContinue
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
if ($node) { $out = & $node.Source (Join-Path $repo 'tests/mock_llm/date_placeholder_check.js') 2>&1; $code = $LASTEXITCODE }
else { $out = & docker run --rm -v "${repo}:/repo" -w /repo node:20.18.0-alpine node tests/mock_llm/date_placeholder_check.js 2>&1; $code = $LASTEXITCODE }
$ErrorActionPreference = $prev
$out | ForEach-Object { Write-Host "$_" }
Assert-That ($code -eq 0) 'JS-Zwilling besteht dieselben Pruefwerte'
Assert-That (@($out | Where-Object { "$_" -match 'PASS' }).Count -ge (@($vec.vectors).Count + @($vec.text).Count + @($vec.invalid).Count)) 'JS hat alle Pruefwerte gelaufen'

Write-Host ""
if ($failed -eq 0) { Write-Host "date_placeholder_test: alles gruen." -ForegroundColor Green } else { Write-Host "date_placeholder_test: $failed Fehler." -ForegroundColor Red }
exit $failed
