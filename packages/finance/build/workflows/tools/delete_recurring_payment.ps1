#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_delete_recurring_payment (standalone Dauerauftrag loeschen: Hard-DELETE) ---
function Build-DeleteRecurringPayment {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('recurring_payment_name','confirm_feeds_savings')

    $readRp = Build-Pg 'Read Recurring' @(220, 0) `
        "=SELECT rp.amount, (SELECT a.currency FROM finance.accounts a WHERE a.id = rp.account_id) AS currency, rp.status::text AS rp_status, (SELECT COUNT(*)::int FROM finance.transactions t WHERE t.recurring_payment_id = rp.id) AS tx_count, (EXISTS (SELECT 1 FROM finance.insurances WHERE recurring_payment_id=rp.id) OR EXISTS (SELECT 1 FROM finance.loans WHERE recurring_payment_id=rp.id) OR EXISTS (SELECT 1 FROM finance.pension WHERE recurring_payment_id=rp.id) OR EXISTS (SELECT 1 FROM finance.savings_goals WHERE recurring_payment_id=rp.id) OR EXISTS (SELECT 1 FROM finance.savings_plans WHERE recurring_payment_id=rp.id)) AS owned FROM finance.recurring_payments rp WHERE rp.name = ((`$1::jsonb)->>'recurring_payment_name') AND NOT EXISTS (SELECT 1 FROM finance.recurring_payments s WHERE s.predecessor_id = rp.id) ORDER BY rp.id LIMIT 1;" `
        ([ordered]@{ recurring_payment_name = '$(''Start'').item.json.recurring_payment_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readRp -KeyField 'rp_status' -IfName 'Recurring Payment found?' -ErrName 'Recurring Payment not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No recurring payment named '{{ `$('Start').item.json.recurring_payment_name }}' exists. List them via postgres_select on finance.active_recurring_payments and ask the user which one is meant."

    # Strukturiertes Summary (Textkatalog): Betrag in der Konto-Waehrung (Read Recurring liest accounts.currency mit).
    # "DB ist das Gesetz": fn_delete_recurring_payment laeuft als Probelauf VOR der Karte (Entitaets-besessen / gebuchte
    # Transaktionen / Zubringer eines Sparplans oder Sparziels ohne confirm_feeds_savings -> {ok:false, code:'feeds_savings'}
    # ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_delete_recurring_payment' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Delete recurring (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'recurring_payment_id')::int AS recurring_payment_id" `
        -Params ([ordered]@{
            recurring_payment_name = '$(''Start'').item.json.recurring_payment_name'
            confirm_feeds_savings  = '$(''Start'').item.json.confirm_feeds_savings'
        })

    $S = "`$('Start').item.json"
    $R = "`$('Read Recurring').item.json"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.delete_recurring_payment' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.designation'        "$S.recurring_payment_name")
        (New-HitlLine 'core.label.amount'                "$R.amount" -Kind money -Currency "$R.currency")
        (New-HitlLine 'core.label.status'                "$R.rp_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlLine 'finance.label.booked_occurrences' "$R.tx_count")
        (New-HitlNote -KeyExpr "($R.owned ? 'finance.note.delete_rp_owned' : ($R.tx_count > 0 ? 'finance.note.delete_rp_booked' : 'finance.note.delete_rp_hard'))")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the delete_recurring_payment action'

    # Atomarer Write ($wg.Write, 'Delete recurring (atomic)'): prueft erneut, falls sich seit dem Probelauf etwas geaendert hat.
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Delete rejected' @(2200, 240) `
        "={{ `$('Delete recurring (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete recurring (atomic)').item.json.action }}", 'string')
        ,@('recurring_payment_id', "={{ `$('Delete recurring (atomic)').item.json.recurring_payment_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_delete_recurring_payment mit denselben Werten, immer zurückgerollt. ok:false (Dauerauftrag gehört einer Entität, hat gebuchte Transaktionen oder füllt als Zubringer das Verrechnungskonto eines Sparplans bzw. den Topf eines Sparziels ohne confirm_feeds_savings=true -> code feeds_savings) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (mehrdeutig; nicht gefunden fängt vorher das Found?-Gate als Tool-Fehler) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_delete_recurring_payment: nur standalone' @(1760, -300) `
        'Hard-DELETE nur für standalone, referenzfrei' `
        'fn_delete_recurring_payment löscht NUR standalone Dauerauftraege. Entitäts-besessen (Versicherung/Kredit/Pension/Sparziel/Sparplan referenziert die rp) -> {ok:false, owner} -> set_/close_-Tool der Entität. Gebuchte Transaktionen (recurring_payment_id) -> {ok:false} (erst voiden). Zubringer (Transfer ins Verrechnungskonto eines aktiven Sparplans oder in den Topf eines aktiven Sparziels) -> {ok:false, code:''feeds_savings''}, nur mit confirm_feeds_savings=true (Nutzer bestätigt, dass es ihn nicht mehr gibt) gelöscht. Sonst: DELETE recurring_payment (skips per ON DELETE CASCADE). RAISE bei nicht gefunden/mehrdeutig (nicht gefunden fängt vorher das Found?-Gate des Tools) (Resolver p_active_only=FALSE -> findet auch pausierte).' 260 520

    $nodes = @($trig, $readRp, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Recurring' ) ) }
        'Read Recurring'         = @{ main = @( ,@( E 'Recurring Payment found?' ) ) }
        'Recurring Payment found?'= @{ main = @(
            @( E 'Dry run' ),
            @( E 'Recurring Payment not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Delete recurring (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete recurring (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_delete_recurring_payment' $nodes $conns `
        @{ Category = 'recurring' }
}
