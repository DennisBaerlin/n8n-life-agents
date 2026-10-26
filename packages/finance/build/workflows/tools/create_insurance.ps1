#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 5. tool_create_insurance (Playbook 5.1) ------------------
function Build-CreateInsurance {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('name','insurance_company','policy_number','policyholder_person','premium_amount','annual_premium',
                           'schedule_interval','schedule_unit','schedule_day_of_month','valid_from',
                           'first_payment_date','debit_account_name',
                           'insurance_type','beneficiary','coverage_amount','claim_deadline_hours')  # WS-0b estate

    # Dedup-Guard (Name, aktive Versicherungen) — Block vor dem Gate
    $checkDup = Build-Pg 'Check duplicate name' @(220, -200) `
        "=SELECT COUNT(*)::int AS hit_count FROM finance.insurances WHERE name = (`$1::jsonb)->>'name' AND status = 'active';" `
        ([ordered]@{ name = '$(''Start'').item.json.name' })

    $ifExists = Build-If 'Insurance exists?' @(440, -200) `
        "={{ `$('Check duplicate name').item.json.hit_count }}" '1' 'largerEqual' 'number'

    $errExists = Build-ToolError 'Insurance exists' @(660, -300) `
        "=An active insurance named '{{ `$('Start').item.json.name }}' already exists. I will NOT create a duplicate. To change it use the appropriate update tool; or choose a different name."

    $resAcc = Build-Pg 'Resolve Debit Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'debit_account_name');" `
        ([ordered]@{ debit_account_name = '$(''Start'').item.json.debit_account_name' })

    $ifAcc = Build-If 'Debit unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcc = Build-ToolError 'Debit ambiguous' @(660, 200) `
        "=Debit account '{{ `$('Start').item.json.debit_account_name }}' resolves to {{ `$('Resolve Debit Account').item.json.hit_count }} matches. Ask the user which exact account to use."

    # Read-only Vorschau fuer die Karte: Rohwerte (Beitrag je Abbuchung oder Jahresbeitrag, Summe mit Tausenderpunkt,
    # Meldefrist, Typ, Rhythmus) aus DERSELBEN fn wie der Write (fn_insurance_fields: Betrag je Abbuchung + abgeleiteter
    # Jahreswert) -> Karte und Buchung koennen nicht auseinanderlaufen; das LLM rechnet nichts um (WP2).
    $preview = Build-Pg 'Preview Rate' @(880, 0) `
        "=SELECT (f->>'ok')::boolean AS ok, f->>'reason' AS reason, (f->>'premium_amount')::numeric AS period_amount, (f->>'annual_premium')::numeric AS annual_premium, (f->>'coverage_amount')::numeric AS coverage_amount FROM finance.fn_insurance_fields(`$1::jsonb) AS f;" `
        ([ordered]@{ premium_amount = '$(''Start'').item.json.premium_amount'; annual_premium = '$(''Start'').item.json.annual_premium'; coverage_amount = '$(''Start'').item.json.coverage_amount'; claim_deadline_hours = '$(''Start'').item.json.claim_deadline_hours'; insurance_type = '$(''Start'').item.json.insurance_type'; schedule_interval = '$(''Start'').item.json.schedule_interval'; schedule_unit = '$(''Start'').item.json.schedule_unit' })
    $ifFields = Build-If 'Fields ok?' @(1100, -120) "={{ `$('Preview Rate').item.json.ok }}" 'true' 'equals' 'boolean'
    $errFields = Build-ToolError 'Invalid values' @(1320, -240) "={{ `$('Preview Rate').item.json.reason }}"

    # WS-4: typisierten Versicherungsnehmer aufloesen (Name -> Slug via core.fn_resolve_person; leer=Haushalt).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(880, 360) 'policyholder_person'

    $ifPersonBad = Build-If 'Person invalid?' @(1100, 360) `
        "={{ !!`$('Start').item.json.policyholder_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1320, 480) `
        "=The policyholder '{{ `$('Start').item.json.policyholder_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member, or leave empty for a joint/household policy."

    # "DB ist das Gesetz": fn_create_insurance laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_insurance' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Create insurance (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'insurance_id' AS insurance_id, r->>'recurring_payment_id' AS recurring_payment_id, (r->>'monthly_equivalent')::numeric AS monthly_equivalent, (r->>'annual_premium')::numeric AS annual_premium" `
        -Params ([ordered]@{
            name                  = '$(''Start'').item.json.name'
            insurance_company     = '$(''Start'').item.json.insurance_company'
            policy_number         = '$(''Start'').item.json.policy_number'
            policyholder_person_id = '$(''Resolve Person'').item.json.person_id'
            premium_amount        = '$(''Start'').item.json.premium_amount'
            annual_premium        = '$(''Start'').item.json.annual_premium'
            schedule_interval     = '$(''Start'').item.json.schedule_interval'
            schedule_unit         = '$(''Start'').item.json.schedule_unit'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            valid_from            = '$(''Start'').item.json.valid_from'
            first_payment_date    = '$(''Start'').item.json.first_payment_date'
            debit_account_id      = '$(''Resolve Debit Account'').item.json.id'
            insurance_type        = '$(''Start'').item.json.insurance_type'          # WS-0b estate
            beneficiary           = '$(''Start'').item.json.beneficiary'
            coverage_amount       = '$(''Start'').item.json.coverage_amount'
            claim_deadline_hours  = '$(''Start'').item.json.claim_deadline_hours'
        })

    # --- HITL approval gate (before the write) ---
    # Strukturiertes Summary (Textkatalog): Beitrag/Versicherungssumme in EUR-Konvention (Praemie wird in EUR erfasst).
    # Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1); leere optionale Zeilen entfallen (-OmitEmpty).
    # Karte zeigt die GELESENEN Betraege (Preview Rate = fn_insurance_fields), nicht die Roh-Strings.
    $S = "(Object.assign({}, `$('Start').item.json, { coverage_amount: `$('Preview Rate').item.json.coverage_amount }))"
    $P = "`$('Resolve Person').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.create_insurance' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity insurance -S $S -D @{
        Person = "$P.full_name"; PeriodAmount = "`$('Preview Rate').item.json.period_amount"; Annual = "`$('Preview Rate').item.json.annual_premium" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 200) 'the create_insurance action'

    # Atomarer Write via Function: recurring_payment + insurance + FK-Link in EINER Transaktion.
    # fn liefert ok/reason: annual_premium<=0 -> {ok:false}.

    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Insurance rejected' @(2860, 200) `
        "={{ `$('Create insurance (atomic)').item.json.reason }}"

    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('insurance_id', "={{ `$('Create insurance (atomic)').item.json.insurance_id }}", 'number')
        ,@('recurring_payment_id', "={{ `$('Create insurance (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('monthly_equivalent', "={{ `$('Create insurance (atomic)').item.json.monthly_equivalent }}", 'number')
        ,@('annual_premium', "={{ `$('Create insurance (atomic)').item.json.annual_premium }}", 'number')
    )

    $stickyGenerated = Build-Sticky 'DB-Automatik Beitrag' @(2420, -260) `
        'Eine Quelle: Beitrags-Zeile (WP2)' `
        'Beitrag je Abbuchung, Rhythmus, Tag und Konto stehen nur an der Beitrags-Zeile (recurring_payment); den Jahreswert leitet fn_annual_equivalent ab, den Monatswert die GENERATED-Spalte monthly_equivalent (read-only). Die Versicherung erscheint über das recurring_payment automatisch im Cashflow. Schreibt finance.fn_create_insurance atomar (recurring_payment + insurance + FK in einer Transaktion). WS-0b (estate): die optionalen Nachlass-Felder insurance_type (geschlossene Liste, CHECK=Backstop) / beneficiary / coverage_amount / claim_deadline_hours werden mitgeschrieben und vom estate-Paket über finance.fn_insurance_register() (Oberfläche A) für Gap-Analyse + Todesfall-Checkliste gelesen.' 220 460

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -220) `
        'fn-Rückgabe {ok:false, reason}' `
        'Nicht-positiver oder unstimmiger Beitrag, Beitrag ohne Rhythmus liefert die fn als {ok:false, reason} -> Insurance rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true legt wirklich an.' 200 380

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -480) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_insurance mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (Beitrag nicht positiv/unstimmig/ohne Rhythmus und weitere korrigierbare Ablehnungen) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resAcc, $ifAcc, $errAcc, $preview, $ifFields, $errFields,
               $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyGenerated, $stickyOk,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                       = @{ main = @( ,@( E 'Check duplicate name' ) ) }
        'Check duplicate name'        = @{ main = @( ,@( E 'Insurance exists?' ) ) }
        'Insurance exists?'           = @{ main = @(
            @( E 'Insurance exists' ),
            @( E 'Resolve Debit Account' )
        ) }
        'Resolve Debit Account'       = @{ main = @( ,@( E 'Debit unique?' ) ) }
        'Debit unique?'               = @{ main = @(
            @( E 'Preview Rate' ),
            @( E 'Debit ambiguous' )
        ) }
        'Preview Rate'            = @{ main = @( ,@( E 'Fields ok?' ) ) }
        'Fields ok?'                  = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Invalid values' )
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
            @( E 'Create insurance (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create insurance (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                   = @{ main = @(
            @( E 'Return' ),
            @( E 'Insurance rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_insurance' $nodes $conns `
        @{ Category = 'insurance' }
}

