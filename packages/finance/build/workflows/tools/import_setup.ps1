#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_import_setup --- gefuehrte Ersteinrichtung aus einer Export-Datei
# Die Sitzung liegt in finance.setup_session (file_id, Antworten); der Agent kennt nur diesen einen Aufruf. Der Schritt kommt aus der DB
# (fn_setup_next), das Einstellen der Positionen aus fn_setup_advance, Karte und Write danach aus tool_commit_import bzw. tool_create_account.
function Build-ImportSetup {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-ImportSetup'
    $idHistoric = Get-RequiredWorkflowId 'agent.finance.sub_fetch_historic_price' 'Build-ImportSetup' -Soft
    $trig = Build-Trigger @('action', 'question_key', 'answer', 'amount')
    $S = "`$('Start').first().json"

    $ifCancel = Build-If 'Cancel?' @(0, 0) "={{ $S.action === 'cancel' }}" 'true' 'equals' 'boolean'
    $cancel = Build-Pg 'Cancel setup' @(220, -300) "=SELECT finance.fn_setup_advance(`$1::jsonb) AS r;" `
        ([ordered]@{ chat_id = "String($S.chat_id || '')"; action = "'cancel'" })

    # aggregiert: ein SELECT ohne Zeile liefert sonst kein Item
    $load = Build-Pg 'Load setup' @(220, 0) `
        "=SELECT (array_agg(file_id ORDER BY updated_at DESC))[1] AS file_id FROM finance.setup_session WHERE chat_id = (`$1::jsonb)->>'chat_id' AND created_at > now() - interval '7 days';" `
        ([ordered]@{ chat_id = "String($S.chat_id || '')" })
    $ifOpen = Build-If 'Setup open?' @(440, 0) "={{ !!`$json.file_id }}" 'true' 'equals' 'boolean'
    $none = Build-Set 'No open setup' @(660, 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', 'no_open_setup', 'string')
        ,@('error', 'There is no open first-time setup. Ask the user to send the export file.', 'string')
    )

    $reader = New-BankExportTableReader -FetchId $idFetch -OnTable 'Peek next' -FileIdExpr "`$('Load setup').first().json.file_id"
    $tableExpr = $reader.TableExpr
    $peek = Build-Pg 'Peek next' @(1100, 400) "=SELECT finance.fn_setup_next(`$1::jsonb) AS r;" `
        ([ordered]@{ chat_id = "String($S.chat_id || '')"; table = $tableExpr })
    $P = "`$('Peek next').first().json.r"

    $ifReanchor = Build-If 'Reanchor?' @(1320, 400) "={{ $S.action === 'reanchor' && $P.phase === 'reanchor' }}" 'true' 'equals' 'boolean'
    $wg = New-FnWriteGate -Fn 'finance.fn_setup_reanchor' -DryPos @(1540, 100) -WritePos @(2420, 100) `
        -WriteName 'Reanchor (atomic)' -WriteSelect "r AS r" `
        -Params ([ordered]@{ chat_id = "String($S.chat_id || '')"; table = $tableExpr })
    $summary = New-HitlSummary -Pos @(1980, 100) -Title 'finance.hitl.setup_reanchor' -TitleParams @{ account = "$P.account_name" } -LinesExpr $wg.CardLinesExpr
    $approve = Build-CallWorkflow 'Request Approval' @(2200, 100) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ $S.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(2420, 300) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $cancelled = Build-ToolCancelled 'Return cancelled' @(2640, 500) 'moving the account start (nothing changed)'

    $ifHist = Build-If 'Needs historic price?' @(1540, 600) "={{ $P.phase === 'open_items' && !!($P.ask || {}).isin && !!($P.ask || {}).date && Number(($P.ask || {}).shares) > 0 }}" 'true' 'equals' 'boolean'
    $hist = Build-CallWorkflow 'Fetch historic price' @(1760, 800) $idHistoric 'agent.finance.sub_fetch_historic_price' `
        ([ordered]@{ isin = "={{ ($P.ask || {}).isin }}"; date = "={{ ($P.ask || {}).date }}"; currency = "={{ $P.currency || 'EUR' }}" })

    $adv = Build-Pg 'Advance' @(1980, 600) "=SELECT finance.fn_setup_advance(`$1::jsonb) AS r;" `
        ([ordered]@{
            chat_id        = "String($S.chat_id || '')"
            action         = "($S.action || 'continue')"
            question_key   = "($S.question_key || null)"
            answer         = "($S.answer || null)"
            amount         = "($S.amount || null)"
            table          = $tableExpr
            historic_price = "(`$('Fetch historic price').isExecuted && `$('Fetch historic price').first().json.ok ? `$('Fetch historic price').first().json.price : null)"
        })
    $adv['executeOnce'] = $true
    $R = "`$('Advance').isExecuted ? `$('Advance').first().json.r : (`$('Reanchor (atomic)').isExecuted ? `$('Reanchor (atomic)').first().json.r : `$('Cancel setup').first().json.r)"
    $ret = Build-Return @(2860, 300) @(
        ,@('ok', "={{ (($R).ok) === true }}", 'boolean')
        ,@('phase', "={{ ($R).phase || '' }}", 'string')
        ,@('say', "={{ ($R).say || ($R).reason || '' }}", 'string')
        ,@('ask', "={{ ($R).ask || null }}", 'object')
        ,@('card', "={{ ($R).card || null }}", 'object')
        ,@('done', "={{ ($R).done === true }}", 'boolean')
        ,@('batch_id', "={{ ($R).batch_id || '' }}", 'string')
        ,@('file_id', "={{ ($R).file_id || '' }}", 'string')
        ,@('account_name', "={{ ($R).account_name || '' }}", 'string')
        ,@('interest_source', "={{ ($R).interest_source || '' }}", 'string')
        ,@('open_count', "={{ ($R).open_count || 0 }}", 'number')
        ,@('notes', "={{ ($R).notes || [] }}", 'array')
        ,@('held', "={{ ($R).held || [] }}", 'array')
    )

    $sticky = Build-Sticky 'Überblick' @(-200, -520) `
        'Ersteinrichtung: eine Datei, nur noch Karten' `
        'Start (action continue|cancel|reanchor, question_key, answer, amount) -> Sitzung aus finance.setup_session laden (Datei-Referenz bleibt nur dort, fällt nie aus dem Gesprächsfenster) -> Datei neu holen und lesen -> Peek next = finance.fn_setup_next (STABLE): der Schritt wird aus Fakten abgeleitet, nie gespeichert -> offener Punkt mit ISIN: historischer Kurs (Vorschlag) -> Advance = finance.fn_setup_advance: Antwort speichern, Konto binden, Positionen per fn_import_positions_from_export einstellen. Karten kommen aus tool_create_account und tool_commit_import, der Agent ruft sie mit card.params. reanchor: unberührtes Konto auf den Anfang einer Datei mit gedrucktem Stand umstellen (Gate, fn_setup_reanchor). Die Datei geht nie ans Sprachmodell. Kein HITL für Antworten und Staging: das sind keine Domänen-Daten.' 460 400

    $nodes = @($trig, $ifCancel, $cancel, $load, $ifOpen, $none) + $reader.Nodes + @($peek, $ifReanchor) + $wg.Nodes +
             @($summary, $approve, $ifApproved, $cancelled, $ifHist, $hist, $adv, $ret, $sticky)
    $conns = [ordered]@{
        'Start'        = @{ main = @( ,@( E 'Cancel?' ) ) }
        'Cancel?'      = @{ main = @( @( E 'Cancel setup' ), @( E 'Load setup' ) ) }
        'Cancel setup' = @{ main = @( ,@( E 'Return' ) ) }
        'Load setup'   = @{ main = @( ,@( E 'Setup open?' ) ) }
        'Setup open?'  = @{ main = @( @( E $reader.Entry ), @( E 'No open setup' ) ) }
    }
    foreach ($k in $reader.Conns.Keys) { $conns[$k] = $reader.Conns[$k] }
    $rest = [ordered]@{
        'Peek next'              = @{ main = @( ,@( E 'Reanchor?' ) ) }
        'Reanchor?'              = @{ main = @( @( E 'Dry run' ), @( E 'Needs historic price?' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @( @( E 'Build Approval Summary' ), @( E 'Dry run rejected' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @( @( E 'Reanchor (atomic)' ), @( E 'Return cancelled' ) ) }
        'Reanchor (atomic)'      = @{ main = @( ,@( E 'Return' ) ) }
        'Needs historic price?'  = @{ main = @( @( E 'Fetch historic price' ), @( E 'Advance' ) ) }
        'Fetch historic price'   = @{ main = @( ,@( E 'Advance' ) ) }
        'Advance'                = @{ main = @( ,@( E 'Return' ) ) }
    }
    foreach ($k in $rest.Keys) { $conns[$k] = $rest[$k] }
    return Build-Workflow 'agent.finance.tool_import_setup' $nodes $conns @{ Internal = $true }
}
