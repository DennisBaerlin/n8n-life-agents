#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 2. tool_book_transfer (Playbook 5.6) ----------------
function Build-BookTransfer {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('from_account_name','to_account_name','amount','to_amount','transaction_date','purpose')

    $resFrom = Build-Pg 'Resolve From' @(220, 0) `
        "=SELECT id, hit_count, candidates, currency FROM finance.fn_resolve_account((`$1::jsonb)->>'from_account_name');" `
        ([ordered]@{ from_account_name = '$(''Start'').item.json.from_account_name' })

    $ifFrom = Build-If 'From unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errFrom = Build-ToolError 'From ambiguous' @(660, 200) `
        "=Source account '{{ `$('Start').item.json.from_account_name }}' resolves to {{ `$('Resolve From').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve From').item.json.candidates) }}. Ask the user which exact account."

    $resTo = Build-Pg 'Resolve To' @(660, 0) `
        "=SELECT id, hit_count, candidates, currency FROM finance.fn_resolve_account((`$1::jsonb)->>'to_account_name');" `
        ([ordered]@{ to_account_name = '$(''Start'').item.json.to_account_name' })

    $ifTo = Build-If 'To unique?' @(880, 0) "={{ `$json.hit_count }}" '1'

    $errTo = Build-ToolError 'To ambiguous' @(1100, 200) `
        "=Target account '{{ `$('Start').item.json.to_account_name }}' resolves to {{ `$('Resolve To').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve To').item.json.candidates) }}. Ask the user which exact account."

    # "DB ist das Gesetz": fn_book_transfer laeuft als Probelauf VOR der Karte (gleiches Konto, amount<=0,
    # Cross-Currency ohne gueltiges to_amount -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in
    # den echten Write: Soll- + Haben-Buchung in EINER Transaktion.
    # WS-C2: reserve_breach (Soll-/from-Bein) als DB-gerenderte NOTE durchreichen (COALESCE -> nie NULL, null-sicher).
    $wg = New-FnWriteGate -Fn 'finance.fn_book_transfer' -DryPos @(1100, 0) -WritePos @(2420, 0) `
        -WriteName 'Create transfer (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'debit_tx_id')::int AS debit_tx_id, (r->>'credit_tx_id')::int AS credit_tx_id, (r->>'fx_rate')::numeric AS fx_rate, (r->>'from_balance')::numeric AS from_balance, (r->>'to_balance')::numeric AS to_balance, COALESCE(r->'reserve_breach'->>'note', '') AS reserve_breach" `
        -Params ([ordered]@{
            from_account_id   = '$(''Resolve From'').item.json.id'
            to_account_id     = '$(''Resolve To'').item.json.id'
            amount            = '$(''Start'').item.json.amount'
            to_amount         = '$(''Start'').item.json.to_amount'
            transaction_date  = '$(''Start'').item.json.transaction_date'
            from_account_name = '$(''Start'').item.json.from_account_name'
            to_account_name   = '$(''Start'').item.json.to_account_name'
            purpose           = '$(''Start'').item.json.purpose'
        })

    # --- HITL approval gate (before the atomic write) ---
    # Strukturiertes Summary (Textkatalog). Jedes Bein in der Waehrung SEINES Kontos (die Resolve-Nodes lesen
    # accounts.currency mit); to_amount nur bei Fremdwaehrung.
    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(1760, 0) -Title 'finance.hitl.book_transfer' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.from'                "$S.from_account_name")
        (New-HitlLine 'finance.label.to'                  "$S.to_account_name")
        (New-HitlLine 'finance.label.amount_from'         "$S.amount" -Kind money -Currency "`$('Resolve From').item.json.currency")
        (New-HitlLine 'finance.label.target_amount_after' "$S.to_amount" -Kind money -Currency "`$('Resolve To').item.json.currency" -If "$S.to_amount")
        (New-HitlLine 'finance.label.purpose'             "$S.purpose")
        (New-HitlLine 'core.label.date'                   "`$('Dry run').item.json.r.effective.transaction_date" -Kind date)   # DB-Default heute (Probelauf)
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1980, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2200, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2420, 200) 'the book_transfer action'

    # Atomarer Write via fn_book_transfer ($wg.Write, Params siehe oben).
    # fn liefert ok/reason: gleiches Konto / amount<=0 -> {ok:false}.
    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2640, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Transfer rejected' @(2860, 200) `
        "={{ `$('Create transfer (atomic)').item.json.reason }}"

    $ret = Build-Return @(2860, 0) @(
        ,@('ok','true','boolean')
        ,@('debit_tx_id', "={{ `$('Create transfer (atomic)').item.json.debit_tx_id }}", 'number')
        ,@('credit_tx_id', "={{ `$('Create transfer (atomic)').item.json.credit_tx_id }}", 'number')
        ,@('from_balance', "={{ `$('Create transfer (atomic)').item.json.from_balance }}", 'number')
        ,@('to_balance', "={{ `$('Create transfer (atomic)').item.json.to_balance }}", 'number')
        ,@('fx_rate', "={{ `$('Create transfer (atomic)').item.json.fx_rate }}", 'number')
        ,@('reserve_breach', "={{ `$('Create transfer (atomic)').item.json.reserve_breach }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1100, -260) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_transfer mit denselben Werten, immer zurückgerollt. ok:false (gleiches Quell-/Zielkonto, amount<=0, Cross-Currency ohne gültiges to_amount) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 240 460

    $stickyBalance = Build-Sticky 'DB-Automatik balance + Reserve-Wächter' @(2420, -200) `
        'trg_finance_balance_update + Multi-Währung + reserve_breach' `
        'fn_book_transfer bucht beide Seiten atomar; je Buchung pflegt ein DB-Trigger den Saldo: Quellkonto (-) und Zielkonto (+). Kein manuelles Balance-Update. CROSS-CURRENCY: bei unterschiedlichen Kontowährungen wird jedes Bein in seiner Native-Währung gebucht (Soll -amount Quell-Wgr., Haben +to_amount Ziel-Wgr.); realisierter Kurs fx_rate=to_amount/amount auf beiden Beinen. WS-C2 Reserve-Wächter: fällt der QUELL-Saldo unter den für Sparziele reservierten Betrag, faltet die fn eine deutsche Hinweis-Note in reserve_breach (sonst leer) -> der Agent spricht den Owner proaktiv an. Kein Block.' 240 460

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2860, -200) `
        'fn-Rückgabe {ok:false, reason}' `
        'Gleiches Quell-/Zielkonto, amount<=0 ODER Cross-Currency ohne gültiges to_amount liefert die fn als {ok:false, reason} -> Transfer rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true bucht wirklich. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 220 400

    $nodes = @($trig, $resFrom, $ifFrom, $errFrom, $resTo, $ifTo, $errTo) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyBalance, $stickyOk)

    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Resolve From' ) ) }
        'Resolve From'             = @{ main = @( ,@( E 'From unique?' ) ) }
        'From unique?'             = @{ main = @(
            @( E 'Resolve To' ),
            @( E 'From ambiguous' )
        ) }
        'Resolve To'               = @{ main = @( ,@( E 'To unique?' ) ) }
        'To unique?'               = @{ main = @(
            @( E 'Dry run' ),
            @( E 'To ambiguous' )
        ) }
        'Dry run'                  = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'              = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Create transfer (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create transfer (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Transfer rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_book_transfer' $nodes $conns `
        @{ Category = 'bookings' }
}

