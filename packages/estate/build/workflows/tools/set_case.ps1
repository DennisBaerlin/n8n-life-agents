#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_case (WS-3, HITL owner_approval, partielles UPDATE eines OFFENEN Falls) ---
# Aendert knowledge_date / bundesland / flags eines offenen Falls und ZIEHT DIE FRISTEN NACH
# (Recompute offener Tasks + Reconcile in beide Richtungen, nur fuer System-Status; Nutzer-Status bleiben).
# WP3: Merkmal 'true'/'false' = Aussage des Nutzers (schlaegt das Register), 'register' = Aussage vergessen -> wieder
# Ableitung aus dem Register (null-Merge in fn_set_case). Relatives knowledge_date loest der Probelauf auf (effective).
# adults_only-DB-Backstop in der fn. Cred = estate_rw.
function Build-EstateSetCase {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('case_id','knowledge_date','bundesland',
                            'tenant','employed','pension_relevant','has_will','no_poa','abroad_or_work_accident')

    # true/false = Aussage, register = Aussage vergessen (null), leer = unveraendert (Key fehlt).
    $setFlagsExpr = 'Object.fromEntries([''tenant'',''employed'',''pension_relevant'',''has_will'',''no_poa'',''abroad_or_work_accident''].map(k => [k, String($(''Start'').item.json[k] || '''').toLowerCase()]).filter(e => [''true'',''false'',''register''].includes(e[1])).map(e => [e[0], e[1] === ''register'' ? null : e[1] === ''true'']))'
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
    # Merkmal-Liste je Aussage (true/false/register) als lesbare Enums; leer -> Zeile entfaellt (-OmitEmpty).
    $flagList = "$flagKeys.filter(k => String($S[k] || '').toLowerCase() === '{0}').map(k => ({{ kind: 'enum', value: k, enum: 'estate.enum.case_flag' }}))"
    $D = "`$('Dry run').item.json.r"   # Probelauf-Ergebnis: effective.knowledge_date = das von der DB aufgeloeste Datum
    # "DB ist das Gesetz": estate.fn_set_case laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_case' -DryPos @(220, 0) -WritePos @(1540, 0) `
        -WriteName 'Set case (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_id')::bigint AS case_id, (r->>'total_open')::int AS total_open, r->>'case_status' AS case_status" `
        -Params $setParams
    $summary = New-HitlSummary -Pos @(880, 0) -Title 'estate.hitl.set_case' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.case_no'            "$S.case_id")
        (New-HitlLine 'estate.label.new_knowledge_date' "$D.effective && $D.effective.knowledge_date" -Kind date -If "$S.knowledge_date")
        (New-HitlLine 'estate.label.new_knowledge_date' "'estate.value.unchanged'" -Kind key -If "!$S.knowledge_date")
        (New-HitlLine 'estate.label.new_state'          "$S.bundesland" -Kind enum -Enum 'estate.enum.state' -If "$S.bundesland")
        (New-HitlLine 'estate.label.new_state'          "'estate.value.unchanged'" -Kind key -If "!$S.bundesland")
        (New-HitlLine 'estate.label.flags_apply'         ($flagList -f 'true') -Kind list -OmitEmpty)
        (New-HitlLine 'estate.label.flags_not_apply'     ($flagList -f 'false') -Kind list -OmitEmpty)
        (New-HitlLine 'estate.label.flags_from_register' ($flagList -f 'register') -Kind list -OmitEmpty)
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
        # Der Abgleich kann den Fall schliessen (letzte offene Task n.a.) -> der Agent sagt es statt den Fall weiterzufuehren
        ,@('case_status', "={{ `$('Set case (atomic)').item.json.case_status }}", 'string')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(220, -280) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_case mit denselben Werten, immer zurückgerollt (Fristen-Recompute und Task-Reconcile bleiben NICHT stehen). ok:false (z. B. Fall nicht offen, Bundesland ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'HITL owner_approval + Reconcile (nur System-Status)' @(1540, -280) `
        'estate.fn_set_case (partielles UPDATE offener Fall -> Fristen-Recompute + Reconcile)' `
        'Ändert knowledge_date/bundesland/Merkmale eines OFFENEN Falls. Merkmal true/false = Aussage des Nutzers (schlägt das Register), register = Aussage vergessen (wieder estate.fn_case_register_flags). estate.fn_instantiate_case_tasks rechnet danach alle offenen Fristen neu und gleicht die Tasks in BEIDE Richtungen ab, aber nur Status, die das System gesetzt hat (status_source=system): neu zutreffend -> open, nicht mehr zutreffend -> n.a.; done und ein vom Nutzer gesetztes "trifft nicht zu" bleiben. Relatives knowledge_date löst der Probelauf auf (effective) und der Write übernimmt genau dieses Datum. adults_only-DB-Backstop.' 300 680
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
