#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_verify_price_symbol (Lese-Tool, kein HITL) ---
# Monats-Check WP-G (Owner 2026-10-22: ETF "P500" ohne Kurs — der Agent soll mit Rueckfragen die Kursabfrage zum
# Laufen bringen). Schlaegt fuer eine ISIN die Boersen-Notierungen bei Yahoo nach bzw. prueft ein vom Nutzer
# genanntes Feed-Symbol (derselbe Sub wie Kauf/set_holding/Import: agent.finance.sub_resolve_yahoo_symbol) und gibt
# die Kandidaten zurueck. Schreibt nichts: der Agent nennt dem Nutzer die Kandidaten (Boerse, Waehrung, Kurs), und der
# gewaehlte Eintrag laeuft ueber tool_set_holding (provider_symbol/quote_currency, mit Bestaetigungs-Karte).
# Plausi-Pflicht (Owner 2026-10-27): verified nur mit passender Kurs-Groessenordnung. Referenz = die gehaltene Position
# mit dieser ISIN (letzter Kurs oder Einstand); ohne Position kein verified (der Agent nennt dann Kandidaten mit Kurs).
function Build-VerifyPriceSymbol {
    $CRED_POSTGRES = $CRED_FINANCE_RO
    $ResolveYahooSymbolId = Get-RequiredWorkflowId 'agent.finance.sub_resolve_yahoo_symbol' 'Build-VerifyPriceSymbol' -Soft
    $trig = Build-Trigger @('isin', 'provider_symbol', 'price_currency')

    # Aggregiert -> immer ein Item (auch ohne Position / ohne ISIN).
    $loadRef = Build-Pg 'Load price reference' @(220, -200) `
        "=SELECT (SELECT jsonb_build_object('price', s.price, 'price_currency', s.price_currency, 'avg', s.avg_price, 'currency', s.currency) FROM finance.fn_holding_price_status() s WHERE s.isin = NULLIF((`$1::jsonb)->>'isin', '') ORDER BY s.holding_id LIMIT 1) AS ref, finance.fn_fx_rate_map() AS fx;" `
        ([ordered]@{ isin = '$(''Start'').item.json.isin' })
    $loadRef['onError'] = 'continueRegularOutput'

    $resolveInputs = [ordered]@{
        isin            = "={{ `$('Start').item.json.isin || '' }}"
        raw_symbol      = "={{ `$('Start').item.json.provider_symbol || '' }}"
        # ohne gewuenschte Waehrung: die der gehaltenen Position (Selektor fuer die Notierung)
        price_currency  = "={{ (`$('Start').item.json.price_currency || (`$('Load price reference').item.json.ref || {}).currency || '').toUpperCase() }}"
        price_per_share = "={{ '' }}"
        provider_symbol = "={{ `$('Start').item.json.provider_symbol || '' }}"
        try_symbols     = "={{ '' }}"
    }
    $refIn = Get-FinancePriceRefInputs -RefJs "(`$('Load price reference').item.json.ref || {})" -FxJs "`$('Load price reference').item.json.fx"
    foreach ($k in $refIn.Keys) { $resolveInputs[$k] = $refIn[$k] }
    $resolve = Build-CallWorkflow 'Resolve Yahoo symbol' @(440, 0) $ResolveYahooSymbolId 'agent.finance.sub_resolve_yahoo_symbol' $resolveInputs

    $ret = Build-Return @(660, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('verified',        "={{ `$json.verified === true }}", 'boolean')
        ,@('plausible',       "={{ `$json.plausible === true }}", 'boolean')
        ,@('adoptable',       "={{ `$json.adoptable === true }}", 'boolean')
        ,@('provider_symbol', "={{ `$json.adoptable === true ? `$json.provider_symbol : '' }}", 'string')
        ,@('candidates',      "={{ `$json.candidates || [] }}", 'array')
    )

    $sticky = Build-Sticky 'Überblick' @(220, -480) `
        'Kurs-Symbol prüfen (Lese-Tool, kein Write, kein LLM)' `
        'Input isin ODER provider_symbol (+ price_currency = gewünschte Kurs-Währung, meist die Depot-Währung). Load price reference (finance_ro): Plausi-Referenzen aus der gehaltenen Position mit dieser ISIN (letzter Kurs, enges Band, UND Einstand, grobes Band, je in ihrer Währung; fn_holding_price_status, Get-FinancePriceRefInputs) + FX-Karte (fn_fx_rate_map); ohne gewünschte Währung gilt die der Position. Ruft agent.finance.sub_resolve_yahoo_symbol (Yahoo search + chart, best-effort, 3-s-Timeouts): ISIN -> bis zu 4 Notierungen {symbol, price, currency, exchange, name}; provider_symbol -> nur dieses prüfen. verified = Treffer in der gewünschten Währung UND plausibel (Plausi-Pflicht 2026-10-27; ohne Referenz nie verified, der Agent nennt dann die Kandidaten mit Kurs). Kein HITL: es wird nichts gespeichert; der Agent zeigt dem Nutzer die Kandidaten und setzt den gewählten über tool_set_holding (Karte).' 300 480

    $nodes = @($trig, $loadRef, $resolve, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                = @{ main = @( ,@( E 'Load price reference' ) ) }
        'Load price reference' = @{ main = @( ,@( E 'Resolve Yahoo symbol' ) ) }
        'Resolve Yahoo symbol' = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.finance.tool_verify_price_symbol' $nodes $conns `
        @{ Category = 'securities' }
}
