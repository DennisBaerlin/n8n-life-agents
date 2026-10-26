#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_funeral_preferences (WS-2, set_ = UPSERT je Person) ---------------
# Erfasst/aendert die Bestattungswuensche EINER Person (1 Zeile je Person, UPSERT + partiell).
# Person (Pflicht) -> Slug via core.fn_resolve_person VOR dem Gate. has_prepaid_contract ist
# Tri-State (nur explizit gesendet aendert). HITL owner_approval. adults_only-DB-Backstop. estate_rw.
function Build-EstateSetFuneralPreferences {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('person','burial_type','has_prepaid_contract','prepaid_contract_provider','wishes')

    $resPerson = Build-ResolvePerson 'Resolve Person' @(220, 0) 'person'
    $ifBad = Build-If 'Person unique?' @(440, 0) "={{ `$('Resolve Person').item.json.hit_count }}" '1'
    $errBad = Build-ToolError 'Person unresolved' @(660, 200) `
        "=The person '{{ `$('Start').item.json.person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Name the household member clearly."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nur genannte Felder erscheinen (-If); der Hinweis "unveraendert" steht als Note darunter.
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    $isPrepaid = "(['true','yes','1','ja'].indexOf(String($S.has_prepaid_contract).toLowerCase()) >= 0)"
    # "DB ist das Gesetz": estate.fn_set_funeral_preferences laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_funeral_preferences' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Set wishes (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'person_id' AS person_id, (r->>'created')::boolean AS created" `
        -Params ([ordered]@{
            chat_id                   = '$(''Start'').item.json.chat_id'
            person_id                 = '$(''Resolve Person'').item.json.person_id'
            burial_type               = '$(''Start'').item.json.burial_type'
            has_prepaid_contract      = '$(''Start'').item.json.has_prepaid_contract'
            prepaid_contract_provider = '$(''Start'').item.json.prepaid_contract_provider'
            wishes                    = '$(''Start'').item.json.wishes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.set_funeral_preferences' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.person'            "$RP.full_name")
        (New-HitlLine 'estate.label.burial_type'     "String($S.burial_type).toLowerCase()" -Kind enum -Enum 'estate.enum.burial_type' -If "$S.burial_type")
        (New-HitlLine 'estate.label.prepaid_contract' "$isPrepaid" -Kind bool -If "$S.has_prepaid_contract")
        (New-HitlLine 'estate.label.prepaid_provider' "$S.prepaid_contract_provider" -If "$S.prepaid_contract_provider")
        (New-HitlLine 'estate.label.wishes'          "$S.wishes" -If "$S.wishes")
        (New-HitlNote -Key 'estate.note.unchanged_fields')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the set_funeral_preferences action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2420, 200) "={{ `$('Set wishes (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('person_id', "={{ `$('Set wishes (atomic)').item.json.person_id }}", 'string')
        ,@('created', "={{ `$('Set wishes (atomic)').item.json.created }}", 'boolean')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_funeral_preferences mit denselben Werten, immer zurückgerollt. ok:false (z. B. Bestattungsart ungültig, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'set_ UPSERT je Person + Tri-State + adults_only' @(1980, -260) `
        'estate.fn_set_funeral_preferences (UPSERT, Tri-State Vorsorgevertrag)' `
        'Person (Pflicht) -> Slug via core.fn_resolve_person -> Person unique? VOR dem Gate. estate.fn_set_funeral_preferences UPSERTet (1 Zeile je Person; created=true beim ersten Write) + partiell. has_prepaid_contract ist TRI-STATE (NULL=unbekannt): nur ein explizit gesendeter true/false-Wert ändert ihn. adults_only-DB-Backstop. updated_at pflegt der Touch-Trigger.' 250 540
    $nodes = @($trig, $resPerson, $ifBad, $errBad) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Person' ) ) }
        'Resolve Person'         = @{ main = @( ,@( E 'Person unique?' ) ) }
        'Person unique?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Person unresolved' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set wishes (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set wishes (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_funeral_preferences' $nodes $conns `
        @{ Category = 'register' }
}
