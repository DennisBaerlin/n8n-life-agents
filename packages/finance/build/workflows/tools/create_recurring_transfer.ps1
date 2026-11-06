#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_create_recurring_transfer (WS-2 Multi-Member) ---------------
# Interner wiederkehrender Transfer zwischen ZWEI eigenen Konten (z. B. Dauerauftrag 200 EUR/Monat
# Owner-Konto -> Kind-Depot-Cash). Markiert per target_account_id -> strukturell cashflow-neutral
# (zaehlt NICHT als Haushalts-Ausgabe/Sparquote). KEIN harter Namens-Dedup (gleichnamige Transfers
# legitim). Zwei Konto-Resolves (Quelle/Ziel) wie book_transfer, Schedule-Felder wie create_recurring_payment.
function Build-CreateRecurringTransfer {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('name','from_account_name','to_account_name','amount','schedule_interval',
                           'schedule_unit','schedule_day_of_month','first_payment_date','valid_from','valid_to','notes',
                           'until_free_money','executed_by')

    $resFrom = Build-Pg 'Resolve From' @(220, 0) `
        "=SELECT id, hit_count, candidates, currency FROM finance.fn_resolve_account((`$1::jsonb)->>'from_account_name');" `
        ([ordered]@{ from_account_name = '$(''Start'').item.json.from_account_name' })

    $ifFrom = Build-If 'From unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errFrom = Build-ToolError 'From ambiguous' @(660, 200) `
        "=Source account '{{ `$('Start').item.json.from_account_name }}' resolves to {{ `$('Resolve From').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve From').item.json.candidates) }}. Ask the user which exact account."

    $resTo = Build-Pg 'Resolve To' @(660, 0) `
        "=SELECT id, hit_count, candidates, currency FROM finance.fn_resolve_account((`$1::jsonb)->>'to_account_name');" `
        ([ordered]@{ to_account_name = '$(''Start'').item.json.to_account_name' })

    $ifTo = Build-If 'To unique?' @(880, 0) "={{ `$json.hit_count }}" '1'

    $errTo = Build-ToolError 'To ambiguous' @(1100, 200) `
        "=Target account '{{ `$('Start').item.json.to_account_name }}' resolves to {{ `$('Resolve To').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve To').item.json.candidates) }}. Ask the user which exact account."

    # "DB ist das Gesetz": fn_create_recurring_transfer laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_recurring_transfer' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Create recurring transfer (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'recurring_payment_id')::int AS recurring_payment_id, (r->>'monthly_equivalent')::numeric AS monthly_equivalent, COALESCE(r->'savings_funding'->>'note', '') AS savings_funding" `
        -Params ([ordered]@{
            name                  = '$(''Start'').item.json.name'
            from_account_id       = '$(''Resolve From'').item.json.id'
            to_account_id         = '$(''Resolve To'').item.json.id'
            amount                = '$(''Start'').item.json.amount'
            schedule_interval     = '$(''Start'').item.json.schedule_interval'
            schedule_unit         = '$(''Start'').item.json.schedule_unit'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            first_payment_date    = '$(''Start'').item.json.first_payment_date'
            valid_from            = '$(''Start'').item.json.valid_from'
            valid_to              = '$(''Start'').item.json.valid_to'
            notes                 = '$(''Start'').item.json.notes'
            until_free_money      = '$(''Start'').item.json.until_free_money'
            executed_by           = '$(''Start'').item.json.executed_by'
        })

    # --- HITL approval gate (before the atomic write) ---
    # Strukturiertes Summary (Textkatalog): Rate in der Waehrung des Quellkontos (Resolve From liest accounts.currency mit).
    # until_free_money: das Ende setzt die DB (Probelauf: effective.last_execution / free_after) statt „unbegrenzt".
    $S = "`$('Start').item.json"
    $free = "(!!" + (Get-DryEffectiveExpr 'last_execution') + ")"   # aus dem Probelauf, nie aus der LLM-Eingabe: Karte = Write
    # Ausfuehrung (bank|manual|unknown) aus dem Probelauf (fn_transfer_executed_by, EIGENES Feld r.execution, nicht unter effective:
    # das Gate mischt effective in den echten Write): waehlt den Schlusssatz; nie aus der LLM-Eingabe geraten.
    $exec = "`$('Dry run').item.json.r.execution"
    $lastDate = New-HitlValue -Kind date -Value (Get-DryEffectiveExpr 'last_execution')
    $dom = Get-FinanceDomTpl "$S.schedule_day_of_month" -Empty "'finance.value.relative_to_start'"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.create_recurring_transfer' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.name'            "$S.name")
        (New-HitlLine 'finance.label.from'         "$S.from_account_name")
        (New-HitlLine 'finance.label.to'           "$S.to_account_name")
        (New-HitlLine 'core.label.amount'          "$S.amount" -Kind money -Currency "`$('Resolve From').item.json.currency")
        (New-HitlLine 'finance.label.cycle'        "'finance.tpl.every_unit'" -Kind tpl -Params @{
            interval = "($S.schedule_interval || '1')"
            unit     = (New-HitlValue -Kind enum -Value "$S.schedule_unit" -Enum 'finance.enum.schedule_unit') })
        (New-HitlLine 'finance.label.debit_day'    $dom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" })
        (New-HitlLine 'finance.label.first_transfer' (Get-DryEffectiveExpr 'first_payment_date') -Kind date)
        (New-HitlLine 'finance.label.valid_from'   ("(" + (Get-DryEffectiveExpr 'valid_from') + " || " + (Get-DryEffectiveExpr 'first_payment_date') + ")") -Kind date -IsDefault "!$S.valid_from")
        (New-HitlLine 'finance.label.valid_to'     "($S.valid_to ? 'finance.tpl.plain' : 'finance.value.unlimited')" -Kind tpl -If "!$free" -Params @{
            value = (New-HitlValue -Kind date -Value (Get-DryEffectiveExpr 'valid_to')) })
        (New-HitlLine 'finance.label.last_transfer' (Get-DryEffectiveExpr 'last_execution') -Kind date -If $free)
        (New-HitlLine 'core.label.note'            "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'finance.note.until_free_money' -If $free -Params @{
            account = "$S.from_account_name"
            free    = (New-HitlValue -Kind money -Value "`$('Dry run').item.json.r.effective.free_after" -Currency "`$('Resolve From').item.json.currency") })   # 0 ist ein Wert: ohne || aus Get-DryEffectiveExpr
        # Schlusssatz je Ausfuehrung (genau einer): Bank-Dauerauftrag / ueberweist selbst / nicht bekannt (Geld-Konto ohne Angabe)
        (New-HitlNote -Key 'finance.note.until_free_money_bank'   -If "$free && $exec === 'bank'"   -Params @{ date = $lastDate })
        (New-HitlNote -Key 'finance.note.until_free_money_manual' -If "$free && $exec === 'manual'" -Params @{ date = $lastDate })
        (New-HitlNote -Key 'finance.note.until_free_money_unsure' -If "$free && $exec !== 'bank' && $exec !== 'manual'" -Params @{ date = $lastDate })
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 240) 'the create_recurring_transfer action'

    # Atomarer Write via fn_create_recurring_transfer: INSERT via Helper + target via Folge-UPDATE
    # (eine Transaktion). amount Quell-seitig negativ; No-Self-Transfer-CHECK ist der Backstop.
    # fn liefert ok/reason: amount<=0 / Quelle==Ziel -> {ok:false}.

    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Recurring transfer rejected' @(2860, 240) `
        "={{ `$('Create recurring transfer (atomic)').item.json.reason }}"

    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('recurring_payment_id', "={{ `$('Create recurring transfer (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('monthly_equivalent', "={{ `$('Create recurring transfer (atomic)').item.json.monthly_equivalent }}", 'number')
        ,@('savings_funding', "={{ `$('Create recurring transfer (atomic)').item.json.savings_funding }}", 'string')
    )

    $stickyFlow = Build-Sticky 'DB-Automatik + Buchung' @(2420, -260) `
        'fn_create_recurring_transfer + Recurring-Scheduler' `
        'fn_create_recurring_transfer legt EINE recurring_payments-Zeile an (INSERT via gemeinsamen Helper fn_add_recurring_payment, amount Quell-seitig NEGATIV) und setzt target_account_id per Folge-UPDATE (eine Transaktion, atomar). monthly_equivalent ist GENERATED. target_account_id != NULL markiert den Transfer -> monthly_cashflow_overview filtert ihn raus (cashflow-neutral, kein Doppelzählen). Gebucht wird je Fälligkeit ZWEI-beinig (Soll -/Haben +) über den bestehenden Recurring-Scheduler: fn_book_recurring_occurrence delegiert für Transfer-rps an fn_book_recurring_transfer. Nach dem Write liest fn_savings_funding_fold die Spar-Deckung von Quelle UND Ziel (fn_account_funding, nur Konten mit Sparplan oder als Dauerauftrags-Ziel): je Konto eine Kartenzeile "Danach ..." schon im Probelauf + Bericht-Note savings_funding (gedeckt / es fehlen noch X), ohne Frage. Bookkeeper relayed.' 220 560

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -260) `
        'fn-Rückgabe {ok:false, reason}' `
        'amount<=0, Quelle==Ziel, ein ungültiger executed_by (nur bank oder manual), until_free_money zusammen mit valid_to oder eine Ablehnung von fn_transfer_free_end (not_running, funding_unknown, source_short, no_free_money, free_money_beyond_horizon; Savepoint rollt den Insert zurück) liefert die fn als {ok:false, reason} -> Recurring transfer rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Der No-Self-Transfer-CHECK ist der strukturelle Backstop.' 220 380

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_recurring_transfer mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (amount kleiner/gleich 0, Quelle gleich Ziel, Ablehnungen von until_free_money) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. until_free_money: fn_transfer_free_end setzt das Ende auf den letzten Termin, bevor Ziel-Geld der Quelle angefasst wird (Rechnung = fn_account_funding mit dieser Zahlung); die Karte zeigt effective.last_execution + free_after aus diesem Probelauf statt der Zeile Gültig bis. Den Schlusssatz darunter wählt r.execution (fn_transfer_executed_by: gespeicherte Nutzerangabe, sonst Kontoart der Quelle): bank = beim Bank-Dauerauftrag das Enddatum eintragen, manual = nach dem Datum nicht mehr überweisen, unknown = vorsichtig (falls ein Dauerauftrag besteht). execution steht bewusst NICHT unter effective, weil das Gate effective in den echten Write mischt. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $resFrom, $ifFrom, $errFrom, $resTo, $ifTo, $errTo) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyFlow, $stickyOk,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Resolve From' ) ) }
        'Resolve From'             = @{ main = @( ,@( E 'From unique?' ) ) }
        'From unique?'             = @{ main = @(
            @( E 'Resolve To' ),
            @( E 'From ambiguous' )
        ) }
        'Resolve To'               = @{ main = @( ,@( E 'To unique?' ) ) }
        'To unique?'               = @{ main = @(
            @( E 'Dry run' ),
            @( E 'To ambiguous' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Create recurring transfer (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create recurring transfer (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Recurring transfer rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_recurring_transfer' $nodes $conns `
        @{ Category = 'recurring' }
}
