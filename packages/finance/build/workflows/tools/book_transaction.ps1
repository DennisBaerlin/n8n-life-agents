#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 2b. tool_book_transaction (externe Ausgabe/Einnahme, EIN Bein) ----
# Bucht eine einzelne Transaktion auf EINES meiner Konten gegen eine externe (nicht getrackte)
# Gegenseite -- KEIN Transfer. direction (inflow/outflow) -> Vorzeichen rechnet die DB-Function.
function Build-BookTransaction {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('account_name','direction','amount','transaction_date','description','category')

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates, currency FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name');" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1' 'equals' 'number'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # "DB ist das Gesetz": fn_book_transaction laeuft als Probelauf VOR der Karte (ungueltige direction, amount<=0,
    # fee auf inflow -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten Write.
    # Atomarer Write via Function: ein Bein, Vorzeichen aus direction.
    # WS-C2: reserve_breach -> als DB-gerenderte NOTE-Zeichenkette durchreichen (COALESCE -> nie NULL: n8n-Set-
    # Typ-Validierung null-sicher; die Note traegt Konto + Fehlbetrag, der Agent formuliert um). Strukturobjekt
    # bleibt in der fn (Tests/Advisor) — das Tool zeigt dem LLM nur die menschliche Note.
    $wg = New-FnWriteGate -Fn 'finance.fn_book_transaction' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Book transaction (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'tx_id')::int AS tx_id, (r->>'amount')::numeric AS amount, (r->>'account_balance')::numeric AS account_balance, COALESCE(r->'reserve_breach'->>'note', '') AS reserve_breach" `
        -Params ([ordered]@{
            account_id       = '$(''Resolve Account'').item.json.id'
            amount           = '$(''Start'').item.json.amount'
            direction        = '$(''Start'').item.json.direction'
            category         = '$(''Start'').item.json.category'
            description      = '$(''Start'').item.json.description'
            transaction_date = '$(''Start'').item.json.transaction_date'
        })

    # --- HITL approval gate (before the atomic write) ---
    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Betrag in der Konto-Waehrung (Resolve Account liest accounts.currency mit), nie ein festes EUR.
    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'finance.hitl.book_transaction' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account'   "$S.account_name")
        (New-HitlLine 'finance.label.direction' "$S.direction" -Kind enum -Enum 'finance.enum.direction')
        (New-HitlLine 'core.label.amount'       "$S.amount" -Kind money -Currency "`$('Resolve Account').item.json.currency")
        (New-HitlLine 'finance.label.purpose'   "$S.description")
        (New-HitlLine 'core.label.date'         "`$('Dry run').item.json.r.effective.transaction_date" -Kind date)   # DB-Default heute (Probelauf)
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the book_transaction action'

    # Atomarer Write via fn_book_transaction ($wg.Write, Params siehe oben).
    # fn liefert ok/reason: ungueltige direction / amount<=0 / fee-needs-outflow -> {ok:false}.
    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Transaction rejected' @(2420, 200) `
        "={{ `$('Book transaction (atomic)').item.json.reason }}"

    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('tx_id', "={{ `$('Book transaction (atomic)').item.json.tx_id }}", 'number')
        ,@('amount', "={{ `$('Book transaction (atomic)').item.json.amount }}", 'number')
        ,@('account_balance', "={{ `$('Book transaction (atomic)').item.json.account_balance }}", 'number')
        ,@('reserve_breach', "={{ `$('Book transaction (atomic)').item.json.reserve_breach }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -200) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_book_transaction mit denselben Werten, immer zurückgerollt. ok:false (ungültige direction, amount<=0, fee auf inflow) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 440

    $stickyBalance = Build-Sticky 'DB-Automatik balance + Reserve-Wächter' @(1980, -200) `
        'finance.fn_book_transaction (atomar) + trg_finance_balance_update + reserve_breach' `
        'Schreibt finance.fn_book_transaction atomar: EIN Bein auf EIN Konto (externe Ausgabe/Einnahme, kein Transfer). direction -> Vorzeichen (outflow=-, inflow=+); category Default other (fee nur outflow). Danach pflegt trg_finance_balance_update den Saldo automatisch -- der Workflow bucht den Saldo nie selbst. WS-C2 Reserve-Wächter: bei einem OUTFLOW prüft die fn nach dem Write, ob der Saldo unter den für Sparziele reservierten Betrag gefallen ist (fn_reserve_breach) und faltet eine deutsche Hinweis-Note in reserve_breach (sonst leer) -> der Agent spricht den Owner proaktiv an. Kein Block (advisory).' 240 460

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(2420, -200) `
        'fn-Rückgabe {ok:false, reason}' `
        'Ungültige direction, amount<=0 oder fee auf inflow liefert die fn als {ok:false, reason} -> Transaction rejected reicht reason an den Agenten (weiche Rückfrage, kein RAISE/Owner-Alert). Nur ok=true bucht wirklich. Normalerweise fängt schon der Probelauf das vor der Karte ab.' 200 400

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct) + $wg.Nodes + @(
               $summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyBalance, $stickyOk)

    $conns = [ordered]@{
        'Start'                     = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'           = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'           = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Account ambiguous' )
        ) }
        'Dry run'                   = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'               = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'    = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'          = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                 = @{ main = @(
            @( E 'Book transaction (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Book transaction (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                 = @{ main = @(
            @( E 'Return' ),
            @( E 'Transaction rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_book_transaction' $nodes $conns `
        @{ Category = 'bookings' }
}

