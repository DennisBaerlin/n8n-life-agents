#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_record_directive (WS-2, Verb record_ = idempotenter UPSERT) ----------
# Erfasst/aktualisiert EINEN Vorsorge-Dokument-Register-Eintrag (UPSERT auf den UNIQUE NULLS NOT
# DISTINCT (owner_person_id, doc_type)-Key). Verb record_ (kein create_ -> KEIN Dubletten-Node:
# der UPSERT-Vertrag ersetzt einen bestehenden Eintrag idempotent, Praezedenz career record_job_match).
# HITL owner_info (member-tauglich; additiver Register-Eintrag, kein Identitaets-/Plan-Write). Der
# adults_only-DB-Backstop lebt in der fn (Kind -> {ok:false}). Cred = estate_rw (finance_rw-Paritaet).
function Build-EstateRecordDirective {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('owner_person','doc_type','doc_status','form','registry',
                            'storage_place_name','location_note','authorized_person','notes')

    # Person aufloesen (optional; leer = gemeinschaftliche Haushalts-Urkunde -> owner_person_id NULL).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(220, 180) 'owner_person'

    $ifPersonBad = Build-If 'Person invalid?' @(440, 180) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(660, 320) `
        "=The person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member, or leave empty for a joint/household document (Berliner Testament)."

    # HITL-Summary (Textkatalog; doc_type/doc_status/form menschenlesbar als Enum-Keys).
    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S  = "`$('Start').item.json"
    $RP = "`$('Resolve Person').item.json"
    # "DB ist das Gesetz": estate.fn_record_directive laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_record_directive' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Record directive (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'directive_id')::bigint AS directive_id, (r->>'created')::boolean AS created, r->>'doc_status' AS doc_status" `
        -Params ([ordered]@{
            chat_id            = '$(''Start'').item.json.chat_id'
            owner_person_id    = '$(''Resolve Person'').item.json.person_id'
            doc_type           = '$(''Start'').item.json.doc_type'
            doc_status         = '$(''Start'').item.json.doc_status'
            form               = '$(''Start'').item.json.form'
            registry           = '$(''Start'').item.json.registry'
            storage_place_name = '$(''Start'').item.json.storage_place_name'
            location_note      = '$(''Start'').item.json.location_note'
            authorized_person  = '$(''Start'').item.json.authorized_person'
            notes              = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.record_directive' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.person'             "$RP.full_name" -If "$RP.full_name")
        (New-HitlLine 'core.label.person'             "'estate.value.household_joint'" -Kind key -If "!$RP.full_name")
        (New-HitlLine 'estate.label.document'         "$S.doc_type" -Kind enum -Enum 'estate.enum.doc_type')
        (New-HitlLine 'core.label.status'             "$S.doc_status" -Kind enum -Enum 'estate.enum.doc_status')
        (New-HitlLine 'estate.label.form'             "$S.form" -Kind enum -Enum 'estate.enum.doc_form' -OmitEmpty)
        (New-HitlLine 'estate.label.registry'         "($S.registry ? String($S.registry).toUpperCase() : null)" -OmitEmpty)
        (New-HitlLine 'estate.label.storage_place'    "($S.storage_place_name || $S.location_note)" -OmitEmpty)
        (New-HitlLine 'estate.label.authorized_person' "$S.authorized_person" -OmitEmpty)
        (New-HitlLine 'estate.label.notes'            "$S.notes" -OmitEmpty)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the record_directive action'

    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Directive rejected' @(2420, 200) "={{ `$('Record directive (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('directive_id', "={{ `$('Record directive (atomic)').item.json.directive_id }}", 'number')
        ,@('created', "={{ `$('Record directive (atomic)').item.json.created }}", 'boolean')
        ,@('doc_status', "={{ `$('Record directive (atomic)').item.json.doc_status }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -320) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_record_directive mit denselben Werten, immer zurückgerollt. ok:false (z. B. Fundstelle nicht eindeutig auflösbar, Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'UPSERT + adults_only-Backstop' @(1980, -280) `
        'estate.fn_record_directive (atomar, UPSERT auf owner_person_id+doc_type)' `
        'Schreibt estate.fn_record_directive atomar: UPSERT auf UNIQUE NULLS NOT DISTINCT (owner_person_id, doc_type) -> genau EIN Eintrag je (Person|Haushalt, Typ); Re-Record aktualisiert (created=false). owner_person_id leer = Haushalts-Urkunde (NULL). storage_place_name löst die fn intern auf (0/>1 -> {ok:false}). adults_only-DB-Backstop (Kind -> {ok:false} ohne Write). doc_status IMMER übernommen, Rest partiell (COALESCE). "Entfernen" = doc_status does_not_exist (kein delete_directive). updated_at pflegt der Touch-Trigger.' 240 520

    $nodes = @($trig, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                     = @{ main = @( ,@( E 'Resolve Person' ) ) }
        'Resolve Person'            = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'           = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                   = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'               = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'    = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'          = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                 = @{ main = @(
            @( E 'Record directive (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Record directive (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                 = @{ main = @(
            @( E 'Return' ),
            @( E 'Directive rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_record_directive' $nodes $conns `
        @{ Category = 'register' }
}
