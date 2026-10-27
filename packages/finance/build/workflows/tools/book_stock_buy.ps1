#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 3. tool_book_stock_buy (Playbook 5.3) ---------------
function Build-BookStockBuy {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    # Paket-interne Cross-Refs (Phase D: hier statt in der Engine). Beide SOFT — 2-Pass-Bootstrap beim Erst-Build.
    $ResolveYahooSymbolId = Get-RequiredWorkflowId 'agent.finance.sub_resolve_yahoo_symbol' 'Build-BookStockBuy' -Soft
    $MarketPricesCronId   = Get-RequiredWorkflowId 'agent.finance.cron_refresh_market_prices' 'Build-BookStockBuy' -Soft
    $FxCronId             = Get-RequiredWorkflowId 'agent.finance.cron_refresh_fx_rates' 'Build-BookStockBuy'
    $trig = Build-Trigger @('isin','symbol','name','shares','price_per_share','order_fee','depot_name','transaction_date','asset_class','provider_symbol','quote_currency','existing_position')

    $resDepot = Build-Pg 'Resolve Depot' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'depot_name', ARRAY['stocks_depot','crypto_depot']);" `
        ([ordered]@{ depot_name = '$(''Start'').item.json.depot_name' })

    $ifDepot = Build-If 'Depot unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errDepot = Build-ToolError 'Depot ambiguous' @(660, 400) `
        "=Depot '{{ `$('Start').item.json.depot_name }}' resolves to {{ `$('Resolve Depot').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Depot').item.json.candidates) }}. Ask the user which exact depot."

    $getSettle = Build-Pg 'Get Settlement Account' @(660, 0) `
        "=SELECT d.settlement_account_id, d.currency, s.name AS settlement_name FROM finance.accounts d LEFT JOIN finance.accounts s ON s.id = d.settlement_account_id WHERE d.id = ((`$1::jsonb)->>'depot_id')::int;" `
        ([ordered]@{ depot_id = '$(''Resolve Depot'').item.json.id' })

    # Kauf-Zeit-Symbol-Validierung (WS-2): Yahoo-Symbol fuer die ISIN ermitteln, gegen die genannte Preis-
    # Waehrung (quote_currency, Default Depot-Waehrung) + Kaufkurs gegenchecken. Deterministisch, non-blocking
    # (Sub faengt Yahoo-Ausfall -> {verified:false, provider_symbol:raw}). LIEGT VOR dem HITL-Gate, NICHT in der
    # atomaren fn. Ergebnis -> HITL-Anzeige + vorgeschlagenes provider_symbol in die Buchung.
    $resolveYahoo = Build-CallWorkflow 'Resolve Yahoo symbol' @(880, -200) $ResolveYahooSymbolId 'agent.finance.sub_resolve_yahoo_symbol' `
        ([ordered]@{
            isin            = "={{ `$('Start').item.json.isin }}"
            raw_symbol      = "={{ `$('Start').item.json.symbol }}"
            price_currency  = "={{ `$('Start').item.json.quote_currency || `$('Get Settlement Account').item.json.currency }}"
            price_per_share = "={{ `$('Start').item.json.price_per_share }}"
            provider_symbol = "={{ `$('Start').item.json.provider_symbol }}"
            ref_price       = "={{ '' }}"
            fx_rates        = "={{ '' }}"
            try_symbols     = "={{ '' }}"
            chat_id         = "={{ `$('Start').item.json.chat_id }}"
        })

    # "DB ist das Gesetz": fn_book_stock_buy laeuft als Probelauf VOR der Karte (Depot-Typ-Mismatch, nicht-positive
    # Werte -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten Write. Der Probelauf
    # liegt NACH dem Yahoo-Sub (dessen provider_symbol steckt in den Params) und VOR den Post-Write-Subs.
    # Holding suchen/anlegen + EINE Kauf-Transaktion in EINER Transaktion; Order-Gebuehr in amount gefaltet +
    # separat in order_fee; shares/avg pflegt der Trigger (avg nur aus buy).
    $wg = New-FnWriteGate -Fn 'finance.fn_book_stock_buy' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Create buy (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'holding_id')::int AS holding_id, (r->>'buy_tx_id')::int AS buy_tx_id, (r->>'settlement_balance')::numeric AS settlement_balance, (r->>'total_shares')::numeric AS total_shares, (r->>'avg_purchase_price')::numeric AS avg_purchase_price, COALESCE(r->'null_tag'->>'note', '') AS null_tag" `
        -Params ([ordered]@{
            depot_id         = '$(''Resolve Depot'').item.json.id'
            settlement_id    = '$(''Get Settlement Account'').item.json.settlement_account_id'
            isin             = '$(''Start'').item.json.isin'
            symbol           = '$(''Start'').item.json.symbol'
            name             = '$(''Start'').item.json.name'
            shares           = '$(''Start'').item.json.shares'
            price_per_share  = '$(''Start'').item.json.price_per_share'
            order_fee        = '$(''Start'').item.json.order_fee'
            transaction_date = '$(''Start'').item.json.transaction_date'
            asset_class      = '$(''Start'').item.json.asset_class'
            # Plausi-Pflicht (2026-10-27): ein Yahoo-Vorschlag wird nur gespeichert, wenn er verifiziert (Waehrung +
            # Kurs-Groessenordnung) oder eine plausible Fremdwaehrungs-Notierung ist; sonst nur ein vom Nutzer genanntes.
            provider_symbol  = '$(''Resolve Yahoo symbol'').item.json.adoptable === true ? $(''Resolve Yahoo symbol'').item.json.provider_symbol : ($(''Start'').item.json.provider_symbol || "")'
            quote_currency   = '$(''Start'').item.json.quote_currency'
            existing_position = '$(''Start'').item.json.existing_position'
        })

    # --- HITL approval gate (before the atomic write) ---
    # Strukturiertes Summary (Textkatalog). Preis-Anzeige in der genannten Waehrung (quote_currency, sonst Depot-Waehrung);
    # Kurs-Symbol-Zeile = Yahoo-Validierung (Warnung "nicht verifiziert" steht als Hinweis unter den Zeilen).
    # Verrechnungskonto = das belastete Konto; bei existing_position (Bestandsuebernahme) bleibt es unveraendert -> Hinweis.
    $S = "`$('Start').item.json"
    $Y = "`$('Resolve Yahoo symbol').item.json"
    $G = "`$('Get Settlement Account').item.json"
    # Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1, dieselbe wie die Import-Karte).
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.book_stock_buy' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity stock_buy -S (Get-WritePayloadExpr) -D @{
        Ccy = "($S.quote_currency || $G.currency)"; Settlement = "$G.settlement_name"; Quote = $Y; Date = "`$('Dry run').item.json.r.effective.transaction_date" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 200) 'the book_stock_buy action'

    # Atomarer Write via Function ($wg.Write, Params siehe oben).
    # fn liefert ok/reason: Depot-Typ-Mismatch (ISIN auf crypto / Crypto auf stocks) -> {ok:false}.
    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Buy rejected' @(2640, 240) `
        "={{ `$('Create buy (atomic)').item.json.reason }}"

    # Sofort-Preis-Fetch (Dual-Trigger): nach erfolgreichem Kauf den Markt-Preis-Cron als Sub aufrufen, damit
    # eine NEU angelegte Position sofort einen Kurs hat (kein null_price-Fenster bis zum naechsten 07:00-Lauf).
    # EINE Logik-Adresse fuer Symbol-Split/Fetch/Upsert (analog set_holding -> FX-Cron).
    $callPriceRefresh = Build-CallWorkflow 'Refresh market prices' @(2860, -160) $MarketPricesCronId 'agent.finance.cron_refresh_market_prices' `
        ([ordered]@{ chat_id = "={{ `$('Start').item.json.chat_id }}" })

    # WP-3a: wurde die Position mit einer fremden MARKT-Quote-Waehrung (quote_currency != EUR) angelegt, muss
    # auch der FX-Kurs sofort geholt werden (sonst bleibt market_value_eur bis zum naechsten Schedule NULL ->
    # still 0 im Net-Worth). Der Markt-Preis-Fetch oben deckt NUR den Kurs, nicht den Waehrungsumrechnungssatz.
    # Ruft den FX-Cron als Sub (Dual-Trigger); der Cron liest fn_active_currencies (jetzt inkl. quote_currency).
    $ifForeignQuote = Build-If 'Non-EUR quote?' @(3080, -160) `
        "={{ (!!(`$('Start').item.json.quote_currency) && `$('Start').item.json.quote_currency !== 'EUR') || `$('Resolve Yahoo symbol').item.json.foreign_listing === true }}" `
        'true' 'equals' 'boolean'

    $callFxRefresh = Build-CallWorkflow 'Refresh FX rates' @(3300, -280) $FxCronId 'agent.finance.cron_refresh_fx_rates' `
        ([ordered]@{ chat_id = "={{ `$('Start').item.json.chat_id }}" })

    # Kurs-Status NACH dem Sofort-Abruf (Owner 2026-10-27: die Antwort sagt, ob ein Kurs gefunden wurde).
    $priceStatus = New-FinancePriceStatusNode -Pos @(3520, -160) -HoldingIdExpr '$(''Create buy (atomic)'').item.json.holding_id'
    # Der Kauf ist schon gebucht: ein Fehler im Kurs-/FX-Abruf darf ihn nie als Fehler melden (weiter zum Kurs-Status).
    foreach ($n in @($callPriceRefresh, $callFxRefresh)) { $n['onError'] = 'continueRegularOutput'; $n['alwaysOutputData'] = $true }

    # Post-State kommt aus der fn (settlement_balance/total_shares/avg) — kein separater Read-back noetig.
    $ret = Build-Return @(3740, 0) @(
        ,@('ok','true','boolean')
        ,@('holding_id', "={{ `$('Create buy (atomic)').item.json.holding_id }}", 'number')
        ,@('buy_tx_id', "={{ `$('Create buy (atomic)').item.json.buy_tx_id }}", 'number')
        ,@('settlement_balance', "={{ `$('Create buy (atomic)').item.json.settlement_balance }}", 'number')
        ,@('total_shares', "={{ `$('Create buy (atomic)').item.json.total_shares }}", 'number')
        ,@('avg_purchase_price', "={{ `$('Create buy (atomic)').item.json.avg_purchase_price }}", 'number')
        ,@('null_tag', "={{ `$('Create buy (atomic)').item.json.null_tag }}", 'string')
        ,@('price_status', "={{ `$('Price status').item.json.st || {} }}", 'object')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1440, -340) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_stock_buy mit denselben Werten (inkl. aufgelöstem provider_symbol), immer zurückgerollt. ok:false (Depot-Typ-Mismatch, Stückzahl/Kurs nicht positiv) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?); die Kurs-Sub-Aufrufe danach laufen nur nach echter Buchung.' 240 460

    $stickyTriggers = Build-Sticky 'DB-Automatik holding+balance + Anlageklasse-Fold' @(2200, -260) `
        'trg_finance_update_holding_shares + trg_finance_update_holding_avg_price + trg_finance_balance_update' `
        'fn_book_stock_buy legt die Holding bei Bedarf an + bucht den Kauf atomar. Danach pflegt die DB automatisch: shares (= SUM der Anteile), average_purchase_price (nur aus buy-Zeilen; Order-Gebühr steckt in amount) und den Saldo des Verrechnungskontos. Die fn liest diesen Post-State (settlement_balance/total_shares/avg_purchase_price) am Ende in derselben Transaktion und gibt ihn zurück -> kein separater Read-back-Node. Phase L WS-6: asset_class wird NUR beim Anlegen der Holding getaggt (Re-Buy überschreibt nie); ist die RESULTIERENDE Holding ungetaggt -> Note in null_tag (sonst leer). Der Agent schlägt die Anlageklasse aus dem Plan vor; Bookkeeper relayed die null_tag-Note.' 230 500

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2640, -260) `
        'fn-Rückgabe {ok:false, reason}' `
        'Depot-Typ-Mismatch (ISIN-Aktie auf crypto_depot oder Crypto ohne ISIN auf stocks_depot) liefert die fn als {ok:false, reason} -> Buy rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true bucht wirklich. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 200 400

    $stickyYahoo = Build-Sticky 'Kauf-Zeit-Symbol-Validierung' @(880, -360) `
        'sub_resolve_yahoo_symbol (vor dem Gate, non-blocking)' `
        'Ermittelt für die ISIN das richtige Yahoo-Kurs-Symbol (Disambiguierung per genannter Preis-Währung quote_currency, Default Depot-Währung) + checkt Live-Kurs gegen den Kaufkurs. LIEGT VOR dem HITL-Gate, AUSSERHALB der atomaren fn -> Yahoo-Ausfall/Timeout (3s) blockiert die Buchung NICHT (Sub liefert {verified:false, provider_symbol:roh}). Das aufgelöste provider_symbol fliesst (COALESCE mit dem ggf. genannten) in fn_book_stock_buy + wird im HITL angezeigt (Owner bestätigt). Krypto (ISIN leer) -> Sub gibt roh zurück.' 300 520

    $stickyFx = Build-Sticky 'FX-Sofort-Fetch (WP-3a)' @(3080, -480) `
        'quote_currency != EUR -> cron_refresh_fx_rates' `
        'Zwei UNABHÄNGIGE Post-Write-Fetches: (1) Refresh market prices = der Wertpapier-KURS; (2) NUR wenn die Position eine fremde Markt-Quote-Währung trägt (quote_currency != EUR) -> Refresh FX rates = der Währungs-Umrechnungssatz. Ohne (2) hätte eine EUR-geführte US-Position (quote USD) bis zum nächsten FX-Schedule keinen USD-Kurs -> market_value_eur NULL -> still 0 im Net-Worth. Der FX-Cron liest fn_active_currencies (jetzt inkl. quote_currency).' 240 420

    $nodes = @($trig, $resDepot, $ifDepot, $errDepot, $getSettle, $resolveYahoo) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $callPriceRefresh, $ifForeignQuote, $callFxRefresh, $priceStatus, $ret,
               $stickyDry, $stickyTriggers, $stickyOk, $stickyYahoo, $stickyFx)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Depot' ) ) }
        'Resolve Depot'          = @{ main = @( ,@( E 'Depot unique?' ) ) }
        'Depot unique?'          = @{ main = @(
            @( E 'Get Settlement Account' ),
            @( E 'Depot ambiguous' )
        ) }
        'Get Settlement Account' = @{ main = @( ,@( E 'Resolve Yahoo symbol' ) ) }
        'Resolve Yahoo symbol'   = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Create buy (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create buy (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Refresh market prices' ),   # true: Kauf gebucht -> Sofort-Preis-Fetch, dann FX-Zweig
            @( E 'Buy rejected' )             # false: korrigierbare Ablehnung
        ) }
        'Refresh market prices'  = @{ main = @( ,@( E 'Non-EUR quote?' ) ) }
        'Non-EUR quote?'         = @{ main = @(
            @( E 'Refresh FX rates' ),        # true: fremde Quote-Waehrung -> FX-Sofort-Fetch
            @( E 'Price status' )              # false: EUR-Quote -> kein FX-Call
        ) }
        'Refresh FX rates'       = @{ main = @( ,@( E 'Price status' ) ) }
        'Price status'           = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.finance.tool_book_stock_buy' $nodes $conns `
        @{ Category = 'securities' }
}

