#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 4. tool_book_stock_sell (Playbook 5.4) ---------------
function Build-BookStockSell {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('depot_name','isin','symbol','shares','price_per_share','order_fee','transaction_date','savings_goal_name')

    # S8: Position per Depot-Name + ISIN/Symbol (finance.fn_find_holding) statt holding_id-Lookup durch das Modell.
    # Liefert settlement_account_id, Depot-Name, Waehrung (WP-5: Depot-/Verrechnungs-Waehrung fuer die Karte) und die
    # verfuegbaren Stuecke; unbekannt/mehrdeutig -> {ok:false, code, reason, candidates} ohne Karte.
    $getInfo = Build-Pg 'Find Holding' @(220, 0) `
        "=SELECT finance.fn_find_holding(`$1::jsonb) AS r;" `
        ([ordered]@{ depot_name = '$(''Start'').item.json.depot_name'; isin = '$(''Start'').item.json.isin'; symbol = '$(''Start'').item.json.symbol' })

    $ifFound = Build-If 'Holding found?' @(440, 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'

    $H = "`$('Find Holding').item.json.r"
    $errNotFound = Build-Set 'Holding not found' @(660, 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('error', "={{ $H.reason }}", 'string')
        ,@('code', "={{ $H.code }}", 'string')
        ,@('candidates', "={{ $H.candidates || [] }}", 'array')
    )

    # "DB ist das Gesetz": fn_book_stock_sell laeuft als Probelauf VOR der Karte (Oversell, nicht-positive Werte ->
    # {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_stock_sell' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create sell (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'sell_tx_id')::int AS sell_tx_id, (r->>'settlement_balance')::numeric AS settlement_balance, (r->>'proceeds')::numeric AS proceeds, (r->>'remaining_shares')::numeric AS remaining_shares, (r->>'derisk_amount')::numeric AS derisk_amount, (r->>'current_amount')::numeric AS goal_current_amount" `
        -Params ([ordered]@{
            settlement_id    = '$(''Find Holding'').item.json.r.settlement_account_id'
            holding_id       = '$(''Find Holding'').item.json.r.holding_id'
            shares           = '$(''Start'').item.json.shares'
            price_per_share  = '$(''Start'').item.json.price_per_share'
            order_fee        = '$(''Start'').item.json.order_fee'
            transaction_date = '$(''Start'').item.json.transaction_date'
            symbol           = '$(''Find Holding'').item.json.r.symbol'   # gespeichertes Symbol (Karte == Buchungstext)
            savings_goal_name = '$(''Start'').item.json.savings_goal_name'   # optional: Erloes dem Sparziel zuordnen (derisk, fn prueft)
        })

    # --- HITL approval gate ---
    # Strukturiertes Summary (Textkatalog); Betraege in der Depot-/Verrechnungs-Waehrung (Find Holding).
    # Post-State-Vertrag: Datum/Gebuehr/Erloes aus dem Probelauf (effective = von der fn gesetzte Werte, proceeds = fn).
    $S = "`$('Start').item.json"
    $G = "`$('Find Holding').item.json.r"
    $E = "`$('Dry run').item.json.r"
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'finance.hitl.book_stock_sell' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.symbol'        "$G.symbol")
        (New-HitlLine 'finance.label.depot'         "$G.depot_name")
        (New-HitlLine 'finance.label.available'     "'finance.tpl.pieces'" -Kind tpl -Params @{ count = (New-HitlValue -Kind number -Value "$G.available_shares" -Digits -1) })
        (New-HitlLine 'finance.label.sell'          "'finance.tpl.pieces'" -Kind tpl -Params @{ count = (New-HitlValue -Kind number -Value "$S.shares" -Digits -1) })
        (New-HitlLine 'finance.label.price'         "$S.price_per_share" -Kind money -Currency "$G.currency")
        (New-HitlLine 'finance.label.order_fee'     "$E.effective.order_fee" -Kind money -Currency "$G.currency")
        (New-HitlLine 'finance.label.proceeds_net'  "$E.proceeds" -Kind money -Currency "$G.currency")
        (New-HitlLine 'core.label.date'             "$E.effective.transaction_date" -Kind date)
        # Umschichten fuer ein Sparziel: der umgebuchte Betrag kommt aus dem Probelauf (die fn rechnet min(Anteil, Erloes))
        (New-HitlLine 'finance.label.derisk_goal'   "'finance.tpl.derisk_goal'" -Kind tpl -If "$S.savings_goal_name" -Params @{
            goal   = "$S.savings_goal_name"
            amount = (New-HitlValue -Kind money -Value "$E.derisk_amount" -Currency "$G.currency") })
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 240) 'the book_stock_sell action'

    # Atomarer Write via fn_book_stock_sell ($wg.Write): EINE sell-Transaktion. Order-Gebuehr gefaltet in amount +
    # separat in order_fee; shares-Delta negativ. Der Bestand kann sich seit dem Probelauf geaendert haben ->
    # korrigierbarer Fall (oversell) kommt hier erneut als {ok:false}.
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Sell rejected' @(2420, 240) `
        "={{ `$('Create sell (atomic)').item.json.reason }}"

    # Post-State kommt aus der fn (settlement_balance/proceeds/remaining_shares) — kein separater Read-back.
    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('sell_tx_id', "={{ `$('Create sell (atomic)').item.json.sell_tx_id }}", 'number')
        ,@('settlement_balance', "={{ `$('Create sell (atomic)').item.json.settlement_balance }}", 'number')
        ,@('proceeds', "={{ `$('Create sell (atomic)').item.json.proceeds }}", 'number')
        ,@('remaining_shares', "={{ `$('Create sell (atomic)').item.json.remaining_shares }}", 'number')
        ,@('derisk_amount', "={{ `$('Create sell (atomic)').item.json.derisk_amount }}", 'number')
        ,@('goal_current_amount', "={{ `$('Create sell (atomic)').item.json.goal_current_amount }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_stock_sell mit denselben Werten, immer zurückgerollt. ok:false (zu viele Stücke, Stückzahl/Kurs nicht positiv; mit savings_goal_name: Ziel unklar, kein Ziel-Geld in diesem Depot, Währung Verrechnungskonto ≠ Depot) -> sonst bucht die fn zusätzlich das Umschichten fürs Sparziel (Journal derisk: Depot -m, Verrechnungskonto +m, m = min(Anteil, Erlös)). Bei Ablehnung -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyTriggers = Build-Sticky 'DB-Automatik shares+balance' @(1980, -220) `
        'trg_finance_update_holding_shares + trg_finance_balance_update' `
        'fn_book_stock_sell bucht atomar: EINE sell-Transaktion (amount=+Erlöse, shares=-Stücke, order_fee separat). Danach: DB-Trigger reduziert holding.shares via SUM + aktualisiert Saldo des Verrechnungskontos. avg_purchase_price bleibt unverändert (Trigger liest nur buy-Zeilen). Die fn liest den Post-State (settlement_balance/proceeds/remaining_shares) am Ende derselben Transaktion und gibt ihn zurück -> kein separater Read-back-Node.' 200 460

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2420, -220) `
        'fn-Rückgabe {ok:false, reason}' `
        'Korrigierbare Fälle (oversell, nicht-positive Stückzahl/Kurs) liefert die fn als {ok:false, reason} -> Sell rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true bucht wirklich. Normalerweise fängt schon der Probelauf diese Fälle vor der Karte ab; hier landet nur, was sich zwischen Karte und Tipp geändert hat.' 200 400

    $nodes = @($trig, $getInfo, $ifFound, $errNotFound) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret,
               $stickyDry, $stickyTriggers, $stickyOk)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Find Holding' ) ) }
        'Find Holding'           = @{ main = @( ,@( E 'Holding found?' ) ) }
        'Holding found?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Holding not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Create sell (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create sell (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Sell rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_book_stock_sell' $nodes $conns `
        @{ Category = 'securities' }
}
