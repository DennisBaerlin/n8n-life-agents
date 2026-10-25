#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 10. tool_create_pension (Altersvorsorge als Net-Worth-Asset) ---------------
function Build-CreatePension {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('name','pension_type','provider','contract_number','owner_person','current_value',
                           'value_updated_at','guaranteed_monthly_pension','retirement_start_date',
                           'contribution_amount','schedule_interval','schedule_unit','debit_account_name','schedule_day_of_month',
                           'first_payment_date','notes')

    # Dedup-Guard (aktive gleichnamige Altersvorsorge) — Block vor dem Gate.
    $checkDup = Build-Pg 'Check duplicate name' @(220, -200) `
        "=SELECT COUNT(*)::int AS hit_count FROM finance.pension WHERE name = (`$1::jsonb)->>'name' AND status = 'active';" `
        ([ordered]@{ name = '$(''Start'').item.json.name' })

    $ifExists = Build-If 'Pension exists?' @(440, -200) `
        "={{ `$('Check duplicate name').item.json.hit_count }}" '1' 'largerEqual' 'number'

    $errExists = Build-ToolError 'Pension exists' @(660, -300) `
        "=An active pension named '{{ `$('Start').item.json.name }}' already exists. I will NOT create a duplicate. Choose a different name or update the existing one."

    # Optionales Beitrags-Abbuchungskonto aufloesen (leer -> debit_id NULL, hits 1 = ok, kein Beitrag).
    $resDebit = Build-Pg 'Resolve Debit Account' @(220, 0) @"
=SELECT
  CASE WHEN NULLIF((`$1::jsonb)->>'debit_account_name','') IS NULL THEN NULL ELSE r.id END       AS debit_id,
  CASE WHEN NULLIF((`$1::jsonb)->>'debit_account_name','') IS NULL THEN 1   ELSE r.hit_count END AS debit_hits,
  r.candidates AS debit_candidates
FROM finance.fn_resolve_account(NULLIF((`$1::jsonb)->>'debit_account_name',''), ARRAY['cash']) r;
"@ ([ordered]@{ debit_account_name = '$(''Start'').item.json.debit_account_name' })

    $ifDebit = Build-If 'Debit ok?' @(440, 0) "={{ `$json.debit_hits }}" '1'

    $errDebit = Build-ToolError 'Debit ambiguous' @(660, 200) `
        "=Debit account '{{ `$('Start').item.json.debit_account_name }}' resolves to {{ `$('Resolve Debit Account').item.json.debit_hits }} matches. Candidates: {{ JSON.stringify(`$('Resolve Debit Account').item.json.debit_candidates) }}. Ask the user the exact cash account for the contribution (or omit the contribution)."

    # WS-4: typisierte Eigentuemer-Person aufloesen (Name -> Slug via core.fn_resolve_person; leer=Haushalt).
    $resPerson = Build-Pg 'Resolve Person' @(440, 360) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'owner_person', ''));" `
        ([ordered]@{ owner_person = '$(''Start'').item.json.owner_person' })

    $ifPersonBad = Build-If 'Person invalid?' @(660, 360) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(880, 480) `
        "=The owner person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member, or leave empty for a joint/household provision."

    # "DB ist das Gesetz": fn_create_pension laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_pension' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Create pension (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'pension_id')::int AS pension_id, (r->>'recurring_payment_id')::int AS recurring_payment_id" `
        -Params ([ordered]@{
            name                       = '$(''Start'').item.json.name'
            pension_type               = '$(''Start'').item.json.pension_type'
            provider                   = '$(''Start'').item.json.provider'
            contract_number            = '$(''Start'').item.json.contract_number'
            owner_person_id            = '$(''Resolve Person'').item.json.person_id'
            current_value              = '$(''Start'').item.json.current_value'
            value_updated_at           = '$(''Start'').item.json.value_updated_at'
            guaranteed_monthly_pension = '$(''Start'').item.json.guaranteed_monthly_pension'
            retirement_start_date      = '$(''Start'').item.json.retirement_start_date'
            contribution_amount        = '$(''Start'').item.json.contribution_amount'
            schedule_interval          = '$(''Start'').item.json.schedule_interval'
            schedule_unit              = '$(''Start'').item.json.schedule_unit'
            debit_account_id           = '$(''Resolve Debit Account'').item.json.debit_id'
            schedule_day_of_month      = '$(''Start'').item.json.schedule_day_of_month'
            first_payment_date         = '$(''Start'').item.json.first_payment_date'
            notes                      = '$(''Start'').item.json.notes'
        })

    # --- HITL approval gate ---
    # Strukturiertes Summary (Textkatalog): Betraege in EUR-Konvention (entity-Werte in EUR erfasst).
    $S = "`$('Start').item.json"
    $P = "`$('Resolve Person').item.json"
    # Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1): Beitrag -> Abbuchungskonto/erste Abbuchung/Tag
    # als vollstaendige Folgegruppe.
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.create_pension' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity pension -S $S -D @{
        Person = "$P.full_name" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the create_pension action'

    # Atomarer Write via fn_create_pension: optional Beitrag-recurring (via Helper) + FK, dann pension.
    # fn liefert ok/reason: current_value<0 / contribution<0 / Beitrag ohne Konto -> {ok:false}.

    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Pension rejected' @(2640, 240) `
        "={{ `$('Create pension (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('pension_id', "={{ `$('Create pension (atomic)').item.json.pension_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Create pension (atomic)').item.json.recurring_payment_id }}", 'number')
    )

    $stickyFn = Build-Sticky 'fn_create_pension (atomar)' @(2200, -240) `
        'optional Beitrag-recurring (Helper) + pension-INSERT' `
        'fn_create_pension schreibt atomar: optional einen Beitrag je Abbuchung (Rhythmus roh, Default monatlich; WP2: den Monatswert leitet pension_overview ab) als recurring_payment (expense) via fn_add_recurring_payment (nur wenn contribution_amount + Abbuchungskonto gesetzt) + FK-Link, dann die finance.pension-Zeile (Asset). current_value optional (gesetzliche Rente oft unbekannt). Erscheint in finance.pension_overview (Net-Worth).' 220 460

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2640, -240) `
        'fn-Rückgabe {ok:false, reason}' `
        'current_value<0, contribution<0 oder Beitrag ohne Abbuchungskonto liefert die fn als {ok:false, reason} -> Pension rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert).' 200 400

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_pension mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (current_value oder Beitrag negativ, Beitrag ohne Abbuchungskonto) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resDebit, $ifDebit, $errDebit,
               $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyFn, $stickyOk,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Check duplicate name' ) ) }
        'Check duplicate name'     = @{ main = @( ,@( E 'Pension exists?' ) ) }
        'Pension exists?'          = @{ main = @(
            @( E 'Pension exists' ),
            @( E 'Resolve Debit Account' )
        ) }
        'Resolve Debit Account'    = @{ main = @( ,@( E 'Debit ok?' ) ) }
        'Debit ok?'                = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Debit ambiguous' )
        ) }
        'Resolve Person'           = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'          = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Create pension (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create pension (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Pension rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_pension' $nodes $conns `
        @{ Category = 'pension' }
}
