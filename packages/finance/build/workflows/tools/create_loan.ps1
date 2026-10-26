#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 6. tool_create_loan (Playbook 5.2) -----------------------
function Build-CreateLoan {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('name','lender','borrower_person','original_amount','current_balance','disbursement_date',
                           'interest_rate','interest_rate_fixed_until','term_end_date',
                           'monthly_annuity','schedule_day_of_month','first_payment_date',
                           'disbursement_account_name','debit_account_name','real_estate_id','notes')

    # Dedup-Guard (Name, aktive Kredite) — Block vor dem Gate. Liest den Namen der verknuepften Immobilie fuer die
    # Karte mit (das Tool bekommt sie als real_estate_id; die Karte zeigt den Namen, leer = '—').
    $checkDup = Build-Pg 'Check duplicate name' @(220, -200) `
        "=SELECT COUNT(*)::int AS hit_count, (SELECT r.name FROM finance.real_estate r WHERE r.id::text = btrim((`$1::jsonb)->>'real_estate_id', ' ''`"')) AS real_estate_name FROM finance.loans WHERE name = (`$1::jsonb)->>'name' AND status = 'active';" `
        ([ordered]@{ name = '$(''Start'').item.json.name'; real_estate_id = '$(''Start'').item.json.real_estate_id' })

    $ifExists = Build-If 'Loan exists?' @(440, -200) `
        "={{ `$('Check duplicate name').item.json.hit_count }}" '1' 'largerEqual' 'number'

    $errExists = Build-ToolError 'Loan exists' @(660, -300) `
        "=An active loan named '{{ `$('Start').item.json.name }}' already exists. I will NOT create a duplicate. To change it use the appropriate update tool; or choose a different name."

    $resAcc = Build-Pg 'Resolve Debit Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'debit_account_name', ARRAY['cash']);" `
        ([ordered]@{ debit_account_name = '$(''Start'').item.json.debit_account_name' })

    $ifAcc = Build-If 'Debit unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcc = Build-ToolError 'Debit ambiguous' @(660, 200) `
        "=Debit account '{{ `$('Start').item.json.debit_account_name }}' resolves to {{ `$('Resolve Debit Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Debit Account').item.json.candidates) }}. Ask the user which exact account to use."

    # Optionales Auszahlungskonto aufloesen: leer -> disbursement_id NULL, disbursement_hits 1 (= ok,
    # keine Auszahlungsbuchung). Gegebener Name -> echtes hit_count (0/>1 = Fehler vor dem Gate).
    # jsonb-Param ist nie leer -> kein Sentinel noetig (leeres Feld -> ->>'...' NULL).
    $resDisbursement = Build-Pg 'Resolve Disbursement Account' @(660, 0) @"
=SELECT
  CASE WHEN NULLIF((`$1::jsonb)->>'disbursement_account_name','') IS NULL THEN NULL ELSE r.id END       AS disbursement_id,
  CASE WHEN NULLIF((`$1::jsonb)->>'disbursement_account_name','') IS NULL THEN 1   ELSE r.hit_count END AS disbursement_hits,
  r.candidates AS disbursement_candidates
