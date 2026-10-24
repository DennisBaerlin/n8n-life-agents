#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_case (WS-3, HITL owner_approval, partielles UPDATE eines OFFENEN Falls) ---
# Aendert knowledge_date / bundesland / flags eines offenen Falls und ZIEHT DIE FRISTEN NACH
# (Recompute offener Tasks + ADDITIVER Reconcile: neu zutreffende Templates -> open; nichts auto-n.a.).
# Die flags sind ADDITIV: nur explizit auf true gesetzte Merkmale werden gemergt (kein Un-Set).
# adults_only-DB-Backstop in der fn. Cred = estate_rw.
function Build-EstateSetCase {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('case_id','knowledge_date','bundesland',
                            'tenant','employed','pension_relevant','has_will','no_poa','abroad_or_work_accident')

    # Nur TRUE-Merkmale in die flags (additiver Merge; leere/false werden weggelassen -> kein Un-Set).
    $setFlagsExpr = 'Object.fromEntries([''tenant'',''employed'',''pension_relevant'',''has_will'',''no_poa'',''abroad_or_work_accident''].filter(k => $(''Start'').item.json[k] === ''true'').map(k => [k, true]))'
    $setParams = [ordered]@{
        chat_id        = '$(''Start'').item.json.chat_id'
        case_id        = '$(''Start'').item.json.case_id'
        knowledge_date = '$(''Start'').item.json.knowledge_date'
        bundesland     = '$(''Start'').item.json.bundesland'
        flags          = $setFlagsExpr
    }

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nicht genannte Felder zeigen "unveraendert"; die Merkmale erscheinen als Liste lesbarer Enum-Werte.
    $S = "`$('Start').item.json"
    $flagKeys = "['tenant','employed','pension_relevant','has_will','no_poa','abroad_or_work_accident']"
    # "DB ist das Gesetz": estate.fn_set_case laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_case' -DryPos @(220, 0) -WritePos @(1540, 0) `
        -WriteName 'Set case (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_id')::bigint AS case_id, (r->>'total_open')::int AS total_open" `
        -Params $setParams
    $summary = New-HitlSummary -Pos @(880, 0) -Title 'estate.hitl.set_case' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.case_no'            "$S.case_id")
        (New-HitlLine 'estate.label.new_knowledge_date' "$S.knowledge_date" -Kind date -If "$S.knowledge_date")
        (New-HitlLine 'estate.label.new_knowledge_date' "'estate.value.unchanged'" -Kind key -If "!$S.knowledge_date")
        (New-HitlLine 'estate.label.new_state'          "$S.bundesland" -Kind enum -Enum 'estate.enum.state' -If "$S.bundesland")
        (New-HitlLine 'estate.label.new_state'          "'estate.value.unchanged'" -Kind key -If "!$S.bundesland")
        (New-HitlLine 'estate.label.new_flags'          "$flagKeys.filter(k => $S[k] === 'true').map(k => ({ kind: 'enum', value: k, enum: 'estate.enum.case_flag' }))" -Kind list)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1100, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1320, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1540, 200) 'the set_case action'
    $ifWriteOk = Build-If 'Write ok?' @(1760, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set case rejected' @(1980, 200) "={{ `$('Set case (atomic)').item.json.reason }}"
    $ret = Build-Return @(1980, 0) @(
        ,@('ok','true','boolean')
        ,@('case_id', "={{ `$('Set case (atomic)').item.json.case_id }}", 'number')
        ,@('total_open', "={{ `$('Set case (atomic)').item.json.total_open }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(220, -280) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_case mit denselben Werten, immer zurückgerollt (Fristen-Recompute und Task-Reconcile bleiben NICHT stehen). ok:false (z. B. Fall nicht offen, Bundesland ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'HITL owner_approval + additiver Reconcile' @(1540, -280) `
        'estate.fn_set_case (partielles UPDATE offener Fall -> Fristen-Recompute + Reconcile)' `
        'Ändert knowledge_date/bundesland/flags eines OFFENEN Falls. estate.fn_set_case ruft danach estate.fn_instantiate_case_tasks (ON CONFLICT): due_date aller offenen Tasks neu (bundesland -> Werktage, knowledge -> kenntnis-verankerte Fristen), und eine not_applicable-Task, deren Condition jetzt zutrifft, kippt auf open (additiv). NICHTS wird auto-n.a. (open/done bleiben). flags additiv (nur true-Merkmale gemergt). adults_only-DB-Backstop.' 300 640
    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set case (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set case (atomic)'      = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set case rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_case' $nodes $conns `
        @{ Category = 'register' }
}
