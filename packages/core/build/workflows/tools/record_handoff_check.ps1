#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_record_handoff_check (Berater-Werkzeug, ohne Gate) -----------------------------------------------------
# Ergebnis des Auftrags "Eintrag pruefen" fuer Eintraege, die zum Plan passen: ein Merker je Eintrag (agent.fn_record_handoff_check),
# damit die Abfolge den Schluss nicht laenger zurueckhaelt. Aendert weder Plan noch Daten -> kein HITL-Gate.
# domain ist beim Aufrufer fixer Binding-Input, chat_id die Identitaet.
function Build-RecordHandoffCheck {
    $trig = Build-Trigger @('domain', 'handoff_task_ids')

    $S = "`$('Start').item.json"
    $run = Build-Pg 'Record check' @(220, 0) '=SELECT agent.fn_record_handoff_check($1::jsonb) AS r;' `
        ([ordered]@{
            domain           = "String($S.domain || '')"
            chat_id          = "String($S.chat_id || '')"
            handoff_task_ids = "String($S.handoff_task_ids || '')"
            outcome          = "'matches'"
        })
    $ifOk = Build-If 'Recorded?' @(440, 0) '={{ ($json.r || {}).ok === true }}' 'true' 'equals' 'boolean'
    $ret = Build-Return @(660, -100) @(
        ,@('ok', 'true', 'boolean')
        ,@('recorded', '={{ $json.r.recorded }}', 'number')
    )
    $err = Build-ToolError 'Check rejected' @(660, 100) `
        "={{ 'Not recorded (' + String((`$json.r || {}).code || 'error') + '): ' + String((`$json.r || {}).reason || '') }}"
    $sticky = Build-Sticky 'Doc Pruef-Ergebnis' @(120, -360) 'Eintrag pruefen: passt zum Plan (ohne Gate)' `
        'Record check ruft agent.fn_record_handoff_check mit outcome matches: je Eintrag des Auftrags "Eintrag prüfen", der zum Plan passt, ein Merker <domain>:<who>:check_done:<id>. Alles oder nichts; nur Altbestand der Person, der beim Berater war und keine Korrektur hat. Danach hält core.fn_plan_rollout_next den Schluss für diese Einträge nicht mehr zurück. Abgebrochene Korrektur-Karten hält agent.tool_record_handoff_correction selbst fest (outcome kept). Kein HITL-Gate: weder Plan noch Daten ändern sich.' 340 300

    $nodes = @($trig, $run, $ifOk, $ret, $err, $sticky)
    $conns = [ordered]@{
        'Start'        = @{ main = @( ,@( E 'Record check' ) ) }
        'Record check' = @{ main = @( ,@( E 'Recorded?' ) ) }
        'Recorded?'    = @{ main = @( @( E 'Return' ), @( E 'Check rejected' ) ) }
    }
    return Build-Workflow 'agent.tool_record_handoff_check' $nodes $conns @{ Internal = $true }   # intern: Berater-Werkzeug
}
