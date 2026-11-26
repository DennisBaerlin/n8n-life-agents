#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_record_handoff_correction (Berater-Werkzeug, HITL) -----------------------------------------------------
# Ergebnis des Auftrags "Eintrag pruefen": ein erledigter Eintrag ohne Soll passt nicht zum Plan -> neue Vormerkung mit
# Verweis auf die alte (agent.fn_record_handoff_correction). Eingetragen wird sie danach wie jede Vormerkung ueber die Liste.
function Build-RecordHandoffCorrection {
    $trig = Build-Trigger @('handoff_task_id', 'kind', 'payload', 'text', 'why', 'option')

    $wg = New-FnWriteGate -Fn 'agent.fn_record_handoff_correction' -DryPos @(220, 0) -WritePos @(1320, 0) `
        -WriteName 'Record correction (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'task_id')::int AS task_id, r->>'status' AS status, r->>'blocked_code' AS blocked_code" `
        -Params ([ordered]@{
            handoff_task_id = '$(''Start'').item.json.handoff_task_id'
            kind            = '$(''Start'').item.json.kind'
            payload         = '$(''Start'').item.json.payload'
            text            = '$(''Start'').item.json.text'
            why             = '$(''Start'').item.json.why'
            option          = '$(''Start'').item.json.option'
            chat_id         = '$(''Start'').item.json.chat_id'
        })
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'core.hitl.record_handoff_correction' -LinesExpr $wg.CardLinesExpr -Lines @()
    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the record_handoff_correction action'
    $ifWriteOk = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Correction rejected' @(1760, 200) "={{ `$('Record correction (atomic)').item.json.reason }}"
    $ret = Build-Return @(1760, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('handoff_task_id', "={{ `$('Record correction (atomic)').item.json.task_id }}", 'number')
        ,@('status', "={{ `$('Record correction (atomic)').item.json.status }}", 'string')
        ,@('blocked_code', "={{ `$('Record correction (atomic)').item.json.blocked_code || '' }}", 'string')
    )
    $sticky = Build-Sticky 'Doc Eintrag nachholen' @(120, -340) `
        'HITL + agent.fn_record_handoff_correction (Eintrag prüfen)' `
        'Der Prüf-Schritt der Abfolge (core.fn_plan_rollout_next, step check) schickt erledigte Einträge ohne Soll (vor der Provenienz abgeschlossen) über den Knopf plan:check an den Berater. Passt ein Eintrag nicht zum Plan, ruft der Berater dieses Werkzeug: Probelauf mit der Vorprüfung des Pakets (handoff_check_fn wie beim Vereinbaren; Kandidaten oder Optionen kommen als Satz im reason zurück, keine Karte), dann die Karte mit dem Satz des Eintrags und dem Grund (card_lines des Probelaufs). Der Write legt eine NEUE Vormerkung mit follows_task_id an (Abschnitt, Thema, Paket der alten; open, oder deferred mit blocked_code); die alte bleibt unverändert, höchstens eine Folge-Aufgabe (UNIQUE). Eingetragen wird danach über die Liste [Jetzt eintragen] der Abfolge. Stimmt der alte Eintrag, gibt es keinen Aufruf.' 340 520
    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                      = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                    = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'     = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'           = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                  = @{ main = @(
            @( E 'Record correction (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Record correction (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                  = @{ main = @(
            @( E 'Return' ),
            @( E 'Correction rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_record_handoff_correction' $nodes $conns @{ Internal = $true }   # intern: Berater-Werkzeug
}
