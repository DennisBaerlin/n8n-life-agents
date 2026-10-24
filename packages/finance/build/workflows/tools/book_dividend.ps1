#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 1. tool_book_dividend (Playbook 5.5) ----------------
function Build-BookDividend {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('isin','symbol','depot_name','amount','transaction_date')

    $resDepot = Build-Pg 'Resolve Depot' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'depot_name', ARRAY['stocks_depot','crypto_depot']);" `
        ([ordered]@{ depot_name = '$(''Start'').item.json.depot_name' })

    $ifDepot = Build-If 'Depot unique?' @(440, 0) "={{ `$json.hit_count }}" '1' 'equals' 'number'

    $errDepot = Build-ToolError 'Depot ambiguous' @(660, 200) `
        "=Depot '{{ `$('Start').item.json.depot_name }}' resolves to {{ `$('Resolve Depot').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Depot').item.json.candidates) }}. Ask the user which exact depot to use."

    # WP-5: settlement_currency = Waehrung des Verrechnungskontos (dorthin fliesst die Dividende) fuer die
    # waehrungs-korrekte Formatierung im HITL-Summary (Self-Join accounts: depot.settlement_account_id -> sa).
    $getSettle = Build-Pg 'Get Settlement Account' @(660, 0) `
        "=SELECT d.settlement_account_id, sa.currency AS settlement_currency FROM finance.accounts d LEFT JOIN finance.accounts sa ON sa.id = d.settlement_account_id WHERE d.id = ((`$1::jsonb)->>'depot_id')::int;" `
        ([ordered]@{ depot_id = '$(''Resolve Depot'').item.json.id' })

    # Die EINE Positionssuche der Tools (finance.fn_find_holding: ISIN ohne Gross-/Kleinschreibung, sonst Symbol), wie
    # book_stock_sell/set_holding; Ausgabe auf id/found gemappt (Holding exists? bleibt unveraendert).
    $resHolding = Build-Pg 'Resolve Holding' @(880, 0) `
        "=SELECT (r->>'holding_id')::int AS id, (r->>'ok')::boolean AS found FROM finance.fn_find_holding(`$1::jsonb) AS r;" `
        ([ordered]@{ depot_name = '$(''Start'').item.json.depot_name'; isin = '$(''Start'').item.json.isin'; symbol = '$(''Start'').item.json.symbol' })

    $ifHolding = Build-If 'Holding exists?' @(1100, 0) "={{ `$json.found }}" 'true' 'equals' 'boolean'

    $errHolding = Build-ToolError 'Holding missing' @(1320, 200) `
        "=No holding for '{{ `$('Start').item.json.isin || `$('Start').item.json.symbol }}' in depot '{{ `$('Start').item.json.depot_name }}'. Create a position first via tool_book_stock_buy."

    # "DB ist das Gesetz": fn_book_dividend laeuft als Probelauf VOR der Karte (nicht-positiver Betrag -> {ok:false}
    # ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_dividend' -DryPos @(1320, 0) -WritePos @(2640, 0) `
        -WriteName 'Book dividend (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'transaction_id')::int AS transaction_id, (r->>'account_balance')::numeric AS account_balance" `
        -Params ([ordered]@{
            account_id       = '$(''Get Settlement Account'').item.json.settlement_account_id'
            amount           = '$(''Start'').item.json.amount'
            transaction_date = '$(''Start'').item.json.transaction_date'
            holding_id       = '$(''Resolve Holding'').item.json.id'
            description      = '"Dividende ISIN " + $(''Start'').item.json.isin'
        })

    # --- HITL approval gate (before the write) ---
    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Betrag in der Verrechnungskonto-Waehrung (Get Settlement Account).
    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(1980, 0) -Title 'finance.hitl.book_dividend' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.security'            "($S.isin || $S.symbol)")
        (New-HitlLine 'finance.label.depot'               "$S.depot_name")
        (New-HitlLine 'finance.label.amount_net_of_tax'   "$S.amount" -Kind money -Currency "`$('Get Settlement Account').item.json.settlement_currency")
        (New-HitlLine 'core.label.date'                   "`$('Dry run').item.json.r.effective.transaction_date" -Kind date)   # DB-Default heute (Probelauf)
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(2200, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2420, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2640, 200) 'the book_dividend action'

    # Write via fn_book_dividend ($wg.Write): nicht-positiver Dividendenbetrag -> {ok:false} (ok/reason).
    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2860, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Dividend rejected' @(3080, 240) `
        "={{ `$('Book dividend (atomic)').item.json.reason }}"

    $ret = Build-Return @(3080, 0) @(
        ,@('ok','true','boolean')
        ,@('transaction_id', "={{ `$('Book dividend (atomic)').item.json.transaction_id }}", 'number')
        ,@('holding_id', "={{ `$('Resolve Holding').item.json.id }}", 'number')
        ,@('account_balance', "={{ `$('Book dividend (atomic)').item.json.account_balance }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1320, -200) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_dividend mit denselben Werten, immer zurückgerollt. ok:false (z. B. Dividendenbetrag nicht positiv) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyBalance = Build-Sticky 'DB-Automatik balance' @(2640, -200) `
        'finance.fn_book_dividend (atomar) + trg_finance_balance_update' `
        'Schreibt finance.fn_book_dividend atomar (eine Dividenden-Buchung aufs Verrechnungskonto, shares=NULL laut CHECK). Danach pflegt trg_finance_balance_update automatisch den Saldo (finance.account_balances) — der Workflow bucht den Saldo nie selbst.' 200 380

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(3080, -200) `
        'fn-Rückgabe {ok:false, reason}' `
        'Nicht-positiver Dividendenbetrag liefert die fn als {ok:false, reason} -> Dividend rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true bucht wirklich. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 200 380

    $nodes = @($trig, $resDepot, $ifDepot, $errDepot, $getSettle, $resHolding, $ifHolding, $errHolding) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyBalance, $stickyOk)

    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Resolve Depot' ) ) }
        'Resolve Depot'           = @{ main = @( ,@( E 'Depot unique?' ) ) }
        'Depot unique?'           = @{ main = @(
            @( E 'Get Settlement Account' ),
            @( E 'Depot ambiguous' )
        ) }
        'Get Settlement Account'  = @{ main = @( ,@( E 'Resolve Holding' ) ) }
        'Resolve Holding'         = @{ main = @( ,@( E 'Holding exists?' ) ) }
        'Holding exists?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Holding missing' )
        ) }
        'Dry run'                 = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'             = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'  = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'        = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'               = @{ main = @(
            @( E 'Book dividend (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book dividend (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Dividend rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_book_dividend' $nodes $conns `
        @{ Category = 'securities' }
}

