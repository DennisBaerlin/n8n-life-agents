#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_provider_contract (WS-2, create_ + Pflicht-Dubletten-Node) ----
# Legt einen NEUEN Nicht-finance-Vertrag im Register an (Energie/Telekom/Abo/Verein/Wohnen).
# HITL owner_info. adults_only-DB-Backstop in der fn. Cred = estate_rw.
function Build-EstateCreateProviderContract {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('owner_person','category','provider','customer_no','contract_no',
                            'contact_info','death_action','notes')

    # Dubletten-Backstop (Anbieter + Kategorie) via Resolver — Pflicht-Node vor dem Gate (create_).
    $checkDup = Build-Pg 'Check duplicate' @(220, -200) `
        "=SELECT hit_count FROM estate.fn_resolve_provider_contract((`$1::jsonb)->>'provider', (`$1::jsonb)->>'category');" `
        ([ordered]@{ provider = '$(''Start'').item.json.provider'; category = '$(''Start'').item.json.category' })
    $ifExists = Build-If 'Contract exists?' @(440, -200) `
        "={{ `$('Check duplicate').item.json.hit_count }}" '1' 'largerEqual' 'number'
    $errExists = Build-ToolError 'Contract exists' @(660, -300) `
        "=A provider contract for '{{ `$('Start').item.json.provider }}' in this category already exists. I will NOT create a duplicate. Use the update tool to change it, or a different category."

    $resPerson = Build-Pg 'Resolve Person' @(220, 180) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'owner_person', ''));" `
        ([ordered]@{ owner_person = '$(''Start'').item.json.owner_person' })
    $ifPersonBad = Build-If 'Person invalid?' @(440, 180) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errPerson = Build-ToolError 'Person unresolved' @(660, 320) `
        "=The person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved. Ask which household member, or leave empty for a household contract."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Offene Todesfall-Aktion (NULL) -> Enum-Wert 'open' ("OFFEN").
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    # "DB ist das Gesetz": estate.fn_create_provider_contract laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_create_provider_contract' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create contract (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'provider_contract_id')::bigint AS provider_contract_id" `
        -Params ([ordered]@{
            chat_id         = '$(''Start'').item.json.chat_id'
            owner_person_id = '$(''Resolve Person'').item.json.person_id'
            category        = '$(''Start'').item.json.category'
            provider        = '$(''Start'').item.json.provider'
            customer_no     = '$(''Start'').item.json.customer_no'
            contract_no     = '$(''Start'').item.json.contract_no'
            contact_info    = '$(''Start'').item.json.contact_info'
            death_action    = '$(''Start'').item.json.death_action'
            notes           = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.create_provider_contract' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.provider'     "$S.provider")
        (New-HitlLine 'estate.label.category'     "$S.category" -Kind enum -Enum 'estate.enum.contract_category')
        (New-HitlLine 'core.label.person'         "$RP.full_name" -If "$RP.full_name")
        (New-HitlLine 'core.label.person'         "'estate.value.household'" -Kind key -If "!$RP.full_name")
        (New-HitlLine 'estate.label.customer_no'  "$S.customer_no" -OmitEmpty)
        (New-HitlLine 'estate.label.contract_no'  "$S.contract_no" -OmitEmpty)
        (New-HitlLine 'estate.label.contact'      "$S.contact_info" -OmitEmpty)
        (New-HitlLine 'estate.label.death_action' "($S.death_action || 'open')" -Kind enum -Enum 'estate.enum.contract_action')
        (New-HitlLine 'estate.label.notes'        "$S.notes" -OmitEmpty)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the create_provider_contract action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Contract rejected' @(2420, 200) "={{ `$('Create contract (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('provider_contract_id', "={{ `$('Create contract (atomic)').item.json.provider_contract_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -320) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_create_provider_contract mit denselben Werten, immer zurückgerollt. ok:false (z. B. Pflichtfeld fehlt, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'create_ + adults_only-Backstop' @(1980, -280) `
        'estate.fn_create_provider_contract (atomar, 1 INSERT)' `
        'Pflicht-Dubletten-Node (Check duplicate -> Contract exists?) BLOCKT gleicher Anbieter+Kategorie VOR dem Gate (create_-Vertrag). estate.fn_create_provider_contract schreibt atomar; adults_only-DB-Backstop (Kind -> {ok:false}). death_action NULL = bewusst OFFENER Gap (Gap-Analyse nudgt). Lose finance-Referenz OHNE FK (stale = Gap-Anzeige, nie Crash). updated_at pflegt der Touch-Trigger.' 240 520
    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Check duplicate' ) ) }
        'Check duplicate'          = @{ main = @( ,@( E 'Contract exists?' ) ) }
        'Contract exists?'         = @{ main = @(
            @( E 'Contract exists' ),
            @( E 'Resolve Person' )
        ) }
        'Resolve Person'           = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'          = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                  = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'              = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Create contract (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create contract (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Contract rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_create_provider_contract' $nodes $conns `
        @{ Category = 'register' }
}
