#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_case_task (WS-3, Fortschritts-Flag-Klasse: KEIN HITL) ----------------
# Fuegt eine MANUELLE Task (template_key NULL) zu einem OFFENEN Fall hinzu — haushaltsspezifische
# Schritte, die kein Template abdeckt. Fortschritts-Flag-Klasse (kein Gate); adults_only-DB-Backstop
# + "Fall offen?"-Guard in der fn. Manuelle Tasks ueberleben den Reconcile. Cred = estate_rw.
function Build-EstateCreateCaseTask {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('case_id','title','phase','detail','due_date')

    $createTask = Build-Pg 'Create task (atomic)' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_task_id')::bigint AS case_task_id, (r->>'case_id')::bigint AS case_id FROM estate.fn_create_case_task(`$1::jsonb) AS r;" `
        ([ordered]@{
            chat_id  = '$(''Start'').item.json.chat_id'
            case_id  = '$(''Start'').item.json.case_id'
            title    = '$(''Start'').item.json.title'
            phase    = '$(''Start'').item.json.phase'
            detail   = '$(''Start'').item.json.detail'
            due_date = '$(''Start'').item.json.due_date'
        })
    $ifWriteOk = Build-If 'Write ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Task creation rejected' @(660, 200) "={{ `$('Create task (atomic)').item.json.reason }}"
    $ret = Build-Return @(660, 0) @(
        ,@('ok','true','boolean')
        ,@('case_task_id', "={{ `$('Create task (atomic)').item.json.case_task_id }}", 'number')
        ,@('case_id', "={{ `$('Create task (atomic)').item.json.case_id }}", 'number')
    )
    $stickyFn = Build-Sticky 'Fortschritts-Flag (KEIN HITL) — manuelle Task' @(220, -240) `
        'estate.fn_create_case_task (manuelle Task, template_key NULL)' `
        'KEIN HITL-Gate (Fortschritts-Flag-Klasse). Fügt eine manuelle Task (template_key NULL, subject_ref '''') zu einem OFFENEN Fall hinzu (phase Default first_week). Manuelle Tasks sind NICHT im Template-Soll-Satz -> vom additiven Reconcile (fn_set_case) nie berührt. adults_only-DB-Backstop + "Fall offen?"-Guard.' 280 560
    $nodes = @($trig, $createTask, $ifWriteOk, $errWrite, $ret, $stickyFn)
    $conns = [ordered]@{
        'Start'                = @{ main = @( ,@( E 'Create task (atomic)' ) ) }
        'Create task (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'            = @{ main = @(
            @( E 'Return' ),
            @( E 'Task creation rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_create_case_task' $nodes $conns `
        @{ Category = 'register' }
}
