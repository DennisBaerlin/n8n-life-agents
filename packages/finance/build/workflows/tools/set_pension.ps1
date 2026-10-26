#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_pension (set_*: Altersvorsorge aktualisieren) ---
function Build-SetPension {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('pension_name','new_name','provider','contract_number','owner_person',
                           'current_value','value_updated_at','guaranteed_monthly_pension',
                           'retirement_start_date','status','notes')

    $resPen = Build-Pg 'Resolve Pension' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_pension((`$1::jsonb)->>'pension_name', TRUE);" `
        ([ordered]@{ pension_name = '$(''Start'').item.json.pension_name' })

    $ifPen = Build-If 'Pension unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errPen = Build-ToolError 'Pension ambiguous' @(660, 200) `
        "=Pension '{{ `$('Start').item.json.pension_name }}' resolves to {{ `$('Resolve Pension').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Pension').item.json.candidates) }}. Ask the user which exact provision."

    $readCur = Build-Pg 'Read Current' @(660, 0) `
        "=SELECT current_value, status::text AS status FROM finance.pension WHERE id = ((`$1::jsonb)->>'id')::int;" `
        ([ordered]@{ id = '$(''Resolve Pension'').item.json.id' })

    # WS-4: optionalen Eigentuemer-Wechsel aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(880, 360) 'owner_person'

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The owner person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # "DB ist das Gesetz": fn_set_pension laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in
    # den echten Write (partielles UPDATE + Status-Kaskade auf den Beitrag).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_pension' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Set pension (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'pension_id')::int AS pension_id" `
        -Params ([ordered]@{
            pension_id                 = '$(''Resolve Pension'').item.json.id'
            name                       = '$(''Start'').item.json.new_name'
            provider                   = '$(''Start'').item.json.provider'
            contract_number            = '$(''Start'').item.json.contract_number'
            owner_person_id            = '$(''Resolve Person'').item.json.person_id'
            current_value              = '$(''Start'').item.json.current_value'
            value_updated_at           = '$(''Start'').item.json.value_updated_at'
            guaranteed_monthly_pension = '$(''Start'').item.json.guaranteed_monthly_pension'
            retirement_start_date      = '$(''Start'').item.json.retirement_start_date'
            status                     = '$(''Start'').item.json.status'
            notes                      = '$(''Start'').item.json.notes'
        })

    # Strukturiertes Summary (Textkatalog): nur gelieferte Felder (-If je Zeile). Betraege in EUR-Konvention
    # (entity-Werte in EUR erfasst).
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $P = "`$('Resolve Person').item.json"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.set_pension' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.provision'     "$S.pension_name")
        (New-HitlLine 'finance.label.new_name'      "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.value'         "'finance.tpl.change'" -Kind tpl -If "$S.current_value" -Params @{
            from = (New-HitlValue -Kind money -Value "$R.current_value" -EurByModel)
            to   = (New-HitlValue -Kind money -Value "$S.current_value" -EurByModel) })
        (New-HitlLine 'finance.label.valuation_date' (Get-DryEffectiveExpr 'value_updated_at') -Kind date -If "$S.value_updated_at")
        (New-HitlLine 'finance.label.guaranteed_monthly_pension' "$S.guaranteed_monthly_pension" -Kind money -EurByModel -If "$S.guaranteed_monthly_pension")
        (New-HitlLine 'finance.label.retirement_start' (Get-DryEffectiveExpr 'retirement_start_date') -Kind date -If "$S.retirement_start_date")
        (New-HitlLine 'finance.label.provider'      "$S.provider" -If "$S.provider")
        (New-HitlLine 'finance.label.contract_number' "$S.contract_number" -If "$S.contract_number")
        (New-HitlLine 'finance.label.owner_person'  "($P.full_name || $S.owner_person)" -If "$S.owner_person")
        (New-HitlLine 'core.label.status'           "'finance.tpl.change'" -Kind tpl -If "$S.status" -Params @{
            from = (New-HitlValue -Kind enum -Value "$R.status" -Enum 'finance.enum.status')
            to   = (New-HitlValue -Kind enum -Value "$S.status" -Enum 'finance.enum.status') })
        (New-HitlLine 'core.label.note'             "$S.notes" -If "$S.notes")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the set_pension action'

    # Atomarer Write via fn_set_pension ($wg.Write, 'Set pension (atomic)').
    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2640, 240) `
        "={{ `$('Set pension (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('pension_id', "={{ `$('Set pension (atomic)').item.json.pension_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_pension mit denselben Werten, immer zurückgerollt. ok:false (z. B. current_value < 0) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyOv = Build-Sticky 'Doc set_pension' @(2200, -240) `
        'fn_set_pension: partielles UPDATE + Status-Kaskade' `
        'Wert/Status/Stammdaten. current_value ohne Datum -> heute. Beitrags-BETRAG wird hier NICHT geändert. STATUS-KASKADE: paused/paid_out -> verknüpfte recurring_payment paused; active -> wieder active. {ok:false} bei current_value<0.' 220 400

    $nodes = @($trig, $resPen, $ifPen, $errPen, $readCur, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Pension' ) ) }
        'Resolve Pension'        = @{ main = @( ,@( E 'Pension unique?' ) ) }
        'Pension unique?'        = @{ main = @(
            @( E 'Read Current' ),
            @( E 'Pension ambiguous' )
        ) }
        'Read Current'           = @{ main = @( ,@( E 'Resolve Person' ) ) }
        'Resolve Person'         = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'        = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set pension (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set pension (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_pension' $nodes $conns `
        @{ Category = 'pension' }
}
