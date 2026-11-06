#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_delete_holding (Depot-Position loeschen: Hard-DELETE einer Fehlanlage/leeren Position) ---
function Build-DeleteHolding {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    # Position per Depot-Name + Symbol/ISIN (finance.fn_find_holding, die EINE Positionssuche der Tools) statt
    # holding_id-Lookup durch das Modell; unbekannt/mehrdeutig -> {ok:false, code, candidates} ohne Karte.
    $trig = Build-Trigger @('depot_name','position')

    $find = Build-Pg 'Find Holding' @(0, 200) "=SELECT finance.fn_find_holding(`$1::jsonb) AS r;" `
        ([ordered]@{ depot_name = '$(''Start'').item.json.depot_name'; position = '$(''Start'').item.json.position' })
    $ifFound = Build-If 'Holding found?' @(220, 200) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $F = "`$('Find Holding').item.json.r"
    $errNotFound = Build-Set 'Holding not found' @(440, 400) @(
        ,@('ok', 'false', 'boolean')
        ,@('error', "={{ $F.reason }}", 'string')
        ,@('code', "={{ $F.code }}", 'string')
        ,@('candidates', "={{ $F.candidates || [] }}", 'array')
    )

    $readH = Build-Pg 'Read Holding' @(220, 0) `
        "=SELECT h.symbol, h.name AS sec_name, h.shares, a.name AS depot_name, (SELECT COUNT(*)::int FROM finance.transactions t WHERE t.holding_id = h.id) AS tx_count FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id WHERE h.id = ((`$1::jsonb)->>'holding_id')::int;" `
        ([ordered]@{ holding_id = '$(''Find Holding'').item.json.r.holding_id' })

    # "DB ist das Gesetz": fn_delete_holding laeuft als Probelauf VOR der Karte (verknuepfte Trades -> {ok:false} ohne
    # Karte); derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_delete_holding' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Delete holding (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'holding_id')::int AS holding_id" `
        -Params ([ordered]@{ holding_id = '$(''Find Holding'').item.json.r.holding_id' })

    # Strukturiertes Summary (Textkatalog): Ablehnungs- bzw. Hard-DELETE-Hinweis haengt an tx_count.
    $H = "`$('Read Holding').item.json"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.delete_holding' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.security'      "($H.sec_name ? 'finance.tpl.symbol_name' : 'finance.tpl.plain')" -Kind tpl -Params @{ symbol = "$H.symbol"; name = "$H.sec_name"; value = "$H.symbol" })
        (New-HitlLine 'finance.label.depot'         "$H.depot_name")
        (New-HitlLine 'finance.label.shares'        "$H.shares" -Kind number -Digits -1)
        (New-HitlLine 'finance.label.booked_trades' "$H.tx_count")
        (New-HitlNote -KeyExpr "($H.tx_count > 0 ? 'finance.note.delete_holding_rejected' : 'finance.note.delete_holding_hard')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the delete_holding action'

    # Atomarer Write ($wg.Write, 'Delete holding (atomic)'): prueft erneut, falls sich seit dem Probelauf etwas geaendert hat.
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Delete rejected' @(2200, 240) `
        "={{ `$('Delete holding (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete holding (atomic)').item.json.action }}", 'string')
        ,@('holding_id', "={{ `$('Delete holding (atomic)').item.json.holding_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Find Holding = Position per Depot + Symbol/ISIN (fn_find_holding); unbekannt/mehrdeutig -> Holding not found mit candidates, keine Karte. Dry run = fn_delete_holding mit denselben Werten, immer zurückgerollt. ok:false (Position hat noch verknüpfte Trades) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (not-found) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_delete_holding: Hard-DELETE-if-empty' @(1760, -260) `
        'Löschen nur ohne verknüpfte Trades' `
        'fn zählt verknüpfte Transaktionen (finance.transactions.holding_id). tx_count>0: {ok:false, reason, transaction_count} OHNE Write -> Delete rejected (erst Trades voiden). tx_count=0: DELETE finance.depot_holdings; action=deleted. RAISE bei not-found. Sinnvoll für eine versehentliche oder nach vollständigem Void verwaiste (shares=0) Position.' 240 500

    $nodes = @($trig, $find, $ifFound, $errNotFound, $readH) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Find Holding' ) ) }
        'Find Holding'           = @{ main = @( ,@( E 'Holding found?' ) ) }
        'Holding found?'         = @{ main = @(
            @( E 'Read Holding' ),
            @( E 'Holding not found' )
        ) }
        'Read Holding'           = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Delete holding (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete holding (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_delete_holding' $nodes $conns `
        @{ Category = 'securities' }
}
