#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_cancel_handoff_task (Uebergabe Berater -> Buchhalter) -------------------------------------------------------
# Schliesst einen im Plan-Gespraech vereinbarten Punkt ohne Buchung: reason skipped -> cancelled, done_elsewhere -> done.
# Gesetz in finance.fn_cancel_handoff_task -> core.fn_cancel_handoff_task (nur Punkte der Person des Absenders, nur open/
# working; Endzustaende unveraenderlich per Trigger). Die Karte zeigt den Satz des Punkts aus dem Probelauf (card_lines).
function Build-CancelHandoffTask {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('handoff_task_id', 'reason')

    $wg = New-FnWriteGate -Fn 'finance.fn_cancel_handoff_task' -DryPos @(220, 0) -WritePos @(1320, 0) `
        -WriteName 'Close handoff task (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'task_id')::int AS task_id, r->>'status' AS status" `
        -Params ([ordered]@{
            handoff_task_id = '$(''Start'').item.json.handoff_task_id'
            reason          = '$(''Start'').item.json.reason'
            chat_id         = '$(''Start'').item.json.chat_id'
        })

    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'finance.hitl.cancel_handoff_task' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.handoff_outcome' "(String($S.reason || '') === 'done_elsewhere' ? 'finance.value.handoff_done_elsewhere' : 'finance.value.handoff_skipped')" -Kind key)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the cancel_handoff_task action'
    $ifWriteOk = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Close rejected' @(1760, 200) "={{ `$('Close handoff task (atomic)').item.json.reason }}"
    $ret = Build-Return @(1760, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('handoff_task_id', "={{ `$('Close handoff task (atomic)').item.json.task_id }}", 'number')
        ,@('status', "={{ `$('Close handoff task (atomic)').item.json.status }}", 'string')
    )

    $sticky = Build-Sticky 'Doc Plan-Punkt schliessen' @(120, -340) `
        'HITL + finance.fn_cancel_handoff_task (Übergabe Berater -> Buchhalter)' `
        'Im Durchgehen-Modus (Auftrag vom Orchestrator nach dem Knopf Durchgehen) schließt der Buchhalter einen vereinbarten Punkt ohne Buchung: reason skipped -> cancelled, done_elsewhere -> done. Dry run = dieselbe fn VOR der Karte (zurückgerollt): fremder, unbekannter oder schon geschlossener Punkt -> Dry run rejected, keine Karte. Die Karte zeigt das Ergebnis und den Satz des Punkts (card_lines: Aus dem Plan-Gespräch …). Ein gebuchter Punkt braucht dieses Tool nicht: die Ziel-fn schließt ihn über handoff_task_id im selben Write (finance.fn_with_handoff). finance_rw erreicht agent.handoff_tasks nur über das DEFINER-Fenster core.fn_cancel_handoff_task.' 340 520

    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                       = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                     = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                 = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'      = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'            = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                   = @{ main = @(
            @( E 'Close handoff task (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Close handoff task (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                   = @{ main = @(
            @( E 'Return' ),
            @( E 'Close rejected' )
        ) }
    }
    return Build-Workflow 'agent.finance.tool_cancel_handoff_task' $nodes $conns @{ Internal = $true }
}
