#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_delete_account (Konto loeschen: Hard-DELETE einer leeren Fehlanlage) ---
function Build-DeleteAccount {
    # Enge Paket-Schreibrolle (finance_rw) statt Owner-Cred; Build-Pg liest $CRED_POSTGRES per Dynamic-Scope.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('account_name')

    $readAcc = Build-Pg 'Read Account' @(220, 0) `
        "=SELECT a.account_type::text AS account_type, a.bank, a.currency, a.status::text AS acc_status, COALESCE(bal.balance,0) AS balance FROM finance.accounts a LEFT JOIN finance.account_balances bal ON bal.account_id=a.id WHERE a.name ILIKE ((`$1::jsonb)->>'account_name') LIMIT 1;" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate).
    $found = New-RequiredRowGate -Read $readAcc -KeyField 'acc_status' -IfName 'Account found?' -ErrName 'Account not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No account named '{{ `$('Start').item.json.account_name }}' exists. List them via postgres_select on finance.account_overview and ask the user which one is meant."

    $wg = New-FnWriteGate -Fn 'finance.fn_delete_account' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Delete account (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'account_id')::int AS account_id" `
        -Params ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    # Saldo in der Konto-Waehrung (Read Account). Die Karte erscheint nur nach bestandenem Probelauf, also ohne jede Referenz:
    # der Hinweis ist fest, ein eigener Referenz-Zaehler im Workflow waere eine zweite Adresse neben fn_delete_account.
    $S = "`$('Start').item.json"
    $A = "`$('Read Account').item.json"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.delete_account' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account' "$S.account_name")
        (New-HitlLine 'core.label.type'       "$A.account_type" -Kind enum -Enum 'finance.enum.account_type')
        (New-HitlLine 'finance.label.bank'    "$A.bank")
        (New-HitlLine 'finance.label.balance' "$A.balance" -Kind money -Currency "$A.currency")
        (New-HitlLine 'core.label.status'     "$A.acc_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlNote -Key 'finance.note.delete_account_hard')
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the delete_account action'

    # Der Write prueft erneut, falls sich seit dem Probelauf etwas geaendert hat.
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Delete rejected' @(2200, 240) `
        "={{ `$('Delete account (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete account (atomic)').item.json.action }}", 'string')
        ,@('account_id', "={{ `$('Delete account (atomic)').item.json.account_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_delete_account mit denselben Werten, immer zurückgerollt. ok:false (Konto hat noch Referenzen: Transaktionen, Holdings, Daueraufträge, Kredite ...) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Mehrdeutig kommt ebenfalls als ok:false (code ambiguous, Kandidaten); nicht gefunden fängt vorher das Found?-Gate als Tool-Fehler. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_delete_account: Hard-DELETE-if-empty' @(1760, -300) `
        'Löschen nur ohne jede Referenz' `
        'fn_delete_account prüft alle FK-Referenzen (Transaktionen, Depot-Holdings, abbuchende recurring_payments und Ziele eines Dauer-Übertrags, Sparziel-Reserve-Journal, Sparpläne, Kredite (loan/debit/disbursement), Verrechnungskonto-Nutzung). Beliebige Referenz: {ok:false, reason, ...count} OHNE Write -> Delete rejected (für aktive Konten close_account nutzen). Sonst: DELETE interest_rates (CASCADE) + balance-Zeile (KEIN CASCADE -> explizit) + Konto; action=deleted. Nicht gefunden/mehrdeutig: {ok:false, code} (nicht gefunden fängt vorher das Found?-Gate des Tools).' 260 520

    $nodes = @($trig, $readAcc, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Account' ) ) }
        'Read Account'           = @{ main = @( ,@( E 'Account found?' ) ) }
        'Account found?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Account not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Delete account (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete account (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_delete_account' $nodes $conns `
        @{ Category = 'accounts' }
}
