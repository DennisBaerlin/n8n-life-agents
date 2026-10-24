#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_create_digital_account (WS-2, create_ + Pflicht-Dubletten-Node) ------
# Legt ein NEUES Konto des digitalen Nachlasses an — OHNE Passwoerter (nur Fundort-Verweise).
# HITL owner_info. adults_only-DB-Backstop + crypto-Kopplung des Seed-Fundorts in der fn. Cred = estate_rw.
function Build-EstateCreateDigitalAccount {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('owner_person','category','provider','username','is_key_account',
                            'desired_action','access_path','legacy_contact_status','twofa_hint',
                            'seed_backup_location','notes')

    $checkDup = Build-Pg 'Check duplicate' @(220, -200) `
        "=SELECT hit_count FROM estate.fn_resolve_digital_account((`$1::jsonb)->>'provider', NULLIF((`$1::jsonb)->>'username',''));" `
        ([ordered]@{ provider = '$(''Start'').item.json.provider'; username = '$(''Start'').item.json.username' })
    $ifExists = Build-If 'Account exists?' @(440, -200) `
        "={{ `$('Check duplicate').item.json.hit_count }}" '1' 'largerEqual' 'number'
    $errExists = Build-ToolError 'Account exists' @(660, -300) `
        "=A digital account for '{{ `$('Start').item.json.provider }}' with this username already exists. I will NOT create a duplicate. Use the update tool, or pass the exact username to distinguish two accounts at the same provider."

    $resPerson = Build-Pg 'Resolve Person' @(220, 180) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'owner_person', ''));" `
        ([ordered]@{ owner_person = '$(''Start'').item.json.owner_person' })
    $ifPersonBad = Build-If 'Person invalid?' @(440, 180) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errPerson = Build-ToolError 'Person unresolved' @(660, 320) `
        "=The person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved. Ask which household member, or leave empty for a shared account."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Offene Todesfall-Aktion (NULL) -> Enum-Wert 'open' ("OFFEN"); Schluesselkonto-Flag wie bisher aus true/yes/1/ja.
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    $isKey = "(['true','yes','1','ja'].indexOf(String($S.is_key_account || '').toLowerCase()) >= 0)"
    # "DB ist das Gesetz": estate.fn_create_digital_account laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_create_digital_account' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create account (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'digital_account_id')::bigint AS digital_account_id, (r->>'is_key_account')::boolean AS is_key_account" `
        -Params ([ordered]@{
            chat_id               = '$(''Start'').item.json.chat_id'
            owner_person_id       = '$(''Resolve Person'').item.json.person_id'
            category              = '$(''Start'').item.json.category'
            provider              = '$(''Start'').item.json.provider'
            username              = '$(''Start'').item.json.username'
            is_key_account        = '$(''Start'').item.json.is_key_account'
            desired_action        = '$(''Start'').item.json.desired_action'
            access_path           = '$(''Start'').item.json.access_path'
            legacy_contact_status = '$(''Start'').item.json.legacy_contact_status'
            twofa_hint            = '$(''Start'').item.json.twofa_hint'
            seed_backup_location  = '$(''Start'').item.json.seed_backup_location'
            notes                 = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.create_digital_account' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.provider'        "$S.provider")
        (New-HitlLine 'estate.label.category'        "$S.category" -Kind enum -Enum 'estate.enum.digital_category')
        (New-HitlLine 'estate.label.username'        "$S.username")
        (New-HitlLine 'core.label.person'            "$RP.full_name" -If "$RP.full_name")
        (New-HitlLine 'core.label.person'            "'estate.value.household_shared'" -Kind key -If "!$RP.full_name")
        (New-HitlLine 'estate.label.key_account'     "($isKey ? 'estate.value.key_account_yes' : 'estate.value.key_account_no')" -Kind key)
        (New-HitlLine 'estate.label.death_action'    "($S.desired_action || 'open')" -Kind enum -Enum 'estate.enum.digital_action')
        (New-HitlLine 'estate.label.legacy_function' "$S.legacy_contact_status" -Kind enum -Enum 'estate.enum.legacy_status')
        (New-HitlLine 'estate.label.access_path'     "$S.access_path")
        (New-HitlLine 'estate.label.twofa_location'  "$S.twofa_hint")
        (New-HitlLine 'estate.label.seed_backup_location' "$S.seed_backup_location" -If "$S.seed_backup_location")
        (New-HitlLine 'estate.label.notes'           "$S.notes")
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the create_digital_account action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Account rejected' @(2420, 200) "={{ `$('Create account (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('digital_account_id', "={{ `$('Create account (atomic)').item.json.digital_account_id }}", 'number')
        ,@('is_key_account', "={{ `$('Create account (atomic)').item.json.is_key_account }}", 'boolean')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -320) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_create_digital_account mit denselben Werten, immer zurückgerollt. ok:false (z. B. Pflichtfeld fehlt, Kategorie/Seed-Backup passt nicht, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'create_ OHNE Passwörter + adults_only' @(1980, -280) `
        'estate.fn_create_digital_account (atomar, 1 INSERT) — NIE Geheimnisse' `
        'Pflicht-Dubletten-Node (Anbieter+Nutzername) BLOCKT VOR dem Gate. estate.fn_create_digital_account schreibt atomar; adults_only-DB-Backstop. NIE Passwörter/PINs/Seed-Phrases — access_path/twofa_hint/seed_backup_location sind FUNDORT-Verweise (die Description + Instructions tragen die Hard-Rule, die DB kann den Inhalt nicht prüfen). seed_backup_location ist crypto-CHECK-gekoppelt (freundliche fn-Spiegelung). desired_action NULL = OFFENER Gap. is_key_account tolerant geparst.' 260 560
    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Check duplicate' ) ) }
        'Check duplicate'         = @{ main = @( ,@( E 'Account exists?' ) ) }
        'Account exists?'         = @{ main = @(
            @( E 'Account exists' ),
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
            @( E 'Create account (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create account (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Account rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_create_digital_account' $nodes $conns `
        @{ Category = 'register' }
}
