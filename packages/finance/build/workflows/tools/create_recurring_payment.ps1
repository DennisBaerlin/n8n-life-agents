#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 9. tool_create_recurring_payment ---------------
# Standalone wiederkehrende Einnahme/Ausgabe (Gehalt, Miete, Abo, Rentenzahlung, Mitgliedschaft).
# KEIN harter Namens-Dedup: gleichnamige Zeilen sind legitim (Betragswechsel ueber valid_from/valid_to,
# z.B. Gehalt -> Elterngeld -> Gehalt). Der Agent prueft per Description und fragt nach.
function Build-CreateRecurringPayment {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('name','account_name','direction','amount','schedule_interval','schedule_unit',
                           'schedule_day_of_month','first_payment_date','valid_from','valid_to','notes')

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates, currency FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name');" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # "DB ist das Gesetz": fn_create_recurring_payment laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_recurring_payment' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create recurring payment (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'recurring_payment_id')::int AS recurring_payment_id, (r->>'monthly_equivalent')::numeric AS monthly_equivalent, COALESCE(r->'cashflow_coverage'->>'note', '') AS cashflow_coverage" `
        -Params ([ordered]@{
            name                  = '$(''Start'').item.json.name'
            account_id            = '$(''Resolve Account'').item.json.id'
            direction             = '$(''Start'').item.json.direction'
            amount                = '$(''Start'').item.json.amount'
            schedule_interval     = '$(''Start'').item.json.schedule_interval'
            schedule_unit         = '$(''Start'').item.json.schedule_unit'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            first_payment_date    = '$(''Start'').item.json.first_payment_date'
            valid_from            = '$(''Start'').item.json.valid_from'
            valid_to              = '$(''Start'').item.json.valid_to'
            notes                 = '$(''Start'').item.json.notes'
        })

    # --- HITL approval gate ---
    # Strukturiertes Summary (Textkatalog): Rate in der Konto-Waehrung (Resolve Account liest accounts.currency mit).
    # Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1, dieselbe wie die Import-Karte).
    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'finance.hitl.create_recurring_payment' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity recurring_payment -S $S -D @{
        Ccy = "`$('Resolve Account').item.json.currency" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 240) 'the create_recurring_payment action'

    # Atomarer Write via fn_create_recurring_payment (Vorzeichen aus direction; INSERT via Helper).
    # fn liefert ok/reason: direction ungueltig / amount<=0 -> {ok:false}.

    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Recurring rejected' @(2420, 240) `
        "={{ `$('Create recurring payment (atomic)').item.json.reason }}"

    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('recurring_payment_id', "={{ `$('Create recurring payment (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('monthly_equivalent', "={{ `$('Create recurring payment (atomic)').item.json.monthly_equivalent }}", 'number')
        ,@('cashflow_coverage', "={{ `$('Create recurring payment (atomic)').item.json.cashflow_coverage }}", 'string')
    )

    $stickyGen = Build-Sticky 'DB-Automatik monthly_equivalent + Cashflow-Fold' @(1980, -240) `
        'GENERATED: monthly_equivalent + Event-Fold cashflow_coverage' `
        'fn_create_recurring_payment leitet das Vorzeichen aus direction ab (income=+, expense=-) und schreibt die Zeile via gemeinsamen Helper fn_add_recurring_payment. monthly_equivalent ist GENERATED (read-only, normalisiert auf Monat) und erscheint automatisch im Cashflow-View. Phase L WS-3 / Audit Paket 3: nach dem Write liest die fn monthly_cashflow_summary.monthly_free (frei nach Konsum + Kreditraten, Sparraten zählen nicht); frei<0 -> Note in cashflow_coverage (sonst leer, COALESCE -> null-sicher). Der Bookkeeper relayed sie nach dem Erfolg (advisory, kein Block).' 230 470

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2420, -240) `
        'fn-Rückgabe {ok:false, reason}' `
        'Ungültige direction oder amount<=0 liefert die fn als {ok:false, reason} -> Recurring rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert).' 200 380

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_recurring_payment mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (ungültige direction, amount kleiner/gleich 0) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyGen, $stickyOk,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                              = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'                    = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'                    = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Account ambiguous' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'             = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'                   = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                          = @{ main = @(
            @( E 'Create recurring payment (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create recurring payment (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                          = @{ main = @(
            @( E 'Return' ),
            @( E 'Recurring rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_recurring_payment' $nodes $conns `
        @{ Category = 'recurring' }
}
