#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_book_savings_reservation (Zweckbindung: vorhandenes Geld eines Kontos einem Sparziel zuordnen, append-only Journal) ---
function Build-BookSavingsReservation {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10).
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('savings_goal_name','account_name','amount')

    $stickyOverview = Build-Sticky 'Überblick tool_book_savings_reservation' @(-40, -260) `
        'Geld einem Sparziel zuordnen (Zweckbindung ohne Überweisung)' `
        'Ordnet einen ABSOLUTEN Betrag eines Kontos einem Sparziel zu, ohne Geld zu bewegen (YNAB-Assign/Firefly-Piggy). Konten: Giro/Tagesgeld, Festgeld, P2P (Betrag in Kontowährung) und Depots (Betrag in EUR) — finance.fn_goal_earmark_account_types. Eingänge: savings_goal_name, account_name, amount. Ablauf: Resolve Ziel + Konto -> Probelauf (Dry run, ohne Karte bei Ablehnung) -> HITL-Gate -> atomarer Write via fn_book_savings_reservation (delta = amount - aktueller Anteil inkl. eingezahltem Geld, EINE Journal-Zeile -> append-only, driftfrei). Saldo-Konto: die fn lehnt ab, wenn mehr zugeordnet würde als frei auf dem Konto liegt. Depot: Marktwert ist nur Deckung. Ausgang {ok:true, entry_id, delta, reserved, current_amount, free_balance | market_value+shortfall} bzw. {ok:false} (korrigierbar) / {cancelled} (Decline).' 260 500

    $resGoal = Build-Pg 'Resolve Goal' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_savings_goal((`$1::jsonb)->>'savings_goal_name', TRUE);" `
        ([ordered]@{ savings_goal_name = '$(''Start'').item.json.savings_goal_name' })

    $ifGoal = Build-If 'Goal unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errGoal = Build-ToolError 'Goal ambiguous' @(660, 200) `
        "=Savings goal '{{ `$('Start').item.json.savings_goal_name }}' resolves to {{ `$('Resolve Goal').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Goal').item.json.candidates) }}. Ask the user which exact goal."

    # Zuordenbare Konten: eine Adresse in der DB (fn_goal_earmark_account_types; Kredit nie). Typ + Waehrung fuer die Karte
    # (Depot-Betrag = EUR, Saldo-Konto = Kontowaehrung) kommen aus derselben Zeile.
    $resAcct = Build-Pg 'Resolve Account' @(660, 0) `
        "=SELECT r.id, r.hit_count, r.candidates, a.currency, (a.account_type IN ('stocks_depot','crypto_depot')) AS is_depot FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', finance.fn_goal_earmark_account_types()::text[]) r LEFT JOIN finance.accounts a ON a.id = r.id;" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(880, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(1100, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches among cash, fixed-deposit, P2P and depot accounts. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # --- HITL approval gate (absoluter Betrag = roher Nutzer-Input; Deckung/freier Saldo zeigt der Post-State NACH dem Write) ---
    # "DB ist das Gesetz": fn_book_savings_reservation laeuft als Probelauf VOR der Karte (amount<0, Ziel/Konto nicht
    # gefunden, Kredit, delta=0, mehr als frei -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den
    # echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_savings_reservation' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Book earmark (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'entry_id')::int AS entry_id, (r->>'delta')::numeric AS delta, (r->>'reserved')::numeric AS reserved, (r->>'current_amount')::numeric AS current_amount, (r->>'free_balance')::numeric AS free_balance, (r->>'market_value')::numeric AS market_value, (r->>'shortfall')::numeric AS shortfall, COALESCE(r->'savings_goal_reached'->>'note', '') AS savings_goal_reached" `
        -Params ([ordered]@{
            savings_goal_id = '$(''Resolve Goal'').item.json.id'
            account_id      = '$(''Resolve Account'').item.json.id'
            amount          = '$(''Start'').item.json.amount'
        })

    $S = "`$('Start').item.json"
    $A = "`$('Resolve Account').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.book_savings_reservation' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.savings_goal'    "$S.savings_goal_name")
        (New-HitlLine 'finance.label.account'         "$S.account_name")
        (New-HitlLine 'finance.label.reserved_amount' "$S.amount" -Kind money -Currency "($A.is_depot ? 'EUR' : $A.currency)")
        (New-HitlNote -KeyExpr "($A.is_depot ? 'finance.note.reserve_fixed' : 'finance.note.earmark_balance')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 200) 'the book_savings_reservation action'

    # Atomarer Write via fn_book_savings_reservation ($wg.Write): absolut-rein -> delta-append (eine Journal-Zeile).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Reservation rejected' @(2860, 200) `
        "={{ `$('Book earmark (atomic)').item.json.reason }}"

    # Post-State von der fn: neuer Anteil (reserved = amount), angehaengte Bewegung (delta), neuer Ziel-Stand, dazu
    # freier Saldo (Saldo-Konto) bzw. Deckung (Depot) und der Erreicht-Hinweis (leer = keiner).
    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('entry_id', "={{ `$('Book earmark (atomic)').item.json.entry_id }}", 'number')
        ,@('delta', "={{ `$('Book earmark (atomic)').item.json.delta }}", 'number')
        ,@('reserved', "={{ `$('Book earmark (atomic)').item.json.reserved }}", 'number')
        ,@('current_amount', "={{ `$('Book earmark (atomic)').item.json.current_amount }}", 'number')
        ,@('free_balance', "={{ `$('Book earmark (atomic)').item.json.free_balance }}", 'number')
        ,@('market_value', "={{ `$('Book earmark (atomic)').item.json.market_value }}", 'number')
        ,@('shortfall', "={{ `$('Book earmark (atomic)').item.json.shortfall }}", 'number')
        ,@('savings_goal_reached', "={{ `$('Book earmark (atomic)').item.json.savings_goal_reached }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_savings_reservation mit denselben Werten, immer zurückgerollt. ok:false (Betrag negativ, Ziel/Konto nicht gefunden, Kreditkonto, delta=0 = gleicher Betrag wie bisher, mehr als frei auf dem Konto) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 240 480

    $stickyFn = Build-Sticky 'fn_book_savings_reservation: absolut -> delta-append' @(2420, -260) `
        'fn_book_savings_reservation (atomar, append-only)' `
        'Absolut-rein -> delta-append (das LLM rechnet NICHT): die fn liest den aktuellen Anteil des Ziels auf dem Konto (savings_goal_account_share: eingezahltes + zugeordnetes Geld), rechnet delta = amount - Anteil und hängt GENAU EINE savings_goal_reserve_entries-Zeile (kind=manual) an — NIE UPDATE einer Zahl -> der Stand bleibt DERIVED. Saldo-Konto: Betrag in Kontowährung, Konto-Zeile gesperrt, Erhöhung nur bis zum freien Saldo. Depot: Betrag in EUR, Marktwert nur Deckung (depot_reserve_status).' 240 560

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -260) `
        'fn-Rückgabe {ok:false, reason}' `
        'amount<0 / Ziel oder Konto nicht gefunden / Kreditkonto / delta=0 (gleicher Betrag) / insufficient_free_balance (mehr als frei) liefert die fn als {ok:false, reason} -> Reservation rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true hängt die Journal-Zeile an. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 240 440

    $nodes = @($trig, $resGoal, $ifGoal, $errGoal, $resAcct, $ifAcct, $errAcct) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret,
               $stickyOverview, $stickyDry, $stickyFn, $stickyOk)

    $conns = [ordered]@{
        'Start'                              = @{ main = @( ,@( E 'Resolve Goal' ) ) }
        'Resolve Goal'                       = @{ main = @( ,@( E 'Goal unique?' ) ) }
        'Goal unique?'                       = @{ main = @(
            @( E 'Resolve Account' ),
            @( E 'Goal ambiguous' )
        ) }
        'Resolve Account'                      = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'                      = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Account ambiguous' )
        ) }
        'Dry run'                            = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                        = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'             = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'                   = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                          = @{ main = @(
            @( E 'Book earmark (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book earmark (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                          = @{ main = @(
            @( E 'Return' ),
            @( E 'Reservation rejected' )
        ) }
    }

    # Kein /help-Beispiel (finance.help.savings_goals.exN): kein Routing-Golden (operiert auf bestehendem Ziel + Konto; keine dauerhafte Prod-Fixture ->
    # der Agent wuerde sonst nachfragen statt zu rufen, tier-Wahl wie book_savings_goal_transfer/set_holding).
    # Abdeckung = db_test (test_fn_book_savings_reservation) + E2E (e2e37). Category 'Sparziele' traegt die Bedeutung.
    return Build-Workflow 'agent.finance.tool_book_savings_reservation' $nodes $conns `
        @{ Category = 'savings_goals' }
}
