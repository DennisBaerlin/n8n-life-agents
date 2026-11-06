#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_book_recurring_occurrence (WS-5c-A: faelliges Dauerauftrag-Vorkommen mit ANGEPASSTEM Betrag buchen) ---
# Normalerweise hakt der Monats-Check (tool_reconcile_bank_statement) die Vorkommen ab. Dieses Tool ist der
# Anpass-Pfad (A2, arch-challenge): zum Abweichen lehnt der Nutzer den Cron-Reminder ab und nennt dem Agenten
# den Ist-Betrag -> dieses Tool bucht ihn. Resolve (Name) + Faelligkeit (fn_recurring_due_open) in n8n,
# Buchung via fn_book_recurring_occurrence(amount-Override).
function Build-BookRecurringOccurrence {
    # Enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('recurring_payment_name', 'actual_amount')

    # Aktive Zahlung aufloesen (nur status='active' = die laufende Zeile).
    $resRp = Build-Pg 'Resolve Payment' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_recurring_payment((`$1::jsonb)->>'recurring_payment_name', TRUE);" `
        ([ordered]@{ recurring_payment_name = '$(''Start'').item.json.recurring_payment_name' })

    $ifRp = Build-If 'Payment unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errRp = Build-ToolError 'Payment ambiguous' @(660, 220) `
        "=Recurring payment '{{ `$('Start').item.json.recurring_payment_name }}' resolves to {{ `$('Resolve Payment').item.json.hit_count }} active matches. Candidates: {{ JSON.stringify(`$('Resolve Payment').item.json.candidates) }}. Ask the user which exact payment."

    # Offenes Vorkommen + Plan-Felder fuer die Summary (frueheste offene Faelligkeit).
    $findOcc = Build-Pg 'Find occurrence' @(660, 0) `
        "=SELECT o.due_date::text AS due_date, rp.amount AS plan_amount, rp.name, a.name AS account_name, a.currency AS currency FROM finance.fn_recurring_due_open(CURRENT_DATE) o JOIN finance.recurring_payments rp ON rp.id = o.recurring_payment_id JOIN finance.accounts a ON a.id = rp.account_id WHERE o.recurring_payment_id = ((`$1::jsonb)->>'id')::int ORDER BY o.due_date LIMIT 1;" `
        ([ordered]@{ id = '$(''Resolve Payment'').item.json.id' })

    $ifOcc = Build-If 'Occurrence open?' @(880, 0) "={{ !!`$json.due_date }}" 'true' 'equals' 'boolean'

    $errOcc = Build-ToolError 'No open occurrence' @(1100, 220) `
        "=No open due occurrence for '{{ `$('Start').item.json.recurring_payment_name }}'. Either already booked for this period or not yet due (90-day window)."

    # "DB ist das Gesetz": fn_book_recurring_occurrence laeuft als Probelauf VOR der Karte (amount<=0,
    # Transfer-Anpassung, bereits gebucht -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den
    # echten Write (amount-Override: sign(rp.amount)*abs(amount)).
    $wg = New-FnWriteGate -Fn 'finance.fn_book_recurring_occurrence' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Book occurrence (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'transaction_id')::int AS transaction_id, (r->>'amount')::numeric AS amount, (r->>'plan_amount')::numeric AS plan_amount" `
        -Params ([ordered]@{
            recurring_payment_id = '$(''Resolve Payment'').item.json.id'
            due_date             = '$(''Find occurrence'').item.json.due_date'
            amount               = '$(''Start'').item.json.actual_amount'
        })

    # HITL-Summary (Textkatalog): Soll vs. Ist + Abweichungs-Warnung (>5 %). plan_amount ist vorzeichenbehaftet -> abs().
    # Betraege in der Konto-Waehrung (Find occurrence).
    $S = "`$('Start').item.json"
    $O = "`$('Find occurrence').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.book_recurring_occurrence' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.item'          "$O.name")
        (New-HitlLine 'finance.label.account'       "$O.account_name")
        (New-HitlLine 'finance.label.due_on'        "$O.due_date" -Kind date)
        (New-HitlLine 'finance.label.planned'       "Math.abs($O.plan_amount)" -Kind money -Currency "$O.currency")
        (New-HitlLine 'finance.label.actual_book'   "Math.abs($S.actual_amount)" -Kind money -Currency "$O.currency")
        (New-HitlNote -Key 'finance.note.deviation_planned' -If "(Math.abs(Math.abs($S.actual_amount) - Math.abs($O.plan_amount)) / Math.abs($O.plan_amount)) > 0.05")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 240) 'the book_recurring_occurrence action'

    # Atomarer Write via fn_book_recurring_occurrence mit amount-Override ($wg.Write, Params siehe oben).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Booking rejected' @(2860, 240) `
        "={{ `$('Book occurrence (atomic)').item.json.reason }}"

    $ret = Build-Return @(2860, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('transaction_id', "={{ `$('Book occurrence (atomic)').item.json.transaction_id }}", 'number')
        ,@('amount', "={{ `$('Book occurrence (atomic)').item.json.amount }}", 'number')
        ,@('plan_amount', "={{ `$('Book occurrence (atomic)').item.json.plan_amount }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_recurring_occurrence mit denselben Werten, immer zurückgerollt. ok:false (amount<=0, Transfer-Anpassung, Vorkommen bereits gebucht) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 260 460

    $stickyOv = Build-Sticky 'Doc book_recurring_occurrence' @(2420, -260) `
        'fn_book_recurring_occurrence: amount-Override + Auto-Verschwinden' `
        'Bucht das offene Vorkommen mit dem ANGEPASSTEN Ist-Betrag (sign(rp.amount)*abs(amount) -> Richtung Einnahme/Ausgabe bleibt, Abweichung in der description). Saldo via Trigger. Die Tx trägt recurring_payment_id+due_date -> das Vorkommen verschwindet beim nächsten Cron-Lauf automatisch aus fn_recurring_due_open. Transfers (target_account_id) lehnt die fn beim Override ab ({ok:false}); amount<=0 -> {ok:false}.' 260 520

    $stickyOk = Build-Sticky 'Doc Write ok? (korrigierbare Ablehnung)' @(2860, -260) `
        'fn-Rückgabe {ok:false, reason}' `
        'amount<=0, Transfer-Anpassung oder bereits gebucht -> {ok:false, reason} (kein RAISE, kein Owner-Alert) -> Build-ToolError -> freundliche Rückfrage. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 220 420

    $nodes = @($trig, $resRp, $ifRp, $errRp, $findOcc, $ifOcc, $errOcc) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv, $stickyOk)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Payment' ) ) }
        'Resolve Payment'        = @{ main = @( ,@( E 'Payment unique?' ) ) }
        'Payment unique?'        = @{ main = @(
            @( E 'Find occurrence' ),
            @( E 'Payment ambiguous' )
        ) }
        'Find occurrence'        = @{ main = @( ,@( E 'Occurrence open?' ) ) }
        'Occurrence open?'       = @{ main = @(
            @( E 'Dry run' ),
            @( E 'No open occurrence' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Book occurrence (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book occurrence (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Booking rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_book_recurring_occurrence' $nodes $conns `
        @{ Category = 'recurring' }
}
