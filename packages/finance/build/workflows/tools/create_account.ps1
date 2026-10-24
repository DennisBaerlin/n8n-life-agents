#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 4. tool_create_account (NEW) -----------------------------
function Build-CreateAccount {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $FxCronId = Get-RequiredWorkflowId 'agent.finance.cron_refresh_fx_rates' 'Build-CreateAccount'   # Sofort-FX-Fetch (Dual-Trigger), paket-intern
    $trig = Build-Trigger @('name','account_type','bank','account_number','settlement_account_name','owner_person','currency','opening_balance','opening_balance_date','interest_rate','interest_credit_unit','interest_credit_interval','interest_credit_day_of_month','interest_day_count_convention','interest_posting_day_of_month','interest_auto_post','interest_valid_from','fixed_deposit_maturity_date','fixed_deposit_auto_renew')

    # Vorab-Spiegel der korrigierbaren fn_create_account-Ablehnungen (die fn ist das Gesetz; hier nur, damit der
    # Nutzer keine Karte bestaetigt, die danach scheitert): Typ loan (Kredite nur ueber tool_create_loan) und ein
    # Eroeffnungssaldo auf einem Depot (Depot-Saldo bleibt 0, Geld liegt auf dem Verrechnungskonto).
    $ifTypeBlocked = Build-If 'Type not allowed?' @(0, -200) `
        "={{ `$('Start').item.json.account_type === 'loan' || (['stocks_depot','crypto_depot'].includes(`$('Start').item.json.account_type) && Number(`$('Start').item.json.opening_balance || 0) !== 0) }}" 'true' 'equals' 'boolean'

    $errType = Build-ToolError 'Type not allowed' @(220, -400) `
        "={{ `$('Start').item.json.account_type === 'loan' ? 'Loans are not created as plain accounts - use tool_create_loan (it creates the loan account together with the remaining debt and the monthly rate).' : 'A depot has no cash balance of its own - leave opening_balance empty and put the cash balance on its settlement account.' }}"

    # Namens-Dublette prueft fn_create_account selbst (ohne Gross-/Kleinschreibung, typuebergreifend, wie der Import)
    # -> kommt im Probelauf als {ok:false, code:'duplicate_name', candidates} zurueck; kein eigener Tool-Knoten mehr.

    # Always run resolve. settlement_account_name may be empty (non-depot accounts) — kein Problem mehr:
    # der EINE jsonb-Param ist nie leer (kein $1-Drop). Leeres Feld -> ->>'...' ist NULL -> fn liefert
    # hit_count=0 (= 'kein Verrechnungskonto'). provided?/INSERT lesen weiter den Start-Wert.
    $resSettle = Build-Pg 'Resolve Settlement' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account(NULLIF((`$1::jsonb)->>'settlement_account_name', ''));" `
        ([ordered]@{ settlement_account_name = '$(''Start'').item.json.settlement_account_name' })

    # Error if user provided a settlement_account_name but it's not unique (hit_count != 1)
    $ifSettleProvided = Build-If 'Settlement provided?' @(440, 0) `
        "={{ `$('Start').item.json.settlement_account_name }}" '' 'notEquals' 'string'

    $ifSettleOk = Build-If 'Settlement unique?' @(660, -120) `
        "={{ `$('Resolve Settlement').item.json.hit_count }}" '1' 'equals' 'number'

    $errSettle = Build-ToolError 'Settlement ambiguous' @(880, -300) `
        "=Settlement account '{{ `$('Start').item.json.settlement_account_name }}' resolves to {{ `$('Resolve Settlement').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Settlement').item.json.candidates) }}. Ask the user which exact account to use."

    # Depot types (stocks_depot/crypto_depot) MUST have a settlement account. If none was provided,
    # stop with a friendly error BEFORE the approval gate (the DB CHECK is the hard backstop).
    $ifDepotType = Build-If 'Settlement required for type?' @(660, 160) `
        "={{ ['stocks_depot','crypto_depot'].includes(`$('Start').item.json.account_type) }}" 'true' 'equals' 'boolean'

    $errDepotNoSettle = Build-ToolError 'Depot needs settlement' @(880, 160) `
        "=Account type '{{ `$('Start').item.json.account_type }}' (depot) requires a settlement account (Verrechnungskonto). Create the cash account first, then create the depot with settlement_account_name set to that cash account."

    # WS-4: typisierte Eigentuemer-Person aufloesen (Name -> Slug via core.fn_resolve_person, dem
    # publizierten DEFINER-Fenster; finance_rw erreicht agent.* sonst nicht, D10). Leer = Haushalt
    # (kein Resolve, person_id NULL). Provided-but-ambiguous/unknown -> sauberer Block VOR dem Gate.
    $resPerson = Build-Pg 'Resolve Person' @(220, 360) `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'owner_person', ''));" `
        ([ordered]@{ owner_person = '$(''Start'').item.json.owner_person' })

    $ifPersonBad = Build-If 'Person invalid?' @(440, 360) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(660, 520) `
        "=The owner person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask the user which household member it is, or leave the owner empty for a joint/household account."

    # Read-only Vorschlag der Zinsmethode + auto_post + gueltig-ab (Owner-Direktive: im HITL-Gate MIT Grund zeigen,
    # ueberschreibbar) aus DERSELBEN fn, die fn_create_account im Write ruft (fn_account_interest_defaults: Karte =
    # Write). Laeuft immer; die Summary zeigt es nur bei Zinsen.
    $resInt = Build-Pg 'Resolve interest defaults' @(680, 360) `
        "=SELECT r->>'conv' AS conv, (r->>'auto_post')::boolean AS auto_post, r->>'conv_reason' AS conv_reason, r->>'valid_from' AS valid_from, r->>'first_credit_date' AS first_credit_date FROM finance.fn_account_interest_defaults(`$1::jsonb) AS r;" `
        ([ordered]@{
            account_type                  = '$(''Start'').item.json.account_type'
            interest_day_count_convention = '$(''Start'').item.json.interest_day_count_convention'
            interest_auto_post            = '$(''Start'').item.json.interest_auto_post'
            interest_credit_unit          = '$(''Start'').item.json.interest_credit_unit'
            interest_credit_interval      = '$(''Start'').item.json.interest_credit_interval'
            interest_credit_day_of_month  = '$(''Start'').item.json.interest_credit_day_of_month'
            interest_posting_day_of_month = '$(''Start'').item.json.interest_posting_day_of_month'
            interest_valid_from           = '$(''Start'').item.json.interest_valid_from'
        })

    # "DB ist das Gesetz": fn_create_account laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_account' -DryPos @(900, 0) -WritePos @(2220, 0) `
        -WriteName 'Create account (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'account_id' AS account_id, (r->>'interest_added')::boolean AS interest_added, (r->>'balance')::numeric AS balance" `
        -Params ([ordered]@{
            name                 = '$(''Start'').item.json.name'
            account_type         = '$(''Start'').item.json.account_type'
            bank                 = '$(''Start'').item.json.bank'
            account_number       = '$(''Start'').item.json.account_number'
            settlement_id        = '$(''Resolve Settlement'').item.json.id'
            owner_person_id      = '$(''Resolve Person'').item.json.person_id'
            currency             = '$(''Start'').item.json.currency'
            opening_balance      = '$(''Start'').item.json.opening_balance'
            opening_balance_date = '$(''Start'').item.json.opening_balance_date'
            interest_rate                 = '$(''Start'').item.json.interest_rate'
            interest_credit_unit          = '$(''Start'').item.json.interest_credit_unit'
            interest_credit_interval      = '$(''Start'').item.json.interest_credit_interval'
            interest_credit_day_of_month  = '$(''Start'').item.json.interest_credit_day_of_month'
            interest_day_count_convention = '$(''Start'').item.json.interest_day_count_convention'
            interest_posting_day_of_month = '$(''Start'').item.json.interest_posting_day_of_month'
            interest_auto_post            = '$(''Start'').item.json.interest_auto_post'
            interest_valid_from           = '$(''Start'').item.json.interest_valid_from'
            fixed_deposit_maturity_date   = '$(''Start'').item.json.fixed_deposit_maturity_date'
            fixed_deposit_auto_renew      = '$(''Start'').item.json.fixed_deposit_auto_renew'
        })

    # --- HITL approval gate (before the write) ---
    # Strukturiertes Summary (Textkatalog), Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1, dieselbe wie die
    # Import-Karte): Saldo + Zins nur bei Nicht-Depots, Verrechnungskonto nur bei Depots, Zins-Details vollstaendig,
    # sobald ein Zins genannt ist, Festgeld-Felder nur bei Festgeld. Saldo in der Kontowaehrung (genannt, sonst EUR).
    $S = "`$('Start').item.json"
    $P = "`$('Resolve Person').item.json"
    $D = "`$('Resolve interest defaults').item.json"
    $summary = New-HitlSummary -Pos @(1560, 0) -Title 'finance.hitl.create_account' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity account -S $S -D @{
        Person = "$P.full_name"; Ccy = "($S.currency ? String($S.currency).toUpperCase() : 'EUR')"
        Conv = "$D.conv"; ConvReason = "$D.conv_reason"; AutoPost = "$D.auto_post"; ValidFrom = "$D.valid_from"; FirstCredit = "$D.first_credit_date"
        BalanceDate = "`$('Dry run').item.json.r.opening_balance_date" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1780, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2000, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2220, 200) 'the create_account action'

    # Atomarer Write via PL/pgSQL-Function: Konto + (optional) Zinszeile + (optional) Eroeffnungsbuchung in EINER
    # Transaktion. EIN jsonb-Param (vermeidet n8n-Empty-Param-Drop bei leeren optionalen Feldern). settlement_id ist
    # oben bereits aufgeloest; interest_* nur gesetzt, wenn der Nutzer Zinsen genannt/bestaetigt hat.

    # Korrigierbare Ablehnung der fn (ungueltige Waehrung, Depot-Waehrung <> Verrechnungskonto) -> reason an den
    # Agenten statt eines falschen ok:true mit leerer account_id (vorher wurde ok der fn nie gelesen).
    $ifWriteOk = Build-If 'Write ok?' @(2440, 200) "={{ `$('Create account (atomic)').item.json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Create rejected' @(2660, 400) "={{ `$('Create account (atomic)').item.json.reason }}"

    # Sofort-Fetch: nur bei echter Fremdwaehrung (nicht leer, nicht EUR). Ruft den FX-Cron-Workflow
    # als Sub auf (Dual-Trigger: executeWorkflowTrigger neben dem Schedule) — EINE Logik-Adresse fuer
    # Check/Fetch/Upsert. Eliminiert das NULL-Fenster in Roll-up-Views bis zum naechsten Schedule-Lauf.
    $ifForeignCurr = Build-If 'Non-EUR currency?' @(2440, 0) `
        "={{ !!(`$('Start').item.json.currency) && `$('Start').item.json.currency !== 'EUR' }}" `
        'true' 'equals' 'boolean'

    $callFxRefresh = Build-CallWorkflow 'Refresh FX rates' @(2660, -120) $FxCronId 'agent.finance.cron_refresh_fx_rates' `
        ([ordered]@{ chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ret = Build-Return @(2880, 0) @(
        ,@('ok','true','boolean')
        ,@('account_id', "={{ `$('Create account (atomic)').item.json.account_id }}", 'number')
        ,@('interest_added', "={{ `$('Create account (atomic)').item.json.interest_added }}", 'boolean')
        ,@('balance', "={{ `$('Create account (atomic)').item.json.balance }}", 'number')
    )

    $stickyBalance = Build-Sticky 'DB-Automatik balance-init + Eröffnungssaldo' @(2220, -200) `
        'trg_finance_account_balance_init + opening_balance' `
        'Beim Anlegen legt ein DB-Trigger die balance-Zeile (0) an. Ein genannter Saldo (opening_balance) wird in fn_create_account als Eröffnungsbuchung (category other, kein Abgleich-Stempel) zum Stichtag (opening_balance_date, z. B. Ende des Kontoauszugs; leer = heute) gebucht und setzt accounts.opening_balance_date; der Trigger führt den Saldo nach. Dieser Workflow schreibt nie selbst einen Saldo. Return balance = Post-State aus der fn.' 260 300

    $stickyGuards = Build-Sticky 'Vorab-Prüfung + Write ok?' @(0, -440) `
        'Korrigierbare Ablehnungen (fn_create_account ist das Gesetz)' `
        'Type not allowed? spiegelt vor der Karte die fn-Ablehnungen loan (-> tool_create_loan) und Saldo auf einem Depot. Write ok? reicht jede weitere korrigierbare Ablehnung der fn (Währung ungültig, Depot-Währung ≠ Verrechnungskonto) als Tool-Fehler durch. Die Karte zeigt Saldo/Zins nur bei Cash-artigen Konten und das Verrechnungskonto nur bei Depots.' 260 300

    $stickyAutoCurr = Build-Sticky 'Sofort-FX-Fetch + Währungs-Registrierung' @(2660, -340) `
        'fn_ensure_currency + Sub-Call cron_refresh_fx_rates' `
        'fn_create_account registriert Fremdwährungen via fn_ensure_currency (ON CONFLICT DO NOTHING). Danach: Sub-Call des FX-Cron-Workflows (Dual-Trigger, Logik dort: Check/Fetch/Upsert) -> eliminiert NULL-Fenster in Roll-up-Views bis zum nächsten Schedule-Lauf. EUR-Konten: kein Call (IF false-Zweig).' 220 440

    $stickyHitl = Build-Sticky 'Doc HITL-Gate' @(1740, -220) `
        'Human-in-the-Loop Approval-Gate' `
        'Vor JEDEM Write: Werteliste -> agent.tool_human_approval (Telegram Approve/Decline). Approve -> finance.fn_create_account (atomar: Konto + ggf. Zinszeile in einer Transaktion). Decline -> cancelled, nichts geschrieben.' 180 360

    $stickyResInt = Build-Sticky 'Doc Resolve interest defaults' @(560, 540) `
        'Read-only Vorschlag der Zinsmethode + auto_post (Owner-Direktive)' `
        'Resolve interest defaults berechnet IN SQL, was fn_create_account setzen wird: day_count_convention = Override sonst aus dem Kontotyp (fn_interest_default_convention: cash->ACT/365, fixed_deposit->30E/360) + auto_post = Override sonst aus der Kadenz (fn_interest_auto_post_default). KEIN dupliziertes Mapping (eine Adresse = die DB-fns). Die HITL-Summary zeigt Methode + Grund + auto_post sowie die erste Gutschrift (first_credit_date, gleiches Kalender-Raster wie die Fälligkeit) in Klartext (Rhythmus, Gutschrift-Zeitpunkt, Zinstage, keine Codes; Get-FinanceInterestScheduleLines), der Nutzer kann per Chat überschreiben. Kein erfundener Rhythmus: ohne interest_credit_unit bleibt unit leer, der Probelauf lehnt ab. Läuft immer, wird nur bei Zinsen angezeigt.' 280 480

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(900, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_account mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (Name schon vergeben – ohne Groß-/Kleinschreibung, typübergreifend, mit candidates; IBAN schon vergeben; Festgeld ohne Zins/Fälligkeit; Zins ohne Rhythmus bzw. Tag unpassend zum Rhythmus (fn_interest_schedule_reason); ungültige Währung, Depot-Währung ungleich Verrechnungskonto, Typ loan, Eröffnungssaldo oder Stichtag auf einem Depot, Stichtag kein YYYY-MM-DD, in der Zukunft oder ohne Saldo) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $ifTypeBlocked, $errType, $resSettle, $ifSettleProvided, $ifSettleOk, $errSettle, $ifDepotType, $errDepotNoSettle,
               $resPerson, $ifPersonBad, $errPerson, $resInt) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ifForeignCurr, $callFxRefresh, $ret,
               $stickyBalance, $stickyHitl, $stickyAutoCurr, $stickyResInt, $stickyGuards,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                        = @{ main = @( ,@( E 'Type not allowed?' ) ) }
        'Type not allowed?'            = @{ main = @(
            @( E 'Type not allowed' ),                # true: loan / Depot mit Saldo -> block
            @( E 'Resolve Settlement' )               # false: weiter (Namens-Dublette prueft der Probelauf)
        ) }
        'Resolve Settlement'           = @{ main = @( ,@( E 'Settlement provided?' ) ) }
        'Settlement provided?'         = @{ main = @(
            @( E 'Settlement unique?' ),              # true (notEmpty): must be unique
            @( E 'Settlement required for type?' )    # false (empty): only allowed for non-depot types
        ) }
        'Settlement required for type?' = @{ main = @(
            @( E 'Depot needs settlement' ),          # true: depot without settlement -> error
            @( E 'Resolve Person' )                   # false: non-depot, settlement legitimately empty
        ) }
        'Settlement unique?'           = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Settlement ambiguous' )
        ) }
        'Resolve Person'               = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'              = @{ main = @(
            @( E 'Person unresolved' ),               # true: provided but 0/>1 matches -> block
            @( E 'Resolve interest defaults' )        # false: resolved (or empty=household)
        ) }
        'Resolve interest defaults'    = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'       = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'             = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                    = @{ main = @(
            @( E 'Create account (atomic)' ),     # true: approved
            @( E 'Return cancelled' )             # false: declined
        ) }
        'Create account (atomic)'      = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                    = @{ main = @(
            @( E 'Non-EUR currency?' ),     # true: angelegt
            @( E 'Create rejected' )        # false: korrigierbare Ablehnung der fn
        ) }
        'Non-EUR currency?'            = @{ main = @(
            @( E 'Refresh FX rates' ),    # true: Fremdwaehrung -> Sub-Call des FX-Crons (Sofort-Fetch)
            @( E 'Return' )                # false: EUR -> kein Call
        ) }
        'Refresh FX rates'             = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.finance.tool_create_account' $nodes $conns `
        @{ Category = 'accounts' }
}

