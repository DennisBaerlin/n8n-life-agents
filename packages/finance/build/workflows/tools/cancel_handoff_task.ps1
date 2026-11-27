#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_cancel_handoff_task (Uebergabe Berater -> Buchhalter) -------------------------------------------------------
# Schliesst einen vereinbarten Plan-Eintrag ohne Buchung (done_elsewhere -> done, dropped -> cancelled) oder legt ihn
# beim Ueberspringen zurueck auf open (skipped). Gesetz in finance.fn_cancel_handoff_task -> core.fn_cancel_handoff_task
# (nur Eintraege der Person des Absenders; Endzustaende unveraenderlich per Trigger).
function Build-CancelHandoffTask {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('handoff_task_id', 'reason', 'ref_type', 'ref_name')
    $S = "`$('Start').item.json"
    $params = [ordered]@{
        handoff_task_id = '$(''Start'').item.json.handoff_task_id'
        reason          = '$(''Start'').item.json.reason'
        ref_type        = '$(''Start'').item.json.ref_type'
        ref_name        = '$(''Start'').item.json.ref_name'
        chat_id         = '$(''Start'').item.json.chat_id'
    }

    # Ueberspringen aendert nichts Dauerhaftes (working -> open, die Stelle k von n bleibt): kein Tipp noetig.
    # Dieselbe Normalisierung wie core.fn_cancel_handoff_task (trim, lower, leer = skipped), sonst landete ein leerer Grund auf der Streich-Karte.
    $ifSkip = Build-If 'Skip only?' @(220, -260) "={{ ['', 'skipped'].includes(String($S.reason || '').trim().toLowerCase()) }}" 'true' 'equals' 'boolean'
    $skipParams = [ordered]@{ handoff_task_id = $params.handoff_task_id; reason = $params.reason; chat_id = $params.chat_id }
    $skip = Build-Pg 'Skip handoff task' @(440, -360) "=SELECT finance.fn_cancel_handoff_task(`$1::jsonb) AS r;" $skipParams
    $ifSkipOk = Build-If 'Skip ok?' @(660, -360) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $errSkip = Build-ToolError 'Skip rejected' @(880, -260) "={{ `$('Skip handoff task').item.json.r.reason || 'The entry could not be skipped.' }}"
    $retSkip = Build-Return @(880, -460) @(
        ,@('ok', 'true', 'boolean')
        ,@('handoff_task_id', "={{ `$('Skip handoff task').item.json.r.task_id }}", 'number')
        ,@('status', "={{ `$('Skip handoff task').item.json.r.status }}", 'string')
        ,@('note', 'Skipped: the entry stays open on the list of agreed entries, nothing was deleted. Go on with the next entry.', 'string')
    ) -Name 'Return skipped'

    $wg = New-FnWriteGate -Fn 'finance.fn_cancel_handoff_task' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Close handoff task (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'task_id')::int AS task_id, r->>'status' AS status" `
        -Params $params

    # Zwei Fassungen der Karte nach card_title_key des Probelaufs (dieselbe Lesart des Grunds wie der Write): "Schon eingetragen – abhaken?" (done_elsewhere) und "Nicht mehr eintragen" (dropped);
    # die Zeilen (Satz des Eintrags, was im System steht, was offen bleibt) liefert der Probelauf (card_lines).
    $ifElsewhere = Build-If 'Done elsewhere?' @(880, 0) "={{ String(`$('Dry run').item.json.r.card_title_key || '') === 'finance.hitl.cancel_handoff_task_done_elsewhere' }}" 'true' 'equals' 'boolean'
    $sumElsewhere = New-HitlSummary -Pos @(1100, -100) -Title 'finance.hitl.cancel_handoff_task_done_elsewhere' -LinesExpr $wg.CardLinesExpr
    $sumDropped = New-HitlSummary -Name 'Build Approval Summary dropped' -Pos @(1100, 100) -Title 'finance.hitl.cancel_handoff_task_dropped' -LinesExpr $wg.CardLinesExpr
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $cancelBranch = New-HandoffCancelBranch -Pos @(1760, 200) -Action 'the cancel_handoff_task action'
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Close rejected' @(2200, 200) "={{ `$('Close handoff task (atomic)').item.json.reason }}"
    $ret = Build-Return @(2200, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('handoff_task_id', "={{ `$('Close handoff task (atomic)').item.json.task_id }}", 'number')
        ,@('status', "={{ `$('Close handoff task (atomic)').item.json.status }}", 'string')
    )

    $sticky = Build-Sticky 'Doc Plan-Eintrag abhaken' @(120, -760) `
        'HITL + finance.fn_cancel_handoff_task (Übergabe Berater -> Buchhalter)' `
        'Im Eintrage-Modus schließt der Buchhalter einen vereinbarten Eintrag ohne Buchung. reason done_elsewhere -> done (Karte „Schon eingetragen – abhaken?“), dropped -> cancelled (Karte „Nicht mehr eintragen“). reason skipped streicht nichts: der Eintrag geht zurück auf open, ohne Karte, weil nichts Dauerhaftes geschieht (die Stelle „Eintrag k von n“ bleibt, core.fn_cancel_handoff_task lässt claimed_at stehen). Dry run = dieselbe fn VOR der Karte (zurückgerollt): fremder, unbekannter oder schon geschlossener Eintrag, unbekannter Grund oder abhaken ohne gefundene Sache (ref_type + ref_name, sonst nothing_to_tick) -> Dry run rejected, keine Karte. Ein gebuchter Eintrag braucht dieses Tool nicht: die Ziel-fn schließt ihn über handoff_task_id im selben Write (finance.fn_with_handoff). finance_rw erreicht agent.handoff_tasks nur über das DEFINER-Fenster core.fn_cancel_handoff_task.' 380 560

    $nodes = @($trig, $ifSkip, $skip, $ifSkipOk, $errSkip, $retSkip) + $wg.Nodes + @($ifElsewhere, $sumElsewhere, $sumDropped, $reqApproval, $ifApproved, $cancelBranch.Nodes[0], $cancelBranch.Nodes[1], $cancelBranch.Nodes[2], $ifWriteOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                          = @{ main = @( ,@( E 'Skip only?' ) ) }
        'Skip only?'                     = @{ main = @(
            @( E 'Skip handoff task' ),
            @( E 'Dry run' )
        ) }
        'Skip handoff task'              = @{ main = @( ,@( E 'Skip ok?' ) ) }
        'Skip ok?'                       = @{ main = @(
            @( E 'Return skipped' ),
            @( E 'Skip rejected' )
        ) }
        'Dry run'                        = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                    = @{ main = @(
            @( E 'Done elsewhere?' ),
            @( E 'Dry run rejected' )
        ) }
        'Done elsewhere?'                = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Build Approval Summary dropped' )
        ) }
        'Build Approval Summary'         = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Build Approval Summary dropped' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'               = @{ main = @( ,@( E 'Approved?' ) ) }
        'Reopen handoff task' = @{ main = @( ,@( E 'Return cancelled' ) ) }
        'Approved?'                      = @{ main = @(
            @( E 'Close handoff task (atomic)' ),
            @( E 'Reopen handoff task' )
        ) }
        'Close handoff task (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                      = @{ main = @(
            @( E 'Return' ),
            @( E 'Close rejected' )
        ) }
    }
    return Build-Workflow 'agent.finance.tool_cancel_handoff_task' $nodes $conns @{ Internal = $true }
}
