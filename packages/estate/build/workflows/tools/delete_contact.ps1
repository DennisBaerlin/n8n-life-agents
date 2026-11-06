#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_delete_contact (WS-2, delete_ = Hard-DELETE) --------------------------
# Loescht einen Schluessel-Kontakt aus dem Register. Resolve (Name + optional Rolle) -> unique?
# VOR dem Gate. HITL owner_approval. adults_only-DB-Backstop. estate_rw.
function Build-EstateDeleteContact {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('name','role')

    $resolve = Build-Pg 'Resolve Contact' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_contact((`$1::jsonb)->>'name', NULLIF((`$1::jsonb)->>'role',''));" `
        ([ordered]@{ name = '$(''Start'').item.json.name'; role = '$(''Start'').item.json.role' })
    $ifBad = Build-If 'Contact unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Contact ambiguous' @(660, 200) `
        "=The contact '{{ `$('Start').item.json.name }}' resolves to {{ `$('Resolve Contact').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Contact').item.json.candidates) }}. Ask which one (add the role), or check the name."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_delete_contact laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_delete_contact' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Delete contact (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'contact_id')::bigint AS contact_id" `
        -Params ([ordered]@{
            chat_id = '$(''Start'').item.json.chat_id'
            name    = '$(''Start'').item.json.name'
            role    = '$(''Start'').item.json.role'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.delete_contact' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.contact' "$S.name")
        (New-HitlLine 'estate.label.role'    "$S.role" -Kind enum -Enum 'estate.enum.contact_role' -If "$S.role")
        (New-HitlNote -Key 'estate.note.entry_deleted')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the delete_contact action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Delete rejected' @(2420, 200) "={{ `$('Delete contact (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete contact (atomic)').item.json.action }}", 'string')
        ,@('contact_id', "={{ `$('Delete contact (atomic)').item.json.contact_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -240) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_delete_contact mit denselben Werten, immer zurückgerollt (das Löschen bleibt NICHT stehen). ok:false (z. B. Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'delete_ Hard-DELETE + adults_only' @(1980, -240) `
        'estate.fn_delete_contact (Hard-DELETE)' `
        'Resolve (Name + optional Rolle) -> Contact unique? VOR dem Gate (0/>1 -> Rückfrage). estate.fn_delete_contact löscht hart; re-resolvt intern; adults_only-DB-Backstop; not-found/ambig = RAISE.' 240 500
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Resolve Contact' ) ) }
        'Resolve Contact'         = @{ main = @( ,@( E 'Contact unique?' ) ) }
        'Contact unique?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Contact ambiguous' )
        ) }
        'Dry run'                 = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'             = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'  = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'        = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'               = @{ main = @(
            @( E 'Delete contact (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete contact (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_delete_contact' $nodes $conns `
        @{ Category = 'register' }
}
