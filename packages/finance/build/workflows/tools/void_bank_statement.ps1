#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_void_bank_statement (Monats-Check WP-C) ---
# Nimmt den LETZTEN eingespielten Kontoauszug eines Kontos zurueck (finance.fn_void_bank_statement): alle Buchungen
# dieses Auszugs, die beim Abgleich uebersprungenen Termine, die gelernten Kennungen und den Abgleichsstand. Danach
# kann der Auszug (z. B. nach falscher Konto-Zuordnung) neu geschickt werden.
function Build-VoidBankStatement {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('account_name')

    $resolve = Build-Pg 'Read statement' @(220, 0) `
        "=SELECT a.id AS account_id, a.name AS account_name, a.currency, r.hit_count, b.period_start::text AS period_start, b.period_end::text AS period_end, (SELECT count(*) FROM finance.transactions t WHERE t.bank_statement_id = b.id)::int AS bookings FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', NULL, TRUE) r LEFT JOIN finance.accounts a ON a.id = r.id LEFT JOIN LATERAL (SELECT * FROM finance.bank_statements s WHERE s.account_id = r.id ORDER BY s.period_end DESC LIMIT 1) b ON true;" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })
    $ifFound = Build-If 'Statement found?' @(440, 0) "={{ `$json.hit_count === 1 && !!`$json.period_end }}" 'true' 'equals' 'boolean'
    $err = Build-ToolError 'No statement' @(660, 200) `
        "={{ `$('Read statement').item.json.hit_count !== 1 ? 'No unique active account with this name - ask which account is meant.' : 'No imported statement exists for this account.' }}"

    $R = "`$('Read statement').item.json"
    # "DB ist das Gesetz": fn_void_bank_statement laeuft als Probelauf VOR der Karte (spaeterer Abgleich blockiert,
    # nicht der juengste Auszug -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_void_bank_statement' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Void statement' -WriteSelect 'r' `
        -Params ([ordered]@{ account_id = "$R.account_id" })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'finance.hitl.void_bank_statement' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account' "$R.account_name")
        (New-HitlLine 'finance.label.statement_period' "'finance.tpl.statement_period'" -Kind tpl -Params @{
            from = (New-HitlValue -Kind date -Value "$R.period_start"); to = (New-HitlValue -Kind date -Value "$R.period_end") })
        (New-HitlLine 'finance.label.statement_bookings_removed' "$R.bookings" -Kind number)
        (New-HitlNote -Key 'finance.note.statement_void')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'taking back the last statement (nothing changed)'

    $ifOk = Build-If 'Voided?' @(2200, 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $errVoid = Build-ToolError 'Not voided' @(2420, 200) "={{ `$('Void statement').item.json.r.reason }}"
    $V = "`$('Void statement').item.json.r"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('account_name', "={{ $R.account_name }}", 'string')
        ,@('period_start', "={{ $V.period_start }}", 'string')
        ,@('period_end', "={{ $V.period_end }}", 'string')
        ,@('removed_bookings', "={{ $V.voided_tx_count }}", 'number')
    )

    $sticky = Build-Sticky 'Überblick' @(220, -300) `
        'Letzten Kontoauszug zurücknehmen (nur der jüngste, LIFO)' `
        'Read statement löst das Konto per Name auf und liest den jüngsten Auszug (Zeitraum, Anzahl seiner Buchungen) für die Karte. Dry run = dieselbe fn als Probelauf VOR der Karte (immer zurückgerollt): spätere Ablehnung -> Dry run rejected, KEINE Karte. Nach dem Tipp nimmt finance.fn_void_bank_statement in EINER Transaktion zurück: alle Buchungen mit bank_statement_id (je Gruppe über fn_void_transaction), die beim Abgleich gesetzten Skips, gelernte Kennungen, den Abgleichsstand davor und das Aggregat. Nicht zurück: gelernte Kontonummer und Plan-Anpassungen (eigene Stammdaten). Ein späterer Abgleich blockiert (ok:false).' 320 360

    $nodes = @($trig, $resolve, $ifFound, $err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifOk, $errVoid, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read statement' ) ) }
        'Read statement'         = @{ main = @( ,@( E 'Statement found?' ) ) }
        'Statement found?'       = @{ main = @( @( E 'Dry run' ), @( E 'No statement' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @( @( E 'Build Approval Summary' ), @( E 'Dry run rejected' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @( @( E 'Void statement' ), @( E 'Return cancelled' ) ) }
        'Void statement'         = @{ main = @( ,@( E 'Voided?' ) ) }
        'Voided?'                = @{ main = @( @( E 'Return' ), @( E 'Not voided' ) ) }
    }
    return Build-Workflow 'agent.finance.tool_void_bank_statement' $nodes $conns @{ Category = 'import' }
}
