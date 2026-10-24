#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_void_transaction (set_*: Fehlbuchung per Hard-DELETE rueckgaengig machen) ---
function Build-VoidTransaction {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('transaction_id')

    # Tx + Kontoname + Anzahl betroffener Beine (Gruppe via group_id; Fallback loan_id+Datum) fuer den HITL-Summary.
    $readTx = Build-Pg 'Read Tx' @(220, 0) `
        "=SELECT t.amount, t.transaction_date, t.category::text AS category, t.description, a.name AS account_name, a.currency AS currency, (CASE WHEN t.group_id IS NOT NULL THEN (SELECT count(*) FROM finance.transactions x WHERE x.group_id = t.group_id) WHEN t.loan_id IS NOT NULL THEN (SELECT count(*) FROM finance.transactions x WHERE x.loan_id = t.loan_id AND x.transaction_date = t.transaction_date) ELSE 1 END)::int AS leg_count FROM finance.transactions t JOIN finance.accounts a ON a.id = t.account_id WHERE t.id = ((`$1::jsonb)->>'transaction_id')::int;" `
        ([ordered]@{ transaction_id = '$(''Start'').item.json.transaction_id' })
    # Unbekannte transaction_id -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, Mock-Tier 2026-10-24).
    $found = New-RequiredRowGate -Read $readTx -KeyField 'account_name' -IfName 'Tx found?' -ErrName 'Tx not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=Transaction {{ `$('Start').item.json.transaction_id }} does not exist. Look up the transaction id via postgres_select on finance.transactions and ask the user which booking to void."

    # Strukturiertes Summary (Textkatalog): Betrag in der Konto-Waehrung (a.currency aus Read Tx), transaction_date ist
    # ISO aus der DB; Kategorie als lesbarer Begriff.
    # "DB ist das Gesetz": fn_void_transaction laeuft als Probelauf VOR der Karte (Oversell-Guard -> {ok:false} ohne
    # Karte); derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_void_transaction' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Void (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'deleted_count')::int AS deleted_count" `
        -Params ([ordered]@{ transaction_id = '$(''Start'').item.json.transaction_id' })

    $T = "`$('Read Tx').item.json"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.void_transaction' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account'      "$T.account_name")
        (New-HitlLine 'core.label.date'            "$T.transaction_date" -Kind date)
        (New-HitlLine 'core.label.amount'          "$T.amount" -Kind money -Currency "$T.currency")
        (New-HitlLine 'finance.label.category'     "$T.category" -Kind enum -Enum 'finance.enum.category')
        (New-HitlLine 'finance.label.purpose_text' "$T.description")
        (New-HitlLine 'finance.label.hint'         "'finance.tpl.void_group'" -Kind tpl -Params @{ count = "$T.leg_count" } -If "$T.leg_count > 1")
        (New-HitlNote -Key 'finance.note.void_warning')
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the void_transaction action'

    # Atomarer Hard-DELETE via fn_void_transaction ($wg.Write, 'Void (atomic)'; Kredit-Paar zusammen; Oversell-Guard).
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Void rejected' @(2200, 240) `
        "={{ `$('Void (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('deleted_count', "={{ `$('Void (atomic)').item.json.deleted_count }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_void_transaction mit denselben Werten, immer zurückgerollt. ok:false (z. B. Oversell-Guard: ein späterer Verkauf hängt am Kauf) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyOv = Build-Sticky 'Doc void_transaction' @(1760, -240) `
        'fn_void_transaction: Hard-DELETE + Trigger-Recompute' `
        'Read Tx gibt immer ein Item aus (alwaysOutputData); unbekannte transaction_id -> Tx not found (Tool-Fehler statt stillem Ende). Löscht die Buchung; Trigger rechnen balance/shares/avg/Restschuld neu. Multi-Leg (transfer + loan) teilt eine group_id -> die GANZE Gruppe wird atomar entfernt (Fallback Altbestand: loan_id+Datum). Oversell-Guard -> {ok:false} wenn ein späterer Verkauf am Kauf hängt. Holding-Zeile (ISIN) bleibt (shares=0) -> spätere Dividende möglich.' 220 440

    $nodes = @($trig, $readTx, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Tx' ) ) }
        'Read Tx'                = @{ main = @( ,@( E 'Tx found?' ) ) }
        'Tx found?'              = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Tx not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Void (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Void (atomic)'          = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Void rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_void_transaction' $nodes $conns `
        @{ Category = 'bookings' }
}
