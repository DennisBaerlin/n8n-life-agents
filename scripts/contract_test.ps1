#Requires -Version 5.1
# Contract-Smoke fuer externe APIs. Kein LLM, kein DB-Write -- prueft nur, dass die
# Antwort-Schemata externer Integrationen dem entsprechen, was unsere Workflows erwarten.
# Grund: cron_refresh_fx_rates -> finance.fn_upsert_fx_rates liest p->'rates'->>CCY als
# positive Zahl (jede gelieferte Waehrung) und as_of aus time_last_update_unix. Aendert open.er-api.com sein Schema (oder liefert 0/n-a), schreibt der Cron
# still falsch/nichts -> jede Cross-Currency-Bewertung kippt, ohne dass ein Test es faengt.
# Ausserdem api.frankfurter.dev /v2/rates: EZB-Historie (Zeilen {date, base EUR, quote USD, rate > 0}) und Edelmetalle XAU/XAG
# (rate = EUR je Feinunze), die Eingaenge der Zweige in cron_refresh_fx_rates.
#
# Usage:  .\scripts\contract_test.ps1 [-Verbose]
# Voraussetzung: Netzzugang zu open.er-api.com und api.frankfurter.dev (kein Container, keine .env).
# Exit-Code = Anzahl fehlgeschlagener Contract-Checks; sofort 1, wenn open.er-api.com nicht antwortet (ein Frankfurter-Ausfall
# zaehlt als fehlgeschlagener Check).
param([switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$failed = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $ok = & $Test
        if ($ok) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
        else     { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
    } catch {
        Write-Host "  [FAIL] $Name -- $($_.Exception.Message)" -ForegroundColor Red; $script:failed++
    }
}

Write-Host ""
Write-Host "Contract-Smoke (externe API-Schemata)"
Write-Host ("-" * 60)

# --- open.er-api.com (FX-Kurse) ---
Write-Host "open.er-api.com /v6/latest/EUR :"
$fx = $null
try {
    $fx = Invoke-RestMethod -Uri 'https://open.er-api.com/v6/latest/EUR' -Method Get -TimeoutSec 15
} catch {
    Write-Host "  [FAIL] HTTP-Request fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ("-" * 60); Write-Host "1 Check fehlgeschlagen (API nicht erreichbar)."; exit 1
}

Check 'result == success'        { $fx.result -eq 'success' }
Check 'base_code == EUR'         { $fx.base_code -eq 'EUR' }       # fn_upsert_fx_rates schreibt base='EUR'
Check 'rates-Objekt vorhanden'   { $null -ne $fx.rates }
# fn_upsert_fx_rates liest die Kurse als positive Zahl.
foreach ($ccy in @('USD','CLP','JPY')) {
    Check "rates.$ccy ist positive Zahl" {
        $v = $fx.rates.$ccy
        $n = 0.0
        ($null -ne $v) -and [double]::TryParse(("$v"), [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and ($n -gt 0)
    }
}
# Vorhaltung aller Feed-Waehrungen: die Antwort muss die volle Liste tragen (rund 160).
Check 'rates traegt >= 100 Waehrungen' { @($fx.rates.PSObject.Properties).Count -ge 100 }
# as_of = UTC-Datum dieses Felds (Upsert fx_rates); fehlt es, datiert der Cron einen alten Stand auf heute und
# fn_fx_feed_gap saehe keinen Ausfall.
Check 'time_last_update_unix ist Unix-Zeit (nach 2020)' {
    $t = 0L
    [long]::TryParse(("$($fx.time_last_update_unix)"), [ref]$t) -and ($t -gt 1577836800)
}
if ($Verbose -and $fx) { Write-Host "    USD=$($fx.rates.USD)  CLP=$($fx.rates.CLP)  last_update=$($fx.time_last_update_utc)" -ForegroundColor DarkGray }

# --- Frankfurter v2 (einmaliger EZB-Nachlauf in cron_refresh_fx_rates) ---
# Import ECB history parst eine Liste von {date, base, quote, rate}; aendert sich die Form, laeuft der Nachlauf taeglich
# leer (fn_fx_history_due bleibt faellig), ohne dass ein Alarm kommt.
Write-Host "api.frankfurter.dev /v2/rates (providers=ecb) :"
$hist = $null
try {
    $to = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'); $from = (Get-Date).ToUniversalTime().AddDays(-10).ToString('yyyy-MM-dd')
    $resp = Invoke-RestMethod -Uri "https://api.frankfurter.dev/v2/rates?from=$from&to=$to&base=EUR&providers=ecb&quotes=USD" -Method Get -TimeoutSec 20
    # PS 5.1 gibt eine JSON-Liste als EIN Objekt aus; die Pipeline entrollt sie
    $hist = @($resp | ForEach-Object { $_ })
} catch {
    Write-Host "  [FAIL] HTTP-Request fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red; $failed++
}
if ($null -ne $hist) {
    Check 'Liste mit Zeilen' { $hist.Count -ge 1 }
    Check 'Zeile {date, base EUR, quote USD, rate > 0}' {
        $r = $hist[0]
        ($r.date -match '^\d{4}-\d{2}-\d{2}$') -and $r.base -eq 'EUR' -and $r.quote -eq 'USD' -and ([double]$r.rate -gt 0)
    }
}

# --- Frankfurter v2 Edelmetalle (Mischkurs, Zweig "Fetch metal prices" in cron_refresh_fx_rates) ---
# Import metal prices erwartet {date, base XAU|XAG, quote EUR, rate = EUR je Feinunze}; die DB invertiert. Eine Antwort in
# Gegenrichtung (EUR je Unze < 1) wuerde still einen Kehrwert-Preis speichern.
foreach ($metal in 'XAU', 'XAG') {
    Write-Host "api.frankfurter.dev /v2/rates (base=$metal, quotes=EUR) :"
    $mrows = $null
    try {
        $to = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'); $from = (Get-Date).ToUniversalTime().AddDays(-5).ToString('yyyy-MM-dd')
        $resp = Invoke-RestMethod -Uri "https://api.frankfurter.dev/v2/rates?base=$metal&quotes=EUR&from=$from&to=$to" -Method Get -TimeoutSec 20
        $mrows = @($resp | ForEach-Object { $_ })
    } catch {
        Write-Host "  [FAIL] HTTP-Request fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red; $failed++
    }
    if ($null -ne $mrows) {
        Check 'Liste mit Zeilen (auch am Wochenende)' { $mrows.Count -ge 3 }
        Check "Zeile {date, base $metal, quote EUR, rate > 1 (EUR je Feinunze)}" {
            $r = $mrows[-1]
            ($r.date -match '^\d{4}-\d{2}-\d{2}$') -and $r.base -eq $metal -and $r.quote -eq 'EUR' -and ([double]$r.rate -gt 1)
        }
    }
}

Write-Host ("-" * 60)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$failed Contract-Check(s) fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
