#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 6. tool_create_savings_goal (Playbook 5.8) ---------------
function Build-CreateSavingsGoal {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('goal_name','goal_type','target_amount','target_date','monthly_savings_rate','account_name','schedule_day_of_month','first_payment_date','notes','beneficiary_person','reserve_account_name','priority')

    # Duplicate-name guard (Backstop wie bei den anderen create_*-Tools): ein create_* darf kein
    # zweites Sparziel gleichen Namens still anlegen (name hat keine UNIQUE-Constraint). Existiert ein
    # AKTIVES Sparziel des Namens -> sauberer BLOCK vor dem Gate (structured return). Aendern eines
    # bestehenden Ziels (Betrag/Datum) ist tool_set_savings_goal.
    $checkDup = Build-Pg 'Check duplicate name' @(220, -200) `
        "=SELECT hit_count, candidates FROM finance.fn_resolve_savings_goal((`$1::jsonb)->>'goal_name');" `
        ([ordered]@{ goal_name = '$(''Start'').item.json.goal_name' })

    $ifExists = Build-If 'Goal exists?' @(440, -200) `
        "={{ `$('Check duplicate name').item.json.hit_count }}" '1' 'largerEqual' 'number'

    $errExists = Build-ToolError 'Goal exists' @(660, -300) `
        "=An active savings goal named '{{ `$('Start').item.json.goal_name }}' already exists ({{ `$('Check duplicate name').item.json.hit_count }} match). I will NOT create a duplicate. To change its target or date, use tool_set_savings_goal; or choose a different name."

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', ARRAY['cash','p2p']);" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # Rate ODER Zieldatum DETERMINISTISCH in der DB berechnen (LLM rechnet nicht, Root-CLAUDE.md).
    # READ-ONLY-Aufruf desselben Helpers, den auch die Write-fn nutzt -> eine Quelle, der HITL-Preview
    # zeigt den exakt zu schreibenden Wert. target_amount + GENAU EINES von {target_date, monthly_savings_rate}.
    # WP2: ohne first_payment_date liefert der Helper den naechsten Termin des Abbuchungstags ab heute; genau dieses Datum
    # geht in den Write (Karte = Write).
    $computeSched = Build-Pg 'Compute Schedule' @(660, 0) `
        "=SELECT (r->>'ok')::boolean AS sched_ok, r->>'reason' AS sched_reason, (r->>'monthly_rate')::numeric AS monthly_rate, (r->>'target_date')::date AS target_date, (r->>'months')::int AS months, r->>'first_payment_date' AS first_payment_date FROM finance.fn_savings_rate_schedule(`$1::jsonb) AS r;" `
        ([ordered]@{
            target_amount        = '$(''Start'').item.json.target_amount'
            target_date          = '$(''Start'').item.json.target_date'
            monthly_savings_rate = '$(''Start'').item.json.monthly_savings_rate'
            first_payment_date   = '$(''Start'').item.json.first_payment_date'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
        })

    $ifSchedOk = Build-If 'Schedule ok?' @(880, 0) "={{ `$json.sched_ok }}" 'true' 'equals' 'boolean'

    $errSched = Build-ToolError 'Schedule rejected' @(1100, 200) `
        "={{ `$('Compute Schedule').item.json.sched_reason }}"

    # WS-4: beguenstigte Person aufloesen (Name -> Slug via core.fn_resolve_person; leer=Haushalt).
    # Beim Sparziel ist die Person der BEGUENSTIGTE (z. B. Kind), unabhaengig vom Abbuchungskonto.
    $resPerson = Build-ResolvePerson 'Resolve Person' @(880, 360) 'beneficiary_person'

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.beneficiary_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The beneficiary '{{ `$('Start').item.json.beneficiary_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member, or leave empty so the goal belongs to the owner of the savings account."

    # Audit Paket 3: Sparkonto (Reserve-Topf, cash/fixed_deposit) ist PFLICHT — Gesetz in fn_create_savings_goal; hier
    # VOR der Karte geprueft (leer oder nicht eindeutig -> Build-ToolError), damit nie etwas bestaetigt wird, das die fn
    # danach ablehnt (Muster close_account). Die Rate wird eine Umbuchung in den Topf -> Fortschritt messbar.
    $resReserve = Build-Pg 'Resolve Reserve' @(880, 600) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account(NULLIF((`$1::jsonb)->>'reserve_account_name', ''), ARRAY['cash','fixed_deposit']);" `
        ([ordered]@{ reserve_account_name = '$(''Start'').item.json.reserve_account_name' })

    $ifReserveBad = Build-If 'Reserve invalid?' @(1100, 600) `
        "={{ !`$('Start').item.json.reserve_account_name || `$('Resolve Reserve').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errReserve = Build-ToolError 'Reserve unresolved' @(1320, 720) `
        "={{ !`$('Start').item.json.reserve_account_name ? 'A savings goal needs a savings account (reserve, e.g. a Tagesgeld) where the money is kept - otherwise the progress cannot be measured. Ask the user which savings account the rate goes to, or offer to create one with tool_create_account first.' : ('The savings account ' + `$('Start').item.json.reserve_account_name + ' could not be uniquely resolved (' + `$('Resolve Reserve').item.json.hit_count + ' match(es)). Candidates: ' + JSON.stringify(`$('Resolve Reserve').item.json.candidates) + '. Ask which exact cash/Tagesgeld or fixed-deposit account.') }}"

    # "DB ist das Gesetz": fn_create_savings_goal laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_savings_goal' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Create savings goal (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'goal_id')::int AS goal_id, (r->>'recurring_payment_id')::int AS recurring_payment_id, (r->>'monthly_rate')::numeric AS monthly_rate, (r->>'target_date')::date AS target_date, COALESCE(r->'savings_squeeze'->>'note', '') AS savings_squeeze" `
        -Params ([ordered]@{
            name                  = '$(''Start'').item.json.goal_name'
            goal_type             = '$(''Start'').item.json.goal_type'
            target_amount         = '$(''Start'').item.json.target_amount'
            target_date           = '$(''Start'').item.json.target_date'
            monthly_savings_rate  = '$(''Start'').item.json.monthly_savings_rate'
            account_id            = '$(''Resolve Account'').item.json.id'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            first_payment_date    = '$(''Compute Schedule'').item.json.first_payment_date'
            notes                 = '$(''Start'').item.json.notes'
            beneficiary_person_id = '$(''Resolve Person'').item.json.person_id'
            reserve_account_id    = '$(''Resolve Reserve'').item.json.id'
            priority              = '$(''Start'').item.json.priority'
        })

    # --- HITL approval gate (Rate + Zieldatum aus Compute Schedule, nicht aus dem Prompt) ---
    # Strukturiertes Summary (Textkatalog): Zielbetrag + berechnete Sparrate sind EUR per Konvention -> Literal 'EUR';
    # Zieldatum + erste Buchung (genannt oder Default) aus Compute Schedule.
    $S  = "`$('Start').item.json"
    $CS = "`$('Compute Schedule').item.json"
    # Begünstigte(r) aus dem Probelauf: genannt, sonst Inhaber des Spartopfs (fn_default_beneficiary) -> Karte = Write.
    $Y  = "`$('Dry run').item.json.r"
    # Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1, dieselbe wie die Import-Karte).
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.create_savings_goal' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity savings_goal -S (Get-WritePayloadExpr) -D @{
        Person = "$Y.beneficiary_name"; TargetDate = "$CS.target_date"; MonthlyRate = "$CS.monthly_rate"; Months = "$CS.months"; FirstPayment = "$CS.first_payment_date" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 240) 'the create_savings_goal action'

    # Atomarer Write via fn_create_savings_goal:
    # 1. fn_savings_rate_schedule: fehlende Groesse (Rate ODER Zieldatum) deterministisch ableiten
    # 2. Sparziel INSERT (finance.savings_goals, status=active, target_date=aufgeloest)
    # 3. recurring_payment INSERT (monatliche Sparrate, amount=-rate, valid_from=first_payment_date)
    # 4. FK-Link goal.recurring_payment_id setzen
    # fn liefert ok/reason: weder Datum noch Rate / nicht-positiver Betrag -> {ok:false}.

    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Goal rejected' @(2860, 240) `
        "={{ `$('Create savings goal (atomic)').item.json.reason }}"

    # Post-State: monthly_rate + target_date (die berechnete bzw. uebernommene Groesse) zurueckgeben.
    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('goal_id', "={{ `$('Create savings goal (atomic)').item.json.goal_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Create savings goal (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('monthly_rate', "={{ `$('Create savings goal (atomic)').item.json.monthly_rate }}", 'number')
        ,@('target_date', "={{ `$('Create savings goal (atomic)').item.json.target_date }}", 'string')
        ,@('savings_squeeze', "={{ `$('Create savings goal (atomic)').item.json.savings_squeeze }}", 'string')
    )

    $stickyCompute = Build-Sticky 'Rate/Zieldatum: DB rechnet (nicht das LLM)' @(660, -240) `
        'fn_savings_rate_schedule (read-only) + Root-CLAUDE.md *Das LLM rechnet NICHT*' `
        'Der Nutzer nennt target_amount + GENAU EINES von {target_date, monthly_savings_rate}. Dieser read-only Aufruf leitet die fehlende Größe deterministisch ab (Ziel-getrieben: Rate=Ziel/Monate; Raten-getrieben: Zieldatum=first+ceil(Ziel/Rate)). Derselbe Helper läuft autoritativ in der Write-fn -> der Preview zeigt exakt den Schreibwert. Ohne first_payment_date liefert er den nächsten Termin des Abbuchungstags ab heute (WP2); genau dieses Datum zeigt die Karte und bekommt der Write. fehlt beides / Datum vor first_payment -> {ok:false} -> Schedule rejected.' 220 520

    $stickyFn = Build-Sticky 'fn_create_savings_goal: 4 Schritte + Über-Spar-Fold' @(2420, -240) `
        'fn_create_savings_goal (atomar)' `
        'Schritte in EINER DB-Transaktion: (0) Sparkonto-Pflicht (Topf aktiv, cash/fixed_deposit, ≠ Abbuchungskonto, sonst {ok:false}), (1) fn_savings_rate_schedule (Rate/Datum ableiten), (2) Sparziel INSERT (status=active, target_date aufgelöst), (3) recurring_payment INSERT (name=''Sparrate <Ziel>'', amount=-rate, schedule_unit=month, valid_from=fn_recurring_valid_from), (4) UPDATE goal.recurring_payment_id + Rate wird Transfer in den Topf (target_account_id). Fortschritt live aus finance.savings_goal_progress-View. Am Ende liest fn_savings_squeeze_fold monthly_cashflow_summary: Kontoveränderung nach dem Sparen < 0 (Sparraten übersteigen das frei Verfügbare) -> Note in savings_squeeze (gelatcht 24 h, sonst leer). Bookkeeper relayed.' 230 520

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -240) `
        'fn-Rückgabe {ok:false, reason}' `
        'Weder Datum noch Rate / nicht-positiver Betrag liefert die fn als {ok:false, reason} -> Goal rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true legt wirklich an.' 200 380

    $stickyDup = Build-Sticky 'Dubletten-Backstop (wie alle create_*)' @(220, -380) `
        'Check duplicate name -> fn_resolve_savings_goal' `
        'Deterministischer Backstop gegen Doppelanlage gleichen Namens (name hat keine UNIQUE-Constraint): aktives Sparziel des Namens vorhanden -> Goal exists blockt VOR dem Gate (structured return). Ergänzt den unscharfen Agent-Dedup (postgres_select im Prompt) -> fängt es auch, wenn der Agent den Check auslässt.' 200 420

    $stickyReserve = Build-Sticky 'Sparkonto-Pflicht vor der Karte' @(880, 800) `
        'Resolve Reserve -> Reserve invalid? (leer ODER nicht eindeutig)' `
        'Audit Paket 3: ein Sparziel ohne Topf liefe als nackte Abbuchung ins Leere (Fortschritt 0, Dauer-hinter-Plan). Gesetz ist fn_create_savings_goal ({ok:false}); dieser Check lehnt schon VOR dem Gate ab, damit der Nutzer nie etwas bestätigt, das danach abgelehnt wird. Leer -> Agent fragt nach dem Sparkonto oder bietet tool_create_account an.' 240 400

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -480) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_savings_goal mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (weder Zieldatum noch Rate, nicht-positiver Betrag, Sparkonto-Pflicht) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resAcct, $ifAcct, $errAcct,
               $computeSched, $ifSchedOk, $errSched, $resPerson, $ifPersonBad, $errPerson,
               $resReserve, $ifReserveBad, $errReserve) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret,
               $stickyDup, $stickyCompute, $stickyFn, $stickyOk, $stickyReserve,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                          = @{ main = @( ,@( E 'Check duplicate name' ) ) }
        'Check duplicate name'           = @{ main = @( ,@( E 'Goal exists?' ) ) }
        'Goal exists?'                   = @{ main = @(
            @( E 'Goal exists' ),
            @( E 'Resolve Account' )
        ) }
        'Resolve Account'                = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'                = @{ main = @(
            @( E 'Compute Schedule' ),
            @( E 'Account ambiguous' )
        ) }
        'Compute Schedule'               = @{ main = @( ,@( E 'Schedule ok?' ) ) }
        'Schedule ok?'                   = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Schedule rejected' )
        ) }
        'Resolve Person'                 = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'                = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Resolve Reserve' )
        ) }
        'Resolve Reserve'                = @{ main = @( ,@( E 'Reserve invalid?' ) ) }
        'Reserve invalid?'               = @{ main = @(
            @( E 'Reserve unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'         = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'               = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                      = @{ main = @(
            @( E 'Create savings goal (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create savings goal (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                      = @{ main = @(
            @( E 'Return' ),
            @( E 'Goal rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_savings_goal' $nodes $conns `
        @{ Category = 'savings_goals' }
}
