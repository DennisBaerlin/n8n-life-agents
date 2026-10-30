#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_create_savings_plan (Sparplan anlegen: Depot, ISIN/Symbol, Betrag, Turnus) ---
function Build-CreateSavingsPlan {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('plan_name','depot_name','isin','symbol','security_name','amount','schedule_interval','schedule_unit','schedule_day_of_month','first_payment_date','notes','beneficiary_person','asset_class','depot_execution_days')

    # WS-4: beguenstigte Person aufloesen (Name -> Slug via core.fn_resolve_person; leer=Haushalt).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(-220, 0) 'beneficiary_person'

    $ifPersonBad = Build-If 'Person invalid?' @(0, 0) `
        "={{ !!`$('Start').item.json.beneficiary_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(0, 200) `
        "=The beneficiary '{{ `$('Start').item.json.beneficiary_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member, or leave empty so the plan belongs to the depot owner."

    # Read-only fuer die Karte: Verrechnungskonto des Depots (von dort wird die Rate abgebucht) + dessen Waehrung.
    # Das Depot selbst loest fn_create_savings_plan auf; bei 0/>1 Treffern bleiben Name/Waehrung leer (die Karte
    # zeigt dann die Zahl ohne Waehrung statt eines falschen Euro-Zeichens, die fn lehnt danach ab).
    $readSettle = Build-Pg 'Read Settlement' @(220, -200) `
        "=SELECT r.hit_count, (SELECT s.name FROM finance.accounts d JOIN finance.accounts s ON s.id = d.settlement_account_id WHERE d.id = r.id) AS settlement_name, r.currency FROM finance.fn_resolve_account((`$1::jsonb)->>'depot_name', ARRAY['stocks_depot','crypto_depot']) r;" `
        ([ordered]@{ depot_name = '$(''Start'').item.json.depot_name' })

    # "DB ist das Gesetz": fn_create_savings_plan laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_savings_plan' -DryPos @(440, 0) -WritePos @(1540, 0) `
        -WriteName 'Create savings plan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'savings_plan_id')::int AS savings_plan_id, (r->>'recurring_payment_id')::int AS recurring_payment_id, COALESCE(r->'savings_squeeze'->>'note', '') AS savings_squeeze, COALESCE(r->'savings_funding'->>'note', '') AS savings_funding" `
        -Params ([ordered]@{
            name                  = '$(''Start'').item.json.plan_name'
            depot_name            = '$(''Start'').item.json.depot_name'
            isin                  = '$(''Start'').item.json.isin'
            symbol                = '$(''Start'').item.json.symbol'
            security_name         = '$(''Start'').item.json.security_name'
            amount                = '$(''Start'').item.json.amount'
            schedule_interval     = '$(''Start'').item.json.schedule_interval'
            schedule_unit         = '$(''Start'').item.json.schedule_unit'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            first_payment_date    = '$(''Start'').item.json.first_payment_date'
            notes                 = '$(''Start'').item.json.notes'
            beneficiary_person_id = '$(''Resolve Person'').item.json.person_id'
            asset_class           = '$(''Start'').item.json.asset_class'
            depot_execution_days  = '$(''Start'').item.json.depot_execution_days'
        })

    # HITL approval gate (Depot loest fn_create_savings_plan intern auf)
    # Strukturiertes Summary (Textkatalog): Rate in der Waehrung des Verrechnungskontos; Crypto hat keine ISIN.
    # Turnus, Begünstigte(r), Betrag je Monat und ein neu gemerkter Bank-Kalender kommen aus dem Probelauf ($Y = r der
    # fn): die DB leitet sie ab (Depot-Kalender, Depot-Inhaber) -> Karte = Write (Post-State-Vertrag).
    $S = "`$('Start').item.json"
    $D = "`$('Read Settlement').item.json"
    $Y = "`$('Dry run').item.json.r"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.create_savings_plan' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'core.label.name'                  "$S.plan_name")
        (New-HitlLine 'finance.label.depot'              "$S.depot_name")
        (New-HitlLine 'finance.label.settlement_account' "$D.settlement_name")
        (New-HitlLine 'finance.label.isin'               "($S.isin ? 'finance.tpl.plain' : 'finance.value.crypto_no_isin')" -Kind tpl -Params @{ value = "$S.isin" })
        (New-HitlLine 'finance.label.symbol_security'    "($S.security_name ? 'finance.tpl.symbol_name' : 'finance.tpl.plain')" -Kind tpl -Params @{ symbol = "($S.symbol || $S.isin)"; name = "$S.security_name"; value = "($S.symbol || $S.isin)" })   # Kennung wie fn_holding_symbol (ohne Ticker = ISIN)
        (New-HitlLine 'core.label.amount'                "$S.amount" -Kind money -Currency "$D.currency")
        (New-HitlLine 'finance.label.cycle'              "($Y.schedule_days ? 'finance.tpl.plan_days_of_month' : (Number($Y.schedule_day_of_month) < 0 ? 'finance.tpl.plan_interval_month_end' : ($Y.schedule_day_of_month ? 'finance.tpl.plan_interval_day' : 'finance.tpl.plan_interval_same_day')))" -Kind tpl -Params @{
            days     = "$Y.schedule_days"
            interval = "$Y.schedule_interval"
            unit     = (New-HitlValue -Kind enum -Value "$Y.schedule_unit" -Enum 'finance.enum.schedule_unit')
            day      = "$Y.schedule_day_of_month"
            end      = (New-HitlValue -Kind key -Value (Get-FinanceMonthEndKey "$Y.schedule_day_of_month")) })
        (New-HitlLine 'finance.label.monthly_equivalent' "$Y.monthly_amount" -Kind money -Currency "$D.currency")
        (New-HitlLine 'finance.label.bank_calendar'      "$Y.calendar_learned" -If "$Y.calendar_learned")
        (New-HitlLine 'finance.label.first_execution'    (Get-DryEffectiveExpr 'first_payment_date') -Kind date)
        (New-HitlLine 'finance.label.beneficiary_person' "($Y.beneficiary_name ? 'finance.tpl.plain' : 'finance.value.household')" -Kind tpl -Params @{ value = "$Y.beneficiary_name" })
        (New-HitlLine 'finance.label.asset_class'        "'finance.tpl.asset_class_inherited'" -Kind tpl -Params @{ value = "$S.asset_class" } -If "$S.asset_class")
        (New-HitlLine 'core.label.note'                  "$S.notes")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1100, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1320, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1540, 240) 'the create_savings_plan action'

    # Atomarer Write via fn_create_savings_plan:
    # 1. Depot per Name aufloesen + Typ/Settlement pruefen (Depot-Typ vs. ISIN-Presence)
    # 2. Uniqueness-Guard (lower(name))
    # 3. recurring_payment INSERT auf Verrechnungskonto (negativ = Ausgabe, -amount)
    # 4. finance.savings_plans INSERT mit FK-Link
    # fn liefert ok/reason: Depot nicht gefunden, Typ-Mismatch, Duplikat, amount<=0 -> {ok:false}

    $ifWriteOk = Build-If 'Write ok?' @(1760, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Plan rejected' @(1980, 240) `
        "={{ `$('Create savings plan (atomic)').item.json.reason }}"

    $ret = Build-Return @(1980, 0) @(
        ,@('ok','true','boolean')
        ,@('savings_plan_id', "={{ `$('Create savings plan (atomic)').item.json.savings_plan_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Create savings plan (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('savings_squeeze', "={{ `$('Create savings plan (atomic)').item.json.savings_squeeze }}", 'string')
        ,@('savings_funding', "={{ `$('Create savings plan (atomic)').item.json.savings_funding }}", 'string')
    )

    $stickyFn = Build-Sticky 'fn_create_savings_plan: 4 Schritte + Anlageklasse-Vererbung' @(1540, -240) `
        'fn_create_savings_plan (atomar)' `
        'Schritte in EINER DB-Transaktion: (1) Depot per Name auflösen + Typ/Settlement-Check (stocks_depot=ISIN erwartet, crypto_depot=kein ISIN), (2) Uniqueness-Guard lower(name), (3) recurring_payment INSERT auf Verrechnungskonto (amount=-betrag, negativ = Ausgabe), (4) finance.savings_plans INSERT mit FK recurring_payment_id. Kein Cron-Change nötig -- fn_recurring_due_open erkennt neue RPs automatisch. Rhythmus über den Depot-Kalender (fn_resolve_plan_schedule): Bank mit festen Monatstagen (z. B. 2./9./16./23.) -> wöchentlich = month + schedule_days_of_month; unbekannter Kalender bei wöchentlich -> {ok:false, needs_calendar} (der Agent fragt einmal, depot_execution_days); gelernter/vorbelegter Kalender wird am Depot gespeichert. Begünstigte(r) leer -> Depot-Inhaber (fn_default_beneficiary, über r.effective fest in den Write). Phase L WS-6: das optionale asset_class ($fromAI, lowercase snake, Format-Verstoss -> {ok:false}) wird gespeichert + von fn_book_savings_plan_execution an fn_book_stock_buy vererbt -> die Position wird beim Anlegen getaggt, nie leer. Nach dem Write liest fn_savings_squeeze_fold monthly_cashflow_summary: Kontoveränderung nach dem Sparen < 0 -> Note in savings_squeeze (gelatcht 24 h, sonst leer; erster Abbuchungstag in der Zukunft -> erst der Cron). Danach liest fn_savings_funding_fold die Spar-Deckung des Abbuchungskontos (fn_account_funding, auch mit erster Ausführung in der Zukunft): Kartenzeile "Danach ..." schon im Probelauf + bei einer Lücke die Frage-Note savings_funding, gelatcht je Konto bis es wieder gedeckt ist (Bookkeeper fragt nach der Geldquelle, core rule 9).' 250 820

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(1980, -240) `
        'fn-Rückgabe {ok:false, reason}' `
        'Depot nicht gefunden/kein Settlement, Typ-Mismatch (ISIN auf crypto_depot oder umgekehrt), Duplikat-Name, amount<=0 -> {ok:false, reason}. Nur ok=true legt wirklich an.' 200 380

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_savings_plan mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (Depot nicht gefunden/ohne Verrechnungskonto, Typ-Mismatch (ISIN), Duplikat-Name, amount kleiner/gleich 0, Rhythmus passt nicht zum Depot-Kalender (code off_calendar / rhythm_not_offered) oder Kalender unbekannt (code needs_calendar)) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 540

    $nodes = @($trig, $resPerson, $ifPersonBad, $errPerson, $readSettle) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyFn, $stickyOk,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                          = @{ main = @( ,@( E 'Resolve Person' ) ) }
        'Resolve Person'                 = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'                = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Read Settlement' )
        ) }
        'Read Settlement'                = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'         = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'               = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                      = @{ main = @(
            @( E 'Create savings plan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create savings plan (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                      = @{ main = @(
            @( E 'Return' ),
            @( E 'Plan rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_savings_plan' $nodes $conns `
        @{ Category = 'securities' }
}
