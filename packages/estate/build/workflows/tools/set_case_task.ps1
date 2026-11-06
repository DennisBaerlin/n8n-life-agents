#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_case_task (WS-3; HITL owner_info seit dem Security-Audit 2026-10) ---------
# Setzt den Status EINER Checklisten-Task (open|done|not_applicable). Owner-Entscheid 2026-10-24 "Karte nur bei
# Abhaken": der Statuswechsel laeuft durch das HITL-Gate (eine Pflichtfrist darf nie still per Modell abgehakt
# werden — z. B. nach einer Anweisung in einem gelesenen Dokument). Stufe owner_info wie create_case/cancel_case
# (Break-Glass: der Owner kann der Betroffene sein). create_case_task bleibt ohne Karte. Der adults_only-DB-Backstop
# + der "Task in offenem Fall"-Guard bleiben in der fn (Probelauf vor der Karte). Der Auto-Complete-Trigger kann
# den Fall danach auf completed kippen (Post-State meldet case_completed). Cred = estate_rw.
function Build-EstateSetCaseTask {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('case_task_id','status')

    # "DB ist das Gesetz": estate.fn_set_case_task laeuft als Probelauf VOR der Karte (unbekannte Task, Fall nicht
    # offen, ungueltiger Status, nicht erwachsen -> ok:false ohne Karte); derselbe Param-Satz geht nach dem Gate in den Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_case_task' -DryPos @(220, 0) -WritePos @(1540, 0) `
        -WriteName 'Set task (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_task_id')::bigint AS case_task_id, r->>'status' AS status, r->>'case_status' AS case_status, (r->>'case_completed')::boolean AS case_completed" `
        -Params ([ordered]@{
            chat_id      = '$(''Start'').item.json.chat_id'
            case_task_id = '$(''Start'').item.json.case_task_id'
            status       = '$(''Start'').item.json.status'
        })
    # Anzeige fuer die Karte (nach dem Probelauf -> die Task existiert): Titel + Fall-Nummer.
    $readTask = Build-Pg 'Read task' @(660, 0) `
        "=SELECT ct.title, ct.case_id FROM estate.case_tasks ct WHERE ct.id = (`$1::jsonb->>'case_task_id')::bigint;" `
        ([ordered]@{ case_task_id = '$(''Start'').item.json.case_task_id' })

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S = "`$('Start').item.json"
    $R = "`$('Read task').item.json"
    $summary = New-HitlSummary -Pos @(880, 0) -Title 'estate.hitl.set_case_task' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.case_no'    "$R.case_id")
        (New-HitlLine 'estate.label.task'       "$R.title")
        (New-HitlLine 'estate.label.new_status' "$S.status" -Kind enum -Enum 'estate.enum.task_status')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1100, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1320, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1540, 200) 'the set_case_task action (the task status stays unchanged)'
    $ifWriteOk = Build-If 'Write ok?' @(1760, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Task update rejected' @(1980, 200) "={{ `$('Set task (atomic)').item.json.reason }}"
    $ret = Build-Return @(1980, 0) @(
        ,@('ok','true','boolean')
        ,@('case_task_id', "={{ `$('Set task (atomic)').item.json.case_task_id }}", 'number')
        ,@('status', "={{ `$('Set task (atomic)').item.json.status }}", 'string')
        ,@('case_status', "={{ `$('Set task (atomic)').item.json.case_status }}", 'string')
        ,@('case_completed', "={{ `$('Set task (atomic)').item.json.case_completed }}", 'boolean')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(220, -280) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_case_task mit denselben Werten, immer zurückgerollt. ok:false (unbekannte Task, Fall nicht offen, ungültiger Status, nicht erwachsen) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Read task (Titel + Fall-Nr. für die Karte) -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'Karte beim Abhaken (owner_info) + Auto-Complete' @(880, -280) `
        'estate.fn_set_case_task (Task-Status; Auto-Complete-Trigger)' `
        'Owner-Entscheid 2026-10-24 (Security-Audit): jeder Statuswechsel einer Checklisten-Task braucht einen Tipp auf Bestätigen — eine Pflichtfrist darf nie still per Modell abgehakt werden (etwa nach einer Anweisung in einem gelesenen Dokument). Stufe owner_info wie create_case/cancel_case (Break-Glass: der Owner kann der Betroffene sein; ein erwachsenes Mitglied bestätigt selbst, der Owner bekommt die Info). Neue Tasks (create_case_task) bleiben ohne Karte. adults_only-DB-Backstop + "Task in OFFENEM Fall"-Guard in der fn. done -> done_at. Wird die letzte offene Task done/n.a., kippt der Auto-Complete-Trigger den Fall auf completed (Post-State case_completed=true).' 300 560
    $nodes = @($trig) + $wg.Nodes + @($readTask, $summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Read task' ),
            @( E 'Dry run rejected' )
        ) }
        'Read task'              = @{ main = @( ,@( E 'Build Approval Summary' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set task (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set task (atomic)'      = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Task update rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_case_task' $nodes $conns `
        @{ Category = 'register' }
}
