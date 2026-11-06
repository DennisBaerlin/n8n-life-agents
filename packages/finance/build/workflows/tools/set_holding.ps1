#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_holding (set_*: Depot-Position-Metadaten aendern) ---
function Build-SetHolding {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    # Paket-interne Cross-Refs (Phase D: hier statt in der Engine). Yahoo-Sub + Preis-Cron SOFT (2-Pass-Bootstrap).
    $ResolveYahooSymbolId = Get-RequiredWorkflowId 'agent.finance.sub_resolve_yahoo_symbol' 'Build-SetHolding' -Soft
    $MarketPricesCronId   = Get-RequiredWorkflowId 'agent.finance.cron_refresh_market_prices' 'Build-SetHolding' -Soft
    $FxCronId             = Get-RequiredWorkflowId 'agent.finance.cron_refresh_fx_rates' 'Build-SetHolding'
    $trig = Build-Trigger @('depot_name','position','new_name','symbol','isin','currency','asset_class','provider_symbol','quote_currency')

    # S8: Position per Depot-Name + aktuellem Symbol/ISIN (finance.fn_find_holding, wie book_stock_sell) statt
    # holding_id-Lookup durch das Modell. symbol/isin im Input sind die NEUEN Werte -> Identifikation ueber 'position'.
    $readCur = Build-Pg 'Find Holding' @(220, 0) `
        "=SELECT finance.fn_find_holding(`$1::jsonb) AS r;" `
        ([ordered]@{ depot_name = '$(''Start'').item.json.depot_name'; position = '$(''Start'').item.json.position' })

    $ifFound = Build-If 'Holding found?' @(440, 200) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'

    $H = "`$('Find Holding').item.json.r"
    $errNotFound = Build-Set 'Holding not found' @(660, 400) @(
        ,@('ok', 'false', 'boolean')
        ,@('error', "={{ $H.reason }}", 'string')
        ,@('code', "={{ $H.code }}", 'string')
        ,@('candidates', "={{ $H.candidates || [] }}", 'array')
    )

    # Kauf-Zeit-Symbol-Validierung (WS-2, DRY mit book_stock_buy): laeuft IMMER (ISIN leer/Krypto -> Sub gibt sofort
    # roh zurueck, kein Yahoo-Call), damit der nachgelagerte fn-Node den Output sicher referenzieren kann (ein
    # IF-gegateter Sub wuerde am unausgefuehrten Zweig "node not executed" werfen). GENUTZT wird der Vorschlag aber
    # nur, wenn symbol/isin/provider_symbol geaendert wird (s. Set-holding-Payload). Effektive Werte = neu || aktuell.
    # Plausi-Referenz (Owner 2026-10-27: Plausi-Pflicht fuer jeden Treffer): letzter Kurs der Position (enges Band),
    # sonst Einstand (grobes Band) + FX-Karte fuer Fremdwaehrungs-Notierungen. Aggregiert -> immer ein Item.
    $loadRef = Build-Pg 'Load price reference' @(440, -420) `
        "=SELECT (SELECT jsonb_build_object('price', s.price, 'price_currency', s.price_currency, 'avg', s.avg_price, 'currency', s.currency) FROM finance.fn_holding_price_status(ARRAY[((`$1::jsonb)->>'holding_id')::int]) s) AS ref, finance.fn_fx_rate_map() AS fx;" `
        ([ordered]@{ holding_id = '$(''Find Holding'').item.json.r.holding_id' })
    $resolveInputs = [ordered]@{
        isin            = "={{ `$('Start').item.json.isin || $H.isin }}"
        raw_symbol      = "={{ `$('Start').item.json.symbol || $H.symbol }}"
        price_currency  = "={{ (`$('Start').item.json.quote_currency || $H.holding_currency || '').toUpperCase() }}"
        price_per_share = "={{ '' }}"
        provider_symbol = "={{ `$('Start').item.json.provider_symbol }}"
        try_symbols     = "={{ '' }}"
        chat_id         = "={{ `$('Start').item.json.chat_id }}"
    }
    $refIn = Get-FinancePriceRefInputs -RefJs "(`$('Load price reference').item.json.ref || {})" -FxJs "`$('Load price reference').item.json.fx"
    foreach ($k in $refIn.Keys) { $resolveInputs[$k] = $refIn[$k] }
    $resolveYahoo = Build-CallWorkflow 'Resolve Yahoo symbol' @(660, -220) $ResolveYahooSymbolId 'agent.finance.sub_resolve_yahoo_symbol' $resolveInputs

    # Strukturiertes Summary (Textkatalog). Kurs-Symbol-Zeile = Yahoo-Validierung; die Warnung "nicht verifiziert"
    # steht als Hinweis unter den Zeilen. Preis in der Yahoo-/Kurs-/Positions-Waehrung (Default EUR).
    # "DB ist das Gesetz": fn_set_holding laeuft als Probelauf VOR der Karte (Identitaets-Dublette ISIN/Symbol im Depot,
    # ungueltiges asset_class-/quote_currency-Format -> {ok:false} ohne Karte); derselbe Param-Satz geht in den Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_set_holding' -DryPos @(660, 0) -WritePos @(1760, 0) `
        -WriteName 'Set holding (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'holding_id')::int AS holding_id" `
        -Params ([ordered]@{
            holding_id      = '$(''Find Holding'').item.json.r.holding_id'
            name            = '$(''Start'').item.json.new_name'
            symbol          = '$(''Start'').item.json.symbol'
            isin            = '$(''Start'').item.json.isin'
            currency        = '$(''Start'').item.json.currency'
            asset_class     = '$(''Start'').item.json.asset_class'
            # Ein ausdruecklich genanntes provider_symbol gilt (die Karte warnt, wenn es nicht verifiziert ist). Nach einer
            # symbol-/ISIN-Aenderung: der Yahoo-Vorschlag, wenn er adoptable ist (Plausi-Pflicht 2026-10-27), sonst das
            # Standard-Feed-Symbol des NEUEN Tickers (fn_feed_symbol-Regel: Aktie = symbol, Krypto = symbol-EUR) — ein altes
            # Override darf nicht stehen bleiben (fn_set_holding kann nicht auf NULL setzen, '' hiesse "unveraendert").
            provider_symbol = '$(''Start'').item.json.provider_symbol ? $(''Start'').item.json.provider_symbol : (($(''Start'').item.json.symbol || $(''Start'').item.json.isin) ? ($(''Resolve Yahoo symbol'').item.json.adoptable === true ? $(''Resolve Yahoo symbol'').item.json.provider_symbol : (($(''Start'').item.json.isin || $(''Find Holding'').item.json.r.isin) ? ($(''Start'').item.json.symbol || $(''Find Holding'').item.json.r.symbol) : ($(''Start'').item.json.symbol || $(''Find Holding'').item.json.r.symbol) + "-EUR")) : "")'
            quote_currency  = '$(''Start'').item.json.quote_currency'
        })

    $S = "`$('Start').item.json"
    $R = "`$('Find Holding').item.json.r"
    $Y = "`$('Resolve Yahoo symbol').item.json"
    $quoted = "($S.symbol || $S.isin || $S.provider_symbol)"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.set_holding' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.position'        "'finance.tpl.name_symbol'" -Kind tpl -Params @{ name = "$R.name"; symbol = "$R.symbol" })
        (New-HitlLine 'finance.label.new_name'        "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.symbol'          "'finance.tpl.change'" -Kind tpl -Params @{ from = "$R.symbol"; to = "$S.symbol" } -If "$S.symbol")
        (New-HitlLine 'finance.label.isin'            "'finance.tpl.change'" -Kind tpl -Params @{ from = "$R.isin"; to = "$S.isin" } -If "$S.isin")
        (New-HitlLine 'core.label.currency'           "$S.currency" -If "$S.currency")
        (New-HitlLine 'finance.label.asset_class'     "$S.asset_class" -If "$S.asset_class")
        # Die Karte zeigt, was geschrieben wird (Payload provider_symbol oben): genanntes Symbol, sonst der Yahoo-Vorschlag
        # nur wenn adoptable, sonst das Standard-Symbol des Tickers; den Kurs nur zu einem tatsaechlich gepruefen Symbol.
        (New-HitlLine 'finance.label.quote_symbol'    "((($S.provider_symbol || $Y.adoptable) && $Y.market_price) ? 'finance.tpl.quote_symbol_price' : 'finance.tpl.quote_symbol_plain')" -Kind tpl -If $quoted -Params @{
            symbol = "($S.provider_symbol || ($Y.adoptable ? $Y.provider_symbol : ($S.symbol || $R.symbol)))"
            price  = (New-HitlValue -Kind money -Value "$Y.market_price" -Currency "($Y.currency || $S.quote_currency || $R.holding_currency || 'EUR')") })
        (New-HitlLine 'finance.label.quote_currency'  "$S.quote_currency" -If "$S.quote_currency")
        (New-HitlNote -Key 'finance.note.quote_symbol_unverified' -If "$quoted && !$Y.adoptable")
        (New-HitlNote -Key 'finance.note.quote_symbol_foreign' -If "$quoted && $Y.foreign_listing && $Y.plausible" -Params @{ currency = "$Y.currency" })
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the set_holding action'

    # Atomarer Write via fn_set_holding ($wg.Write): nur Metadaten; shares/avg sind Trigger-gepflegt.
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2200, 240) `
        "={{ `$('Set holding (atomic)').item.json.reason }}"

    # Phase M (Item 3): Sofort-Preis-Fetch nach einer Symbol-/Feed-Symbol-Aenderung — ein neuer (oder
    # umgemappter) Ticker hat sonst bis zum naechsten 07:00-Lauf keinen Kurs. Bedingung = symbol ODER
    # provider_symbol gesetzt (ein reiner provider_symbol-Override aendert auch den Feed-Key). Ruft denselben
    # Markt-Preis-Cron als Sub auf wie book_stock_buy (Dual-Trigger 'Start'). Unabhaengig vom FX-Zweig unten.
    $ifSymChanged = Build-If 'Symbol/Provider changed?' @(2200, -40) `
        "={{ !!(`$('Start').item.json.symbol) || !!(`$('Start').item.json.provider_symbol) }}" `
        'true' 'equals' 'boolean'

    $callPriceRefresh = Build-CallWorkflow 'Refresh market prices' @(2420, -320) $MarketPricesCronId 'agent.finance.cron_refresh_market_prices' `
        ([ordered]@{ chat_id = "={{ `$('Start').item.json.chat_id }}" })

    # Sofort-Fetch wenn eine Fremdwaehrung gesetzt wurde — currency ODER quote_currency (WP-3a: eine EUR-
    # gefuehrte Position mit fremder MARKT-Quote-Waehrung braucht den FX-Kurs genauso, sonst bleibt
    # market_value_eur bis zum naechsten Schedule NULL). Ruft den FX-Cron als Sub (Dual-Trigger) — EINE
    # Logik-Adresse fuer Check/Fetch/Upsert; der Cron liest fn_active_currencies (jetzt inkl. quote_currency).
    $ifForeignCurr = Build-If 'Non-EUR currency?' @(2640, 0) `
        "={{ (!!(`$('Start').item.json.currency) && `$('Start').item.json.currency !== 'EUR') || (!!(`$('Start').item.json.quote_currency) && `$('Start').item.json.quote_currency !== 'EUR') || ((!!`$('Start').item.json.symbol || !!`$('Start').item.json.isin || !!`$('Start').item.json.provider_symbol) && `$('Resolve Yahoo symbol').item.json.foreign_listing === true) }}" `
        'true' 'equals' 'boolean'

    $callFxRefresh = Build-CallWorkflow 'Refresh FX rates' @(2860, -120) $FxCronId 'agent.finance.cron_refresh_fx_rates' `
        ([ordered]@{ chat_id = "={{ `$('Start').item.json.chat_id }}" })

    # Kurs-Status NACH den Sofort-Abrufen (Owner 2026-10-27: die Antwort sagt, ob ein Kurs gefunden wurde).
    $priceStatus = New-FinancePriceStatusNode -Pos @(3080, -160) -HoldingIdExpr '$(''Set holding (atomic)'').item.json.holding_id'
    # Die Aenderung ist schon gespeichert: ein Fehler im Kurs-/FX-Abruf darf sie nie als Fehler melden.
    foreach ($n in @($callPriceRefresh, $callFxRefresh)) { $n['onError'] = 'continueRegularOutput'; $n['alwaysOutputData'] = $true }

    $ret = Build-Return @(3300, 0) @(
        ,@('ok','true','boolean')
        ,@('holding_id', "={{ `$('Set holding (atomic)').item.json.holding_id }}", 'number')
        ,@('price_status', "={{ `$('Price status').item.json.st || {} }}", 'object')
    )

    $stickyDry = Build-Sticky 'Position + Probelauf vor der Karte' @(220, 420) `
        'fn_find_holding + core.fn_dry_run (DB ist das Gesetz)' `
        'Find Holding = Position per Depot-Name + aktuellem Symbol/ISIN (Feld position); unbekannt/mehrdeutig -> Holding not found mit code + candidates (Positionen des Depots), keine Karte. Dry run = fn_set_holding mit denselben Werten, immer zurückgerollt: Identitäts-Dublette ISIN/Symbol im Depot, ungültiges asset_class-/quote_currency-Format -> Dry run rejected (KEINE Karte, card_sent:false). Echte Exception -> errorWorkflow-Alarm. Der echte Write prüft erneut (Write ok?); die Sofort-Fetches danach sind unverändert.' 220 440

    $stickyOv = Build-Sticky 'Doc set_holding' @(1760, -240) `
        'fn_set_holding: nur Metadaten' `
        'Ändert NUR name/symbol/isin/currency/asset_class/provider_symbol/quote_currency. shares + average_purchase_price sind Trigger-gepflegt (aus finance.transactions) -> falsche Stückzahl/avg über die Transaktionen korrigieren, nicht hier. asset_class = Allokations-Block-key (lowercase snake; korrigiert den Auto-Tag aus book_stock_buy); ungültiges Format -> {ok:false}. provider_symbol (Phase M) = Kurs-Feed-Symbol-Override (z. B. VWCE.DE); quote_currency = native Quote-Währung (via fn_ensure_currency validiert -> {ok:false}). Dubletten-ISIN/-Symbol im Depot -> {ok:false}. NACH dem Write zwei unabhängige Sofort-Fetches: Symbol/provider_symbol geändert -> cron_refresh_market_prices; Fremdwährung (currency ODER quote_currency, WP-3a) gesetzt -> cron_refresh_fx_rates (je eliminieren das NULL-Fenster in den Roll-up-Views bis zum nächsten Schedule).' 220 560

    $stickyYahoo = Build-Sticky 'Kauf-Zeit-Symbol-Validierung' @(440, -420) `
        'sub_resolve_yahoo_symbol (vor dem Gate, immer-laufend/non-blocking)' `
        'Läuft IMMER (ISIN leer/Krypto -> Sub gibt sofort roh, kein Yahoo-Call) -> der fn-Node referenziert den Output sicher (ein IF-gegateter Sub würde am unausgeführten Zweig "node not executed" werfen). Load price reference liefert die Plausi-Referenz (letzter Kurs, sonst Einstand, nur in der gewünschten Währung) + FX-Karte (fn_fx_rate_map). GENUTZT wird ein Yahoo-Vorschlag nur nach symbol-/ISIN-Änderung UND wenn er verifiziert oder eine plausible Fremdwährungs-Notierung ist (Plausi-Pflicht 2026-10-27); ein ausdrücklich genanntes provider_symbol gilt immer (Karte warnt). Yahoo-Ausfall/Timeout (3s) -> {verified:false, provider_symbol:roh}, der Edit läuft trotzdem. NACH den Sofort-Abrufen liefert Price status (fn_holding_price_status) den Kurs-Status für die Antwort.' 300 560

    $nodes = @($trig, $readCur, $ifFound, $errNotFound, $loadRef, $resolveYahoo) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ifSymChanged, $callPriceRefresh,
               $ifForeignCurr, $callFxRefresh, $priceStatus, $ret, $stickyDry, $stickyOv, $stickyYahoo)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Find Holding' ) ) }
        'Find Holding'           = @{ main = @( ,@( E 'Holding found?' ) ) }
        'Holding found?'         = @{ main = @(
            @( E 'Load price reference' ),
            @( E 'Holding not found' )
        ) }
        'Load price reference'   = @{ main = @( ,@( E 'Resolve Yahoo symbol' ) ) }
        'Resolve Yahoo symbol'   = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set holding (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set holding (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Symbol/Provider changed?' ),
            @( E 'Update rejected' )
        ) }
        'Symbol/Provider changed?' = @{ main = @(
            @( E 'Refresh market prices' ),  # true: Ticker/Feed-Symbol geaendert -> Sofort-Preis-Fetch
            @( E 'Non-EUR currency?' )        # false: weiter zum FX-Zweig
        ) }
        'Refresh market prices'  = @{ main = @( ,@( E 'Non-EUR currency?' ) ) }
        'Non-EUR currency?'      = @{ main = @(
            @( E 'Refresh FX rates' ),    # true: Fremdwaehrung geaendert -> Sub-Call des FX-Crons
            @( E 'Price status' )          # false: EUR oder unveraendert -> kein Call
        ) }
        'Refresh FX rates'       = @{ main = @( ,@( E 'Price status' ) ) }
        'Price status'           = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.finance.tool_set_holding' $nodes $conns `
        @{ Category = 'securities' }
}
