#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_savings_goal (set_*: Sparziel aendern, Rate neu rechnen) ---
function Build-SetSavingsGoal {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('goal_name','new_name','target_amount','target_date','status','notes','beneficiary_person','reserve_account_name','priority','link_savings_plan_name','unlink_savings_plan_name','stop_funders','account_name','replace_transfer')

    $resGoal = Build-Pg 'Resolve Goal' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_savings_goal((`$1::jsonb)->>'goal_name', TRUE);" `
        ([ordered]@{ goal_name = '$(''Start'').item.json.goal_name' })

    $ifGoal = Build-If 'Goal unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errGoal = Build-ToolError 'Goal ambiguous' @(660, 200) `
        "=Savings goal '{{ `$('Start').item.json.goal_name }}' resolves to {{ `$('Resolve Goal').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Goal').item.json.candidates) }}. Ask the user which exact goal."

    $readCur = Build-Pg 'Read Current' @(660, 0) `
        "=SELECT target_amount, target_date, status::text AS status FROM finance.savings_goals WHERE id = ((`$1::jsonb)->>'id')::int;" `
        ([ordered]@{ id = '$(''Resolve Goal'').item.json.id' })

    # WS-4: optionale beguenstigte Person aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(880, 360) 'beneficiary_person'

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.beneficiary_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The beneficiary '{{ `$('Start').item.json.beneficiary_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # WS-A: optionaler Reserve-Topf (Name -> id, saldo-basiert: finance.fn_goal_pot_account_types) — OPTIONAL wie beneficiary_person.
    # Leer -> id NULL -> fn laesst den Topf unveraendert. Gesetzt -> rate.target_account_id zieht mit (Rate wird Umbuchung);
    # ALTE getaggte Buchungen bleiben dem Ziel zugeordnet (nur kuenftiges Routing aendert sich).
    $resReserve = Build-Pg 'Resolve Reserve' @(880, 600) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account(NULLIF((`$1::jsonb)->>'reserve_account_name', ''), finance.fn_goal_pot_account_types()::text[]);" `
        ([ordered]@{ reserve_account_name = '$(''Start'').item.json.reserve_account_name' })

    $ifReserveBad = Build-If 'Reserve invalid?' @(1100, 600) `
        "={{ !!`$('Start').item.json.reserve_account_name && `$('Resolve Reserve').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errReserve = Build-ToolError 'Reserve unresolved' @(1320, 720) `
        "=The reserve account '{{ `$('Start').item.json.reserve_account_name }}' could not be uniquely resolved ({{ `$('Resolve Reserve').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Reserve').item.json.candidates) }}. Ask which exact cash/Tagesgeld, fixed-deposit or P2P account."

    # Sparziel-Zweckbindung 2026-10-27: optionales Abbuchungskonto, um fuer ein Ziel OHNE laufende Rate eine Rate auf dem
    # Rest anzulegen (fn_set_savings_goal entscheidet; leer = keine neue Rate).
    $resFund = Build-Pg 'Resolve Funding' @(1320, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account(NULLIF((`$1::jsonb)->>'account_name', ''), ARRAY['cash','p2p']);" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifFundBad = Build-If 'Funding invalid?' @(1540, 0) `
        "={{ !!`$('Start').item.json.account_name && `$('Resolve Funding').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errFund = Build-ToolError 'Funding unresolved' @(1760, 200) `
        "=The debit account '{{ `$('Start').item.json.account_name }}' could not be uniquely resolved ({{ `$('Resolve Funding').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Funding').item.json.candidates) }}. Ask which exact account."

    # "DB ist das Gesetz": fn_set_savings_goal laeuft als Probelauf VOR der Karte (kein Topf fuer eine neue Rate, Zieldatum
    # Vergangenheit, Sparplan-Link-Konflikte usw. -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in
    # den echten Write (Rate aus Rest-Betrag/Rest-Zeit + Recurring-Sync + Status-Kaskade).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_savings_goal' -DryPos @(1760, 0) -WritePos @(3080, 0) `
        -WriteName 'Set goal (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'goal_id')::int AS goal_id, (r->>'recurring_payment_id')::int AS recurring_payment_id, (r->>'new_monthly_rate')::numeric AS new_monthly_rate, COALESCE((r->>'covered')::boolean, false) AS covered, (r->>'required_monthly_rate')::numeric AS required_monthly_rate, COALESCE(r->>'note', '') AS rate_note, (r->>'linked_savings_plan_id')::int AS linked_savings_plan_id, (r->>'paused_cash_rate')::boolean AS paused_cash_rate, (r->>'paused_plan_count')::int AS paused_plan_count, (r->>'replaced_transfer_id')::int AS replaced_transfer_id, COALESCE(r->'savings_squeeze'->>'note', '') AS savings_squeeze" `
        -Params ([ordered]@{
            goal_id       = '$(''Resolve Goal'').item.json.id'
            name          = '$(''Start'').item.json.new_name'
            target_amount = '$(''Start'').item.json.target_amount'
            target_date   = '$(''Start'').item.json.target_date'
            status        = '$(''Start'').item.json.status'
            notes         = '$(''Start'').item.json.notes'
            beneficiary_person_id = '$(''Resolve Person'').item.json.person_id'
            reserve_account_id    = '$(''Resolve Reserve'').item.json.id'
            priority              = '$(''Start'').item.json.priority'
            link_savings_plan_name   = '$(''Start'').item.json.link_savings_plan_name'
            unlink_savings_plan_name = '$(''Start'').item.json.unlink_savings_plan_name'
            stop_funders             = '$(''Start'').item.json.stop_funders'
            account_id               = '$(''Resolve Funding'').item.json.id'
            replace_transfer         = '$(''Start'').item.json.replace_transfer'
        })

    # Strukturiertes Summary (Textkatalog): nur gelieferte Felder (-If je Zeile). Zielbetrag alt/neu in EUR-Konvention,
    # Zieldatum alt/neu als Datum.
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $P = "`$('Resolve Person').item.json"
    $RS = "`$('Resolve Reserve').item.json"
    $Y  = "`$('Dry run').item.json.r"
    $summary = New-HitlSummary -Pos @(2420, 0) -Title 'finance.hitl.set_savings_goal' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.goal'               "$S.goal_name")
        (New-HitlLine 'finance.label.new_name'           "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.beneficiary_person' "($P.full_name || $S.beneficiary_person)" -If "$S.beneficiary_person")
        (New-HitlLine 'finance.label.target_amount'      "'finance.tpl.change'" -Kind tpl -If "$S.target_amount" -Params @{
            from = (New-HitlValue -Kind money -Value "$R.target_amount" -EurByModel)
            to   = (New-HitlValue -Kind money -Value "$S.target_amount" -EurByModel) })
        (New-HitlLine 'finance.label.target_date'        "'finance.tpl.change'" -Kind tpl -If "$S.target_date" -Params @{
            from = (New-HitlValue -Kind date -Value "$R.target_date")
            to   = (New-HitlValue -Kind date -Value (Get-DryEffectiveExpr 'target_date')) })
        (New-HitlLine 'core.label.status'                "'finance.tpl.change'" -Kind tpl -If "$S.status" -Params @{
            from = (New-HitlValue -Kind enum -Value "$R.status" -Enum 'finance.enum.status')
            to   = (New-HitlValue -Kind enum -Value "$S.status" -Enum 'finance.enum.status') })
        (New-HitlLine 'core.label.note'                  "$S.notes" -If "$S.notes")
        (New-HitlLine 'finance.label.priority'           "'finance.tpl.priority_hint'" -Kind tpl -Params @{ value = "$S.priority" } -If "$S.priority")
        (New-HitlLine 'finance.label.link_savings_plan'  "'finance.tpl.link_savings_plan'" -Kind tpl -Params @{ name = "$S.link_savings_plan_name" } -If "$S.link_savings_plan_name")
        (New-HitlLine 'finance.label.unlink_savings_plan' "$S.unlink_savings_plan_name" -If "$S.unlink_savings_plan_name")
        (New-HitlLine 'finance.label.reserve_pot'        "'finance.tpl.reserve_pot_set'" -Kind tpl -Params @{ name = "$S.reserve_account_name" } -If "$RS.id")
        (New-HitlLine 'finance.label.stop_funding'       "'finance.value.stop_funders'" -Kind key -If "$S.stop_funders")
        # neue bzw. neu gerechnete Rate aus dem Probelauf (Karte = Write); eine neue Rate kommt vom genannten Konto
        (New-HitlLine 'finance.label.monthly_savings_rate' "$Y.new_monthly_rate" -Kind money -EurByModel -If "$Y.new_monthly_rate")
        (New-HitlLine 'finance.label.debit_account'      "$S.account_name" -If "$S.account_name && $Y.new_monthly_rate")
        (New-HitlNote -Key 'finance.note.goal_covered' -If "$Y.covered")
        (New-HitlNote -Key 'finance.note.set_goal_recalc' -If "($S.target_amount || $S.target_date) && !$Y.covered")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(2640, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2860, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(3080, 240) 'the set_savings_goal action'

    # Atomarer Write via fn_set_savings_goal ($wg.Write, 'Set goal (atomic)').
    $ifWriteOk = Build-If 'Write ok?' @(3300, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(3520, 240) `
        "={{ `$('Set goal (atomic)').item.json.reason }}"

    $ret = Build-Return @(3520, 0) @(
        ,@('ok','true','boolean')
        ,@('goal_id', "={{ `$('Set goal (atomic)').item.json.goal_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Set goal (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('new_monthly_rate', "={{ `$('Set goal (atomic)').item.json.new_monthly_rate }}", 'number')
        ,@('covered', "={{ `$('Set goal (atomic)').item.json.covered }}", 'boolean')
        ,@('required_monthly_rate', "={{ `$('Set goal (atomic)').item.json.required_monthly_rate }}", 'number')
        ,@('rate_note', "={{ `$('Set goal (atomic)').item.json.rate_note }}", 'string')
        ,@('linked_savings_plan_id', "={{ `$('Set goal (atomic)').item.json.linked_savings_plan_id }}", 'number')
        ,@('paused_cash_rate', "={{ `$('Set goal (atomic)').item.json.paused_cash_rate }}", 'boolean')
        ,@('paused_plan_count', "={{ `$('Set goal (atomic)').item.json.paused_plan_count }}", 'number')
        ,@('replaced_transfer_id', "={{ `$('Set goal (atomic)').item.json.replaced_transfer_id }}", 'number')
        ,@('savings_squeeze', "={{ `$('Set goal (atomic)').item.json.savings_squeeze }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1760, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_savings_goal mit denselben Werten, immer zurückgerollt (nach den Person-/Topf-/Abbuchungskonto-Checks). ok:false (Zielbetrag <= 0, Zieldatum in der Vergangenheit, Topf = Abbuchungskonto, kein Topf für eine neue Rate, existing_transfer/transfer_not_monthly, Sparplan nicht gefunden/fremd gebunden) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyOv = Build-Sticky 'Doc set_savings_goal' @(3080, -240) `
        'fn_set_savings_goal: Rate Rest/Rest-Zeit + Recurring-Sync' `
        'Ziel/Datum-Änderung -> Sparrate = (Zielbetrag - bereits gespart) / Rest-Monate (NICHT Gesamt/Gesamt) -> verknüpfte Sparrate (recurring) in-place. Gedecktes Ziel (Rest <= 0): Datum/Betrag ändern ist ok, covered=true, Rate bleibt. Ziel OHNE Rate mit Rest: account_name (Resolve Funding/Funding invalid?) legt eine Rate in den Topf an (reserve_account_name oder Konto mit dem größten Anteil); ohne account_name -> code no_rate_running + required_monthly_rate (Agent fragt nach dem Konto). Fließt vom Abbuchungskonto schon ein freistehender Dauerauftrag in den Topf (fn_goal_transfer_candidates): ohne replace_transfer -> existing_transfer (Dry run rejected); true -> die Rate führt ihn fort (sein Betrag, Tag, nächster Termin), er endet dann (Karten-Hinweis aus card_lines); false -> zusätzliche Rate. Status completed/cancelled -> {ok:false} mit Verweis auf close_savings_goal (Reserve-Gate); active -> Rate wieder aktiv bzw. Folge-Rate ab heute, wenn sie schon beendet war. WS-A: reserve_account_name (optional, via Resolve Reserve/Reserve invalid?) -> rp.target_account_id zieht mit (künftige Raten = Umbuchung in den Topf; Guard reserve<>Abbuchungskonto); leer = Topf unverändert; BEREITS zugeordnete Buchungen bleiben dem Ziel zugeordnet. WS-B Stufe 2: link_savings_plan_name / unlink_savings_plan_name werden als String direkt an die fn gereicht (KEIN eigener Resolve-Node im Canvas) -> die fn löst den Plan DB-seitig auf (fn_resolve_savings_plan) und setzt/löscht savings_plans.savings_goal_id (ein Ziel hat 0..N Sparpläne; ein bereits an ein ANDERES Ziel gebundener Plan -> {ok:false}, erst lösen); danach speist jeder goal-verknüpfte Sparplan-Kauf die Depot-Reserve (Zwei-Schritt-Auto-Journal in fn_book_stock_buy). WS-B Stufe 3: stop_funders=true -> fn_stop_savings_goal_funders pausiert die Cash-Rate + ALLE verknüpften Sparpläne (deren rps), Ziel + Reserve UNBERÜHRT ("erreicht != ausgegeben"; Lebenszyklus ERREICHT). {ok:false}: target<=0 / Zieldatum Vergangenheit / reserve==funding / kein Topf für eine neue Rate / Sparplan nicht gefunden/mehrdeutig / unlink eines nicht-gebundenen Plans / link eines fremd-gebundenen Plans. "bereits gespart" = savings_goal_progress.current_amount (Reserve-Stand = getaggte Bewegungen + Depot-Journal). Ändert der Write die Sparrate (neu gerechnet, reaktiviert, Topf gewechselt, Beiträge gestoppt), liest fn_savings_squeeze_fold monthly_cashflow_summary: Kontoveränderung nach dem Sparen < 0 -> Note in savings_squeeze (gelatcht 24 h, sonst leer). Bookkeeper relayed.' 240 560

    $nodes = @($trig, $resGoal, $ifGoal, $errGoal, $readCur, $resPerson, $ifPersonBad, $errPerson,
               $resReserve, $ifReserveBad, $errReserve, $resFund, $ifFundBad, $errFund) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Goal' ) ) }
        'Resolve Goal'           = @{ main = @( ,@( E 'Goal unique?' ) ) }
        'Goal unique?'           = @{ main = @(
            @( E 'Read Current' ),
            @( E 'Goal ambiguous' )
        ) }
        'Read Current'           = @{ main = @( ,@( E 'Resolve Person' ) ) }
        'Resolve Person'         = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'        = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Resolve Reserve' )
        ) }
        'Resolve Reserve'        = @{ main = @( ,@( E 'Reserve invalid?' ) ) }
        'Reserve invalid?'       = @{ main = @(
            @( E 'Reserve unresolved' ),
            @( E 'Resolve Funding' )
        ) }
        'Resolve Funding'        = @{ main = @( ,@( E 'Funding invalid?' ) ) }
        'Funding invalid?'       = @{ main = @(
            @( E 'Funding unresolved' ),
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
            @( E 'Set goal (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set goal (atomic)'      = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_savings_goal' $nodes $conns `
        @{ Category = 'savings_goals' }
}
