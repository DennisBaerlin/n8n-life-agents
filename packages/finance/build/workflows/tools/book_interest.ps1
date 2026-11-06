#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_book_interest (WS-5c-B: faellige Zinsgutschrift buchen, berechnet ODER angepasst) ---
# Der Stichtags-Cron (cron_remind_interest) bucht den von der DB BERECHNETEN Zins per Approve. Dieses Tool
# ist der Chat-Pfad: zum Anpassen (oder manuell) nennt der Nutzer das Konto + optional den Ist-Betrag.
# Resolve (Konto) + offene Faelligkeit (fn_interest_due_open) + Vorschlag (fn_interest_amount_due) in n8n,
# Buchung via fn_book_interest_occurrence (amount fehlt -> DB-berechnet; gesetzt -> Override).
function Build-BookInterest {
    # Enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    # actual_amount OPTIONAL (Default '' -> DB berechnet den Zins selbst).
    $trig = Build-Trigger @('account_name', 'actual_amount')

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', NULL, TRUE);" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 220) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} active matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # Offene Zins-Faelligkeit (frueheste offene per period_end) + value_date (Gutschrift-Datum, bei Arrears im
    # Folgemonat) + DB-berechneter Vorschlag (basis x Satz x day-count-Anteil zum period_end).
    $findOcc = Build-Pg 'Find occurrence' @(660, 0) `
        "=SELECT o.value_date::text AS value_date, o.period_end::text AS period_end, a.name AS account_name, a.currency AS currency, finance.fn_interest_amount_due(o.account_id, o.period_end) AS computed FROM finance.fn_interest_due_open(CURRENT_DATE) o JOIN finance.accounts a ON a.id = o.account_id WHERE o.account_id = ((`$1::jsonb)->>'id')::int ORDER BY o.period_end LIMIT 1;" `
        ([ordered]@{ id = '$(''Resolve Account'').item.json.id' })

    $ifOcc = Build-If 'Occurrence open?' @(880, 0) "={{ !!`$json.period_end }}" 'true' 'equals' 'boolean'

    $errOcc = Build-ToolError 'No open occurrence' @(1100, 220) `
        "=No open interest occurrence for '{{ `$('Start').item.json.account_name }}'. Either already credited for this period or not yet due (90-day window)."

    # "DB ist das Gesetz": fn_book_interest_occurrence laeuft als Probelauf VOR der Karte (amount<=0, auch ein
    # berechneter 0-Vorschlag, bereits gebucht -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate
    # in den echten Write. transaction_date=value_date (Gutschrift-Datum), interest_period_end=period_end
    # (Idempotenz-/booked-Key); amount leer -> DB-berechnet, gesetzt -> Override.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_interest_occurrence' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Book interest (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'transaction_id')::int AS transaction_id, (r->>'amount')::numeric AS amount, (r->>'account_balance')::numeric AS account_balance" `
        -Params ([ordered]@{
            account_id = '$(''Resolve Account'').item.json.id'
            value_date = '$(''Find occurrence'').item.json.value_date'
            period_end = '$(''Find occurrence'').item.json.period_end'
            amount     = '$(''Start'').item.json.actual_amount'
        })

    # HITL-Summary (Textkatalog): Gutschrift-Datum (value_date) + abgedeckte Periode (period_end) + berechneter
    # Vorschlag + tatsaechlich gebuchter Betrag (Override falls genannt, sonst Vorschlag); Waehrung = Konto-Waehrung.
    $S = "`$('Start').item.json"
    $O = "`$('Find occurrence').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.book_interest' -TitleParams @{ account = "$O.account_name" } -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.credit_date'        "$O.value_date" -Kind date)
        (New-HitlLine 'finance.label.period_end'         "$O.period_end" -Kind date)
        (New-HitlLine 'finance.label.suggested_computed' "$O.computed" -Kind money -Currency "$O.currency")
        (New-HitlLine 'finance.label.book_amount'        "($S.actual_amount ? $S.actual_amount : $O.computed)" -Kind money -Currency "$O.currency")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 240) 'the book_interest action'

    # Atomarer Write via fn_book_interest_occurrence ($wg.Write, Params siehe oben).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Interest rejected' @(2860, 240) `
        "={{ `$('Book interest (atomic)').item.json.reason }}"

    $ret = Build-Return @(2860, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('transaction_id', "={{ `$('Book interest (atomic)').item.json.transaction_id }}", 'number')
        ,@('amount', "={{ `$('Book interest (atomic)').item.json.amount }}", 'number')
        ,@('account_balance', "={{ `$('Book interest (atomic)').item.json.account_balance }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_interest_occurrence mit denselben Werten, immer zurückgerollt. ok:false (amount<=0, auch ein berechneter 0-Vorschlag bei Nullsaldo; Periode bereits gebucht) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 260 460

    $stickyOv = Build-Sticky 'Doc book_interest' @(2420, -260) `
        'fn_book_interest_occurrence: DB-berechnet ODER Override' `
        'Bucht die Zinsgutschrift (category=interest): transaction_date=value_date (Gutschrift-Datum, bei Arrears im Folgemonat), interest_period_end=period_end (abgedeckte Vorperiode). Ohne actual_amount rechnet die DB (basis zum period_end x am period_end gültiger Satz x day-count-Anteil — NIE das LLM); mit actual_amount = Nutzer-Override. Saldo via Trigger. Idempotenz je (Konto, period_end); amount<=0 -> {ok:false}.' 260 560

    $stickyOk = Build-Sticky 'Doc Write ok? (korrigierbare Ablehnung)' @(2860, -260) `
        'fn-Rückgabe {ok:false, reason}' `
        'amount<=0 (auch berechneter 0-Vorschlag bei Nullsaldo) oder bereits gebucht -> {ok:false, reason} (kein RAISE) -> Build-ToolError -> freundliche Rückfrage. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 220 420

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct, $findOcc, $ifOcc, $errOcc) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv, $stickyOk)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'        = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'        = @{ main = @(
            @( E 'Find occurrence' ),
            @( E 'Account ambiguous' )
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
            @( E 'Book interest (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book interest (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Interest rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_book_interest' $nodes $conns `
        @{ Category = 'bookings' }
}
