#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_verify_price_symbol (Lese-Tool, kein HITL) ---
# Monats-Check WP-G (Owner 2026-10-22: ETF "P500" ohne Kurs — der Agent soll mit Rueckfragen die Kursabfrage zum
# Laufen bringen). Schlaegt fuer eine ISIN die Boersen-Notierungen bei Yahoo nach bzw. prueft ein vom Nutzer
# genanntes Feed-Symbol (derselbe Sub wie Kauf/set_holding/Import: agent.finance.sub_resolve_yahoo_symbol) und gibt
# die Kandidaten zurueck. Schreibt nichts: der Agent nennt dem Nutzer die Kandidaten (Boerse, Waehrung, Kurs), und der
# gewaehlte Eintrag laeuft ueber tool_set_holding (provider_symbol/quote_currency, mit Bestaetigungs-Karte).
function Build-VerifyPriceSymbol {
    $ResolveYahooSymbolId = Get-RequiredWorkflowId 'agent.finance.sub_resolve_yahoo_symbol' 'Build-VerifyPriceSymbol' -Soft
    $trig = Build-Trigger @('isin', 'provider_symbol', 'price_currency')

    $resolve = Build-CallWorkflow 'Resolve Yahoo symbol' @(220, 0) $ResolveYahooSymbolId 'agent.finance.sub_resolve_yahoo_symbol' `
        ([ordered]@{
            isin            = "={{ `$('Start').item.json.isin || '' }}"
            raw_symbol      = "={{ `$('Start').item.json.provider_symbol || '' }}"
            price_currency  = "={{ (`$('Start').item.json.price_currency || '').toUpperCase() }}"
            price_per_share = "={{ '' }}"
            provider_symbol = "={{ `$('Start').item.json.provider_symbol || '' }}"
        })

    $ret = Build-Return @(440, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('verified',        "={{ `$json.verified === true }}", 'boolean')
        ,@('provider_symbol', "={{ `$json.verified === true ? `$json.provider_symbol : '' }}", 'string')
        ,@('candidates',      "={{ `$json.candidates || [] }}", 'array')
    )

    $sticky = Build-Sticky 'Überblick' @(220, -280) `
        'Kurs-Symbol prüfen (Lese-Tool, kein Write, kein LLM)' `
        'Input isin ODER provider_symbol (+ price_currency = gewünschte Kurs-Währung, meist die Depot-Währung). Ruft agent.finance.sub_resolve_yahoo_symbol (Yahoo search + chart, best-effort, 3-s-Timeouts): ISIN -> bis zu 4 Notierungen {symbol, price, currency, exchange}; provider_symbol -> nur dieses prüfen. verified = Treffer in der gewünschten Währung (und plausibel). Kein HITL: es wird nichts gespeichert; der Agent zeigt dem Nutzer die Kandidaten und setzt den gewählten über tool_set_holding (Karte).' 300 400

    $nodes = @($trig, $resolve, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                = @{ main = @( ,@( E 'Resolve Yahoo symbol' ) ) }
        'Resolve Yahoo symbol' = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.finance.tool_verify_price_symbol' $nodes $conns `
        @{ Category = 'securities' }
}
