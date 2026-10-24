#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_digital_account (WS-2, set_ = partielles Update) ------------------
# Aendert ein bestehendes Konto des digitalen Nachlasses ("nicht gesendet = unveraendert").
# NIE Passwoerter — Zugangs-Felder sind Fundort-Verweise. Resolve (Anbieter + optional
# Nutzername) VOR dem Gate. HITL owner_approval. adults_only-DB-Backstop in der fn. estate_rw.
function Build-EstateSetDigitalAccount {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('provider','username','new_provider','new_username','new_category',
                            'is_key_account','desired_action','access_path','legacy_contact_status',
                            'twofa_hint','seed_backup_location','notes')

    $resolve = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_digital_account((`$1::jsonb)->>'provider', NULLIF((`$1::jsonb)->>'username',''));" `
        ([ordered]@{ provider = '$(''Start'').item.json.provider'; username = '$(''Start'').item.json.username' })
    $ifBad = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=The account '{{ `$('Start').item.json.provider }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask which one (add the username), or check the provider."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nur genannte Felder erscheinen (-If); der Hinweis "unveraendert" steht als Note darunter.
    $S = "`$('Start').item.json"
    $isKey = "(['true','yes','1','ja'].indexOf(String($S.is_key_account || '').toLowerCase()) >= 0)"
    # "DB ist das Gesetz": estate.fn_set_digital_account laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_digital_account' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Set account (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'digital_account_id')::bigint AS digital_account_id" `
        -Params ([ordered]@{
            chat_id               = '$(''Start'').item.json.chat_id'
            digital_account_id    = '$(''Resolve Account'').item.json.id'
            new_provider          = '$(''Start'').item.json.new_provider'
            new_username          = '$(''Start'').item.json.new_username'
            new_category          = '$(''Start'').item.json.new_category'
            is_key_account        = '$(''Start'').item.json.is_key_account'
            desired_action        = '$(''Start'').item.json.desired_action'
            access_path           = '$(''Start'').item.json.access_path'
            legacy_contact_status = '$(''Start'').item.json.legacy_contact_status'
            twofa_hint            = '$(''Start'').item.json.twofa_hint'
            seed_backup_location  = '$(''Start'').item.json.seed_backup_location'
            notes                 = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.set_digital_account' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.account'         "$S.provider")
        (New-HitlLine 'estate.label.new_provider'    "$S.new_provider" -If "$S.new_provider")
        (New-HitlLine 'estate.label.new_username'    "$S.new_username" -If "$S.new_username")
        (New-HitlLine 'estate.label.new_category'    "$S.new_category" -Kind enum -Enum 'estate.enum.digital_category' -If "$S.new_category")
        (New-HitlLine 'estate.label.key_account'     "$isKey" -Kind bool -If "$S.is_key_account")
        (New-HitlLine 'estate.label.death_action'    "$S.desired_action" -Kind enum -Enum 'estate.enum.digital_action' -If "$S.desired_action")
        (New-HitlLine 'estate.label.legacy_function' "$S.legacy_contact_status" -Kind enum -Enum 'estate.enum.legacy_status' -If "$S.legacy_contact_status")
        (New-HitlLine 'estate.label.access_path'     "$S.access_path" -If "$S.access_path")
        (New-HitlLine 'estate.label.twofa_location'  "$S.twofa_hint" -If "$S.twofa_hint")
        (New-HitlLine 'estate.label.seed_backup_location' "$S.seed_backup_location" -If "$S.seed_backup_location")
        (New-HitlLine 'estate.label.notes'           "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'estate.note.unchanged_fields')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the set_digital_account action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2420, 200) "={{ `$('Set account (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('digital_account_id', "={{ `$('Set account (atomic)').item.json.digital_account_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_digital_account mit denselben Werten, immer zurückgerollt. ok:false (z. B. Seed-Backup passt nicht zur Kategorie, Wert ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'set_ (partiell) + adults_only + Fundort-Regel' @(1980, -260) `
        'estate.fn_set_digital_account (partielles UPDATE) — NIE Geheimnisse' `
        'Resolve (Anbieter + optional Nutzername) -> Account unique? VOR dem Gate. estate.fn_set_digital_account updated partiell; NIE Passwörter (Fundort-Verweise); seed_backup_location bleibt crypto-gekoppelt gegen die EFFEKTIVE Kategorie (bestehend ODER neu); adults_only-DB-Backstop; not-found = RAISE. updated_at pflegt der Touch-Trigger.' 250 540
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'        = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'        = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Account ambiguous' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set account (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set account (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_digital_account' $nodes $conns `
        @{ Category = 'register' }
}
