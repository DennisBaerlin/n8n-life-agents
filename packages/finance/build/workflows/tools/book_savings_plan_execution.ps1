#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_book_savings_plan_execution (Broker-Ausfuehrung eines Sparplans eintragen) ---
function Build-BookSavingsPlanExecution {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $MarketPricesCronId = Get-RequiredWorkflowId 'agent.finance.cron_refresh_market_prices' 'Build-BookSavingsPlanExecution' -Soft
    $trig = Build-Trigger @('savings_plan_name','shares','price_per_share','order_fee')

    # Plan-Details fuer HITL-Summary aus DERSELBEN fn wie die Buchung (Audit Paket 2, Punkt 3): naechste offene
    # Ausfuehrung ueber die Vorgaenger-Kette -> Soll-Betrag der rp, deren Vorkommen gebucht wird (nach einer
    # Betragsaenderung mit Stichtag in der Zukunft noch der alte Betrag), Waehrung des Verrechnungskontos.
    $readPlan = Build-Pg 'Read Plan' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'symbol' AS symbol, r->>'security_name' AS security_name, (r->>'plan_amount')::numeric AS plan_amount, r->>'currency' AS currency, r->>'due_date' AS due_date FROM finance.fn_savings_plan_next_execution(`$1::jsonb) AS r;" `
        ([ordered]@{ savings_plan_name = '$(''Start'').item.json.savings_plan_name' })

    # Keine offene Ausfuehrung / Plan nicht aktiv / nicht eindeutig -> korrigierbar VOR der Karte (der Owner bestaetigt
    # nie etwas, das die Buchung danach ablehnt).
    $ifOpen = Build-If 'Execution open?' @(330, -160) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errOpen = Build-ToolError 'No open execution' @(440, 240) "={{ `$('Read Plan').item.json.reason }}"

    # HITL approval gate (Textkatalog): zeigt Soll vs. Ist-Kosten sowie Abweichung, alles in der Waehrung des
    # Verrechnungskontos (= Depot-Waehrung, fn_create_account erzwingt die Gleichheit); Read Plan liest sie mit.
    $S = "`$('Start').item.json"
    $P = "`$('Read Plan').item.json"
    $cost = "($S.shares * $S.price_per_share + ($S.order_fee || 0))"

    # "DB ist das Gesetz": nach Read Plan (bleibt: liefert die Kartenwerte) laeuft fn_book_savings_plan_execution
    # selbst als Probelauf VOR der Karte (shares/price<=0, Depot-Ablehnung -> {ok:false} ohne Karte); derselbe
    # Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_savings_plan_execution' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Book execution (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'holding_id')::int AS holding_id, (r->>'buy_tx_id')::int AS buy_tx_id, r->>'due_date' AS due_date, (r->>'total_cost')::numeric AS total_cost, (r->>'plan_amount')::numeric AS plan_amount, (r->>'variance')::numeric AS variance" `
        -Params ([ordered]@{
            savings_plan_name = '$(''Start'').item.json.savings_plan_name'
            shares            = '$(''Start'').item.json.shares'
            price_per_share   = '$(''Start'').item.json.price_per_share'
            order_fee         = '$(''Start'').item.json.order_fee'
        })

    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.book_savings_plan_execution' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.plan'          "$S.savings_plan_name")
        (New-HitlLine 'finance.label.security'      "($P.security_name ? 'finance.tpl.symbol_name' : 'finance.tpl.plain')" -Kind tpl -Params @{ symbol = "$P.symbol"; name = "$P.security_name"; value = "$P.symbol" })
        (New-HitlLine 'finance.label.target_sum'    "$P.plan_amount" -Kind money -Currency "$P.currency")
        (New-HitlLine 'finance.label.shares_pieces' "$S.shares" -Kind number -Digits -1)
        (New-HitlLine 'finance.label.price'         "$S.price_per_share" -Kind money -Currency "$P.currency")
        (New-HitlLine 'finance.label.order_fee'     "($S.order_fee || 0)" -Kind money -Currency "$P.currency")
        (New-HitlLine 'finance.label.actual_cost'   "(Math.round($cost * 100) / 100)" -Kind money -Currency "$P.currency")
        (New-HitlNote -Key 'finance.note.deviation_target' -If "((Math.abs($cost - $P.plan_amount) / $P.plan_amount) > 0.05)")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the book_savings_plan_execution action'

    # Atomarer Write via fn_book_savings_plan_execution ($wg.Write, Params siehe oben):
    # 1.+2. fn_savings_plan_next_execution (wie Read Plan): Plan aufloesen + Status-Guard, fruehestes offenes
    #       Vorkommen ueber die Vorgaenger-Kette (auto-detektiert due_date + rp)
    # 3. fn_book_stock_buy mit recurring_payment_id (dieses Ketten-Glied) + transaction_date=due_date
    # DB: Holding-shares + avg_purchase_price via Trigger; rp_id auf Tx -> Vorkommen
    #     taucht automatisch nicht mehr in fn_recurring_due_open auf.
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Execution rejected' @(2200, 240) `
        "={{ `$('Book execution (atomic)').item.json.reason }}"

    # Kurs-Einrichtung (Owner 2026-10-27): die erste Ausfuehrung legt die Position oft erst an -> Kurs sofort holen
    # (Dual-Trigger des Markt-Preis-Crons, Muster book_stock_buy) und den Status in die Antwort. Der Sparplan kennt
    # nur das rohe Symbol: fehlt der Kurs, bietet der Agent tool_verify_price_symbol an, sonst meldet ihn
    # cron_remind_missing_prices mit geprueftem Vorschlag. FX-Kurse braucht es hier nicht neu (Plan-Waehrung = Depot).
    $callPriceRefresh = Build-CallWorkflow 'Refresh market prices' @(2200, -160) $MarketPricesCronId 'agent.finance.cron_refresh_market_prices' `
        ([ordered]@{ chat_id = "={{ `$('Start').item.json.chat_id }}" })
    # Die Ausfuehrung ist schon gebucht: ein Fehler im Kurs-Abruf darf sie nie als Fehler melden.
    $callPriceRefresh['alwaysOutputData'] = $true
    $callPriceRefresh['onError'] = 'continueRegularOutput'
    $priceStatus = New-FinancePriceStatusNode -Pos @(2420, -160) -HoldingIdExpr '$(''Book execution (atomic)'').item.json.holding_id'

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('holding_id', "={{ `$('Book execution (atomic)').item.json.holding_id }}", 'number')
        ,@('buy_tx_id', "={{ `$('Book execution (atomic)').item.json.buy_tx_id }}", 'number')
        ,@('due_date', "={{ `$('Book execution (atomic)').item.json.due_date }}", 'string')
        ,@('total_cost', "={{ `$('Book execution (atomic)').item.json.total_cost }}", 'number')
        ,@('variance', "={{ `$('Book execution (atomic)').item.json.variance }}", 'number')
        ,@('price_status', "={{ `$('Price status').item.json.st || {} }}", 'object')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(500, -320) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Nach Read Plan läuft fn_book_savings_plan_execution mit denselben Werten als Probelauf, immer zurückgerollt. ok:false (Stückzahl/Kurs nicht positiv, Depot lehnt den Kauf ab) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 460

    $stickyFn = Build-Sticky 'fn_book_savings_plan_execution: Cron-Verknüpfung' @(1760, -260) `
        'fn: auto-due_date + rp_id-Stempel' `
        'Karte (Read Plan) und Buchung lesen dieselbe fn_savings_plan_next_execution: frühestes offenes Vorkommen über ALLE Glieder der Vorgänger-Kette des Plans (nach einer Betragsänderung mit Stichtag in der Zukunft liegt die noch anstehende Ausführung auf der alten Zeile, mit altem Betrag). Kauf-Transaktion bekommt recurring_payment_id = genau dieses Ketten-Glied + transaction_date = due_date. Dadurch verschwindet das Vorkommen beim nächsten Cron-Lauf automatisch aus der offenen Liste -- kein Write an fn_recurring_due_open nötig. DB-Trigger: shares + avg_purchase_price via Trigger (nie manuell schreiben). NACH dem Write: Refresh market prices (Sofort-Kurs, die erste Ausführung legt die Position oft erst an) -> Price status (fn_holding_price_status) -> price_status in der Antwort (Read nach HTTP, bewusst außerhalb der Write-fn).' 260 640

    $stickyOk = Build-Sticky 'Execution open? / Write ok? (korrigierbare Ablehnung)' @(2200, -240) `
        'fn-Rückgabe {ok:false, reason}' `
        'Execution open? (vor der Karte): Plan nicht gefunden/mehrdeutig/nicht aktiv oder kein offenes Vorkommen (bereits gebucht oder noch nicht fällig) -> ToolError, keine Bestätigung. Dry run ok? (vor der Karte): shares<=0/price<=0 oder Depot-Ablehnung -> Dry run rejected, keine Karte. Write ok? (nach der Karte): dieselben Fälle erneut, falls sich seit der Karte etwas geändert hat -> {ok:false, reason}. Abweichung > 5 % wird in der Summary als Warnung angezeigt (kein harter Block).' 220 480

    $nodes = @($trig, $readPlan, $ifOpen, $errOpen) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $callPriceRefresh, $priceStatus, $ret, $stickyDry, $stickyFn, $stickyOk)

    $conns = [ordered]@{
        'Start'                      = @{ main = @( ,@( E 'Read Plan' ) ) }
        'Read Plan'                  = @{ main = @( ,@( E 'Execution open?' ) ) }
        'Execution open?'            = @{ main = @(
            @( E 'Dry run' ),
            @( E 'No open execution' )
        ) }
        'Dry run'                    = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'     = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'           = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                  = @{ main = @(
            @( E 'Book execution (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book execution (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                  = @{ main = @(
            @( E 'Refresh market prices' ),
            @( E 'Execution rejected' )
        ) }
        'Refresh market prices'      = @{ main = @( ,@( E 'Price status' ) ) }
        'Price status'               = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.finance.tool_book_savings_plan_execution' $nodes $conns `
        @{ Category = 'securities' }
}
