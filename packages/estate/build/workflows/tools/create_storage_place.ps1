#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_storage_place (WS-2, create_ + Pflicht-Dubletten-Node) --------
# Legt eine NEUE Fundstelle an (Tresor/Bankschliessfach/Ordner/digital). access_hint = Fundort-
# Verweis OHNE Codes/PINs. HITL owner_info. adults_only-DB-Backstop in der fn. Cred = estate_rw.
function Build-EstateCreateStoragePlace {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('owner_person','name','kind','location','access_hint','notes')

    $checkDup = Build-Pg 'Check duplicate' @(220, -200) `
        "=SELECT hit_count FROM estate.fn_resolve_storage_place((`$1::jsonb)->>'name');" `
        ([ordered]@{ name = '$(''Start'').item.json.name' })
    $ifExists = Build-If 'Place exists?' @(440, -200) `
        "={{ `$('Check duplicate').item.json.hit_count }}" '1' 'largerEqual' 'number'
    $errExists = Build-ToolError 'Place exists' @(660, -300) `
        "=A storage place named '{{ `$('Start').item.json.name }}' already exists. I will NOT create a duplicate. Use the update tool to change it, or a different name."

    $resPerson = Build-Pg 'Resolve Person' @(220, 180) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'owner_person', ''));" `
        ([ordered]@{ owner_person = '$(''Start'').item.json.owner_person' })
    $ifPersonBad = Build-If 'Person invalid?' @(440, 180) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errPerson = Build-ToolError 'Person unresolved' @(660, 320) `
        "=The person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved. Ask which household member, or leave empty for a household place."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    # "DB ist das Gesetz": estate.fn_create_storage_place laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_create_storage_place' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create place (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'storage_place_id')::bigint AS storage_place_id" `
        -Params ([ordered]@{
            chat_id         = '$(''Start'').item.json.chat_id'
            owner_person_id = '$(''Resolve Person'').item.json.person_id'
            name            = '$(''Start'').item.json.name'
            kind            = '$(''Start'').item.json.kind'
            location        = '$(''Start'').item.json.location'
            access_hint     = '$(''Start'').item.json.access_hint'
            notes           = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.create_storage_place' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.name'          "$S.name")
        (New-HitlLine 'estate.label.kind'        "$S.kind" -Kind enum -Enum 'estate.enum.storage_kind')
        (New-HitlLine 'core.label.person'        "$RP.full_name" -If "$RP.full_name")
        (New-HitlLine 'core.label.person'        "'estate.value.household'" -Kind key -If "!$RP.full_name")
        (New-HitlLine 'estate.label.location'    "$S.location" -OmitEmpty)
        (New-HitlLine 'estate.label.access_hint' "$S.access_hint" -OmitEmpty)
        (New-HitlLine 'estate.label.notes'       "$S.notes" -OmitEmpty)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the create_storage_place action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Place rejected' @(2420, 200) "={{ `$('Create place (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('storage_place_id', "={{ `$('Create place (atomic)').item.json.storage_place_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -320) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_create_storage_place mit denselben Werten, immer zurückgerollt. ok:false (z. B. Pflichtfeld fehlt, Art ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'create_ + adults_only + Fundort-Regel' @(1980, -280) `
        'estate.fn_create_storage_place (atomar, 1 INSERT) — access_hint ist NIE ein Code' `
        'Pflicht-Dubletten-Node (Name) blockt VOR dem Gate. estate.fn_create_storage_place schreibt atomar; adults_only-DB-Backstop. access_hint = WIE man rankommt (Fundort-Verweis), NIE Codes/PINs (Description + Instructions tragen die Hard-Rule). Fundstellen sind FK-Ziel der directives (RESTRICT) -> es gibt bewusst KEIN delete_storage_place (Umwidmung via set_storage_place).' 260 560
    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                 = @{ main = @( ,@( E 'Check duplicate' ) ) }
        'Check duplicate'       = @{ main = @( ,@( E 'Place exists?' ) ) }
        'Place exists?'         = @{ main = @(
            @( E 'Place exists' ),
            @( E 'Resolve Person' )
        ) }
        'Resolve Person'        = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'       = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'               = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'           = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'= @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'      = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'             = @{ main = @(
            @( E 'Create place (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create place (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'             = @{ main = @(
            @( E 'Return' ),
            @( E 'Place rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_create_storage_place' $nodes $conns `
        @{ Category = 'register' }
}
