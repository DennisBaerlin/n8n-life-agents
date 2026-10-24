#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_case_task (WS-3, Fortschritts-Flag-Klasse: KEIN HITL) -------------------
# Setzt den Status EINER Checklisten-Task (open|done|not_applicable). Fortschritts-Flag (Praezedenz
# confirm_review/set_onboarding_section) -> KEIN Gate, KEIN approval_matrix-Eintrag; der adults_only-
# DB-Backstop + der "Task in offenem Fall"-Guard bleiben in der fn. Der Auto-Complete-Trigger kann den
# Fall danach auf completed kippen (Post-State meldet case_completed). Cred = estate_rw.
function Build-EstateSetCaseTask {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('case_task_id','status')

    $setTask = Build-Pg 'Set task (atomic)' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_task_id')::bigint AS case_task_id, r->>'status' AS status, r->>'case_status' AS case_status, (r->>'case_completed')::boolean AS case_completed FROM estate.fn_set_case_task(`$1::jsonb) AS r;" `
        ([ordered]@{
            chat_id      = '$(''Start'').item.json.chat_id'
            case_task_id = '$(''Start'').item.json.case_task_id'
            status       = '$(''Start'').item.json.status'
        })
    $ifWriteOk = Build-If 'Write ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Task update rejected' @(660, 200) "={{ `$('Set task (atomic)').item.json.reason }}"
    $ret = Build-Return @(660, 0) @(
        ,@('ok','true','boolean')
        ,@('case_task_id', "={{ `$('Set task (atomic)').item.json.case_task_id }}", 'number')
        ,@('status', "={{ `$('Set task (atomic)').item.json.status }}", 'string')
        ,@('case_status', "={{ `$('Set task (atomic)').item.json.case_status }}", 'string')
        ,@('case_completed', "={{ `$('Set task (atomic)').item.json.case_completed }}", 'boolean')
    )
    $stickyFn = Build-Sticky 'Fortschritts-Flag (KEIN HITL) + Auto-Complete' @(220, -240) `
        'estate.fn_set_case_task (Task-Status; Auto-Complete-Trigger)' `
        'KEIN HITL-Gate (Fortschritts-Flag-Klasse wie confirm_review/set_onboarding_section -> kein approval_matrix-Eintrag). Der adults_only-DB-Backstop (Kind -> {ok:false}) + der "Task in OFFENEM Fall"-Guard sind die Absicherung. done -> done_at. Wird die letzte offene Task done/n.a., kippt der Auto-Complete-Trigger den Fall auf completed (Post-State case_completed=true).' 280 560
    $nodes = @($trig, $setTask, $ifWriteOk, $errWrite, $ret, $stickyFn)
    $conns = [ordered]@{
        'Start'             = @{ main = @( ,@( E 'Set task (atomic)' ) ) }
        'Set task (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'         = @{ main = @(
            @( E 'Return' ),
            @( E 'Task update rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_case_task' $nodes $conns `
        @{ Category = 'register' }
}
