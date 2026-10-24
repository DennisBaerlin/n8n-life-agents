#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_delete_special_asset (WS-2, delete_ = Hard-DELETE) --------------------
# Loescht einen Sonderfall-Stub (verkauft/abgegeben — Stubs haben keinen Lifecycle-Status; ein
# verkauftes Fahrzeug MUSS raus, sonst falsche WS-3-Checklisten-Tasks). Resolve (Beschreibung +
# optional Typ) -> unique? VOR dem Gate. HITL owner_approval. adults_only-DB-Backstop. estate_rw.
function Build-EstateDeleteSpecialAsset {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('description','asset_type')

    $resolve = Build-Pg 'Resolve Asset' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_special_asset((`$1::jsonb)->>'description', NULLIF((`$1::jsonb)->>'asset_type',''));" `
        ([ordered]@{ description = '$(''Start'').item.json.description'; asset_type = '$(''Start'').item.json.asset_type' })
    $ifBad = Build-If 'Asset unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Asset ambiguous' @(660, 200) `
        "=The special asset '{{ `$('Start').item.json.description }}' resolves to {{ `$('Resolve Asset').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Asset').item.json.candidates) }}. Ask which one (add the type), or check the description."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_delete_special_asset laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_delete_special_asset' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Delete asset (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'special_asset_id')::bigint AS special_asset_id" `
        -Params ([ordered]@{
            chat_id     = '$(''Start'').item.json.chat_id'
            description = '$(''Start'').item.json.description'
            asset_type  = '$(''Start'').item.json.asset_type'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.delete_special_asset' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.description' "$S.description")
        (New-HitlLine 'core.label.type'        "$S.asset_type" -Kind enum -Enum 'estate.enum.asset_type' -If "$S.asset_type")
        (New-HitlNote -Key 'estate.note.special_asset_deleted')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the delete_special_asset action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Delete rejected' @(2420, 200) "={{ `$('Delete asset (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete asset (atomic)').item.json.action }}", 'string')
        ,@('special_asset_id', "={{ `$('Delete asset (atomic)').item.json.special_asset_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -240) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_delete_special_asset mit denselben Werten, immer zurückgerollt (das Löschen bleibt NICHT stehen). ok:false (z. B. Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'delete_ Hard-DELETE + adults_only' @(1980, -240) `
        'estate.fn_delete_special_asset (Hard-DELETE)' `
        'Resolve (Beschreibung + optional Typ) -> Asset unique? VOR dem Gate (0/>1 -> Rückfrage). estate.fn_delete_special_asset löscht hart (Stubs haben keinen Lifecycle-Status -> ein verkauftes/abgegebenes Objekt MUSS raus, sonst falsche WS-3-Checklisten-Tasks); re-resolvt intern; adults_only-DB-Backstop; not-found/ambig = RAISE.' 250 540
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                 = @{ main = @( ,@( E 'Resolve Asset' ) ) }
        'Resolve Asset'         = @{ main = @( ,@( E 'Asset unique?' ) ) }
        'Asset unique?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Asset ambiguous' )
        ) }
        'Dry run'               = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'           = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'= @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'      = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'             = @{ main = @(
            @( E 'Delete asset (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete asset (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'             = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_delete_special_asset' $nodes $conns `
        @{ Category = 'register' }
}
