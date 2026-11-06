#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_close_savings_goal (Sparziel beenden: Smart-Close wie close_savings_plan) ---
function Build-CloseSavingsGoal {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('savings_goal_name','outcome','force')

    # tx_count zaehlt wie die fn (Rate-rp ODER savings_goal_id-Tag) -> Soft/Hard-Vorschau korrekt;
    # current_amount = Reservebestand (savings_goal_progress) fuer den completed-Gate-Hinweis.
    $readGoal = Build-Pg 'Read Goal' @(220, 0) `
        "=SELECT g.target_amount, g.target_date::text AS target_date, g.status::text AS goal_status, COALESCE((SELECT current_amount FROM finance.savings_goal_progress p WHERE p.id = g.id), 0) AS current_amount, (SELECT COUNT(*)::int FROM finance.transactions t WHERE (g.recurring_payment_id IS NOT NULL AND t.recurring_payment_id = g.recurring_payment_id) OR t.savings_goal_id = g.id) AS tx_count FROM finance.savings_goals g WHERE g.name ILIKE ((`$1::jsonb)->>'savings_goal_name') LIMIT 1;" `
        ([ordered]@{ savings_goal_name = '$(''Start'').item.json.savings_goal_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readGoal -KeyField 'goal_status' -IfName 'Savings Goal found?' -ErrName 'Savings Goal not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No savings goal named '{{ `$('Start').item.json.savings_goal_name }}' exists. List them via postgres_select on finance.savings_goal_progress and ask the user which one is meant."

    # "DB ist das Gesetz": fn_close_savings_goal laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_close_savings_goal' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Close goal (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, r->>'status' AS status, (r->>'tx_count')::int AS tx_count" `
        -Params ([ordered]@{
            savings_goal_name = '$(''Start'').item.json.savings_goal_name'
            outcome           = '$(''Start'').item.json.outcome'
            force             = '$(''Start'').item.json.force'
        })

    # Outcome steuert Titel + Aktionszeile: completed (erfuellt, Reserve verbraucht) vs cancelled (abgebrochen,
    # Zuordnungen frei) vs Hard-DELETE (keine Buchungen). Bei completed + Restreserve ein Achtung-Hinweis.
    # Strukturiertes Summary (Textkatalog): Zielbetrag/Reservebestand (EUR-Konvention), Zieldatum ISO aus dem SELECT.
    $S = "`$('Start').item.json"
    $G = "`$('Read Goal').item.json"
    $done = "(($S.outcome || 'cancelled') === 'completed')"
    $titleVal = New-HitlValue -Kind key -Value "($done ? 'finance.hitl.close_savings_goal_completed' : ($G.tx_count > 0 ? 'finance.hitl.close_savings_goal_cancelled' : 'finance.hitl.close_savings_goal_deleted'))"
    $noteKey = "($done ? ($G.current_amount > 0.01 ? 'finance.note.close_goal_reserve_left' : 'finance.note.close_goal_done') : ($G.tx_count > 0 ? 'finance.note.close_goal_cancel' : 'finance.note.close_goal_delete'))"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.close_savings_goal' -LinesExpr $wg.CardLinesExpr -TitleParams @{ title = $titleVal } -Lines @(
        (New-HitlLine 'finance.label.savings_goal'    "$S.savings_goal_name")
        (New-HitlLine 'finance.label.target_amount'   "$G.target_amount" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.target_date'     "$G.target_date" -Kind date)
        (New-HitlLine 'core.label.status'             "$G.goal_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlLine 'finance.label.reserve_balance' "$G.current_amount" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.booked_movements' "$G.tx_count")
        (New-HitlNote -KeyExpr $noteKey)
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the close_savings_goal action'


    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Close rejected' @(2200, 240) `
        "={{ `$('Close goal (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Close goal (atomic)').item.json.action }}", 'string')
        ,@('status', "={{ `$('Close goal (atomic)').item.json.status }}", 'string')
        ,@('tx_count', "={{ `$('Close goal (atomic)').item.json.tx_count }}", 'number')
    )

    $stickyFn = Build-Sticky 'fn_close_savings_goal: outcome + Hard-DELETE vs. Soft-Close' @(1760, -300) `
        'WS-B Stufe 3: erreicht != ausgegeben' `
        'outcome=completed (ERFÜLLT): nur wenn Reserve ~0 (savings_goal_progress.current_amount) ODER force=true -> sonst {ok:false} (kein Auto-Freigeben). outcome=cancelled (Default, ABGEBROCHEN): Zuordnungen frei. Smart-Close-Guard: tx_count (Rate-rp ODER savings_goal_id-Tag) entscheidet Hard vs. Soft. tx_count=0: Hard-DELETE finance.savings_goals (Reserve-Journal CASCADE; tags/plans SET NULL) dann ggf. recurring_payments; action=deleted. tx_count>0: Soft-Close — goal.status=outcome; RP paused + valid_to=heute; bei cancelled zusätzlich transactions.savings_goal_id + savings_plans.savings_goal_id SET NULL (reassignbar, Historie bleibt; Journal append-only, vom status-Filter entkoppelt); action=closed. Bestand (depot_holdings) bleibt IMMER (RESTRICT). RAISE bei nicht gefunden/mehrdeutig (nicht gefunden fängt vorher das Found?-Gate des Tools).' 260 520

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_close_savings_goal mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (outcome=completed bei Restreserve ohne force, sonstige korrigierbare Ablehnungen; mehrdeutig kommt als Exception, nicht gefunden fängt vorher das Found?-Gate) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $readGoal, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyFn,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Goal' ) ) }
        'Read Goal'              = @{ main = @( ,@( E 'Savings Goal found?' ) ) }
        'Savings Goal found?'    = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Savings Goal not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Close goal (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Close goal (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Close rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_close_savings_goal' $nodes $conns `
        @{ Category = 'savings_goals' }
}
