#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_case (WS-3, Break-Glass owner_info) ----------------------------
# Legt einen Ereignisfall (Todesfall/Vorsorgefall) an und instanziiert die Fristen-Checkliste
# (DB rechnet, LLM nie). HITL-Preview = ZUSAMMENFASSUNG (Fall-Typ, Person, Datum, Bundesland,
# Task-ZAHL je Phase — KEINE Voll-Liste, Trauer-UX); die Werte holt read-only estate.fn_preview_case
# VOR dem Gate. bundesland fail-closed in der fn (Parameter -> Config estate.general.bundesland ->
# sonst bundesland_required). adults_only-DB-Backstop + subject_is_sender-Guard in der fn. Cred=estate_rw.
function Build-EstateCreateCase {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('subject_person','case_type','event_date','knowledge_date','bundesland',
                            'tenant','employed','pension_relevant','has_will','no_poa','abroad_or_work_accident')

    # Die Intake-Booleans -> flags-jsonb (der Agent erfragt sie proaktiv; leer = false = Task sichtbar n.a.).
    $flagsExpr = '{ tenant: $(''Start'').item.json.tenant === ''true'', employed: $(''Start'').item.json.employed === ''true'', pension_relevant: $(''Start'').item.json.pension_relevant === ''true'', has_will: $(''Start'').item.json.has_will === ''true'', no_poa: $(''Start'').item.json.no_poa === ''true'', abroad_or_work_accident: $(''Start'').item.json.abroad_or_work_accident === ''true'' }'
    $caseParams = [ordered]@{
        chat_id           = '$(''Start'').item.json.chat_id'
        subject_person_id = '$(''Resolve Subject'').item.json.person_id'
        case_type         = '$(''Start'').item.json.case_type'
        event_date        = '$(''Start'').item.json.event_date'
        knowledge_date    = '$(''Start'').item.json.knowledge_date'
        bundesland        = '$(''Start'').item.json.bundesland'
        flags             = $flagsExpr
    }

    $resSubj = Build-Pg 'Resolve Subject' @(220, 0) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'subject_person', ''));" `
        ([ordered]@{ subject_person = '$(''Start'').item.json.subject_person' })
    $ifSubjBad = Build-If 'Subject invalid?' @(440, 0) `
        "={{ `$('Resolve Subject').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errSubj = Build-ToolError 'Subject unresolved' @(660, 200) `
        "=The affected person '{{ `$('Start').item.json.subject_person }}' could not be uniquely resolved. Name the household member clearly (you cannot open a case for someone outside the household)."

    $preview = Build-Pg 'Preview' @(660, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->'phase_counts' AS phase_counts, (r->>'total_open')::int AS total_open, r->>'supersede_case_id' AS supersede_case_id, r->>'case_type' AS case_type, r->>'bundesland' AS bundesland, r->>'event_date' AS event_date FROM estate.fn_preview_case(`$1::jsonb) AS r;" `
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
        (New-HitlLine 'estate.label.hint'            "'estate.note.supersede_incapacity'" -Kind key -If "$P.supersede_case_id")
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 200) 'the create_case action'
    $create = Build-Pg 'Create case (atomic)' @(1760, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_id')::bigint AS case_id, (r->>'total_open')::int AS total_open, r->>'case_type' AS case_type, r->>'superseded_case_id' AS superseded_case_id FROM estate.fn_create_case(`$1::jsonb) AS r;" `
        $caseParams
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Case rejected' @(2200, 200) "={{ `$('Create case (atomic)').item.json.reason }}"
    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('case_id', "={{ `$('Create case (atomic)').item.json.case_id }}", 'number')
        ,@('total_open', "={{ `$('Create case (atomic)').item.json.total_open }}", 'number')
        ,@('superseded_case_id', "={{ `$('Create case (atomic)').item.json.superseded_case_id }}", 'string')
    )
    $stickyFn = Build-Sticky 'Break-Glass owner_info + Fristen-Engine' @(660, -320) `
        'estate.fn_create_case (Preview -> Gate -> atomarer Write + Task-Instanziierung)' `
        'Subject-Name -> Slug (core.fn_resolve_person). estate.fn_preview_case (read-only, DIESELBE fn) validiert VOR dem Gate (adults_only, subject_is_sender via core.fn_person_chat_id, bundesland fail-closed [Parameter -> Config estate.general.bundesland -> bundesland_required], Datums-Guards, Dublette/Supersede) und liefert die Task-ZAHL je Phase für die HITL-Zusammenfassung (Trauer-UX: KEINE Voll-Liste). Nach Approve schreibt estate.fn_create_case atomar: Fall anlegen (+ AUTO-SUPERSEDE eines offenen incapacity-Falls bei death) + case_tasks aus task_templates (estate.fn_case_template_rows: Condition-Matrix + fan_out je special_asset; Fristen estate.fn_compute_due_date). Die Intake-Booleans (tenant/employed/...) werden zu case.flags. HITL owner_info (Break-Glass: der Owner kann der Betroffene sein).' 340 720
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
