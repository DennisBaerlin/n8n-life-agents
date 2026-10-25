#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_contact (WS-2, create_ + Pflicht-Dubletten-Node) --------------
# Legt einen NEUEN Schluessel-Kontakt an (Notar/Steuerberater/Anwalt/Arzt/Bestatter/HR/Vermieter/
# Vertrauensperson). Mehrere je Rolle sind legitim (Dubletten-Node blockt nur EXAKT name+role).
# HITL owner_info. adults_only-DB-Backstop in der fn. Cred = estate_rw.
function Build-EstateCreateContact {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('owner_person','role','name','organization','phone','email','address','notes')

    $checkDup = Build-Pg 'Check duplicate' @(220, -200) `
        "=SELECT hit_count FROM estate.fn_resolve_contact((`$1::jsonb)->>'name', (`$1::jsonb)->>'role');" `
        ([ordered]@{ name = '$(''Start'').item.json.name'; role = '$(''Start'').item.json.role' })
    $ifExists = Build-If 'Contact exists?' @(440, -200) `
        "={{ `$('Check duplicate').item.json.hit_count }}" '1' 'largerEqual' 'number'
    $errExists = Build-ToolError 'Contact exists' @(660, -300) `
        "=A contact named '{{ `$('Start').item.json.name }}' with this role already exists. I will NOT create a duplicate. Use the update tool to change it."

    $resPerson = Build-Pg 'Resolve Person' @(220, 180) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'owner_person', ''));" `
        ([ordered]@{ owner_person = '$(''Start'').item.json.owner_person' })
    $ifPersonBad = Build-If 'Person invalid?' @(440, 180) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errPerson = Build-ToolError 'Person unresolved' @(660, 320) `
        "=The person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved. Ask which household member, or leave empty for a household contact."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    # "DB ist das Gesetz": estate.fn_create_contact laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_create_contact' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create contact (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'contact_id')::bigint AS contact_id" `
        -Params ([ordered]@{
            chat_id         = '$(''Start'').item.json.chat_id'
            owner_person_id = '$(''Resolve Person'').item.json.person_id'
            role            = '$(''Start'').item.json.role'
            name            = '$(''Start'').item.json.name'
            organization    = '$(''Start'').item.json.organization'
            phone           = '$(''Start'').item.json.phone'
            email           = '$(''Start'').item.json.email'
            address         = '$(''Start'').item.json.address'
            notes           = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.create_contact' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.role'         "$S.role" -Kind enum -Enum 'estate.enum.contact_role')
        (New-HitlLine 'core.label.name'           "$S.name")
        (New-HitlLine 'estate.label.organization' "$S.organization" -OmitEmpty)
        (New-HitlLine 'estate.label.for_person'   "$RP.full_name" -If "$RP.full_name")
        (New-HitlLine 'estate.label.for_person'   "'estate.value.household'" -Kind key -If "!$RP.full_name")
        (New-HitlLine 'estate.label.phone'        "$S.phone" -OmitEmpty)
        (New-HitlLine 'estate.label.email'        "$S.email" -OmitEmpty)
        (New-HitlLine 'estate.label.address'      "$S.address" -OmitEmpty)
        (New-HitlLine 'estate.label.notes'        "$S.notes" -OmitEmpty)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the create_contact action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Contact rejected' @(2420, 200) "={{ `$('Create contact (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('contact_id', "={{ `$('Create contact (atomic)').item.json.contact_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -320) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_create_contact mit denselben Werten, immer zurückgerollt. ok:false (z. B. Pflichtfeld fehlt, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'create_ + adults_only-Backstop' @(1980, -280) `
        'estate.fn_create_contact (atomar, 1 INSERT)' `
        'Pflicht-Dubletten-Node blockt EXAKT gleichen Name+Rolle VOR dem Gate; mehrere Kontakte je Rolle sind legitim (kein UNIQUE auf role — zwei Vertrauenspersonen mit verschiedenen Namen sind ok). estate.fn_create_contact schreibt atomar; adults_only-DB-Backstop. updated_at pflegt der Touch-Trigger.' 240 520
    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Check duplicate' ) ) }
        'Check duplicate'         = @{ main = @( ,@( E 'Contact exists?' ) ) }
        'Contact exists?'         = @{ main = @(
            @( E 'Contact exists' ),
            @( E 'Resolve Person' )
        ) }
        'Resolve Person'          = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'         = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                 = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'             = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'  = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'        = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'               = @{ main = @(
            @( E 'Create contact (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create contact (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Contact rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_create_contact' $nodes $conns `
        @{ Category = 'register' }
}
