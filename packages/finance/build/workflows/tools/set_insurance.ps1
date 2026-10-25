#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_insurance (set_*: Versicherung aendern, mit Recurring-Sync) ---
function Build-SetInsurance {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('insurance_name','new_name','insurance_company','policy_number','policyholder_person',
                           'premium_amount','annual_premium','schedule_interval','schedule_unit','schedule_day_of_month',
                           'effective_from','valid_to','status','notes',
                           'insurance_type','beneficiary','coverage_amount','claim_deadline_hours')  # WS-0b estate

    $resIns = Build-Pg 'Resolve Insurance' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_insurance((`$1::jsonb)->>'insurance_name', TRUE);" `
        ([ordered]@{ insurance_name = '$(''Start'').item.json.insurance_name' })

    $ifIns = Build-If 'Insurance unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errIns = Build-ToolError 'Insurance ambiguous' @(660, 200) `
        "=Insurance '{{ `$('Start').item.json.insurance_name }}' resolves to {{ `$('Resolve Insurance').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Insurance').item.json.candidates) }}. Ask the user which exact policy."

    # Aktuelle Werte fuer die Karte (alt->neu): Beitrag/Rhythmus aus dem heute gueltigen Glied der Beitrags-Kette (WP2: die
    # Police traegt keine Kopie), Jahreswert abgeleitet (fn_annual_equivalent), Status von der Police.
    $readCur = Build-Pg 'Read Current' @(660, 0) `
        "=SELECT finance.fn_annual_equivalent(abs(rc.amount), rc.schedule_interval, rc.schedule_unit, COALESCE(cardinality(rc.schedule_days_of_month), 1)) AS annual_premium, abs(rc.amount) AS premium_amount, rc.schedule_interval, rc.schedule_unit::text AS schedule_unit, i.status::text AS status FROM finance.insurances i LEFT JOIN finance.recurring_payments rc ON rc.id = finance.fn_recurring_current(i.recurring_payment_id, current_date) WHERE i.id = ((`$1::jsonb)->>'id')::int;" `
        ([ordered]@{ id = '$(''Resolve Insurance'').item.json.id' })

    # Read-only Vorschau fuer die Karte: Rohwerte aus DERSELBEN fn wie der Write (fn_insurance_fields: "1.200" -> 1200,
    # Meldefrist, Typ, Beitrag; Status per fn_enum_reason). Ohne genannten Rhythmus gilt der bisherige (wie fn_set_insurance).
    # Den wirksamen Beitrag je Abbuchung + Jahreswert + Stichtag zeigt die Karte aus dem Probelauf (r.*).
    $preview = Build-Pg 'Preview Rate' @(880, 0) `
        "=SELECT r IS NULL AND (f->>'ok')::boolean AS ok, COALESCE(r, f->>'reason') AS reason, (f->>'coverage_amount')::numeric AS coverage_amount FROM finance.fn_insurance_fields(`$1::jsonb) AS f, finance.fn_enum_reason('finance.insurance_status'::regtype, (`$1::jsonb)->>'status', 'status') AS r;" `
        ([ordered]@{ premium_amount = '$(''Start'').item.json.premium_amount'; annual_premium = '$(''Start'').item.json.annual_premium'; coverage_amount = '$(''Start'').item.json.coverage_amount'; claim_deadline_hours = '$(''Start'').item.json.claim_deadline_hours'; insurance_type = '$(''Start'').item.json.insurance_type'; status = '$(''Start'').item.json.status'; schedule_interval = '($(''Start'').item.json.schedule_interval || $(''Read Current'').item.json.schedule_interval)'; schedule_unit = '($(''Start'').item.json.schedule_unit || $(''Read Current'').item.json.schedule_unit)' })
    $ifFields = Build-If 'Fields ok?' @(1100, -120) "={{ `$('Preview Rate').item.json.ok }}" 'true' 'equals' 'boolean'
    $errFields = Build-ToolError 'Invalid values' @(1320, -240) "={{ `$('Preview Rate').item.json.reason }}"

    # WS-4: optionalen Versicherungsnehmer-Wechsel aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-Pg 'Resolve Person' @(1100, 360) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'policyholder_person', ''));" `
        ([ordered]@{ policyholder_person = '$(''Start'').item.json.policyholder_person' })

    $ifPersonBad = Build-If 'Person invalid?' @(1320, 360) `
        "={{ !!`$('Start').item.json.policyholder_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1540, 480) `
        "=The policyholder '{{ `$('Start').item.json.policyholder_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # "DB ist das Gesetz": fn_set_insurance laeuft als Probelauf VOR der Karte (nach Preview Rate / Fields ok?); derselbe
    # Param-Satz geht nach dem Gate in den echten Write (partielles UPDATE + Recurring-Sync + Kuendigungs-Kaskade).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_insurance' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Set insurance (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'insurance_id')::int AS insurance_id, (r->>'recurring_payment_id')::int AS recurring_payment_id" `
        -Params ([ordered]@{
            insurance_id          = '$(''Resolve Insurance'').item.json.id'
            name                  = '$(''Start'').item.json.new_name'
            insurance_company     = '$(''Start'').item.json.insurance_company'
            policy_number         = '$(''Start'').item.json.policy_number'
            policyholder_person_id = '$(''Resolve Person'').item.json.person_id'
            premium_amount        = '$(''Start'').item.json.premium_amount'
            annual_premium        = '$(''Start'').item.json.annual_premium'
            effective_from        = '$(''Start'').item.json.effective_from'
            schedule_interval     = '$(''Start'').item.json.schedule_interval'
            schedule_unit         = '$(''Start'').item.json.schedule_unit'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            valid_to              = '$(''Start'').item.json.valid_to'
            status                = '$(''Start'').item.json.status'
            notes                 = '$(''Start'').item.json.notes'
            insurance_type        = '$(''Start'').item.json.insurance_type'          # WS-0b estate
            beneficiary           = '$(''Start'').item.json.beneficiary'
            coverage_amount       = '$(''Start'').item.json.coverage_amount'
            claim_deadline_hours  = '$(''Start'').item.json.claim_deadline_hours'
        })

    # Strukturiertes Summary (Textkatalog): nur gelieferte Felder (-If je Zeile). Jahresbeitrag/Versicherungssumme in
    # EUR-Konvention; Nachlass-Felder (WS-0b estate) optional.
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $D = "`$('Dry run').item.json.r"
    $hasPrem = "($S.premium_amount || $S.annual_premium)"
    $P = "`$('Resolve Person').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.set_insurance' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.insurance'           "$S.insurance_name")
        (New-HitlLine 'finance.label.new_name'            "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.rate_per_debit'      "'finance.tpl.change'" -Kind tpl -If $hasPrem -Params @{
            from = (New-HitlValue -Kind money -Value "$R.premium_amount" -EurByModel)
            to   = (New-HitlValue -Kind money -Value "$D.premium_amount" -EurByModel) })
        (New-HitlLine 'finance.label.payment_mode'        "'finance.tpl.every_unit'" -Kind tpl -If "$S.schedule_unit" -Params @{
            interval = "($S.schedule_interval || '1')"
            unit     = (New-HitlValue -Kind enum -Value "$S.schedule_unit" -Enum 'finance.enum.schedule_unit') })
        (New-HitlLine 'finance.label.annual_contribution' "'finance.tpl.change'" -Kind tpl -If $hasPrem -Params @{
            from = (New-HitlValue -Kind money -Value "$R.annual_premium" -EurByModel)
            to   = (New-HitlValue -Kind money -Value "$D.annual_premium" -EurByModel) })
        (New-HitlLine 'finance.label.effective_from'      "$D.effective_from" -Kind date -If "($hasPrem || $S.schedule_day_of_month)" -OmitEmpty)
        (New-HitlLine 'finance.label.policyholder_person' "($P.full_name || $S.policyholder_person)" -If "$S.policyholder_person")
        (New-HitlLine 'finance.label.company'             "$S.insurance_company" -If "$S.insurance_company")
        (New-HitlLine 'finance.label.policy_number'       "$S.policy_number" -If "$S.policy_number")
        (New-HitlLine 'finance.label.insurance_type'      "$S.insurance_type" -Kind enum -Enum 'finance.enum.insurance_type' -If "$S.insurance_type")
        (New-HitlLine 'finance.label.coverage_amount'     "`$('Preview Rate').item.json.coverage_amount" -Kind money -EurByModel -If "$S.coverage_amount")
        (New-HitlLine 'finance.label.beneficiary'         "$S.beneficiary" -If "$S.beneficiary")
        (New-HitlLine 'finance.label.claim_deadline'      "'finance.tpl.hours'" -Kind tpl -Params @{ value = "$S.claim_deadline_hours" } -If "$S.claim_deadline_hours")
        (New-HitlLine 'core.label.status'                 "'finance.tpl.change'" -Kind tpl -If "$S.status" -Params @{
            from = (New-HitlValue -Kind enum -Value "$R.status" -Enum 'finance.enum.insurance_status')
            to   = (New-HitlValue -Kind enum -Value "$S.status" -Enum 'finance.enum.insurance_status') })
        (New-HitlLine 'finance.label.valid_to'            "$S.valid_to" -Kind date -If "$S.valid_to")
        (New-HitlLine 'core.label.note'                   "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'finance.note.set_insurance_pause' -If "($S.status == 'cancelled' || $S.status == 'expired')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 240) 'the set_insurance action'

    # Atomarer Write via fn_set_insurance ($wg.Write, 'Set insurance (atomic)'): partielles UPDATE + Recurring-Sync
    # (Betrag/Schedule) + Kuendigungs-Kaskade.
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2860, 240) `
        "={{ `$('Set insurance (atomic)').item.json.reason }}"

    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('insurance_id', "={{ `$('Set insurance (atomic)').item.json.insurance_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Set insurance (atomic)').item.json.recurring_payment_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -440) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_insurance mit denselben Werten, immer zurückgerollt (nach Preview Rate / Fields ok?). Liefert den wirksamen Beitrag je Abbuchung, den Jahreswert und den Stichtag für die Karte. ok:false (z. B. Beitrag nicht positiv, neuer Rhythmus ohne Betrag) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (CHECK, Recurring-Sync) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyGen = Build-Sticky 'DB-Automatik Beitrags-Kette' @(2420, -280) `
        'Eine Quelle: Beitrags-Kette (WP2)' `
        'Beitrag, Rhythmus, Tag und Vertragsende stehen nur an der Beitrags-Kette. Neuer Beitrag/Rhythmus/Tag -> fn_change_owned_recurring: Korrektur direkt nach der Anlage in place, sonst neues Glied ab effective_from (Default nächster offener Termin), der alte Beitrag bleibt Historie. status=cancelled/expired -> Kette endet zum Vertragsende (paused erst, wenn erreicht). Umbenennung führt Versicherung <Name> an allen Gliedern mit. WS-0b (estate): die optionalen Nachlass-Felder insurance_type (geschlossene Liste, CHECK=Backstop) / beneficiary / coverage_amount / claim_deadline_hours werden partiell mitgesetzt (leer=unverändert) und vom estate-Paket über finance.fn_insurance_register() (Oberfläche A) gelesen.' 220 480

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -240) `
        'fn-Rückgabe {ok:false, reason}' `
        'Nicht-positiver/unstimmiger Beitrag, Rhythmus ohne Betrag, Split-Guards -> {ok:false, reason} -> Update rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true ändert wirklich. Normalerweise fängt schon der Probelauf diese Fälle vor der Karte ab; hier landet nur, was sich zwischen Karte und Tipp geändert hat.' 200 400

    $nodes = @($trig, $resIns, $ifIns, $errIns, $readCur, $preview, $ifFields, $errFields, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyGen, $stickyOk)

    $conns = [ordered]@{
        'Start'                     = @{ main = @( ,@( E 'Resolve Insurance' ) ) }
        'Resolve Insurance'         = @{ main = @( ,@( E 'Insurance unique?' ) ) }
        'Insurance unique?'         = @{ main = @(
            @( E 'Read Current' ),
            @( E 'Insurance ambiguous' )
        ) }
        'Read Current'              = @{ main = @( ,@( E 'Preview Rate' ) ) }
        'Preview Rate'          = @{ main = @( ,@( E 'Fields ok?' ) ) }
        'Fields ok?'                = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Invalid values' )
        ) }
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
            @( E 'Set insurance (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set insurance (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                 = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_insurance' $nodes $conns `
        @{ Category = 'insurance' }
}
