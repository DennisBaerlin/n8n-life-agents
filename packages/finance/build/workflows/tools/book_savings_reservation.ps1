#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_book_savings_reservation (Phase S WS-B: Depot-Anteil einer Sparziel-Reserve ins append-only Journal) ---
function Build-BookSavingsReservation {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10).
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('savings_goal_name','depot_account_name','amount')

    $stickyOverview = Build-Sticky 'Überblick tool_book_savings_reservation' @(-40, -260) `
        'Depot-Anteil einer Sparziel-Reserve buchen (Phase S WS-B)' `
        'Reserviert einen ABSOLUTEN €-Betrag des DEPOTS für ein Sparziel — der Depot-Anteil der Reserve (der Cash-Anteil läuft über tool_book_savings_goal_transfer). Eingänge: savings_goal_name, depot_account_name (stocks_depot/crypto_depot), amount (absoluter Ziel-Betrag). Ablauf: Resolve Ziel + Depot -> Probelauf (Dry run, ohne Karte bei Ablehnung) -> HITL-Gate -> atomarer Write via fn_book_savings_reservation (rechnet delta = amount - Σ Journal, hängt EINE Zeile an -> append-only, driftfrei). Der Marktwert ist Deckel/Deckung (depot_reserve_status), NIE die gespeicherte Reserve. Ausgang {ok:true, entry_id, delta, reserved (= amount), market_value, shortfall} bzw. {ok:false} (korrigierbar) / {cancelled} (Decline).' 260 460

    $resGoal = Build-Pg 'Resolve Goal' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_savings_goal((`$1::jsonb)->>'savings_goal_name', TRUE);" `
        ([ordered]@{ savings_goal_name = '$(''Start'').item.json.savings_goal_name' })

    $ifGoal = Build-If 'Goal unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errGoal = Build-ToolError 'Goal ambiguous' @(660, 200) `
        "=Savings goal '{{ `$('Start').item.json.savings_goal_name }}' resolves to {{ `$('Resolve Goal').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Goal').item.json.candidates) }}. Ask the user which exact goal."

    # Der Depot-Anteil deckt gegen den Depot-Marktwert -> NUR stocks_depot/crypto_depot (Cash-Reserve = book_savings_goal_transfer).
    $resDepot = Build-Pg 'Resolve Depot' @(660, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'depot_account_name', ARRAY['stocks_depot','crypto_depot']);" `
        ([ordered]@{ depot_account_name = '$(''Start'').item.json.depot_account_name' })

    $ifDepot = Build-If 'Depot unique?' @(880, 0) "={{ `$json.hit_count }}" '1'

    $errDepot = Build-ToolError 'Depot ambiguous' @(1100, 200) `
        "=Depot account '{{ `$('Start').item.json.depot_account_name }}' resolves to {{ `$('Resolve Depot').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Depot').item.json.candidates) }}. Ask the user which exact depot."

    # --- HITL approval gate (absoluter Betrag = roher Nutzer-Input; Marktwert-Deckung zeigt der Post-State NACH dem Write) ---
    # Strukturiertes Summary (Textkatalog); absolute EUR-Reserve per Konvention -> Literal 'EUR'.
    # "DB ist das Gesetz": fn_book_savings_reservation laeuft als Probelauf VOR der Karte (amount<0, Ziel nicht
    # gefunden, Konto kein Depot, delta=0 -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den
    # echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_savings_reservation' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Book depot reservation (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'entry_id')::int AS entry_id, (r->>'delta')::numeric AS delta, (r->>'reserved')::numeric AS reserved, (r->>'market_value')::numeric AS market_value, (r->>'shortfall')::numeric AS shortfall" `
        -Params ([ordered]@{
            savings_goal_id  = '$(''Resolve Goal'').item.json.id'
            depot_account_id = '$(''Resolve Depot'').item.json.id'
            amount           = '$(''Start'').item.json.amount'
        })

    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.book_savings_reservation' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.savings_goal'    "$S.savings_goal_name")
        (New-HitlLine 'finance.label.depot'           "$S.depot_account_name")
        (New-HitlLine 'finance.label.reserved_amount' "$S.amount" -Kind money -EurByModel)
        (New-HitlNote -Key 'finance.note.reserve_fixed')
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 200) 'the book_savings_reservation action'

    # Atomarer Write via fn_book_savings_reservation ($wg.Write): absolut-rein -> delta-append (eine Journal-Zeile).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Reservation rejected' @(2860, 200) `
        "={{ `$('Book depot reservation (atomic)').item.json.reason }}"

    # Post-State: neuer Depot-Anteil (reserved = amount), angehaengte Bewegung (delta) + Deckung (market_value/shortfall), von der fn berechnet.
    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('entry_id', "={{ `$('Book depot reservation (atomic)').item.json.entry_id }}", 'number')
        ,@('delta', "={{ `$('Book depot reservation (atomic)').item.json.delta }}", 'number')
        ,@('reserved', "={{ `$('Book depot reservation (atomic)').item.json.reserved }}", 'number')
        ,@('market_value', "={{ `$('Book depot reservation (atomic)').item.json.market_value }}", 'number')
        ,@('shortfall', "={{ `$('Book depot reservation (atomic)').item.json.shortfall }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_savings_reservation mit denselben Werten, immer zurückgerollt. ok:false (Betrag negativ, Ziel nicht gefunden, Konto kein Depot, delta=0 = gleicher Betrag wie bisher) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 240 460

    $stickyFn = Build-Sticky 'fn_book_savings_reservation: absolut -> delta-append' @(2420, -260) `
        'fn_book_savings_reservation (atomar, append-only)' `
        'Absolut-rein -> delta-append (das LLM rechnet NICHT): die fn liest die aktuelle Σ des Journals je (Ziel, Depot), rechnet delta = amount - Σ und hängt GENAU EINE savings_goal_reserve_entries-Zeile (kind=manual) an — NIE UPDATE einer Zahl -> der Stand bleibt DERIVED -> strukturell driftfrei. Marktwert ist Deckel/Deckung, NIE die gespeicherte Reserve. Post-State {reserved (= amount), delta, market_value (Depot-Marktwert EUR, NULL ohne Kurs), shortfall} liest die fn aus depot_reserve_status.' 240 560

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -260) `
        'fn-Rückgabe {ok:false, reason}' `
        'amount<0 (keine negative Reserve) / Ziel nicht gefunden / Konto kein Depot / delta=0 (no-op, gleicher Betrag) liefert die fn als {ok:false, reason} -> Reservation rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true hängt die Journal-Zeile an. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 240 440

    $nodes = @($trig, $resGoal, $ifGoal, $errGoal, $resDepot, $ifDepot, $errDepot) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret,
               $stickyOverview, $stickyDry, $stickyFn, $stickyOk)

    $conns = [ordered]@{
        'Start'                              = @{ main = @( ,@( E 'Resolve Goal' ) ) }
        'Resolve Goal'                       = @{ main = @( ,@( E 'Goal unique?' ) ) }
        'Goal unique?'                       = @{ main = @(
            @( E 'Resolve Depot' ),
            @( E 'Goal ambiguous' )
        ) }
        'Resolve Depot'                      = @{ main = @( ,@( E 'Depot unique?' ) ) }
        'Depot unique?'                      = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Depot ambiguous' )
        ) }
        'Dry run'                            = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                        = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'             = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'                   = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                          = @{ main = @(
            @( E 'Book depot reservation (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book depot reservation (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                          = @{ main = @(
            @( E 'Return' ),
            @( E 'Reservation rejected' )
        ) }
    }

    # Kein /help-Beispiel (finance.help.savings_goals.exN): kein Routing-Golden (operiert auf bestehendem Ziel + Depot; keine dauerhafte Prod-Fixture ->
    # der Agent wuerde sonst nachfragen statt zu rufen, tier-Wahl wie book_savings_goal_transfer/set_holding).
    # Abdeckung = db_test (test_fn_book_savings_reservation) + E2E (e2e37). Category 'Sparziele' traegt die Bedeutung.
    return Build-Workflow 'agent.finance.tool_book_savings_reservation' $nodes $conns `
        @{ Category = 'savings_goals' }
}
