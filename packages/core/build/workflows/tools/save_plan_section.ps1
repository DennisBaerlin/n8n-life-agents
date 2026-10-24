#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_save_plan_section (CROSS-AGENT, HITL-Write) -----------------
# Speichert EINE Interview-Sektion in den Draft-Plan der Domain (Upsert in
# interview_state; fn legt den Draft bei Bedarf an — Versionszaehler rechnet die DB).
# domain ist beim aufrufenden Agenten ein FIXER Binding-Input (nie $fromAI) — ein
# kuenftiger Career-Advisor bindet dasselbe Tool mit domain='career'.
# WICHTIG (Playback != Gate): der Agent spielt die Sektion VOR diesem Tool-Call als
# normale Chat-Nachricht zurueck und ruft erst nach verbalem OK — die Gate-Message
# hier ist bewusst KNAPP (Sektion + Kurz-Preview), kein zweites Voll-Playback.
function Build-SavePlanSection {
    $trig = Build-Trigger @('domain', 'section_key', 'section_content', 'section_data', 'plan_name')

    # Strukturiertes Summary (Textkatalog): Inhalt nur angerissen (220 Zeichen), die volle Fassung stand im Chat.
    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(220, 0) -Title 'core.hitl.save_plan_section' -Lines @(
        (New-HitlLine 'core.label.section' "$S.section_key")
        (New-HitlLine 'core.label.plan' "$S.plan_name" -If "$S.plan_name")
        (New-HitlLine 'core.label.plan' "'core.tpl.plan_draft'" -Kind tpl -Params @{ domain = "$S.domain" } -If "!$S.plan_name")
        (New-HitlLine 'core.label.content_start' "(($S.section_content || '').slice(0, 220) + (($S.section_content || '').length > 220 ? '…' : ''))")
        (New-HitlNote -Key 'core.note.full_content_confirmed')
    )

    $reqApproval = Build-CallWorkflow 'Request Approval' @(440, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(660, 0) '={{ $json.approved }}' 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(880, 200) 'the save_plan_section action'

    $save = Build-Pg 'Save section (atomic)' @(880, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'plan_id')::int AS plan_id, (r->>'version')::int AS version, (r->>'draft_created')::boolean AS draft_created, (r->>'section_count')::int AS section_count, (r->'sections')::text AS sections FROM agent.fn_advisor_save_section(`$1::jsonb) AS r;" `
        ([ordered]@{
            domain          = '$(''Start'').item.json.domain'
            section_key     = '$(''Start'').item.json.section_key'
            section_content = '$(''Start'').item.json.section_content'
            section_data    = '$(''Start'').item.json.section_data'
            plan_name       = '$(''Start'').item.json.plan_name'
            chat_id         = '$(''Start'').item.json.chat_id'   # WS-5b/P0c: Person + Permission (fn_check_write_permission; per_user->own_user_only, household->owner_only)
        })

    $ifOk = Build-If 'Write ok?' @(1100, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Save rejected' @(1320, 200) "={{ `$('Save section (atomic)').item.json.reason }}"

    $ret = Build-Return @(1320, 0) @(
        ,@('ok','true','boolean')
        ,@('plan_id', '={{ $json.plan_id }}', 'number')
        ,@('version', '={{ $json.version }}', 'number')
        ,@('draft_created', '={{ $json.draft_created }}', 'boolean')
        ,@('section_count', '={{ $json.section_count }}', 'number')
        ,@('sections', '={{ $json.sections }}', 'string')
    )

    $sticky = Build-Sticky 'Doc Save Section' @(120, -300) `
        'HITL + agent.fn_advisor_save_section (atomar)' `
        'Cross-agent (domain = fixer Binding-Input des Aufrufers, nie $fromAI). fn_advisor_save_section: findet/erzeugt den EINEN Draft je (Domain, Person) (Partial-UNIQUE NULLS NOT DISTINCT = DB-Gesetz; version = MAX+1, DB zählt) und upsertet die Sektion in interview_state. P0c PERSON-SCOPE: household (finance) -> person_id NULL; per_user (career, core.context_scopes) -> person_id = Sender (own_user_only) aus chat_id (fn_resolve_sender, NIE LLM); Permission via fn_check_write_permission (owner_only delegiert byte-gleich an fn_sender_is_member). Korrigierbar (leerer key/content, invalides section_data-JSON, unaufgelöster per_user-Sender) -> {ok:false, reason} -> Write ok?-Zweig reicht reason als Tool-Error. Gate-Message knapp: das Voll-Playback lief davor als Chat-Turn (Playback != Gate).' 280 440

    $nodes = @($trig, $summary, $reqApproval, $ifApproved, $retCancelled, $save, $ifOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Build Approval Summary' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Save section (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Save section (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Save rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_save_plan_section' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
