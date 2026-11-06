#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_record_plan_wish (CROSS-AGENT, HITL owner_info) — Plan teilen, 2026-10-28 ---------------------------
# "Wunsch an den Owner": ein erwachsenes Mitglied (partner) schickt dem Owner einen Aenderungswunsch zum AKTIVEN
# Haushalts-Plan der Domain. Aendert den Plan NICHT (der Owner entscheidet). HITL-Stufe owner_info: das Mitglied
# bestaetigt die Karte in seiner Sprache, der Owner bekommt danach die Info mit dem Wortlaut in SEINER Sprache — das
# ist die Benachrichtigung (kein eigener Owner-Send). domain ist beim Aufrufer FIXER Binding-Input (nie $fromAI).
function Build-RecordPlanWish {
    $trig = Build-Trigger @('domain', 'wish_text')

    # "DB ist das Gesetz": agent.fn_record_plan_wish laeuft als Probelauf VOR der Karte (nur Partner, aktiver Plan,
    # Laenge); derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'agent.fn_record_plan_wish' -DryPos @(220, 0) -WritePos @(1320, 0) `
        -WriteName 'Record wish (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'wish_id')::int AS wish_id, (r->>'plan_version')::int AS plan_version" `
        -Params ([ordered]@{
            domain    = '$(''Start'').item.json.domain'
            chat_id   = '$(''Start'').item.json.chat_id'
            wish_text = '$(''Start'').item.json.wish_text'
        })
    $S = "`$('Start').item.json"
    $D = "`$('Dry run').item.json.r"
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'core.hitl.record_plan_wish' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.version' "$D.plan_version")
        (New-HitlLine 'core.label.wish'    "$S.wish_text")
        (New-HitlNote -Key 'core.note.plan_wish_owner_decides')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the record_plan_wish action'
    $ifWriteOk = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Wish rejected' @(1760, 200) "={{ `$('Record wish (atomic)').item.json.reason }}"
    $ret = Build-Return @(1760, 0) @(
        ,@('ok','true','boolean')
        ,@('wish_id', "={{ `$('Record wish (atomic)').item.json.wish_id }}", 'number')
        ,@('plan_version', "={{ `$('Record wish (atomic)').item.json.plan_version }}", 'number')
    )
    $sticky = Build-Sticky 'Doc Wunsch an den Owner' @(120, -340) `
        'HITL owner_info + agent.fn_record_plan_wish (atomar, 1 INSERT)' `
        'Dry run = agent.fn_record_plan_wish mit denselben Werten, immer zurückgerollt (core.fn_dry_run). ok:false (nicht Partner/unbekannt, kein aktiver Haushalts-Plan der Domain, leer, über 2000 Zeichen) -> Dry run rejected: KEINE Karte, reason an den Berater. ok:true -> Karte (Version aus dem Probelauf, Wortlaut, Hinweis "der Owner entscheidet"). Gate-Stufe owner_info (approval_matrix core): das Mitglied bestätigt, danach bekommt der Owner die Info mit dem Wortlaut in seiner Sprache = die Benachrichtigung. Write: INSERT agent.advisor_plan_wishes (plan_id = aktive Version, Wortlaut getrimmt in Originalsprache, CHECK nicht leer/<= 2000 als Backstop). Der Plan selbst bleibt unverändert.' 320 520
    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $sticky)
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
            @( E 'Record wish (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Record wish (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Wish rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_record_plan_wish' $nodes $conns @{ Internal = $true }   # intern: Berater-Werkzeug, keine eigene Nutzer-Capability
}
