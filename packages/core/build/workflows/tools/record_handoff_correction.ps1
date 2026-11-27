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
    # Abgebrochen (nur der Tipp, nie der Ablauf: das ist keine Entscheidung): der alte Eintrag bleibt, wie er ist, das Ergebnis der Pruefung
    # steht fest (agent.fn_record_handoff_check outcome kept), damit die Abfolge nicht bis zur Frist wartet. onError continue: der Text ans
    # Modell kommt immer.
    $recKept = Build-Pg 'Record kept' @(1320, 200) `
        "=SELECT CASE WHEN (`$1::jsonb)->>'outcome' = 'declined' THEN agent.fn_record_handoff_check(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'domain', (SELECT h.domain FROM agent.handoff_tasks h WHERE h.id::text = (`$1::jsonb)->>'handoff_task_id'), 'handoff_task_ids', (`$1::jsonb)->>'handoff_task_id', 'outcome', 'kept')) END AS r;" `
        ([ordered]@{
            outcome         = "String(`$('Request Approval').item.json.outcome || '')"
            chat_id         = "String(`$('Start').item.json.chat_id || '')"
            handoff_task_id = "String(`$('Start').item.json.handoff_task_id || '')"
        })
    $recKept['onError'] = 'continueRegularOutput'
    $recKept['alwaysOutputData'] = $true
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1540, 200) 'the record_handoff_correction action' -HandoffIdExpr 'true' -HandoffMore -Source "`$('Request Approval').item.json"
    $ifWriteOk = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Correction rejected' @(1760, 200) "={{ `$('Record correction (atomic)').item.json.reason }}"
    $ret = Build-Return @(1760, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('handoff_task_id', "={{ `$('Record correction (atomic)').item.json.task_id }}", 'number')
        ,@('status', "={{ `$('Record correction (atomic)').item.json.status }}", 'string')
        ,@('blocked_code', "={{ `$('Record correction (atomic)').item.json.blocked_code || '' }}", 'string')
        ,@('note', 'Recorded: the entry comes on the list to enter. Your whole written reply, counting any text before the cards, is exactly one short sentence in the user language that it is noted; do not repeat the comparison or what the card shows.', 'string')
    )
    $sticky = Build-Sticky 'Doc Eintrag nachholen' @(120, -340) `
        'HITL + agent.fn_record_handoff_correction (Eintrag prüfen)' `
        'Der Prüf-Schritt der Abfolge (core.fn_plan_rollout_next, step check) schickt erledigte Einträge ohne Soll (vor der Provenienz abgeschlossen) über den Knopf plan:check an den Berater. Passt ein Eintrag nicht zum Plan, ruft der Berater dieses Werkzeug: Probelauf mit der Vorprüfung des Pakets (handoff_check_fn wie beim Vereinbaren; Kandidaten oder Optionen kommen als Satz im reason zurück, keine Karte), dann die Karte mit dem Satz des Eintrags und dem Grund (card_lines des Probelaufs). Der Write legt eine NEUE Vormerkung mit follows_task_id an (Abschnitt, Thema, Paket der alten; open, oder deferred mit blocked_code); die alte bleibt unverändert, höchstens eine Folge-Aufgabe (UNIQUE). Eingetragen wird danach über die Liste [Jetzt eintragen] der Abfolge. Stimmt der alte Eintrag, gibt es keinen Aufruf (das Ergebnis hält agent.tool_record_handoff_check fest). Wird die Karte abgebrochen, hält Record kept fest, dass der alte Eintrag bleibt (agent.fn_record_handoff_check outcome kept, nur beim Tipp, nicht beim Ablauf).' 340 560
    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $recKept, $retCancelled, $ifWriteOk, $errWrite, $ret, $sticky)
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
            @( E 'Record kept' )
        ) }
        'Record kept'                = @{ main = @( ,@( E 'Return cancelled' ) ) }
        'Record correction (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                  = @{ main = @(
            @( E 'Return' ),
            @( E 'Correction rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_record_handoff_correction' $nodes $conns @{ Internal = $true }   # intern: Berater-Werkzeug
}
