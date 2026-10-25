#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_special_asset (WS-2, create_ + Pflicht-Dubletten-Node) --------
# Legt einen NEUEN Sonderfall-Stub an (Owner-Entscheid 7: erkennen + ehrlich verweisen).
# Geschlossene Typ-Liste OHNE other (jeder Typ mappt auf eine WS-3-Checklisten-Condition).
# HITL owner_info. adults_only-DB-Backstop in der fn. Cred = estate_rw.
function Build-EstateCreateSpecialAsset {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('owner_person','asset_type','description','notes')

    $checkDup = Build-Pg 'Check duplicate' @(220, -200) `
        "=SELECT hit_count FROM estate.fn_resolve_special_asset((`$1::jsonb)->>'description', (`$1::jsonb)->>'asset_type');" `
        ([ordered]@{ description = '$(''Start'').item.json.description'; asset_type = '$(''Start'').item.json.asset_type' })
    $ifExists = Build-If 'Asset exists?' @(440, -200) `
        "={{ `$('Check duplicate').item.json.hit_count }}" '1' 'largerEqual' 'number'
    $errExists = Build-ToolError 'Asset exists' @(660, -300) `
        "=A special asset with this exact description already exists. I will NOT create a duplicate. Use the delete tool to remove it if it no longer applies, or a distinct description."

    $resPerson = Build-Pg 'Resolve Person' @(220, 180) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'owner_person', ''));" `
        ([ordered]@{ owner_person = '$(''Start'').item.json.owner_person' })
    $ifPersonBad = Build-If 'Person invalid?' @(440, 180) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errPerson = Build-ToolError 'Person unresolved' @(660, 320) `
        "=The person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved. Ask which household member, or leave empty for a household asset."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    # "DB ist das Gesetz": estate.fn_create_special_asset laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_create_special_asset' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create asset (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'special_asset_id')::bigint AS special_asset_id" `
        -Params ([ordered]@{
            chat_id         = '$(''Start'').item.json.chat_id'
            owner_person_id = '$(''Resolve Person'').item.json.person_id'
            asset_type      = '$(''Start'').item.json.asset_type'
            description     = '$(''Start'').item.json.description'
            notes           = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.create_special_asset' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.type'        "$S.asset_type" -Kind enum -Enum 'estate.enum.asset_type')
        (New-HitlLine 'core.label.description' "$S.description")
        (New-HitlLine 'core.label.person'      "$RP.full_name" -If "$RP.full_name")
        (New-HitlLine 'core.label.person'      "'estate.value.household'" -Kind key -If "!$RP.full_name")
        (New-HitlLine 'estate.label.notes'     "$S.notes" -OmitEmpty)
        (New-HitlNote -Key 'estate.note.special_asset_legal')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the create_special_asset action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Asset rejected' @(2420, 200) "={{ `$('Create asset (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('special_asset_id', "={{ `$('Create asset (atomic)').item.json.special_asset_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -320) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_create_special_asset mit denselben Werten, immer zurückgerollt. ok:false (z. B. Pflichtfeld fehlt, Typ nicht in der geschlossenen Liste, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'create_ + adults_only + geschlossene Liste' @(1980, -280) `
        'estate.fn_create_special_asset (atomar, 1 INSERT) — kein other' `
        'Pflicht-Dubletten-Node (Beschreibung+Typ) blockt VOR dem Gate. estate.fn_create_special_asset schreibt atomar; adults_only-DB-Backstop. Geschlossene asset_type-Liste OHNE other (jeder Typ mappt auf eine WS-3-Checklisten-Condition; ein offener Typ löste still nichts aus). updated_at pflegt der Touch-Trigger.' 250 540
    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                 = @{ main = @( ,@( E 'Check duplicate' ) ) }
        'Check duplicate'       = @{ main = @( ,@( E 'Asset exists?' ) ) }
        'Asset exists?'         = @{ main = @(
            @( E 'Asset exists' ),
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
            @( E 'Create asset (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create asset (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'             = @{ main = @(
            @( E 'Return' ),
            @( E 'Asset rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_create_special_asset' $nodes $conns `
        @{ Category = 'register' }
}