FROM finance.fn_resolve_account(NULLIF((`$1::jsonb)->>'disbursement_account_name',''), ARRAY['cash']) r;
"@ ([ordered]@{ disbursement_account_name = '$(''Start'').item.json.disbursement_account_name' })

    $ifDisbursement = Build-If 'Disbursement ok?' @(880, 0) "={{ `$json.disbursement_hits }}" '1'

    $errDisbursement = Build-ToolError 'Disbursement ambiguous' @(880, 200) `
        "=Disbursement account '{{ `$('Start').item.json.disbursement_account_name }}' resolves to {{ `$('Resolve Disbursement Account').item.json.disbursement_hits }} matches. Candidates: {{ JSON.stringify(`$('Resolve Disbursement Account').item.json.disbursement_candidates) }}. Ask the user the exact account (or confirm the loan was NOT paid into one of their own accounts)."

    # WS-4: typisierten Kreditnehmer aufloesen (Name -> Slug via core.fn_resolve_person; leer=Haushalt).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(880, 360) 'borrower_person'

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.borrower_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The borrower '{{ `$('Start').item.json.borrower_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member, or leave empty for a joint/household loan."

    # "DB ist das Gesetz": fn_create_loan laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_loan' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Create loan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'loan_id' AS loan_id, r->>'loan_account_id' AS loan_account_id, r->>'debit_account_id' AS debit_account_id, r->>'recurring_payment_id' AS recurring_payment_id, (r->>'balance_at_fixed_until')::numeric AS balance_at_fixed_until, (r->>'balance_at_term_end')::numeric AS balance_at_term_end" `
        -Params ([ordered]@{
            name                      = '$(''Start'').item.json.name'
            lender                    = '$(''Start'').item.json.lender'
            borrower_person_id        = '$(''Resolve Person'').item.json.person_id'
            original_amount           = '$(''Start'').item.json.original_amount'
            current_balance           = '$(''Start'').item.json.current_balance'
            disbursement_date         = '$(''Start'').item.json.disbursement_date'
            interest_rate             = '$(''Start'').item.json.interest_rate'
            interest_rate_fixed_until = '$(''Start'').item.json.interest_rate_fixed_until'
            term_end_date             = '$(''Start'').item.json.term_end_date'
            monthly_annuity           = '$(''Start'').item.json.monthly_annuity'
            schedule_day_of_month      = '$(''Start'').item.json.schedule_day_of_month'
            first_payment_date        = '$(''Start'').item.json.first_payment_date'
            disbursement_account_id   = '$(''Resolve Disbursement Account'').item.json.disbursement_id'
            debit_account_id          = '$(''Resolve Debit Account'').item.json.id'
            real_estate_id            = '$(''Start'').item.json.real_estate_id'
            notes                     = '$(''Start'').item.json.notes'
        })

    # --- HITL approval gate (before the atomic write) ---
    # Strukturiertes Summary (Textkatalog): Betraege in EUR-Konvention (Kredit-Stammwerte werden in EUR erfasst);
    # leere Daten -> '—' uebernimmt das Gate.
    # Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1, dieselbe wie die Import-Karte).
    $S = "`$('Start').item.json"
    $P = "`$('Resolve Person').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.create_loan' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity loan -S (Get-WritePayloadExpr) -D @{
        Person = "$P.full_name"; RealEstate = "`$('Check duplicate name').item.json.real_estate_name"
        RateInterest = "`$('Dry run').item.json.r.first_rate_interest"; RatePrincipal = "`$('Dry run').item.json.r.first_rate_principal"
        Running = "!!`$('Dry run').item.json.r.opening_balance_date"
        BalFixed = "`$('Dry run').item.json.r.balance_at_fixed_until"; BalTermEnd = "`$('Dry run').item.json.r.balance_at_term_end" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 200) 'the create_loan action'

    # Atomarer Write via Function: Loan-Konto + Loan + optional Rate-recurring_payment + 2 Auszahlungen.
    # fn liefert ok/reason: original_amount<=0 oder monthly_annuity<=0 -> {ok:false}.

    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Loan rejected' @(2860, 200) `
        "={{ `$('Create loan (atomic)').item.json.reason }}"

    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('loan_id', "={{ `$('Create loan (atomic)').item.json.loan_id }}", 'number')
        ,@('loan_account_id', "={{ `$('Create loan (atomic)').item.json.loan_account_id }}", 'number')
        ,@('debit_account_id', "={{ `$('Create loan (atomic)').item.json.debit_account_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Create loan (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('balance_at_fixed_until', "={{ `$('Create loan (atomic)').item.json.balance_at_fixed_until }}", 'number')
        ,@('balance_at_term_end', "={{ `$('Create loan (atomic)').item.json.balance_at_term_end }}", 'number')
    )

    $stickyGen = Build-Sticky 'DB-Automatik Loan' @(2420, -240) `
        'Trigger + GENERATED (fn_create_loan atomar)' `
        'fn_create_loan schreibt in EINER Transaktion: Loan-Konto (balance-Zeile via trg_finance_account_balance_init), Loan-Stammdaten, optional recurring_payment für die Rate (gültig ab dem Stichtag von Abbuchungs- und Kreditkonto), Restschuld-Eröffnung aufs Loan-Konto (frisch mit Datum: -original_amount zum Auszahlungsdatum; laufend oder ohne Datum: Restschuld zum Stichtag heute + opening_balance_date am Kreditkonto, Datum später per set_loan nachtragbar), und NUR bei gesetztem disbursement_account_id eine Auszahlungsbuchung (+original_amount). Salden via trg_finance_balance_update. Rate/Rhythmus/Tag stehen NUR an der Raten-Zeile (WP2, eine Quelle). Zins/Tilgung je Rate rechnet die DB immer aus der Restschuld (fn_loan_monthly_interest, finance.loan_overview); die voraussichtliche Restschuld zum Zinsbindungs-/Laufzeitende (bei gleichem Zins, ohne Sondertilgung) liefert der Probelauf aus loan_overview (fn_loan_projected_balance).' 240 560

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -240) `
        'fn-Rückgabe {ok:false, reason}' `
        'Korrigierbare Fehler (Restschuld fehlt, Auszahlungsdatum in der Zukunft, Laufzeitende vor Zinsbindung/Auszahlung, nicht-positive Beträge, Rate unter dem Monatszins der Restschuld, Auszahlungskonto bei laufendem Kredit …) liefert die fn als {ok:false, reason} -> Loan rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true legt wirklich an.' 200 420

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_loan mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (z. B. Rate unter dem Monatszins, frischer Kredit ohne Betrag) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte mit der DB-Aufteilung der 1. Rate (first_rate_interest/_principal aus der Restschuld) und der voraussichtlichen Restschuld zum Zinsbindungs-/Laufzeitende (leer entfällt); Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 460

    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resAcc, $ifAcc, $errAcc,
               $resDisbursement, $ifDisbursement, $errDisbursement,
               $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyGen, $stickyOk,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                       = @{ main = @( ,@( E 'Check duplicate name' ) ) }
        'Check duplicate name'        = @{ main = @( ,@( E 'Loan exists?' ) ) }
        'Loan exists?'                = @{ main = @(
            @( E 'Loan exists' ),
            @( E 'Resolve Debit Account' )
        ) }
        'Resolve Debit Account'       = @{ main = @( ,@( E 'Debit unique?' ) ) }
        'Debit unique?'               = @{ main = @(
            @( E 'Resolve Disbursement Account' ),
            @( E 'Debit ambiguous' )
        ) }
        'Resolve Disbursement Account' = @{ main = @( ,@( E 'Disbursement ok?' ) ) }
        'Disbursement ok?'            = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Disbursement ambiguous' )
        ) }
        'Resolve Person'              = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'             = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'      = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'            = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                   = @{ main = @(
            @( E 'Create loan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create loan (atomic)'        = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                   = @{ main = @(
            @( E 'Return' ),
            @( E 'Loan rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_loan' $nodes $conns `
        @{ Category = 'loans' }
}

