#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_case (WS-3, Break-Glass owner_info) ----------------------------
# Legt einen Ereignisfall (Todesfall/Vorsorgefall) an und instanziiert die Fristen-Checkliste
# (DB rechnet, LLM nie). HITL-Preview = ZUSAMMENFASSUNG (Fall-Typ, Person, Datum, Bundesland,
# Task-ZAHL je Phase — KEINE Voll-Liste, Trauer-UX); die Werte holt read-only estate.fn_preview_case
# VOR dem Gate. bundesland fail-closed in der fn (Parameter -> Config estate.general.bundesland ->
# sonst bundesland_required). adults_only-DB-Backstop + subject_is_sender-Guard in der fn. Cred=estate_rw.
# WP3: Merkmale aus dem Register abgeleitet (nur Aussagen in flags), relative Daten einmal in der Preview aufgeloest.
function Build-EstateCreateCase {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('subject_person','case_type','event_date','knowledge_date','bundesland',
                            'tenant','employed','pension_relevant','has_will','no_poa','abroad_or_work_accident')

    # Die Intake-Merkmale -> flags-jsonb NUR mit ausdruecklichen Aussagen ('true'/'false'); leer = weglassen, dann
    # leitet die DB den Wert aus dem Register ab (estate.fn_case_register_flags, WP3) — der Agent fragt nur Unbekanntes.
    $flagsExpr = 'Object.fromEntries([''tenant'',''employed'',''pension_relevant'',''has_will'',''no_poa'',''abroad_or_work_accident''].filter(k => [''true'',''false''].includes(String($(''Start'').item.json[k] || '''').toLowerCase())).map(k => [k, String($(''Start'').item.json[k]).toLowerCase() === ''true'']))'
    $caseParams = [ordered]@{
        chat_id           = '$(''Start'').item.json.chat_id'
        subject_person_id = '$(''Resolve Subject'').item.json.person_id'
        case_type         = '$(''Start'').item.json.case_type'
        event_date        = '$(''Start'').item.json.event_date'
        knowledge_date    = '$(''Start'').item.json.knowledge_date'
        bundesland        = '$(''Start'').item.json.bundesland'
        flags             = $flagsExpr
    }
    # Der Write uebernimmt die in der Preview AUFGELOESTEN Daten ("yesterday" -> Datum): Karte = Speicher, auch wenn
    # erst nach Mitternacht getippt wird (die gesetzlichen Fristen haengen am Datum).
    $writeParams = [ordered]@{}
    foreach ($k in $caseParams.Keys) { $writeParams[$k] = $caseParams[$k] }
    $writeParams['event_date']     = '$(''Preview'').item.json.event_date'
    $writeParams['knowledge_date'] = '$(''Preview'').item.json.knowledge_date'

    $resSubj = Build-ResolvePerson 'Resolve Subject' @(220, 0) 'subject_person'
    $ifSubjBad = Build-If 'Subject invalid?' @(440, 0) `
        "={{ `$('Resolve Subject').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errSubj = Build-ToolError 'Subject unresolved' @(660, 200) `
        "=The affected person '{{ `$('Start').item.json.subject_person }}' could not be uniquely resolved. Name the household member clearly (you cannot open a case for someone outside the household)."

    $preview = Build-Pg 'Preview' @(660, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->'phase_counts' AS phase_counts, (r->>'total_open')::int AS total_open, r->>'supersede_case_id' AS supersede_case_id, r->>'case_type' AS case_type, r->>'bundesland' AS bundesland, r->>'event_date' AS event_date, r->>'knowledge_date' AS knowledge_date, r->'intake_facts' AS intake_facts, r->'unknown_flags' AS unknown_flags FROM estate.fn_preview_case(`$1::jsonb) AS r;" `
        $caseParams
    $ifPrevOk = Build-If 'Preview ok?' @(880, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errPrev = Build-ToolError 'Preview rejected' @(1100, 200) "={{ `$('Preview').item.json.reason }}"

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Die Task-Zahl je Phase ist DB-berechnet (Preview); die Phasen-Liste entsteht als Liste typisierter tpl-Werte.
    $P = "`$('Preview').item.json"
    $phaseKeys = "['immediate','first_week','first_month','later']"
    $phaseHas = "$phaseKeys.some(k => ($P.phase_counts || {})[k])"
    $phaseList = "{ kind: 'list', value: $phaseKeys.filter(k => ($P.phase_counts || {})[k]).map(k => ({ kind: 'tpl', value: 'estate.tpl.phase_count', params: { phase: { kind: 'enum', value: k, enum: 'estate.enum.case_phase' }, n: $P.phase_counts[k] } })) }"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'estate.hitl.create_case' -Lines @(
        (New-HitlLine 'estate.label.case_type'       "$P.case_type" -Kind enum -Enum 'estate.enum.case_type')
        (New-HitlLine 'estate.label.affected_person' "(`$('Resolve Subject').item.json.full_name || `$('Start').item.json.subject_person)")
        (New-HitlLine 'estate.label.event_date'      "$P.event_date" -Kind date)
        (New-HitlLine 'estate.label.state'           "$P.bundesland" -Kind enum -Enum 'estate.enum.state')
        (New-HitlLine 'estate.label.task_checklist'  "($phaseHas ? 'estate.tpl.checklist_phases' : 'estate.tpl.checklist')" -Kind tpl `
            -Params @{ n = "($P.total_open || 0)"; phases = $phaseList })
        # WP3: was laut Register bzw. Angabe fuer den Fall gilt (DB-abgeleitet, Preview) — leer -> Zeile entfaellt
        (New-HitlLine 'estate.label.intake_facts'    "($P.intake_facts || []).map(k => ({ kind: 'enum', value: k, enum: 'estate.enum.case_flag' }))" -Kind list -OmitEmpty)
        (New-HitlLine 'estate.label.hint'            "'estate.note.supersede_incapacity'" -Kind key -If "$P.supersede_case_id")
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 200) 'the create_case action'
    $create = Build-Pg 'Create case (atomic)' @(1760, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_id')::bigint AS case_id, (r->>'total_open')::int AS total_open, r->>'case_type' AS case_type, r->>'superseded_case_id' AS superseded_case_id FROM estate.fn_create_case(`$1::jsonb) AS r;" `
        $writeParams
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Case rejected' @(2200, 200) "={{ `$('Create case (atomic)').item.json.reason }}"
    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('case_id', "={{ `$('Create case (atomic)').item.json.case_id }}", 'number')
        ,@('total_open', "={{ `$('Create case (atomic)').item.json.total_open }}", 'number')
        ,@('superseded_case_id', "={{ `$('Create case (atomic)').item.json.superseded_case_id }}", 'string')
        # WP3: Merkmale, die weder Register noch Angabe kennen -> der Agent fragt sie EINMAL gesammelt (dann tool_set_case)
        ,@('unknown_flags', "={{ `$('Preview').item.json.unknown_flags || [] }}", 'array')
    )
    $stickyFn = Build-Sticky 'Break-Glass owner_info + Fristen-Engine' @(660, -320) `
        'estate.fn_create_case (Preview -> Gate -> atomarer Write + Task-Instanziierung)' `
        'Subject-Name -> Slug (core.fn_resolve_person). estate.fn_preview_case (read-only, DIESELBE fn) validiert VOR dem Gate (adults_only, subject_is_sender via core.fn_person_chat_id, bundesland fail-closed [Parameter -> Config estate.general.bundesland -> bundesland_required], Datums-Guards, Dublette/Supersede) und liefert die Task-ZAHL je Phase für die HITL-Zusammenfassung (Trauer-UX: KEINE Voll-Liste). Nach Approve schreibt estate.fn_create_case atomar: Fall anlegen (+ AUTO-SUPERSEDE eines offenen incapacity-Falls bei death) + case_tasks aus task_templates (estate.fn_case_template_rows: Condition-Matrix + fan_out je special_asset; Fristen estate.fn_compute_due_date). Intake-Merkmale (tenant/employed/...): nur ausdrückliche Aussagen (true/false) gehen in case.flags; den Rest leitet estate.fn_case_register_flags aus dem Register ab (Testament, Vollmacht, Arbeitgeber, Rentennummer, Vermieter). Die Preview liefert intake_facts (Karte) und unknown_flags (Rückgabe: der Agent fragt nur das). Relative Daten (yesterday, -3 days) löst die Preview EINMAL auf, der Write übernimmt genau diese Daten. HITL owner_info (Break-Glass: der Owner kann der Betroffene sein).' 340 760
    $nodes = @($trig, $resSubj, $ifSubjBad, $errSubj, $preview, $ifPrevOk, $errPrev, $summary,
               $reqApproval, $ifApproved, $retCancelled, $create, $ifWriteOk, $errWrite, $ret, $stickyFn)
    $conns = [ordered]@{
        'Start'                = @{ main = @( ,@( E 'Resolve Subject' ) ) }
        'Resolve Subject'      = @{ main = @( ,@( E 'Subject invalid?' ) ) }
        'Subject invalid?'     = @{ main = @(
            @( E 'Subject unresolved' ),
            @( E 'Preview' )
        ) }
        'Preview'              = @{ main = @( ,@( E 'Preview ok?' ) ) }
        'Preview ok?'          = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Preview rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'     = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'            = @{ main = @(
            @( E 'Create case (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create case (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'            = @{ main = @(
            @( E 'Return' ),
            @( E 'Case rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_create_case' $nodes $conns `
        @{ Category = 'register' }
}
