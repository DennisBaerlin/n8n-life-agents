#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_contact (WS-2, set_ = partielles Update) --------------------------
# Aendert einen bestehenden Schluessel-Kontakt ("nicht gesendet = unveraendert"). Resolve
# (Name + optional Rolle) VOR dem Gate. HITL owner_approval. adults_only-DB-Backstop. estate_rw.
function Build-EstateSetContact {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('name','role','new_name','new_role','organization','phone','email','address','notes')

    $resolve = Build-Pg 'Resolve Contact' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_contact((`$1::jsonb)->>'name', NULLIF((`$1::jsonb)->>'role',''));" `
        ([ordered]@{ name = '$(''Start'').item.json.name'; role = '$(''Start'').item.json.role' })
    $ifBad = Build-If 'Contact unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Contact ambiguous' @(660, 200) `
        "=The contact '{{ `$('Start').item.json.name }}' resolves to {{ `$('Resolve Contact').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Contact').item.json.candidates) }}. Ask which one (add the role), or check the name."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nur genannte Felder erscheinen (-If); der Hinweis "unveraendert" steht als Note darunter.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_set_contact laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_contact' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Set contact (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'contact_id')::bigint AS contact_id" `
        -Params ([ordered]@{
            chat_id      = '$(''Start'').item.json.chat_id'
            contact_id   = '$(''Resolve Contact'').item.json.id'
            new_name     = '$(''Start'').item.json.new_name'
            new_role     = '$(''Start'').item.json.new_role'
            organization = '$(''Start'').item.json.organization'
            phone        = '$(''Start'').item.json.phone'
            email        = '$(''Start'').item.json.email'
            address      = '$(''Start'').item.json.address'
            notes        = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.set_contact' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.contact'      "$S.name")
        (New-HitlLine 'estate.label.new_name'     "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'estate.label.new_role'     "$S.new_role" -Kind enum -Enum 'estate.enum.contact_role' -If "$S.new_role")
        (New-HitlLine 'estate.label.organization' "$S.organization" -If "$S.organization")
        (New-HitlLine 'estate.label.phone'        "$S.phone" -If "$S.phone")
        (New-HitlLine 'estate.label.email'        "$S.email" -If "$S.email")
        (New-HitlLine 'estate.label.address'      "$S.address" -If "$S.address")
        (New-HitlLine 'estate.label.notes'        "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'estate.note.unchanged_fields')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the set_contact action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2420, 200) "={{ `$('Set contact (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('contact_id', "={{ `$('Set contact (atomic)').item.json.contact_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_contact mit denselben Werten, immer zurückgerollt. ok:false (z. B. Rolle ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'set_ (partiell) + adults_only' @(1980, -260) `
        'estate.fn_set_contact (partielles UPDATE)' `
        'Resolve (Name + optional Rolle) -> Contact unique? VOR dem Gate. estate.fn_set_contact updated partiell (COALESCE); adults_only-DB-Backstop; not-found = RAISE. updated_at pflegt der Touch-Trigger.' 220 480
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Contact' ) ) }
        'Resolve Contact'        = @{ main = @( ,@( E 'Contact unique?' ) ) }
        'Contact unique?'        = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Contact ambiguous' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set contact (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set contact (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_contact' $nodes $conns `
        @{ Category = 'register' }
}
