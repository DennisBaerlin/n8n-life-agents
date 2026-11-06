#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_storage_place (WS-2, set_ = partielles Update / Repurpose) --------
# Aendert eine bestehende Fundstelle ("nicht gesendet = unveraendert"). Fundstellen sind FK-Ziel
# der directives (RESTRICT) -> KEIN delete_storage_place; eine obsolete Fundstelle wird hier
# umbenannt/umgewidmet. access_hint = Fundort-Verweis OHNE Codes. Resolve (Name) VOR dem Gate.
# HITL owner_approval. adults_only-DB-Backstop. estate_rw.
function Build-EstateSetStoragePlace {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('name','new_name','new_kind','location','access_hint','notes')

    $resolve = Build-Pg 'Resolve Place' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM estate.fn_resolve_storage_place((`$1::jsonb)->>'name');" `
        ([ordered]@{ name = '$(''Start'').item.json.name' })
    $ifBad = Build-If 'Place unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errBad = Build-ToolError 'Place ambiguous' @(660, 200) `
        "=The storage place '{{ `$('Start').item.json.name }}' resolves to {{ `$('Resolve Place').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Place').item.json.candidates) }}. Ask which one, or check the name."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nur genannte Felder erscheinen (-If); der Hinweis "unveraendert" steht als Note darunter.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_set_storage_place laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_storage_place' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Set place (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'storage_place_id')::bigint AS storage_place_id" `
        -Params ([ordered]@{
            chat_id          = '$(''Start'').item.json.chat_id'
            storage_place_id = '$(''Resolve Place'').item.json.id'
            new_name         = '$(''Start'').item.json.new_name'
            new_kind         = '$(''Start'').item.json.new_kind'
            location         = '$(''Start'').item.json.location'
            access_hint      = '$(''Start'').item.json.access_hint'
            notes            = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.set_storage_place' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.storage_site' "$S.name")
        (New-HitlLine 'estate.label.new_name'     "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'estate.label.new_kind'     "$S.new_kind" -Kind enum -Enum 'estate.enum.storage_kind' -If "$S.new_kind")
        (New-HitlLine 'estate.label.location'     "$S.location" -If "$S.location")
        (New-HitlLine 'estate.label.access_hint'  "$S.access_hint" -If "$S.access_hint")
        (New-HitlLine 'estate.label.notes'        "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'estate.note.unchanged_fields')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the set_storage_place action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2420, 200) "={{ `$('Set place (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('storage_place_id', "={{ `$('Set place (atomic)').item.json.storage_place_id }}", 'number')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_storage_place mit denselben Werten, immer zurückgerollt. ok:false (z. B. Art ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'set_ (partiell) + adults_only + Repurpose-Regel' @(1980, -260) `
        'estate.fn_set_storage_place (partielles UPDATE)' `
        'Resolve (Name) -> Place unique? VOR dem Gate. estate.fn_set_storage_place updated partiell (COALESCE); adults_only-DB-Backstop; not-found = RAISE. Fundstellen sind FK-Ziel der directives (RESTRICT) -> KEIN delete_storage_place; eine obsolete Fundstelle wird hier umbenannt/umgewidmet. access_hint = Fundort-Verweis OHNE Codes. updated_at pflegt der Touch-Trigger.' 250 540
    $nodes = @($trig, $resolve, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Place' ) ) }
        'Resolve Place'          = @{ main = @( ,@( E 'Place unique?' ) ) }
        'Place unique?'          = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Place ambiguous' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set place (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set place (atomic)'     = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_storage_place' $nodes $conns `
        @{ Category = 'register' }
}
