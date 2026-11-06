#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_provider_contract (WS-2, set_ = partielles Update) ----------------
# Aendert einen bestehenden Nicht-finance-Vertrag ("nicht gesendet = unveraendert"). Resolve
# (Anbieter + optional Kategorie) VOR dem Gate; 0/>1 -> Tool-Rueckfrage. HITL owner_approval
# (Floor: gegatetes Mitglied -> Owner-Vier-Augen). adults_only-DB-Backstop in der fn. estate_rw.
function Build-EstateSetProviderContract {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('provider','category','new_provider','new_category','customer_no',
                            'contract_no','contact_info','death_action','notes')

    $resolve = Build-Pg 'Resolve Contract' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_provider_contract((`$1::jsonb)->>'provider', NULLIF((`$1::jsonb)->>'category',''));" `
        ([ordered]@{ provider = '$(''Start'').item.json.provider'; category = '$(''Start'').item.json.category' })
    $ifBad = Build-If 'Contract unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Contract ambiguous' @(660, 200) `
        "=The contract '{{ `$('Start').item.json.provider }}' resolves to {{ `$('Resolve Contract').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Contract').item.json.candidates) }}. Ask the user which one (add the category), or check the name."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nur genannte Felder erscheinen (-If); der Hinweis "unveraendert" steht als Note darunter.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_set_provider_contract laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_provider_contract' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Set contract (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'provider_contract_id')::bigint AS provider_contract_id" `
        -Params ([ordered]@{
            chat_id             = '$(''Start'').item.json.chat_id'
            provider_contract_id = '$(''Resolve Contract'').item.json.id'
            new_provider        = '$(''Start'').item.json.new_provider'
            new_category        = '$(''Start'').item.json.new_category'
            customer_no         = '$(''Start'').item.json.customer_no'
            contract_no         = '$(''Start'').item.json.contract_no'
            contact_info        = '$(''Start'').item.json.contact_info'
            death_action        = '$(''Start'').item.json.death_action'
            notes               = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.set_provider_contract' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.contract'     "$S.provider")
        (New-HitlLine 'estate.label.new_provider' "$S.new_provider" -If "$S.new_provider")
        (New-HitlLine 'estate.label.new_category' "$S.new_category" -Kind enum -Enum 'estate.enum.contract_category' -If "$S.new_category")
        (New-HitlLine 'estate.label.customer_no'  "$S.customer_no" -If "$S.customer_no")
        (New-HitlLine 'estate.label.contract_no'  "$S.contract_no" -If "$S.contract_no")
        (New-HitlLine 'estate.label.contact'      "$S.contact_info" -If "$S.contact_info")
        (New-HitlLine 'estate.label.death_action' "$S.death_action" -Kind enum -Enum 'estate.enum.contract_action' -If "$S.death_action")
        (New-HitlLine 'estate.label.notes'        "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'estate.note.unchanged_fields')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the set_provider_contract action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2420, 200) "={{ `$('Set contract (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('provider_contract_id', "={{ `$('Set contract (atomic)').item.json.provider_contract_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_provider_contract mit denselben Werten, immer zurückgerollt. ok:false (z. B. Kategorie ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'set_ (partiell) + adults_only' @(1980, -260) `
        'estate.fn_set_provider_contract (partielles UPDATE)' `
        'Resolve (Anbieter + optional Kategorie) -> Contract unique? (0/>1 -> Rückfrage) VOR dem Gate. estate.fn_set_provider_contract updated partiell (COALESCE; nicht gesendet = unverändert); adults_only-DB-Backstop; not-found = RAISE (Backstop). updated_at pflegt der Touch-Trigger.' 240 500
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Contract' ) ) }
        'Resolve Contract'       = @{ main = @( ,@( E 'Contract unique?' ) ) }
        'Contract unique?'       = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Contract ambiguous' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set contract (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set contract (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_provider_contract' $nodes $conns `
        @{ Category = 'register' }
}
