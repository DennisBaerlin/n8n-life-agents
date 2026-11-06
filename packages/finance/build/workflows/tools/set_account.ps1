#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_account (set_*: Konto-Stammdaten aendern) -----
function Build-SetAccount {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('account_name','new_name','bank','account_number','remove_account_number','owner_person','settlement_account',
                           'notes','fixed_deposit_maturity_date','fixed_deposit_auto_renew',
                           'ownership','has_transmortal_poa',  # WS-0b estate
                           'min_balance','min_balance_default')  # Puffer je Konto (Transparenz 2026-10-30)

    # currency: Waehrung des Puffers auf der Karte (min_balance ist in Kontowaehrung)
    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT r.id, r.hit_count, r.candidates, a.currency FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', NULL, TRUE) r LEFT JOIN finance.accounts a ON a.id = r.id;" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # WS-4: optionalen Eigentuemer-Wechsel aufloesen (Name -> Slug; leer = unveraendert).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(660, 360) 'owner_person'

    $ifPersonBad = Build-If 'Person invalid?' @(880, 360) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(1100, 480) `
        "=The owner person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member."

    # Bank-Import-Modul: optionales Verrechnungskonto (Name -> id; leer = unveraendert). Muster tool_create_account
    # (Resolve Settlement); ob die Kontoart eins haben darf, prueft die DB (fn_settlement_account_reason) im Probelauf.
    $resSettle = Build-Pg 'Resolve Settlement' @(1100, 360) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account(NULLIF((`$1::jsonb)->>'settlement_account', ''), NULL, TRUE);" `
        ([ordered]@{ settlement_account = '$(''Start'').item.json.settlement_account' })
    $ifSettleBad = Build-If 'Settlement invalid?' @(1320, 360) `
        "={{ !!`$('Start').item.json.settlement_account && `$('Resolve Settlement').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'
    $errSettle = Build-ToolError 'Settlement unresolved' @(1540, 480) `
        "=Settlement account '{{ `$('Start').item.json.settlement_account }}' resolves to {{ `$('Resolve Settlement').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Settlement').item.json.candidates) }}. Ask the user which exact account."

    # "DB ist das Gesetz": fn_set_account laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate
    # in den echten Write (partielles UPDATE der Stammdaten).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_account' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Set account (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, (r->>'account_id')::int AS account_id" `
        -Params ([ordered]@{
            account_id                  = '$(''Resolve Account'').item.json.id'
            name                        = '$(''Start'').item.json.new_name'
            bank                        = '$(''Start'').item.json.bank'
            account_number              = '$(''Start'').item.json.account_number'
            remove_account_number       = '$(''Start'').item.json.remove_account_number'   # Import zuerst: falsche IBAN entfernen
            owner_person_id            = '$(''Resolve Person'').item.json.person_id'
            settlement_id               = '($(''Start'').item.json.settlement_account ? $(''Resolve Settlement'').item.json.id : null)'
            notes                       = '$(''Start'').item.json.notes'
            fixed_deposit_maturity_date = '$(''Start'').item.json.fixed_deposit_maturity_date'
            fixed_deposit_auto_renew    = '$(''Start'').item.json.fixed_deposit_auto_renew'
            ownership                   = '$(''Start'').item.json.ownership'              # WS-0b estate
            has_transmortal_poa         = '$(''Start'').item.json.has_transmortal_poa'
            min_balance                 = '$(''Start'').item.json.min_balance'            # Puffer je Konto
            min_balance_default         = '$(''Start'').item.json.min_balance_default'
        })

    # HITL: nur die tatsaechlich gelieferten Felder anzeigen (-If je Zeile). Strukturiertes Summary (Textkatalog).
    # Einziger Geldbetrag: der Puffer (min_balance) in Kontowaehrung.
    $S = "`$('Start').item.json"
    $P = "`$('Resolve Person').item.json"
    $A = "`$('Resolve Account').item.json"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.set_account' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account'            "$S.account_name")
        (New-HitlLine 'finance.label.new_name'           "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'finance.label.bank'               "$S.bank" -If "$S.bank")
        (New-HitlLine 'finance.label.iban_number' "$S.account_number" -If "$S.account_number")
        (New-HitlNote -Key 'finance.note.iban_removed' -If "(['true','t','yes','y','on','1'].indexOf(String($S.remove_account_number || '').toLowerCase().trim()) >= 0)")
        (New-HitlLine 'finance.label.owner_person'       "($P.full_name || $S.owner_person)" -If "$S.owner_person")
        (New-HitlLine 'finance.label.settlement_account' "$S.settlement_account" -If "$S.settlement_account")
        (New-HitlLine 'finance.label.maturity'           (Get-DryEffectiveExpr 'fixed_deposit_maturity_date') -Kind date -If "$S.fixed_deposit_maturity_date")
        (New-HitlLine 'finance.label.auto_renew'       "$S.fixed_deposit_auto_renew" -Kind bool -If "$S.fixed_deposit_auto_renew")
        (New-HitlLine 'finance.label.ownership'          "$S.ownership" -Kind enum -Enum 'finance.enum.ownership' -If "$S.ownership")
        (New-HitlLine 'finance.label.transmortal_poa'    "(['true','t','yes','y','on','1'].indexOf(String($S.has_transmortal_poa).toLowerCase().trim()) >= 0)" -Kind bool -If "$S.has_transmortal_poa")
        (New-HitlLine 'core.label.note'                  "$S.notes" -If "$S.notes")
        (New-HitlLine 'finance.label.min_balance'        "Number($S.min_balance)" -Kind money -Currency "$A.currency" -If "$S.min_balance")
        (New-HitlNote -Key 'finance.note.min_balance_default' -If "(['true','t','yes','y','on','1'].indexOf(String($S.min_balance_default || '').toLowerCase().trim()) >= 0)")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the set_account action'

    # Atomarer Write via fn_set_account ($wg.Write, 'Set account (atomic)'): partielles UPDATE der Stammdaten.

    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('account_id', "={{ `$('Set account (atomic)').item.json.account_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_account mit denselben Werten, immer zurückgerollt. ok:false -> Dry run rejected: KEINE Karte, card_sent:false + Grund an den Agenten. Die fn kennt kaum freundliche Ablehnungen; ein Verstoß gegen den ownership-CHECK ist eine Exception -> Abbruch + errorWorkflow-Alarm, aber VOR der Karte statt nach dem Tipp. ok:true -> Karte. Der echte Write nach dem Tipp prüft erneut.' 200 400

    $stickyOv = Build-Sticky 'Doc set_account' @(2200, -220) `
        'fn_set_account: partielles Stammdaten-UPDATE' `
        'Ändert NUR Stammdaten (Name/Bank/Nr./Inhaber/Verrechnungskonto (nur Depot/P2P, Resolve Settlement -> settlement_id; die DB prüft die Kontoart)/Notiz/Festgeld-Felder + WS-0b estate: ownership [single/joint_or/joint_and], transmortale Bankvollmacht). BEWUSST NICHT: account_type, currency (-> Korruption), status (-> close_account), Saldo (Trigger). Nur gelieferte Felder werden gesetzt (COALESCE); remove_account_number=true entfernt die Kontonummer (Korrektur einer falsch zugeordneten bzw. gelernten IBAN, Karten-Hinweis). Puffer je Konto (min_balance, Kontowährung, nur Geld-Konten; min_balance_default=true = zurück auf den Haushalts-Standard core.config coverage_buffer_eur) speist die Kontovorschau fn_account_outlook; CHECK finance_accounts_min_balance_chk ist der Backstop. Freundliche {ok:false}-Fälle (Probelauf vor der Karte): Puffer negativ / kein Geld-Konto / Puffer setzen und zurücksetzen zugleich, Kontonummer schon vergeben, Nummer setzen und entfernen zugleich, Verrechnungskonto unzulässig (fn_settlement_account_reason: falsche Kontoart, kein Girokonto bei P2P, andere Währung, das Konto selbst). Der ownership-CHECK (geschlossene Liste) ist der strukturelle Backstop, die Tool-Description führt den Agenten.' 220 440

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct, $resPerson, $ifPersonBad, $errPerson, $resSettle, $ifSettleBad, $errSettle) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ret, $stickyDry, $stickyOv)

    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'          = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'          = @{ main = @(
            @( E 'Resolve Person' ),
            @( E 'Account ambiguous' )
        ) }
        'Resolve Person'           = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'          = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Resolve Settlement' )
        ) }
        'Resolve Settlement'       = @{ main = @( ,@( E 'Settlement invalid?' ) ) }
        'Settlement invalid?'      = @{ main = @(
            @( E 'Settlement unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                  = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'              = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Set account (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set account (atomic)'     = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.finance.tool_set_account' $nodes $conns `
        @{ Category = 'accounts' }
}
