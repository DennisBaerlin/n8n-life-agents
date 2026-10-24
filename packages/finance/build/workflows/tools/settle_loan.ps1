#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_settle_loan (vorzeitige Abloesung buchen: Restschuld -> 0, paid_off, Rate beendet) ---
function Build-SettleLoan {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('loan_name','debit_account_name','settlement_date','settlement_amount')

    $resAcc = Build-Pg 'Resolve Debit Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'debit_account_name', ARRAY['cash']);" `
        ([ordered]@{ debit_account_name = '$(''Start'').item.json.debit_account_name' })

    $ifAcc = Build-If 'Debit unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcc = Build-ToolError 'Debit ambiguous' @(660, 240) `
        "=Debit account '{{ `$('Start').item.json.debit_account_name }}' resolves to {{ `$('Resolve Debit Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Debit Account').item.json.candidates) }}. Ask the user which exact account to use."

    $readLoan = Build-Pg 'Read Loan' @(660, 0) `
        "=SELECT l.lender, l.status::text AS loan_status, GREATEST(-COALESCE(bal.balance,0),0) AS remaining_debt FROM finance.loans l LEFT JOIN finance.account_balances bal ON bal.account_id = l.loan_account_id WHERE l.name = ((`$1::jsonb)->>'loan_name') ORDER BY l.id LIMIT 1;" `
        ([ordered]@{ loan_name = '$(''Start'').item.json.loan_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readLoan -KeyField 'loan_status' -IfName 'Loan found?' -ErrName 'Loan not found' `
        -IfPos @(770, -160) -ErrPos @(880, 240) `
        -NotFoundExpr "=No loan named '{{ `$('Start').item.json.loan_name }}' exists. List them via postgres_select on finance.loan_overview and ask the user which one is meant."

    # "DB ist das Gesetz": fn_settle_loan laeuft als Probelauf VOR der Karte (keine Restschuld, Abloesesumme < Restschuld
    # -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten Write (2-Bein-Abloesung).
    $wg = New-FnWriteGate -Fn 'finance.fn_settle_loan' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Settle loan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'settlement_tx_id')::int AS settlement_tx_id, (r->>'principal_tx_id')::int AS principal_tx_id, (r->>'remaining_debt')::numeric AS remaining_debt, (r->>'interest')::numeric AS interest" `
        -Params ([ordered]@{
            loan_name         = '$(''Start'').item.json.loan_name'
            debit_account_id  = '$(''Resolve Debit Account'').item.json.id'
            settlement_date   = '$(''Start'').item.json.settlement_date'
            settlement_amount = '$(''Start'').item.json.settlement_amount'
        })

    # Strukturiertes Summary (Textkatalog): Restschuld/Abloesesumme/Zins-Anteil in EUR-Konvention (Kredit-Werte in EUR).
    $S = "`$('Start').item.json"
    $L = "`$('Read Loan').item.json"
    $withInt = "($S.settlement_amount && Number($S.settlement_amount) > Number($L.remaining_debt))"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.settle_loan' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.loan'                   "$S.loan_name")
        (New-HitlLine 'finance.label.lender'                 "$L.lender")
        (New-HitlLine 'finance.label.remaining_debt_current' "$L.remaining_debt" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.settlement_sum'         "($withInt ? 'finance.tpl.settle_with_interest' : 'finance.tpl.plain')" -Kind tpl -Params @{
            value    = (New-HitlValue -Kind money -Value "($S.settlement_amount || $L.remaining_debt)" -EurByModel)
            interest = (New-HitlValue -Kind money -Value "(Number($S.settlement_amount) - Number($L.remaining_debt))" -EurByModel) })
        (New-HitlLine 'finance.label.debit_account'          "$S.debit_account_name")
        (New-HitlLine 'core.label.date'                      "$S.settlement_date" -Kind date)
        (New-HitlNote -Key 'finance.note.settle_loan_action')
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the settle_loan action'

    # Atomarer Write ($wg.Write, 'Settle loan (atomic)'): prueft erneut, falls sich seit dem Probelauf etwas geaendert hat.
    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Settle rejected' @(2640, 240) `
        "={{ `$('Settle loan (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('remaining_debt', "={{ `$('Settle loan (atomic)').item.json.remaining_debt }}", 'number')
        ,@('interest', "={{ `$('Settle loan (atomic)').item.json.interest }}", 'number')
        ,@('settlement_tx_id', "={{ `$('Settle loan (atomic)').item.json.settlement_tx_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_settle_loan mit denselben Werten, immer zurückgerollt. ok:false (keine Restschuld, Ablösesumme kleiner als die Restschuld) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (mehrdeutig; nicht gefunden fängt vorher das Found?-Gate als Tool-Fehler) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_settle_loan: 2-Bein-Ablösung' @(2200, -300) `
        'group_id; Restschuld -> 0; paid_off; Rate beendet' `
        'fn_settle_loan liest die Restschuld (GREATEST(-Saldo,0)) und bucht 2 Beine mit gemeinsamer group_id (category settlement): Giro -Ablösesumme, Kreditkonto +Restschuld (Saldo via Trigger -> 0). interest = Ablösesumme - Restschuld (implizit). Danach loan.status=paid_off und die Rate-rp wird beendet (status=paused + valid_to=Datum). Keine Restschuld -> {ok:false}; Ablösesumme < Restschuld -> {ok:false} (book_loan_payment für Teilzahlung). RAISE bei nicht gefunden/mehrdeutig (nicht gefunden fängt vorher das Found?-Gate des Tools).' 260 540

    $nodes = @($trig, $resAcc, $ifAcc, $errAcc, $readLoan, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Debit Account' ) ) }
        'Resolve Debit Account'  = @{ main = @( ,@( E 'Debit unique?' ) ) }
        'Debit unique?'          = @{ main = @(
            @( E 'Read Loan' ),
            @( E 'Debit ambiguous' )
        ) }
        'Read Loan'              = @{ main = @( ,@( E 'Loan found?' ) ) }
        'Loan found?'            = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Loan not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Settle loan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Settle loan (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Settle rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_settle_loan' $nodes $conns `
        @{ Category = 'loans' }
}
