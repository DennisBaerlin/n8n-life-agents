#Requires -Version 5.1
# Contract-Smoke fuer externe APIs (A4b). Kein LLM, kein DB-Write -- prueft NUR, dass die
# Antwort-Schemata externer Integrationen noch dem entsprechen, was unsere Workflows erwarten.
# Hintergrund: cron_refresh_fx_rates -> agent.fn_upsert_fx_rates liest p->'rates'->>CCY als
# positive Zahl. Aendert open.er-api.com sein Schema (oder liefert 0/n-a), schreibt der Cron
# still falsch/nichts -> jede Cross-Currency-Bewertung kippt, ohne dass ein Test es faengt.
# Dieser Smoke macht genau diese ungemockte Integration sichtbar.
#
# Usage:  .\scripts\contract_test.ps1 [-Verbose]
# Exit-Code = Anzahl fehlgeschlagener Contract-Checks. Netz-abhaengig (externe API).
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
# Repraesentative getrackte Waehrungen muessen als positive Zahl vorliegen (so liest sie die fn).
foreach ($ccy in @('USD','KRW')) {
    Check "rates.$ccy ist positive Zahl" {
        $v = $fx.rates.$ccy
        $n = 0.0
        ($null -ne $v) -and [double]::TryParse(("$v"), [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and ($n -gt 0)
    }
}
if ($Verbose -and $fx) { Write-Host "    USD=$($fx.rates.USD)  KRW=$($fx.rates.KRW)  last_update=$($fx.time_last_update_utc)" -ForegroundColor DarkGray }

Write-Host ("-" * 60)
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "$failed Contract-Check(s) fehlgeschlagen." -ForegroundColor $color
Write-Host ""
exit $failed
