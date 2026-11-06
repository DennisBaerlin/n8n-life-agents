#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_delete_loan (Kredit-Fehlanlage loeschen: Hard-DELETE, Inverse von create_loan) ---
function Build-DeleteLoan {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('loan_name')

    $readLoan = Build-Pg 'Read Loan' @(220, 0) `
        "=SELECT l.lender, l.status::text AS loan_status, l.original_amount, GREATEST(-COALESCE(bal.balance,0),0) AS remaining_debt, (SELECT COUNT(*)::int FROM finance.transactions t WHERE t.loan_id = l.id AND t.category IN ('loan_payment','principal','settlement')) AS repayment_count FROM finance.loans l LEFT JOIN finance.account_balances bal ON bal.account_id = l.loan_account_id WHERE l.name = ((`$1::jsonb)->>'loan_name') ORDER BY l.id LIMIT 1;" `
        ([ordered]@{ loan_name = '$(''Start'').item.json.loan_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readLoan -KeyField 'loan_status' -IfName 'Loan found?' -ErrName 'Loan not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No loan named '{{ `$('Start').item.json.loan_name }}' exists. List them via postgres_select on finance.loan_overview and ask the user which one is meant."

    # "DB ist das Gesetz": fn_delete_loan laeuft als Probelauf VOR der Karte (gebuchte Raten -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_delete_loan' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Delete loan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'loan_id')::int AS loan_id, (r->>'loan_account_id')::int AS loan_account_id" `
        -Params ([ordered]@{ loan_name = '$(''Start'').item.json.loan_name' })

    # Strukturiertes Summary (Textkatalog): Betraege in EUR-Konvention (vorher hart " €" an der Rohzahl).
    $S = "`$('Start').item.json"
    $L = "`$('Read Loan').item.json"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.delete_loan' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.loan'                   "$S.loan_name")
        (New-HitlLine 'finance.label.lender'                 "$L.lender")
        (New-HitlLine 'core.label.status'                    "$L.loan_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlLine 'finance.label.loan_amount_original'   "$L.original_amount" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.remaining_debt_current' "$L.remaining_debt" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.booked_instalments'     "$L.repayment_count")
        (New-HitlNote -KeyExpr "($L.repayment_count > 0 ? 'finance.note.delete_loan_rejected' : 'finance.note.delete_loan_hard')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the delete_loan action'

    # Atomarer Write ($wg.Write, 'Delete loan (atomic)'): prueft erneut, falls sich seit dem Probelauf etwas geaendert hat.
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Delete rejected' @(2200, 240) `
        "={{ `$('Delete loan (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete loan (atomic)').item.json.action }}", 'string')
        ,@('loan_id', "={{ `$('Delete loan (atomic)').item.json.loan_id }}", 'number')
        ,@('loan_account_id', "={{ `$('Delete loan (atomic)').item.json.loan_account_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_delete_loan mit denselben Werten, immer zurückgerollt. ok:false (Kredit hat gebuchte Raten) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (mehrdeutig; nicht gefunden fängt vorher das Found?-Gate als Tool-Fehler) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_delete_loan: Hard-DELETE-if-no-repayments' @(1760, -300) `
        'Inverse von create_loan; nur Fehlanlagen' `
        'fn_delete_loan zählt gebuchte Raten (category loan_payment/principal/settlement). >0: {ok:false, reason} OHNE Write -> Delete rejected (settle_loan/set_loan nutzen). =0: löscht (Inverse von create_loan) alle Tx mit loan_id (Eröffnung + ggf. Auszahlung; Trigger rechnen Giro-/Loan-Saldo neu), Loan-Stammdaten, Rate-rp, balance-Zeile + das dedizierte Loan-Konto. Debit-/Disbursement-Konto bleiben. RAISE bei nicht gefunden/mehrdeutig (nicht gefunden fängt vorher das Found?-Gate des Tools) (Resolver p_active_only=FALSE -> findet auch paused).' 260 520

    $nodes = @($trig, $readLoan, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Loan' ) ) }
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
            @( E 'Delete loan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete loan (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_delete_loan' $nodes $conns `
        @{ Category = 'loans' }
}
