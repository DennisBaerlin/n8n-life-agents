#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_loan (set_*: Kredit-Konditionen/Status aendern) ---
function Build-SetLoan {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('loan_name','new_name','lender','borrower_person','interest_rate','principal_rate',
                           'interest_rate_fixed_until','monthly_annuity','schedule_day_of_month','status','notes')

    # Resolve ueber ALLE Status (auch paused/refinanced -> reaktivieren/markieren moeglich); inline,
    # da fn_resolve_loan nur active liefert.
    $resLoan = Build-Pg 'Resolve Loan' @(220, 0) `
        "=SELECT (CASE WHEN count(*) = 1 THEN min(id) END)::int AS id, count(*)::int AS hit_count, COALESCE(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'lender', lender, 'status', status) ORDER BY id), '[]'::jsonb) AS candidates FROM finance.loans WHERE name = (`$1::jsonb)->>'loan_name';" `
        ([ordered]@{ loan_name = '$(''Start'').item.json.loan_name' })

    $ifLoan = Build-If 'Loan unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errLoan = Build-ToolError 'Loan ambiguous' @(660, 200) `
        "=Loan '{{ `$('Start').item.json.loan_name }}' resolves to {{ `$('Resolve Loan').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Loan').item.json.candidates) }}. Ask the user which exact loan."

    $readCur = Build-Pg 'Read Current' @(660, 0) `
        "=SELECT interest_rate, monthly_annuity, status::text AS status FROM finance.loans WHERE id = ((`$1::jsonb)->>'id')::int;" `
        ([ordered]@{ id = '$(''Resolve Loan'').item.json.id' })

    # WS-4: optionalen Kreditnehmer-Wechsel aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-Pg 'Resolve Person' @(880, 360) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'borrower_person', ''));" `
        ([ordered]@{ borrower_person = '$(''Start'').item.json.borrower_person' })

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.borrower_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The borrower '{{ `$('Start').item.json.borrower_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # "DB ist das Gesetz": fn_set_loan laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den
    # echten Write (partielles UPDATE (GENERATED rechnen auto) + Rate-Sync + Status-Kaskade).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_loan' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Set loan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'loan_id')::int AS loan_id, (r->>'recurring_payment_id')::int AS recurring_payment_id" `
        -Params ([ordered]@{
            loan_id                   = '$(''Resolve Loan'').item.json.id'
            name                      = '$(''Start'').item.json.new_name'
            lender                    = '$(''Start'').item.json.lender'
            borrower_person_id        = '$(''Resolve Person'').item.json.person_id'
            interest_rate             = '$(''Start'').item.json.interest_rate'
            principal_rate            = '$(''Start'').item.json.principal_rate'
            interest_rate_fixed_until = '$(''Start'').item.json.interest_rate_fixed_until'
            monthly_annuity           = '$(''Start'').item.json.monthly_annuity'
            schedule_day_of_month      = '$(''Start'').item.json.schedule_day_of_month'
            status                    = '$(''Start'').item.json.status'
            notes                     = '$(''Start'').item.json.notes'
        })

    # Strukturiertes Summary (Textkatalog): nur gelieferte Felder (-If je Zeile). Monatsrate in EUR-Konvention.
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $P = "`$('Resolve Person').item.json"
    $dom = "($S.schedule_day_of_month == '-1' ? 'finance.value.last_day_of_month' : 'finance.tpl.day_of_month')"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.set_loan' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.loan'            "$S.loan_name")
        (New-HitlLine 'finance.label.new_name'        "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.borrower_person' "($P.full_name || $S.borrower_person)" -If "$S.borrower_person")
        (New-HitlLine 'finance.label.interest_rate'   "'finance.tpl.percent_change'" -Kind tpl -Params @{ from = "$R.interest_rate"; to = "$S.interest_rate" } -If "$S.interest_rate")
        (New-HitlLine 'finance.label.principal_rate'  "'finance.tpl.percent'" -Kind tpl -Params @{ value = "$S.principal_rate" } -If "$S.principal_rate")
        (New-HitlLine 'finance.label.monthly_instalment'    "'finance.tpl.change'" -Kind tpl -If "$S.monthly_annuity" -Params @{
            from = (New-HitlValue -Kind money -Value "$R.monthly_annuity" -EurByModel)
            to   = (New-HitlValue -Kind money -Value "$S.monthly_annuity" -EurByModel) })
        (New-HitlLine 'finance.label.fixed_until'     "$S.interest_rate_fixed_until" -Kind date -If "$S.interest_rate_fixed_until")
        (New-HitlLine 'finance.label.debit_day'       $dom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" } -If "$S.schedule_day_of_month")
        (New-HitlLine 'core.label.status'             "'finance.tpl.change'" -Kind tpl -If "$S.status" -Params @{
            from = (New-HitlValue -Kind enum -Value "$R.status" -Enum 'finance.enum.status')
            to   = (New-HitlValue -Kind enum -Value "$S.status" -Enum 'finance.enum.status') })
        (New-HitlLine 'core.label.note'               "$S.notes" -If "$S.notes")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the set_loan action'

    # Atomarer Write via fn_set_loan ($wg.Write, 'Set loan (atomic)').
    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2640, 240) `
        "={{ `$('Set loan (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('loan_id', "={{ `$('Set loan (atomic)').item.json.loan_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Set loan (atomic)').item.json.recurring_payment_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_loan mit denselben Werten, immer zurückgerollt. ok:false (negative Rate, Annuität <= 0, aktiver Kredit ohne Annuität) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (CHECK) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyOv = Build-Sticky 'Doc set_loan' @(2200, -240) `
        'fn_set_loan: GENERATED-Recompute + Rate-Sync + Status-Kaskade' `
        'GENERATED annuity_rate/monthly_interest/monthly_principal rechnen auto neu; LIVE-Werte in finance.loan_overview. Annuität-Änderung -> verknüpfte Kreditrate (recurring) -annuity; Status paused/paid_off/refinanced -> recurring paused. {ok:false}: neg. Rate / annuity<=0 / active ohne Annuität (CHECK). Umschuldungs-Mehrschritt NICHT hier.' 230 430

    $nodes = @($trig, $resLoan, $ifLoan, $errLoan, $readCur, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Loan' ) ) }
        'Resolve Loan'           = @{ main = @( ,@( E 'Loan unique?' ) ) }
        'Loan unique?'           = @{ main = @(
            @( E 'Read Current' ),
            @( E 'Loan ambiguous' )
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
            @( E 'Set loan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set loan (atomic)'      = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_loan' $nodes $conns `
        @{ Category = 'loans' }
}
