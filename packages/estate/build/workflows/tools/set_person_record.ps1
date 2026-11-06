#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_person_record (WS-2, set_ = UPSERT je Person) ---------------------
# Erfasst/aendert die amtlichen Stammdaten EINER Person (1 Zeile je Person, UPSERT + partiell).
# Person (Pflicht) -> Slug via core.fn_resolve_person VOR dem Gate. Die fn normalisiert Steuer-
# ID/RV-Nr. + spiegelt die Format-CHECKs freundlich. KEINE Geheimnisse (nur Kennnummern +
# Fundort-Verweise). HITL owner_approval. adults_only-DB-Backstop in der fn. estate_rw.
function Build-EstateSetPersonRecord {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('person','tax_id','pension_insurance_no','health_insurance_type',
                            'health_insurance_name','health_insurance_no','employer',
                            'certificates_location','notes')

    $resPerson = Build-ResolvePerson 'Resolve Person' @(220, 0) 'person'
    $ifBad = Build-If 'Person unique?' @(440, 0) "={{ `$('Resolve Person').item.json.hit_count }}" '1'
    $errBad = Build-ToolError 'Person unresolved' @(660, 200) `
        "=The person '{{ `$('Start').item.json.person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Name the household member clearly."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nur genannte Felder erscheinen (-If); der Hinweis "unveraendert" steht als Note darunter.
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    # "DB ist das Gesetz": estate.fn_set_person_record laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_person_record' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Set record (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'person_id' AS person_id, (r->>'created')::boolean AS created" `
        -Params ([ordered]@{
            chat_id               = '$(''Start'').item.json.chat_id'
            person_id             = '$(''Resolve Person'').item.json.person_id'
            tax_id                = '$(''Start'').item.json.tax_id'
            pension_insurance_no  = '$(''Start'').item.json.pension_insurance_no'
            health_insurance_type = '$(''Start'').item.json.health_insurance_type'
            health_insurance_name = '$(''Start'').item.json.health_insurance_name'
            health_insurance_no   = '$(''Start'').item.json.health_insurance_no'
            employer              = '$(''Start'').item.json.employer'
            certificates_location = '$(''Start'').item.json.certificates_location'
            notes                 = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.set_person_record' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.person'                "$RP.full_name")
        (New-HitlLine 'estate.label.tax_id'              "$S.tax_id" -If "$S.tax_id")
        (New-HitlLine 'estate.label.pension_no'          "$S.pension_insurance_no" -If "$S.pension_insurance_no")
        (New-HitlLine 'estate.label.health_insurance'    "String($S.health_insurance_type).toLowerCase()" -Kind enum -Enum 'estate.enum.health_insurance_type' -If "$S.health_insurance_type")
        (New-HitlLine 'estate.label.health_fund'         "$S.health_insurance_name" -If "$S.health_insurance_name")
        (New-HitlLine 'estate.label.insured_no'          "$S.health_insurance_no" -If "$S.health_insurance_no")
        (New-HitlLine 'estate.label.employer'            "$S.employer" -If "$S.employer")
        (New-HitlLine 'estate.label.certificates_location' "$S.certificates_location" -If "$S.certificates_location")
        (New-HitlLine 'estate.label.notes'               "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'estate.note.unchanged_fields')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the set_person_record action'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2420, 200) "={{ `$('Set record (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('person_id', "={{ `$('Set record (atomic)').item.json.person_id }}", 'string')
        ,@('created', "={{ `$('Set record (atomic)').item.json.created }}", 'boolean')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -280) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_person_record mit denselben Werten, immer zurückgerollt. ok:false (z. B. Steuer-ID/RV-Nr. im falschen Format, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'set_ UPSERT je Person + Normalisierung + adults_only' @(1980, -280) `
        'estate.fn_set_person_record (UPSERT, DB normalisiert Steuer-ID/RV-Nr.)' `
        'Person (Pflicht) -> Slug via core.fn_resolve_person -> Person unique? VOR dem Gate. estate.fn_set_person_record UPSERTet (1 Zeile je Person, PK person_id; created=true beim ersten Write) + partiell (COALESCE). Die DB NORMALISIERT Steuer-ID/RV-Nr. (Leerzeichen raus, RV upper) + spiegelt die Gesetz-Format-CHECKs freundlich (§ 139b AO 11 Ziffern; RV ^\\d{8}[A-Z]\\d{3}$) -> das LLM rechnet/validiert NICHT. adults_only-DB-Backstop. KEINE Geheimnisse. updated_at pflegt der Touch-Trigger.' 260 580
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
            @( E 'Set record (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set record (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_person_record' $nodes $conns `
        @{ Category = 'register' }
}
