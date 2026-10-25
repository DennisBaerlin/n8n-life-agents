#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 5. tool_book_loan_payment (Playbook 5.7) ---------------
function Build-BookLoanPayment {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('loan_name','payment_amount','payment_date','principal_amount')

    $resLoan = Build-Pg 'Resolve Loan' @(220, 0) `
        "=SELECT loan_id, loan_account_id, debit_account_id, hit_count, candidates FROM finance.fn_resolve_loan((`$1::jsonb)->>'loan_name');" `
        ([ordered]@{ loan_name = '$(''Start'').item.json.loan_name' })

    $ifLoan = Build-If 'Loan unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errLoan = Build-ToolError 'Loan ambiguous' @(660, 400) `
        "=Loan '{{ `$('Start').item.json.loan_name }}' resolves to {{ `$('Resolve Loan').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Loan').item.json.candidates) }}. Ask the user which exact loan."

    # Kreditname + Waehrung fuer die Karte (die Restschuld kommt positiv aus der Vorschau-fn, nicht aus der View:
    # loan_overview.current_remaining_debt ist der NEGATIVE Kontosaldo).
    $readOverview = Build-Pg 'Read Loan Overview' @(660, 0) `
        "=SELECT name, currency FROM finance.loan_overview WHERE id = ((`$1::jsonb)->>'loan_id')::int;" `
        ([ordered]@{ loan_id = '$(''Resolve Loan'').item.json.loan_id' })

    # Zins/Tilgung + Buchungsdatum aus DERSELBEN fn, die fn_book_loan_payment intern nutzt (Audit F7: vorher
    # rechnete dieser Graph mit der negativen Restschuld -> Karte "Zins -600 / Tilgung 1.600", gebucht 600/400).
    # WP2: ohne genannten Betrag liefert die fn die faellige Rate (payment_amount); genau dieser Betrag geht in den Write
    # (Karte = Buchung, auch wenn zwischen Karte und Tipp ein Tag wechselt).
    $preview = Build-Pg 'Preview Loan Payment' @(880, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'payment_amount')::numeric AS payment_amount, (r->>'remaining_debt')::numeric AS remaining_debt, (r->>'interest_portion')::numeric AS interest_portion, (r->>'principal_amount')::numeric AS principal_amount, r->>'booking_date' AS booking_date FROM finance.fn_get_loan_payment_split(`$1::jsonb) AS r;" `
        ([ordered]@{
            loan_id          = '$(''Resolve Loan'').item.json.loan_id'
            payment_amount   = '$(''Start'').item.json.payment_amount'
            payment_date     = '$(''Start'').item.json.payment_date'
            principal_amount = '$(''Start'').item.json.principal_amount'
        })

    # Ueber-/Unterzahlung schon VOR der Karte zurueck an den Agenten (der Owner bestaetigt nie etwas Unbuchbares).
    $ifPreviewOk = Build-If 'Preview ok?' @(1100, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errPreview = Build-ToolError 'Payment not possible' @(1320, 240) `
        "={{ `$('Preview Loan Payment').item.json.reason }}"

    # "DB ist das Gesetz": nach der Vorschau laeuft fn_book_loan_payment selbst als Probelauf VOR der Karte
    # (Ueber-/Unterzahlung, payment<=0 -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den
    # echten Write. Die Vorschau bleibt: sie liefert die Kartenwerte (Restschuld/Zins/Tilgung).
    $wg = New-FnWriteGate -Fn 'finance.fn_book_loan_payment' -DryPos @(1320, 0) -WritePos @(2640, 0) `
        -WriteName 'Create loan payment (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'loan_payment_tx_id')::int AS loan_payment_tx_id, (r->>'principal_tx_id')::int AS principal_tx_id, (r->>'interest_portion')::numeric AS interest_portion, (r->>'principal_amount')::numeric AS principal_amount, (r->>'remaining_debt')::numeric AS remaining_debt, r->>'matched_due_date' AS matched_due_date" `
        -Params ([ordered]@{
            loan_id          = '$(''Resolve Loan'').item.json.loan_id'
            loan_account_id  = '$(''Resolve Loan'').item.json.loan_account_id'
            debit_account_id = '$(''Resolve Loan'').item.json.debit_account_id'
            payment_amount   = '$(''Preview Loan Payment'').item.json.payment_amount'
            payment_date     = '$(''Start'').item.json.payment_date'
            principal_amount = '$(''Start'').item.json.principal_amount'
        })

    # --- HITL approval gate ---
    # Strukturiertes Summary (Textkatalog); Betraege in der Loan-Konto-Waehrung (Read Loan Overview).
    $S = "`$('Start').item.json"
    $L = "`$('Read Loan Overview').item.json"
    $I = "`$('Preview Loan Payment').item.json"
    $summary = New-HitlSummary -Pos @(1980, 0) -Title 'finance.hitl.book_loan_payment' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.loan'                  "$L.name")
        (New-HitlLine 'finance.label.remaining_debt_current' "$I.remaining_debt" -Kind money -Currency "$L.currency")
        (New-HitlLine 'finance.label.rate_total'            "$I.payment_amount" -Kind money -Currency "$L.currency" -IsDefault "!$S.payment_amount")
        (New-HitlLine 'finance.label.principal_part'        "$I.principal_amount" -Kind money -Currency "$L.currency")
        (New-HitlLine 'finance.label.interest_part'         "$I.interest_portion" -Kind money -Currency "$L.currency")
        (New-HitlLine 'core.label.date'                     "$I.booking_date" -Kind date)
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(2200, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2420, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2640, 240) 'the book_loan_payment action'

    # Atomarer Write via fn_book_loan_payment ($wg.Write):
    # 1. Abbuchung vom Girokonto (-payment_amount, category=loan_payment, loan_id gesetzt)
    # 2. Tilgungsanteil auf Kreditkonto (+principal, category=principal, loan_id gesetzt)
    # fn liefert ok/reason: Ueberzahlung (mit payoff_amount) / Unterzahlung / payment<=0 -> {ok:false}.
    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2860, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Payment rejected' @(3080, 240) `
        "={{ `$('Create loan payment (atomic)').item.json.reason }}"

    $ret = Build-Return @(3080, 0) @(
        ,@('ok','true','boolean')
        ,@('loan_payment_tx_id', "={{ `$('Create loan payment (atomic)').item.json.loan_payment_tx_id }}", 'number')
        ,@('principal_tx_id', "={{ `$('Create loan payment (atomic)').item.json.principal_tx_id }}", 'number')
        ,@('interest_portion', "={{ `$('Create loan payment (atomic)').item.json.interest_portion }}", 'number')
        ,@('principal_amount', "={{ `$('Create loan payment (atomic)').item.json.principal_amount }}", 'number')
        ,@('remaining_debt', "={{ `$('Create loan payment (atomic)').item.json.remaining_debt }}", 'number')
        ,@('matched_due_date', "={{ `$('Create loan payment (atomic)').item.json.matched_due_date }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1320, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Nach der Vorschau läuft fn_book_loan_payment mit denselben Werten als Probelauf, immer zurückgerollt. ok:false (Überzahlung, Unterzahlung, Rate<=0) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 240 460

    $stickyTriggers = Build-Sticky 'DB-Automatik balance (2 Konten)' @(2640, -220) `
        'trg_finance_balance_update' `
        'fn_book_loan_payment bucht atomar 2 Transaktionen: (1) Girokonto -payment (loan_payment), (2) Kreditkonto +principal (principal). Zins/Tilgung aus fn_get_loan_payment_split (dieselbe fn wie die Vorschau). Eine reguläre Rate (Betrag = geplante Rate) schließt das nächstgelegene offene Vorkommen der Kredit-Rate (rp-Stempel, Buchung auf dessen Fälligkeitsdatum) -> die Erinnerung fragt sie nicht erneut ab. DB-Trigger pflegen Salden beider Konten. Restschuld = negativer Saldo des Kreditkontos. Die fn liest die neue Restschuld nach der Tilgung (remaining_debt) und gibt sie zurück -> Agent nennt sie in der Bestätigung.' 200 520

    $stickyPreview = Build-Sticky 'Vorschau = Buchung' @(880, -260) `
        'fn_get_loan_payment_split (eine Formel)' `
        'Die Karte zeigt Restschuld, Tilgung, Zins und Buchungsdatum aus fn_get_loan_payment_split -- derselben fn, die fn_book_loan_payment intern ruft. Der Graph rechnet nichts selbst (früher JS mit der negativen Restschuld -> Karte zeigte Zins -600 / Tilgung 1.600, gebucht wurden 600 / 400). Über-/Unterzahlung kommt schon hier als ok=false zurück -> Payment not possible reicht reason an den Agenten, bevor der Owner eine Karte sieht.' 240 460

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(3080, -220) `
        'fn-Rückgabe {ok:false, reason}' `
        'Überzahlung (Rate > Restschuld; reason nennt payoff_amount = Restschuld+Zins), Unterzahlung (Rate < Zins) und payment<=0 liefert die fn als {ok:false, reason} -> Payment rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Normalerweise fängt schon der Probelauf das vor der Karte ab.' 200 400

    $nodes = @($trig, $resLoan, $ifLoan, $errLoan, $readOverview, $preview, $ifPreviewOk, $errPreview) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyTriggers, $stickyOk, $stickyPreview)

    $conns = [ordered]@{
        'Start'                        = @{ main = @( ,@( E 'Resolve Loan' ) ) }
        'Resolve Loan'                 = @{ main = @( ,@( E 'Loan unique?' ) ) }
        'Loan unique?'                 = @{ main = @(
            @( E 'Read Loan Overview' ),
            @( E 'Loan ambiguous' )
        ) }
        'Read Loan Overview'           = @{ main = @( ,@( E 'Preview Loan Payment' ) ) }
        'Preview Loan Payment'         = @{ main = @( ,@( E 'Preview ok?' ) ) }
        'Preview ok?'                  = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Payment not possible' )
        ) }
        'Dry run'                      = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                  = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'       = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'             = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                    = @{ main = @(
            @( E 'Create loan payment (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create loan payment (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                    = @{ main = @(
            @( E 'Return' ),
            @( E 'Payment rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_book_loan_payment' $nodes $conns `
        @{ Category = 'loans' }
}
