#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_savings_plan (Sparplan aendern: Betrag-Split, Pause, Resume, Notiz) ---
function Build-SetSavingsPlan {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('savings_plan_name','new_amount','schedule_unit','schedule_interval','status','valid_from','notes','beneficiary_person','asset_class','depot_execution_days')

    # Aktuelle Werte fuer informativen HITL-Summary
    $readCur = Build-Pg 'Read Current' @(220, 0) `
        "=SELECT sp.symbol, sp.security_name, ABS(rp.amount) AS current_amount, (SELECT a.currency FROM finance.accounts a WHERE a.id = rp.account_id) AS currency, sp.status::text AS plan_status FROM finance.savings_plans sp JOIN finance.recurring_payments rp ON rp.id = sp.recurring_payment_id WHERE sp.name ILIKE ((`$1::jsonb)->>'savings_plan_name') LIMIT 1;" `
        ([ordered]@{ savings_plan_name = '$(''Start'').item.json.savings_plan_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, Muster close_savings_plan).
    $found = New-RequiredRowGate -Read $readCur -KeyField 'plan_status' -IfName 'Savings Plan found?' -ErrName 'Savings Plan not found' `
        -IfPos @(330, -160) -ErrPos @(440, -320) `
        -NotFoundExpr "=No savings plan named '{{ `$('Start').item.json.savings_plan_name }}' exists. List them via postgres_select on finance.savings_plans and ask the user which one is meant."

    # WS-4: optionale beguenstigte Person aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(220, 360) 'beneficiary_person'

    $ifPersonBad = Build-If 'Person invalid?' @(440, 360) `
        "={{ !!`$('Start').item.json.beneficiary_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(660, 480) `
        "=The beneficiary '{{ `$('Start').item.json.beneficiary_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # "DB ist das Gesetz": fn_set_savings_plan laeuft als Probelauf VOR der Karte (Betrag <= 0, Stichtag <= valid_from,
    # Anlageklassen-Format -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten Write:
    # - new_amount gesetzt: Validity-Split (alte RP valid_to=v_from, neue RP ab v_from;
    #   plan.recurring_payment_id zeigt auf neue RP)
    # - status gesetzt: IN-PLACE (plan.status + rp.status kaskadiert)
    # - nur notes: IN-PLACE notes-Update
    $wg = New-FnWriteGate -Fn 'finance.fn_set_savings_plan' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Set plan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'savings_plan_id')::int AS savings_plan_id, (r->>'recurring_payment_id')::int AS recurring_payment_id, (r->>'split')::boolean AS split, COALESCE(r->'savings_squeeze'->>'note', '') AS savings_squeeze" `
        -Params ([ordered]@{
            savings_plan_name = '$(''Start'').item.json.savings_plan_name'
            new_amount        = '$(''Start'').item.json.new_amount'
            schedule_unit     = '$(''Start'').item.json.schedule_unit'
            schedule_interval = '$(''Start'').item.json.schedule_interval'
            status            = '$(''Start'').item.json.status'
            valid_from        = '$(''Start'').item.json.valid_from'
            notes             = '$(''Start'').item.json.notes'
            beneficiary_person_id = '$(''Resolve Person'').item.json.person_id'
            asset_class       = '$(''Start'').item.json.asset_class'
            depot_execution_days = '$(''Start'').item.json.depot_execution_days'
        })

    # Strukturiertes Summary (Textkatalog): nur gelieferte Felder (-If je Zeile). Sparrate in der Konto-Waehrung (Read Current);
    # valid_from als Datum unter Erhalt des "heute"-Fallbacks bei leerem Feld.
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $P = "`$('Resolve Person').item.json"
    $Y = "`$('Dry run').item.json.r"   # Probelauf: abgeleitete Tage (Depot-Kalender) + Betrag je Monat der neuen Zeile
    $validFrom = "($S.valid_from ? " + (New-HitlValue -Kind date -Value "$S.valid_from") + " : " + (New-HitlValue -Kind key -Value "'finance.value.today'") + ")"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.set_savings_plan' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.plan'               "'finance.tpl.name_symbol'" -Kind tpl -Params @{ name = "$S.savings_plan_name"; symbol = "$R.symbol" })
        (New-HitlLine 'finance.label.beneficiary_person' "($P.full_name || $S.beneficiary_person)" -If "$S.beneficiary_person")
        (New-HitlLine 'core.label.amount'                "'finance.tpl.amount_change_split'" -Kind tpl -If "$S.new_amount" -Params @{
            from = (New-HitlValue -Kind money -Value "$R.current_amount" -Currency "$R.currency")
            to   = (New-HitlValue -Kind money -Value "$S.new_amount" -Currency "$R.currency")
            date = $validFrom })
        (New-HitlLine 'finance.label.rhythm'             "($Y.schedule_days ? 'finance.tpl.cycle_days_split' : 'finance.tpl.cycle_split')" -Kind tpl -If "($S.schedule_unit || $S.schedule_interval)" -Params @{
            days     = "$Y.schedule_days"
            interval = "$Y.schedule_interval"
            unit     = (New-HitlValue -Kind enum -Value "$Y.schedule_unit" -Enum 'finance.enum.schedule_unit')
            date     = $validFrom })
        (New-HitlLine 'finance.label.monthly_equivalent' "$Y.monthly_amount" -Kind money -Currency "$R.currency" -If "$Y.monthly_amount")
        (New-HitlLine 'core.label.status'                "'finance.tpl.change'" -Kind tpl -If "$S.status" -Params @{
            from = (New-HitlValue -Kind enum -Value "$R.plan_status" -Enum 'finance.enum.status')
            to   = (New-HitlValue -Kind enum -Value "$S.status" -Enum 'finance.enum.status') })
        (New-HitlLine 'finance.label.asset_class'        "'finance.tpl.asset_class_from_next'" -Kind tpl -Params @{ value = "$S.asset_class" } -If "$S.asset_class")
        (New-HitlLine 'finance.label.new_note'           "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'finance.note.set_plan_split' -If "($S.new_amount || $S.schedule_unit || $S.schedule_interval)")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the set_savings_plan action'

    # Atomarer Write via fn_set_savings_plan ($wg.Write, 'Set plan (atomic)').
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2200, 240) `
        "={{ `$('Set plan (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('savings_plan_id', "={{ `$('Set plan (atomic)').item.json.savings_plan_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Set plan (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('split', "={{ `$('Set plan (atomic)').item.json.split }}", 'boolean')
        ,@('savings_squeeze', "={{ `$('Set plan (atomic)').item.json.savings_squeeze }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_savings_plan mit denselben Werten, immer zurückgerollt. ok:false (Betrag <= 0, Stichtag <= valid_from, Anlageklasse im falschen Format, Rhythmus passt nicht zum Depot-Kalender bzw. Kalender unbekannt; ein unbekannter Name endet schon vorher am Found?-Gate) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_set_savings_plan: Split vs. In-Place + Anlageklasse' @(1760, -240) `
        'Betrag/Kadenz = Validity-Split; Status/Notiz/Anlageklasse = In-Place' `
        'new_amount ODER schedule_unit/schedule_interval (WS-B Stufe 2: Kadenz editierbar) -> Validity-Split: altes RP beendet (valid_to=Stichtag), neues RP ab Stichtag (nicht-genannte Betrags-/Kadenz-Felder aus der alten Zeile übernommen -> reine Kadenz-Änderung erhält den Betrag), plan.recurring_payment_id aktualisiert. Kadenzwechsel über den Depot-Kalender (fn_resolve_plan_schedule, wie beim Anlegen): Bank mit festen Monatstagen -> Tage statt 7-Tage-Abstand, Stichtag muss ein Kalendertag sein (sonst ok:false + nächster Tag); depot_execution_days korrigiert den Kalender am Depot; ein reiner Betrags-Split erbt die Tage. status paused/active -> IN-PLACE auf plan + kaskadierend auf RP. Nur notes -> IN-PLACE notes. Phase L WS-6: asset_class ($fromAI, Format-Verstoss -> {ok:false}) = IN-PLACE-Korrektur, orthogonal (kein Split); vererbt sich ab der nächsten Ausführung. fn lehnt new_amount<=0 und Stichtag<=valid_from ab ({ok:false}). Ändert der Write die laufende Rate (Split/Reaktivierung ab heute, Status-Wechsel), liest fn_savings_squeeze_fold monthly_cashflow_summary: Kontoveränderung nach dem Sparen < 0 -> Note in savings_squeeze (gelatcht 24 h, sonst leer; Split mit künftigem Stichtag oder reine Notiz-/Anlageklasse-Edits -> keine Note). Bookkeeper relayed.' 250 640

    $nodes = @($trig, $readCur, $found.If, $found.Err, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Current' ) ) }
        'Read Current'           = @{ main = @( ,@( E 'Savings Plan found?' ) ) }
        'Savings Plan found?'    = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Savings Plan not found' )
        ) }
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
            @( E 'Set plan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set plan (atomic)'      = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_savings_plan' $nodes $conns `
        @{ Category = 'securities' }
}
