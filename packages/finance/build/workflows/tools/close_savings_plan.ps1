#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_close_savings_plan (Sparplan schliessen: Hard-DELETE ohne Buchungen, Soft-Close mit Buchungen) ---
function Build-CloseSavingsPlan {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('savings_plan_name')

    # Plan-Details + Buchungsanzahl fuer dynamischen HITL-Summary
    $readPlan = Build-Pg 'Read Plan' @(220, 0) `
        "=SELECT sp.symbol, sp.security_name, sp.status::text AS plan_status, ABS(rp.amount) AS plan_amount, (SELECT a.currency FROM finance.accounts a WHERE a.id = rp.account_id) AS currency, (SELECT COUNT(*)::int FROM finance.transactions t WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(sp.recurring_payment_id))) AS tx_count FROM finance.savings_plans sp JOIN finance.recurring_payments rp ON rp.id = sp.recurring_payment_id WHERE sp.name ILIKE ((`$1::jsonb)->>'savings_plan_name') LIMIT 1;" `
        ([ordered]@{ savings_plan_name = '$(''Start'').item.json.savings_plan_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readPlan -KeyField 'plan_status' -IfName 'Savings Plan found?' -ErrName 'Savings Plan not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No savings plan named '{{ `$('Start').item.json.savings_plan_name }}' exists. List them via postgres_select on finance.savings_plans and ask the user which one is meant."

    # "DB ist das Gesetz": fn_close_savings_plan laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_close_savings_plan' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Close plan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'tx_count')::int AS tx_count" `
        -Params ([ordered]@{ savings_plan_name = '$(''Start'').item.json.savings_plan_name' })

    # Strukturiertes Summary (Textkatalog): tx_count=0 -> Hard-DELETE-Warnung; tx_count>0 -> Soft-Close-Info.
    # Sparrate in der Waehrung des Verrechnungskontos (Read Plan liest accounts.currency mit). Keine Datumsfelder.
    $S = "`$('Start').item.json"
    $P = "`$('Read Plan').item.json"
    $titleVal = New-HitlValue -Kind key -Value "($P.tx_count > 0 ? 'finance.hitl.close_savings_plan_close' : 'finance.hitl.close_savings_plan_delete')"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.close_savings_plan' -LinesExpr $wg.CardLinesExpr -TitleParams @{ title = $titleVal } -Lines @(
        (New-HitlLine 'finance.label.plan'              "$S.savings_plan_name")
        (New-HitlLine 'finance.label.security'          "($P.security_name ? 'finance.tpl.symbol_name' : 'finance.tpl.plain')" -Kind tpl -Params @{ symbol = "$P.symbol"; name = "$P.security_name"; value = "$P.symbol" })
        (New-HitlLine 'finance.label.monthly_amount'    "$P.plan_amount" -Kind money -Currency "$P.currency")
        (New-HitlLine 'core.label.status'               "$P.plan_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlLine 'finance.label.booked_executions' "$P.tx_count")
        (New-HitlNote -KeyExpr "($P.tx_count > 0 ? 'finance.note.close_plan_soft' : 'finance.note.close_plan_hard')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the close_savings_plan action'

    # Atomarer Write via fn_close_savings_plan:
    # - tx_count=0: Hard-DELETE (finance.savings_plans zuerst, dann finance.recurring_payments; FK-Reihenfolge)
    # - tx_count>0: Soft-Close (alle laufenden Ketten-rps valid_to=CURRENT_DATE + status=paused; plan.status=paused)
    # RAISE EXCEPTION wenn Plan nicht gefunden (kein {ok:false} -- nach Approval nicht mehr nutzerkorrigierbar)

    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Close rejected' @(2200, 240) `
        "={{ `$('Close plan (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Close plan (atomic)').item.json.action }}", 'string')
        ,@('tx_count', "={{ `$('Close plan (atomic)').item.json.tx_count }}", 'number')
    )

    $stickyFn = Build-Sticky 'fn_close_savings_plan: Hard-DELETE vs. Soft-Close' @(1760, -260) `
        'Smart-Close-Guard: tx_count entscheidet' `
        'fn und Karte (Read Plan) zählen Transaktionen über die ganze Vorgänger-Kette des Plans (fn_recurring_lineage; nach einer Betragsänderung liegt die Historie auf der alten Zeile). tx_count=0: Hard-DELETE finance.savings_plans, dann alle Ketten-rps; action=deleted. tx_count>0: Soft-Close — alle noch laufenden Ketten-Glieder enden heute (fn_end_recurring_chain, status=paused); plan.status=paused; action=closed. RAISE EXCEPTION bei Plan-nicht-gefunden.' 240 480

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_close_savings_plan mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (korrigierbare Ablehnungen der fn; Plan mehrdeutig kommt als Exception, nicht gefunden fängt vorher das Found?-Gate) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $readPlan, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyFn,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Plan' ) ) }
        'Read Plan'              = @{ main = @( ,@( E 'Savings Plan found?' ) ) }
        'Savings Plan found?'    = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Savings Plan not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Close plan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Close plan (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Close rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_close_savings_plan' $nodes $conns `
        @{ Category = 'securities' }
}
