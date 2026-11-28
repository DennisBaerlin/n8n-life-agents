#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_pension (set_*: Altersvorsorge aktualisieren) ---
function Build-SetPension {
    # Enge Paket-Schreibrolle (finance_rw) statt Owner-Cred; Build-Pg liest $CRED_POSTGRES per Dynamic-Scope.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('pension_name','new_name','provider','contract_number','owner_person',
                           'current_value','value_updated_at','guaranteed_monthly_pension',
                           'retirement_start_date','status','notes',
                           'contribution_amount','effective_from','schedule_interval','schedule_unit','debit_account_name','handoff_task_id')

    # p_active_only NULL = aktive zuerst, ohne aktiven Treffer alle: eine pausierte Sache bleibt aenderbar (status active).
    $resPen = Build-Pg 'Resolve Pension' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_pension((`$1::jsonb)->>'pension_name', NULL);" `
        ([ordered]@{ pension_name = '$(''Start'').item.json.pension_name' })

    $ifPen = Build-If 'Pension unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errPen = Build-ToolError 'Pension ambiguous' @(660, 200) `
        "=Pension '{{ `$('Start').item.json.pension_name }}' resolves to {{ `$('Resolve Pension').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Pension').item.json.candidates) }}. Ask the user which exact provision."

    $readCur = Build-Pg 'Read Current' @(660, 0) `
        "=SELECT p.current_value, p.status::text AS status, rc.schedule_interval, rc.schedule_unit::text AS schedule_unit FROM finance.pension p LEFT JOIN finance.recurring_payments rc ON rc.id = finance.fn_recurring_current(p.recurring_payment_id, current_date) WHERE p.id = ((`$1::jsonb)->>'id')::int;" `
        ([ordered]@{ id = '$(''Resolve Pension'').item.json.id' })

    # Optionalen Eigentuemer-Wechsel aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(880, 360) 'owner_person'

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The owner person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # Abbuchungskonto nur fuer den ersten Beitrag einer Vorsorge ohne Beitrag (leer = kein Konto; ob es gebraucht wird,
    # entscheidet der Probelauf).
    $resAcc = Build-Pg 'Resolve Debit Account' @(1100, 600) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'debit_account_name');" `
        ([ordered]@{ debit_account_name = '$(''Start'').item.json.debit_account_name' })
    $ifAcc = Build-If 'Debit ok?' @(1320, 600) "={{ `$json.hit_count === 1 || !`$('Start').item.json.debit_account_name }}" 'true' 'equals' 'boolean'
    $errAcc = Build-ToolError 'Debit ambiguous' @(1540, 720) `
        "=Debit account '{{ `$('Start').item.json.debit_account_name }}' resolves to {{ `$('Resolve Debit Account').item.json.hit_count }} matches. Ask the user which exact account to use."

    $wg = New-FnWriteGate -Fn 'finance.fn_set_pension' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Set pension (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'pension_id')::int AS pension_id, (r->>'recurring_payment_id')::int AS recurring_payment_id, (r->>'contribution_amount')::numeric AS contribution_amount, (r->>'monthly_contribution')::numeric AS monthly_contribution, r->>'first_due' AS first_due, CASE WHEN jsonb_typeof(r->'handoff_diff') = 'array' AND jsonb_array_length(r->'handoff_diff') > 0 THEN (r->'handoff_diff')::text ELSE '' END AS handoff_diff" `
        -Params ([ordered]@{
            handoff_task_id            = '$(''Start'').item.json.handoff_task_id'   # vereinbarte Plan-Aufgabe: finance.fn_with_handoff prueft + schliesst sie im selben Write
            chat_id                    = '$(''Start'').item.json.chat_id'           # Person der Plan-Aufgabe (nie LLM)
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
            contribution_amount        = '$(''Start'').item.json.contribution_amount'
            effective_from             = '$(''Start'').item.json.effective_from'
            schedule_interval          = '$(''Start'').item.json.schedule_interval'
            schedule_unit              = '$(''Start'').item.json.schedule_unit'
            debit_account_id           = '$(''Resolve Debit Account'').item.json.id'
        })

    # Nur gelieferte Felder (-If je Zeile). Betraege in EUR-Konvention
    # (entity-Werte in EUR erfasst).
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $P = "`$('Resolve Person').item.json"
    # Beitrag: alter und neuer Wert, Monatswert und erster Termin kommen aus dem Probelauf (r.*), nie aus der Eingabe;
    # ohne Aenderung (gleicher Beitrag) liefert er nichts und die Zeilen entfallen.
    $D = "`$('Dry run').item.json.r"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.set_pension' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.provision'     "$S.pension_name")
        (New-HitlLine 'finance.label.new_name'      "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.rate_per_debit' "'finance.tpl.change'" -Kind tpl -If "$D.previous_contribution_amount" -Params @{
            from = (New-HitlValue -Kind money -Value "$D.previous_contribution_amount" -EurByModel)
            to   = (New-HitlValue -Kind money -Value "$D.contribution_amount" -EurByModel) })
        (New-HitlLine 'finance.label.rate_per_debit' "$D.contribution_amount" -Kind money -EurByModel -If "($D.contribution_amount && !$D.previous_contribution_amount)")
        # Intervall ohne neue Angabe = das gespeicherte (wie fn_set_pension), beim ersten Beitrag 1
        (Get-FinanceRhythmLine -Label 'finance.label.payment_mode' -Interval "($S.schedule_interval || $R.schedule_interval)" -Unit "$S.schedule_unit" -If "$S.schedule_unit")
        (New-HitlLine 'finance.label.monthly_equivalent' "$D.monthly_contribution" -Kind money -EurByModel -If "($D.monthly_contribution && $D.monthly_contribution != $D.contribution_amount)")
        (New-HitlLine 'finance.label.effective_from' "$D.first_due" -Kind date -If "$D.contribution_amount" -OmitEmpty)
        (New-HitlLine 'finance.label.debit_account' "$S.debit_account_name" -If "$S.debit_account_name")
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

    $cancelBranch = New-HandoffCancelBranch -Pos @(2200, 240) -Action 'the set_pension action'

    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2640, 240) `
        "={{ `$('Set pension (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('handoff_diff', "={{ `$('Set pension (atomic)').item.json.handoff_diff }}", 'string')   # Abweichung vom vereinbarten Soll nach dem Write (finance.fn_with_handoff); leer = wie vereinbart oder kein Soll
        ,@('pension_id', "={{ `$('Set pension (atomic)').item.json.pension_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Set pension (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('contribution_amount', "={{ `$('Set pension (atomic)').item.json.contribution_amount }}", 'number')
        ,@('monthly_contribution', "={{ `$('Set pension (atomic)').item.json.monthly_contribution }}", 'number')
        ,@('first_due', "={{ `$('Set pension (atomic)').item.json.first_due }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_pension mit denselben Werten, immer zurückgerollt. Liefert für die Karte den bisherigen und den neuen Beitrag je Abbuchung, den Monatswert und den ersten Termin mit dem neuen Beitrag. ok:false (z. B. current_value < 0, Beitrag 0, erster Beitrag ohne Datum oder Konto) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyOv = Build-Sticky 'Doc set_pension' @(2200, -240) `
        'fn_set_pension: partielles UPDATE + Beitrags-Kette + Status-Kaskade' `
        'Wert/Status/Stammdaten. current_value ohne Datum -> heute. BEITRAG steht nur an der Beitrags-Kette: neuer Beitrag -> fn_change_owned_recurring (Korrektur direkt nach der Anlage in place, sonst neues Glied ab effective_from, Default nächster offener Termin; der alte Beitrag bleibt Historie). Vorsorge ohne Beitrag: der erste Beitrag legt die Kette an (effective_from = erste Abbuchung, Konto aus Resolve Debit Account). Beitrag 0 gibt es nicht (beitragsfrei = status paused). STATUS-KASKADE über alle Glieder: paused/paid_out -> paused; active -> wieder active bzw. Folge-Zeile ab heute, wenn der Beitrag beendet war.' 220 480

    $nodes = @($trig, $resPen, $ifPen, $errPen, $readCur, $resPerson, $ifPersonBad, $errPerson, $resAcc, $ifAcc, $errAcc) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $cancelBranch.Nodes[0], $cancelBranch.Nodes[1], $cancelBranch.Nodes[2], $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv)

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
            @( E 'Resolve Debit Account' )
        ) }
        'Resolve Debit Account'  = @{ main = @( ,@( E 'Debit ok?' ) ) }
        'Debit ok?'              = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Debit ambiguous' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Reopen handoff task' = @{ main = @( ,@( E 'Return cancelled' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set pension (atomic)' ),
            @( E 'Reopen handoff task' )
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
