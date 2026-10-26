#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_real_estate (set_*: Immobilie aktualisieren/neubewerten) ---
function Build-SetRealEstate {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('real_estate_name','new_name','current_value','value_updated_at',
                           'owner_person','status','notes')

    $resRe = Build-Pg 'Resolve Real Estate' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_real_estate((`$1::jsonb)->>'real_estate_name', TRUE);" `
        ([ordered]@{ real_estate_name = '$(''Start'').item.json.real_estate_name' })

    $ifRe = Build-If 'Real estate unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errRe = Build-ToolError 'Real estate ambiguous' @(660, 200) `
        "=Real estate '{{ `$('Start').item.json.real_estate_name }}' resolves to {{ `$('Resolve Real Estate').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Real Estate').item.json.candidates) }}. Ask the user which exact property."

    # Aktuellen Wert/Status fuer den HITL-Summary (alt -> neu) lesen.
    $readCur = Build-Pg 'Read Current' @(660, 0) `
        "=SELECT current_value, status::text AS status FROM finance.real_estate WHERE id = ((`$1::jsonb)->>'id')::int;" `
        ([ordered]@{ id = '$(''Resolve Real Estate'').item.json.id' })

    # WS-4: optionalen Eigentuemer-Wechsel aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(880, 360) 'owner_person'

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The owner person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # "DB ist das Gesetz": fn_set_real_estate laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate
    # in den echten Write (partielles UPDATE; current_value ohne Datum -> heute).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_real_estate' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Set real estate (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'real_estate_id')::int AS real_estate_id" `
        -Params ([ordered]@{
            real_estate_id   = '$(''Resolve Real Estate'').item.json.id'
            name             = '$(''Start'').item.json.new_name'
            current_value    = '$(''Start'').item.json.current_value'
            value_updated_at = '$(''Start'').item.json.value_updated_at'
            owner_person_id  = '$(''Resolve Person'').item.json.person_id'
            status           = '$(''Start'').item.json.status'
            notes            = '$(''Start'').item.json.notes'
        })

    # Strukturiertes Summary (Textkatalog): nur gelieferte Felder (-If je Zeile). Wert in EUR-Konvention
    # (vorher hart " €" an Rohzahlen), Bewertungsdatum formatiert.
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $P = "`$('Resolve Person').item.json"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.set_real_estate' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.object'         "$S.real_estate_name")
        (New-HitlLine 'finance.label.new_name'       "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.value'          "'finance.tpl.change'" -Kind tpl -If "$S.current_value" -Params @{
            from = (New-HitlValue -Kind money -Value "$R.current_value" -EurByModel)
            to   = (New-HitlValue -Kind money -Value "$S.current_value" -EurByModel) })
        (New-HitlLine 'finance.label.valuation_date' "$S.value_updated_at" -Kind date -If "$S.value_updated_at")
        (New-HitlLine 'finance.label.owner_person'   "($P.full_name || $S.owner_person)" -If "$S.owner_person")
        (New-HitlLine 'core.label.status'            "'finance.tpl.change'" -Kind tpl -If "$S.status" -Params @{
            from = (New-HitlValue -Kind enum -Value "$R.status" -Enum 'finance.enum.status')
            to   = (New-HitlValue -Kind enum -Value "$S.status" -Enum 'finance.enum.status') })
        (New-HitlLine 'core.label.note'              "$S.notes" -If "$S.notes")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the set_real_estate action'

    # Atomarer Write via fn_set_real_estate ($wg.Write, 'Set real estate (atomic)').
    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2640, 240) `
        "={{ `$('Set real estate (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('real_estate_id', "={{ `$('Set real estate (atomic)').item.json.real_estate_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_real_estate mit denselben Werten, immer zurückgerollt. ok:false (z. B. current_value < 0) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyOv = Build-Sticky 'Doc set_real_estate' @(2200, -220) `
        'fn_set_real_estate: partielles UPDATE' `
        'Neubewertung/Status/Stammdaten. current_value ohne value_updated_at -> Datum = heute. Net-Worth-View liest current_value live (kein Recompute). HINWEIS: status=sold löst verknüpfte Kredite NICHT ab. {ok:false} bei current_value<0.' 200 400

    $nodes = @($trig, $resRe, $ifRe, $errRe, $readCur, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv)

    $conns = [ordered]@{
        'Start'                       = @{ main = @( ,@( E 'Resolve Real Estate' ) ) }
        'Resolve Real Estate'         = @{ main = @( ,@( E 'Real estate unique?' ) ) }
        'Real estate unique?'         = @{ main = @(
            @( E 'Read Current' ),
            @( E 'Real estate ambiguous' )
        ) }
        'Read Current'                = @{ main = @( ,@( E 'Resolve Person' ) ) }
        'Resolve Person'              = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'             = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                     = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'                 = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'      = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'            = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                   = @{ main = @(
            @( E 'Set real estate (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set real estate (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                   = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_real_estate' $nodes $conns `
        @{ Category = 'real_estate' }
}
