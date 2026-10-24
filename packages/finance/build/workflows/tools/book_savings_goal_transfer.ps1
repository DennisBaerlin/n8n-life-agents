#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_book_savings_goal_transfer (D1 Phase S: Einzahlen / Entnehmen / Umschichten) ---
function Build-BookSavingsGoalTransfer {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('savings_goal_name','from_account_name','to_account_name','amount','direction','transaction_date','purpose','to_amount')

    $stickyOverview = Build-Sticky 'Überblick tool_book_savings_goal_transfer' @(-40, -260) `
        'Sparziel-Geldbewegung (Phase S WS-A): einzahlen / entnehmen / umschichten' `
        'Bewegt Geld in Bezug auf ein Sparziel — die EINE fokussierte Fähigkeit für eine Extra-Einzahlung, eine Entnahme oder das Umschichten der Reserve zwischen eigenen Konten (NICHT die monatliche Sparrate = create_savings_goal). Eingänge: savings_goal_name, amount, direction (deposit|withdrawal|relocate), optional from_account_name/to_account_name/transaction_date/purpose/to_amount. Ablauf: Resolve Ziel -> Probelauf (die fn löst Von/An-Namen auf und leitet fehlende aus dem Reserve-Topf ab) (Dry run, ohne Karte bei Ablehnung) -> HITL-Gate -> atomarer Write via fn_book_savings_goal_transfer (intern fn_book_transfer + savings_goal_id-Tag). Ausgang {ok:true, debit_tx_id, credit_tx_id, current_amount (neuer Ziel-Stand), from_balance, to_balance} bzw. {ok:false} (korrigierbar) / {cancelled} (Decline).' 260 460

    $resGoal = Build-Pg 'Resolve Goal' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_savings_goal((`$1::jsonb)->>'savings_goal_name', TRUE);" `
        ([ordered]@{ savings_goal_name = '$(''Start'').item.json.savings_goal_name' })

    $ifGoal = Build-If 'Goal unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errGoal = Build-ToolError 'Goal ambiguous' @(660, 200) `
        "=Savings goal '{{ `$('Start').item.json.savings_goal_name }}' resolves to {{ `$('Resolve Goal').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Goal').item.json.candidates) }}. Ask the user which exact goal."

    # Nachtrag D (DB ist das Gesetz): Von/An loest die fn selbst auf (Namen; nur cash/Festgeld, Depot -> Verweis auf
    # die Reservierung) und leitet fehlende aus dem Sparziel ab (Topf = Zielkonto der Sparrate, Von = Abbuchungskonto
    # bzw. Reserve-Konto). Kein eigener Resolve-Knoten mehr; Kartenwerte aus dem Probelauf (effective).
    # "DB ist das Gesetz": fn_book_savings_goal_transfer laeuft als Probelauf VOR der Karte (Betrag, Richtung, falsches
    # Konto not_reserve, zu kleiner Anteil insufficient_share, interner Transfer {ok:false} -> keine Karte); derselbe
    # Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_savings_goal_transfer' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Book savings movement (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'debit_tx_id')::int AS debit_tx_id, (r->>'credit_tx_id')::int AS credit_tx_id, (r->>'current_amount')::numeric AS current_amount, (r->>'from_balance')::numeric AS from_balance, (r->>'to_balance')::numeric AS to_balance, COALESCE(r->'savings_goal_reached'->>'note', '') AS savings_goal_reached" `
        -Params ([ordered]@{
            savings_goal_id  = '$(''Resolve Goal'').item.json.id'
            from_account_name = '$(''Start'').item.json.from_account_name'
            to_account_name  = '$(''Start'').item.json.to_account_name'
            amount           = '$(''Start'').item.json.amount'
            direction        = '$(''Start'').item.json.direction'
            transaction_date = '$(''Start'').item.json.transaction_date'
            purpose          = '$(''Start'').item.json.purpose'
            to_amount        = '$(''Start'').item.json.to_amount'
        })

    # Strukturiertes Summary (Textkatalog). Konten, Waehrungen und Datum aus dem Probelauf (effective = von der fn
    # eingesetzt/abgeleitet): Betrag in der Waehrung des Quellkontos, to_amount (nur bei Fremdwaehrung) in der des Ziels.
    $S = "`$('Start').item.json"
    $E = "`$('Dry run').item.json.r.effective"
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'finance.hitl.book_savings_goal_transfer' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.savings_goal'          "$S.savings_goal_name")
        (New-HitlLine 'finance.label.kind'                  "$S.direction" -Kind enum -Enum 'finance.enum.savings_move')
        (New-HitlLine 'core.label.amount'                   "$S.amount" -Kind money -Currency "$E.from_currency")
        (New-HitlLine 'finance.label.target_amount_after'   "$S.to_amount" -Kind money -Currency "$E.to_currency" -If "$S.to_amount")
        (New-HitlLine 'finance.label.from'                  "$E.from_account_name")
        (New-HitlLine 'finance.label.to'                    "$E.to_account_name")
        (New-HitlLine 'core.label.date'                     "$E.transaction_date" -Kind date)   # DB-Default heute (Probelauf)
        (New-HitlLine 'finance.label.purpose'               "$S.purpose" -If "$S.purpose")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the book_savings_goal_transfer action'

    # Atomarer Write via fn_book_savings_goal_transfer ($wg.Write): intern fn_book_transfer (zwei Beine) + Tag-Zuordnung je direction.
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Movement rejected' @(2420, 200) `
        "={{ `$('Book savings movement (atomic)').item.json.reason }}"

    # Post-State: neuer Ziel-Stand + Salden beider Konten (von der fn berechnet).
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('debit_tx_id', "={{ `$('Book savings movement (atomic)').item.json.debit_tx_id }}", 'number')
        ,@('credit_tx_id', "={{ `$('Book savings movement (atomic)').item.json.credit_tx_id }}", 'number')
        ,@('current_amount', "={{ `$('Book savings movement (atomic)').item.json.current_amount }}", 'number')
        ,@('from_balance', "={{ `$('Book savings movement (atomic)').item.json.from_balance }}", 'number')
        ,@('to_balance', "={{ `$('Book savings movement (atomic)').item.json.to_balance }}", 'number')
        ,@('savings_goal_reached', "={{ `$('Book savings movement (atomic)').item.json.savings_goal_reached }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1540, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_savings_goal_transfer mit denselben Werten, immer zurückgerollt. Die fn leitet fehlende Konten ab: deposit An = Topf (Zielkonto der Sparrate), Von = Abbuchungskonto; withdrawal/relocate Von = Topf. Ein Bein muss zur Reserve gehören (Topf + Konten mit getaggtem Geld); Altziel ohne Rate: das eine Reserve-Konto. Hinweise von fn_book_transfer (mögliche Doppelbuchung) kommen als card_lines auf die Karte. ok:false (Betrag<=0, direction nicht im Enum, Konto unbekannt/mehrdeutig, Depot-Name, not_reserve, insufficient_share, missing_from/missing_to, no_reserve, use_relocate (Geld zwischen zwei Reserve-Konten), from==to, interner Transfer abgelehnt, z. B. Cross-Currency ohne to_amount) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 250 460

    $stickyFn = Build-Sticky 'fn_book_savings_goal_transfer: Reuse + Tag + Erreicht-Fold' @(2860, -260) `
        'fn_book_savings_goal_transfer (atomar)' `
        'Jede Sparziel-Bewegung ist physisch ein Transfer: die fn ruft INTERN finance.fn_book_transfer (zwei Beine, group_id, Multi-Währung, Saldo-Trigger) und stempelt dann je direction den savings_goal_id-Tag: deposit -> Haben-(to-)Bein (+); withdrawal -> Soll-(from-)Bein (-); relocate -> BEIDE Beine (Netto-0, nur Umzug). savings_goal_progress.current_amount = signed SUM der getaggten Tx -> bewegt sich entsprechend. Scheitert der interne Transfer ({ok:false}, z. B. Cross-Currency ohne to_amount), wird NICHT gestempelt (Guard vor dem UPDATE) -> kein stiller no-op-Tag. Phase L WS-5: NUR bei direction=deposit + current>=target faltet die fn eine Glückwunsch-Note in savings_goal_reached (withdrawal/relocate nie; sonst leer). Bookkeeper relayed (erreicht != ausgegeben).' 250 580

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(3300, -260) `
        'fn-Rückgabe {ok:false, reason}' `
        'amount<=0 / direction nicht im Enum / Konto- und Reserve-Ablehnungen (not_reserve, insufficient_share, use_relocate, missing_from/missing_to, ...) / from==to / interner Transfer {ok:false} (z. B. Cross-Currency ohne to_amount) liefert die fn als {ok:false, reason} -> Movement rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true bucht + stempelt. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 240 440

    $nodes = @($trig, $resGoal, $ifGoal, $errGoal) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret,
               $stickyOverview, $stickyDry, $stickyFn, $stickyOk)

    $conns = [ordered]@{
        'Start'                          = @{ main = @( ,@( E 'Resolve Goal' ) ) }
        'Resolve Goal'                   = @{ main = @( ,@( E 'Goal unique?' ) ) }
        'Goal unique?'                   = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Goal ambiguous' )
        ) }
        'Dry run'                        = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                    = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'         = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'               = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                      = @{ main = @(
            @( E 'Book savings movement (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book savings movement (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                      = @{ main = @(
            @( E 'Return' ),
            @( E 'Movement rejected' )
        ) }
    }

    # Kein /help-Beispiel (finance.help.savings_goals.exN): kein Routing-Golden (operiert auf bestehendem Ziel; keine dauerhafte Prod-Fixture -> Agent
    # wuerde sonst nachfragen statt zu rufen, tier-Wahl wie set_savings_goal/set_holding). Abdeckung = db_test
    # (test_fn_book_savings_goal_transfer) + E2E. Category-Beschreibung 'Sparziele' traegt die Bedeutung.
    return Build-Workflow 'agent.finance.tool_book_savings_goal_transfer' $nodes $conns `
        @{ Category = 'savings_goals' }
}
