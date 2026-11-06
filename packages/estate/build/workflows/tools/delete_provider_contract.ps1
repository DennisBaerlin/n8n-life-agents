#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_delete_provider_contract (WS-2, delete_ = Hard-DELETE) ----------------
# Loescht einen Vertrag aus dem Register (beendet/Fehlanlage). Resolve (Anbieter + optional
# Kategorie) -> unique? VOR dem Gate (0/>1 -> Rueckfrage, kein RAISE/Owner-Alert). HITL
# owner_approval. adults_only-DB-Backstop in der fn. estate_rw.
function Build-EstateDeleteProviderContract {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('provider','category')

    $resolve = Build-Pg 'Resolve Contract' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_provider_contract((`$1::jsonb)->>'provider', NULLIF((`$1::jsonb)->>'category',''));" `
        ([ordered]@{ provider = '$(''Start'').item.json.provider'; category = '$(''Start'').item.json.category' })
    $ifBad = Build-If 'Contract unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Contract ambiguous' @(660, 200) `
        "=The contract '{{ `$('Start').item.json.provider }}' resolves to {{ `$('Resolve Contract').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Contract').item.json.candidates) }}. Ask which one (add the category), or check the name."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_delete_provider_contract laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_delete_provider_contract' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Delete contract (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'provider_contract_id')::bigint AS provider_contract_id" `
        -Params ([ordered]@{
            chat_id  = '$(''Start'').item.json.chat_id'
            provider = '$(''Start'').item.json.provider'
            category = '$(''Start'').item.json.category'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.delete_provider_contract' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.provider' "$S.provider")
        (New-HitlLine 'estate.label.category' "$S.category" -Kind enum -Enum 'estate.enum.contract_category' -If "$S.category")
        (New-HitlNote -Key 'estate.note.entry_deleted')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the delete_provider_contract action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Delete rejected' @(2420, 200) "={{ `$('Delete contract (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete contract (atomic)').item.json.action }}", 'string')
        ,@('provider_contract_id', "={{ `$('Delete contract (atomic)').item.json.provider_contract_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -240) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_delete_provider_contract mit denselben Werten, immer zurückgerollt (das Löschen bleibt NICHT stehen). ok:false (z. B. Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'delete_ Hard-DELETE + adults_only' @(1980, -240) `
        'estate.fn_delete_provider_contract (Hard-DELETE)' `
        'Resolve (Anbieter + optional Kategorie) -> Contract unique? VOR dem Gate (0/>1 -> Rückfrage; kein RAISE/Owner-Alert). estate.fn_delete_provider_contract löscht hart (keine FK-Referenzen); re-resolvt intern; adults_only-DB-Backstop; not-found/ambig = RAISE (Backstop hinter dem Tool-Resolve).' 240 500
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Resolve Contract' ) ) }
        'Resolve Contract'         = @{ main = @( ,@( E 'Contract unique?' ) ) }
        'Contract unique?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Contract ambiguous' )
        ) }
        'Dry run'                  = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'              = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Delete contract (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete contract (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_delete_provider_contract' $nodes $conns `
        @{ Category = 'register' }
}
