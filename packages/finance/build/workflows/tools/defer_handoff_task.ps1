#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_defer_handoff_task (Uebergabe Berater -> Buchhalter) --------------------------------------------------------
# Stellt einen vereinbarten Plan-Eintrag zurueck, den das System so noch nicht eintragen kann (Status deferred mit festem
# blocked_code), statt einen Ersatzweg zu nehmen. Gesetz in finance.fn_defer_handoff_task -> core.fn_defer_handoff_task (nur Eintraege der Person des
# Absenders, nur open/working; gueltige Codes = Katalog-Keys finance.handoff.blocked.<code>).
function Build-DeferHandoffTask {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('handoff_task_id', 'blocked_code')

    $wg = New-FnWriteGate -Fn 'finance.fn_defer_handoff_task' -DryPos @(220, 0) -WritePos @(1320, 0) `
        -WriteName 'Defer handoff task (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'task_id')::int AS task_id, r->>'status' AS status, r->>'blocked_code' AS blocked_code" `
        -Params ([ordered]@{
            handoff_task_id = '$(''Start'').item.json.handoff_task_id'
            blocked_code    = '$(''Start'').item.json.blocked_code'
            chat_id         = '$(''Start'').item.json.chat_id'
        })

    # Der Code ist nach dem Probelauf gueltig, also existiert sein Satz im Katalog.
    $D = "`$('Dry run').item.json.r"
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'finance.hitl.defer_handoff_task' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.handoff_blocked' "('finance.handoff.blocked.' + String($D.blocked_code || ''))" -Kind key)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the defer_handoff_task action'
    $ifWriteOk = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Defer rejected' @(1760, 200) "={{ `$('Defer handoff task (atomic)').item.json.reason }}"
    $ret = Build-Return @(1760, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('handoff_task_id', "={{ `$('Defer handoff task (atomic)').item.json.task_id }}", 'number')
        ,@('status', "={{ `$('Defer handoff task (atomic)').item.json.status }}", 'string')
        ,@('blocked_code', "={{ `$('Defer handoff task (atomic)').item.json.blocked_code }}", 'string')
    )

    $sticky = Build-Sticky 'Doc Plan-Eintrag zurückstellen' @(120, -340) `
        'HITL + core.fn_defer_handoff_task (Übergabe Berater -> Buchhalter)' `
        'Im Eintrage-Modus stellt der Buchhalter einen vereinbarten Eintrag zurück, den das System so noch nicht kann (Ende in der Zukunft, Zahlung bis Betrag, Sparziel aus nicht monatlichen Einzahlungen, fehlende Sache oder fehlendes Werkzeug): Status deferred mit festem blocked_code statt eines Ersatzwegs in Notizen. Gültige Codes = Katalog-Keys finance.handoff.blocked.<code>; ein unbekannter Code scheitert im Probelauf (code unknown_blocked_code, keine Karte); die gültige Liste kennt der Agent aus der Tool-Beschreibung, die der Build aus denselben Keys schreibt (Dry run rejected reicht valid_codes nicht durch). Die Karte zeigt den Grund aus dem Katalog und den Satz des Eintrags (card_lines des Probelaufs). Ein zurückgestellter Eintrag zählt nirgends als offen; der Korrektur-Schritt der Abfolge (core.fn_plan_rollout_next, step fix) bietet ihn nach einem Update wieder an. finance_rw erreicht agent.handoff_tasks nur über das DEFINER-Fenster.' 340 520

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
            @( E 'Defer handoff task (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Defer handoff task (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                   = @{ main = @(
            @( E 'Return' ),
            @( E 'Defer rejected' )
        ) }
    }
    return Build-Workflow 'agent.finance.tool_defer_handoff_task' $nodes $conns @{ Internal = $true }
}
