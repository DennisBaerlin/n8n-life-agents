#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_delete_monitor_trigger (CROSS-AGENT, HITL-Write) -------------
# Loescht EINEN Monitor-Trigger HART (Trigger sind Config, kein Ledger; Observations
# gehen per FK-CASCADE mit). Binder: NUR agent.monitor. Stilllegen statt loeschen ->
# tool_set_monitor_trigger status=disabled (die Summary weist darauf hin).
function Build-DeleteMonitorTrigger {
    $trig = Build-Trigger @('domain', 'label')

    $resolveDomain = Build-Set 'Resolve domain' @(180, 0) @(
        ,@('domain', '={{ String($(''Start'').item.json.chat_id || '''').startsWith(''test_e2e'') ? ''__e2e_monitor__'' : ($(''Start'').item.json.domain || ''general'') }}', 'string')
    )

    $resolve = Build-Pg 'Resolve trigger' @(360, 0) `
        "=SELECT r.id, r.hit_count, r.candidates::text AS candidates, t.trigger_type, t.status AS cur_status, (SELECT COUNT(*) FROM agent.monitor_observations o WHERE o.trigger_id = r.id)::int AS obs_count FROM agent.fn_resolve_monitor_trigger((`$1::jsonb)->>'label', (`$1::jsonb)->>'domain', false) AS r LEFT JOIN agent.monitor_triggers t ON t.id = r.id;" `
        ([ordered]@{
            label  = '$(''Start'').item.json.label'
            domain = '$(''Resolve domain'').item.json.domain'
        })
    $ifFound = Build-If 'Found?' @(540, 0) '={{ $json.hit_count }}' '1' 'equals' 'number'
    $errFound = Build-ToolError 'Not found' @(720, -200) `
        "={{ `$('Resolve trigger').item.json.hit_count === 0 ? 'No trigger with this label in this domain. List existing triggers via postgres_select on agent.monitor_triggers and ask the user.' : 'Label is ambiguous across domains - specify the domain. Candidates: ' + `$('Resolve trigger').item.json.candidates }}"

    # Strukturiertes Summary (Textkatalog). Der Hinweis nennt den Knopf "Abbrechen" (seit dem Chat-Knopf-Wortlaut).
    $R = "`$('Resolve trigger').item.json"
    $summary = New-HitlSummary -Pos @(720, 0) -Title 'core.hitl.delete_monitor_trigger' -Lines @(
        (New-HitlLine 'core.label.label'  "`$('Start').item.json.label")
        (New-HitlLine 'core.label.domain' "`$('Resolve domain').item.json.domain")
        (New-HitlLine 'core.label.type' "'core.tpl.type_with_status'" -Kind tpl -Params @{
            type   = (New-HitlValue -Kind enum -Value "$R.trigger_type" -Enum 'core.enum.trigger_type')
            status = (New-HitlValue -Kind enum -Value "$R.cur_status" -Enum 'core.enum.trigger_status') })
        (New-HitlLine 'core.label.observation_history' "'core.tpl.monitor_obs_deleted'" -Kind tpl -Params @{ n = "$R.obs_count" })
        (New-HitlNote -Key 'core.note.monitor_delete_final')
    )

    $reqApproval = Build-CallWorkflow 'Request Approval' @(900, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1080, 0) '={{ $json.approved }}' 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1260, 200) 'the delete_monitor_trigger action'

    $del = Build-Pg 'Delete trigger (atomic)' @(1260, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'trigger_id')::int AS trigger_id, (r->>'observations_deleted')::int AS observations_deleted FROM agent.fn_delete_monitor_trigger(`$1::jsonb) AS r;" `
        ([ordered]@{
            domain = '$(''Resolve domain'').item.json.domain'
            label  = '$(''Start'').item.json.label'
        })

    $ifOk = Build-If 'Write ok?' @(1440, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Delete rejected' @(1620, 200) "={{ `$('Delete trigger (atomic)').item.json.reason }}"

    $ret = Build-Return @(1620, 0) @(
        ,@('ok','true','boolean')
        ,@('trigger_id', '={{ $json.trigger_id }}', 'number')
        ,@('observations_deleted', '={{ $json.observations_deleted }}', 'number')
    )

    $sticky = Build-Sticky 'Doc Delete Trigger' @(120, -380) `
        'HITL + agent.fn_delete_monitor_trigger (Hard-DELETE)' `
        'Nur agent.monitor bindet dieses Tool. Trigger sind CONFIG, kein Ledger -> Hard-DELETE legitim; monitor_observations gehen per FK ON DELETE CASCADE mit (Count steht in Summary + Rückgabe). Auflösung per (domain, label) VOR dem Gate (0/>1 Treffer = ToolError, kein Gate-Spam). Stilllegen statt löschen = tool_set_monitor_trigger status=disabled.' 240 480

    $nodes = @($trig, $resolveDomain, $resolve, $ifFound, $errFound, $summary, $reqApproval,
               $ifApproved, $retCancelled, $del, $ifOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Resolve domain' ) ) }
        'Resolve domain'          = @{ main = @( ,@( E 'Resolve trigger' ) ) }
        'Resolve trigger'         = @{ main = @( ,@( E 'Found?' ) ) }
        'Found?'                  = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Not found' )
        ) }
        'Build Approval Summary'  = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'        = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'               = @{ main = @(
            @( E 'Delete trigger (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete trigger (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_delete_monitor_trigger' $nodes $conns `
        @{ Category = 'monitoring' }
}
