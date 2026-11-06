#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_delete_digital_account (WS-2, delete_ = Hard-DELETE) ------------------
# Loescht ein Konto des digitalen Nachlasses aus dem Register. Resolve (Anbieter + optional
# Nutzername) -> unique? VOR dem Gate. HITL owner_approval. adults_only-DB-Backstop. estate_rw.
function Build-EstateDeleteDigitalAccount {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('provider','username')

    $resolve = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_digital_account((`$1::jsonb)->>'provider', NULLIF((`$1::jsonb)->>'username',''));" `
        ([ordered]@{ provider = '$(''Start'').item.json.provider'; username = '$(''Start'').item.json.username' })
    $ifBad = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=The account '{{ `$('Start').item.json.provider }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask which one (add the username), or check the provider."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_delete_digital_account laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_delete_digital_account' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Delete account (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'digital_account_id')::bigint AS digital_account_id" `
        -Params ([ordered]@{
            chat_id  = '$(''Start'').item.json.chat_id'
            provider = '$(''Start'').item.json.provider'
            username = '$(''Start'').item.json.username'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.delete_digital_account' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.provider' "$S.provider")
        (New-HitlLine 'estate.label.username' "$S.username" -If "$S.username")
        (New-HitlNote -Key 'estate.note.entry_deleted')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the delete_digital_account action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Delete rejected' @(2420, 200) "={{ `$('Delete account (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete account (atomic)').item.json.action }}", 'string')
        ,@('digital_account_id', "={{ `$('Delete account (atomic)').item.json.digital_account_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -240) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_delete_digital_account mit denselben Werten, immer zurückgerollt (das Löschen bleibt NICHT stehen). ok:false (z. B. Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'delete_ Hard-DELETE + adults_only' @(1980, -240) `
        'estate.fn_delete_digital_account (Hard-DELETE)' `
        'Resolve (Anbieter + optional Nutzername) -> Account unique? VOR dem Gate (0/>1 -> Rückfrage). estate.fn_delete_digital_account löscht hart; re-resolvt intern; adults_only-DB-Backstop; not-found/ambig = RAISE.' 240 500
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'         = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Account ambiguous' )
        ) }
        'Dry run'                 = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'             = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'  = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'        = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'               = @{ main = @(
            @( E 'Delete account (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete account (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_delete_digital_account' $nodes $conns `
        @{ Category = 'register' }
}
