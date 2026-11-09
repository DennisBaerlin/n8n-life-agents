#Requires -Version 5.1
# Prueft die Positionsrechnung der Ersteinrichtung gegen ein lokales Test-Paket mit Beispieldaten (kein Gate).
# Rechnet fn_setup_positions auf export.csv mit den Einstand-Antworten aus user_inputs.json und vergleicht Stueck, Einstand und Euro-Wert
# (Mocks price_feed_mock.json, fx_mock.json) mit expected_positions.json und expected_valuation.json. Ausgabe nur Anzahlen und Muster-ISIN, keine Werte.
# Fehlt das Paket: "uebersprungen", Exit 0.
# Aufruf:  $env:DBTEST_CONTAINER='...'; .\scripts\dev\test_setup_sample_package.ps1 [-PackageDir <Pfad>]
#          (Pfad sonst $env:LIFEAGENTS_SETUP_TEST_PACKAGE)
# Voraussetzung: laufender Test-Container (db_test.ps1 hat das Schema gebaut). Exit-Code = Anzahl Abweichungen.
param([string]$PackageDir = $env:LIFEAGENTS_SETUP_TEST_PACKAGE)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8 = [System.Text.UTF8Encoding]::new($false)

if (-not $PackageDir -or -not (Test-Path (Join-Path $PackageDir 'export.csv'))) {
    Write-Host 'uebersprungen: kein Test-Paket (LIFEAGENTS_SETUP_TEST_PACKAGE oder -PackageDir).'
    exit 0
}
if (-not $env:DBTEST_CONTAINER) { throw 'DBTEST_CONTAINER fehlt (eigener Test-Container).' }
function Read-J([string]$n) { return [IO.File]::ReadAllText((Join-Path $PackageDir $n), $Utf8) | ConvertFrom-Json }

$csv = Import-Csv (Join-Path $PackageDir 'export.csv') -Encoding UTF8
$hdr = @($csv[0].PSObject.Properties.Name)
$grid = New-Object System.Collections.ArrayList
[void]$grid.Add($hdr)
foreach ($r in $csv) { [void]$grid.Add(@($hdr | ForEach-Object { [string]$r.$_ })) }
$table = (@{ rows = $grid } | ConvertTo-Json -Depth 4 -Compress)

$inputs = Read-J 'user_inputs.json'
$answers = @{}
foreach ($i in $inputs.positions_needing_cost) {
    $total = if ($i.user_input.kind -eq 'per_share') { [decimal]$i.user_input.expected_total } else { [decimal]$i.user_input.value_eur }
    $answers[$i.isin] = $total
}
$amounts = ($answers | ConvertTo-Json -Compress)
$sql = @"
SET client_min_messages = error;
BEGIN;
SELECT finance.fn_create_account('{"name":"__sample_pkg__","account_type":"cash","currency":"EUR","bank":"Testbroker","opening_balance":1}'::jsonb) \gset c_
WITH n AS (SELECT finance.fn_bank_export_normalize(`$j`$$table`$j`$::jsonb)->'rows' AS r),
     a AS (SELECT id FROM finance.accounts WHERE name = '__sample_pkg__'),
     o AS (SELECT finance.fn_setup_effective_rows(n.r, '{}'::jsonb, core.fn_today())->'open_items' AS items FROM n),
     d AS (SELECT COALESCE(jsonb_object_agg(i->>'key', jsonb_build_object('amount', (`$k`$$amounts`$k`$::jsonb->>(i->>'isin'))::numeric)), '{}'::jsonb) AS dec
           FROM o, jsonb_array_elements(o.items) i WHERE `$k`$$amounts`$k`$::jsonb ? (i->>'isin'))
SELECT 'RESULT' || finance.fn_setup_positions(n.r, d.dec, a.id, core.fn_today())::text FROM n, a, d;
ROLLBACK;
"@
$tmp = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($tmp, $sql, $Utf8)
    $out = Get-Content $tmp -Raw -Encoding UTF8 | docker exec -i $env:DBTEST_CONTAINER psql -U postgres -d lifeagents_dbtest -At
} finally { Remove-Item $tmp -Force }
$line = @($out) | Where-Object { $_ -like 'RESULT*' } | Select-Object -First 1
if (-not $line) { throw 'Keine Rueckgabe aus fn_setup_positions.' }
$res = $line.Substring(6) | ConvertFrom-Json

$fail = 0
function Near($a, $b, $tol) { return [math]::Abs([double]$a - [double]$b) -le $tol }
$exp = Read-J 'expected_positions.json'
$got = @{}
foreach ($p in $res.positions) { $got[$p.isin] = $p }
foreach ($e in ($exp.positions | Where-Object { $_.status -eq 'open' })) {
    $p = $got[$e.isin]
    if (-not $p) { Write-Host "FEHLT: $($e.isin)"; $fail++; continue }
    if (-not (Near $p.shares $e.shares 0.000001)) { Write-Host "STUECK weicht ab: $($e.isin)"; $fail++ }
    if (-not (Near $p.cost $e.cost_eur 0.05)) { Write-Host "EINSTAND weicht ab: $($e.isin)"; $fail++ }
}
foreach ($e in ($exp.positions | Where-Object { $_.status -ne 'open' })) {
    if ($got.ContainsKey($e.isin)) { Write-Host "SOLLTE ZU SEIN: $($e.isin) ($($e.status))"; $fail++ }
}
$feed = @{}; foreach ($f in (Read-J 'price_feed_mock.json')) { $feed[$f.isin] = $f }
$fx = (Read-J 'fx_mock.json').rates
$val = Read-J 'expected_valuation.json'
foreach ($v in $val.positions) {
    $p = $got[$v.isin]; $f = $feed[$v.isin]
    if (-not $p -or -not $f) { Write-Host "BEWERTUNG unvollstaendig: $($v.isin)"; $fail++; continue }
    $rate = if ($f.listing_currency -eq 'EUR') { 1 } else { [double]$fx.($f.listing_currency) }
    if (-not (Near (([double]$p.shares * [double]$f.latest_price) / $rate) $v.market_value_eur 0.05)) { Write-Host "EUROWERT weicht ab: $($v.isin)"; $fail++ }
}
Write-Host ("Positionen: {0}, offene Punkte: {1}, Abweichungen: {2}" -f @($res.positions).Count, @($res.open_items).Count, $fail)
exit $fail
