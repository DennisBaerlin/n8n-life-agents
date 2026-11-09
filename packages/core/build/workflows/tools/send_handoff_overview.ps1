#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_send_handoff_overview (CROSS-AGENT, Seitenkanal-Versand ohne Write) ---------------------------------
# Uebersicht der im Plan-Gespraech vereinbarten, noch offenen Eintraege (agent.handoff_tasks) mit dem Knopf
# [Durchgehen] = handoff:<domain>:<max_task_id>. Zwei Aufrufer: agent.tool_publish_plan inline nach dem Publish und der
# Berater als Tool, wenn der Nutzer vor dem Publish eintragen will oder das Gespraech ohne Publish endet. domain ist beim
# Aufrufer fixer Binding-Input (nie $fromAI). Kein Write, kein Gate: der Knopf startet nur das Durchgehen, jede Buchung
# kommt danach mit ihrer eigenen Karte.
function Build-SendHandoffOverview {
    $trig = Build-Trigger @('domain')

    $read = Build-Pg 'Read overview' @(220, 0) `
        ("=SELECT core.fn_handoff_overview(jsonb_build_object('domain', (`$1::jsonb)->>'domain', 'chat_id', (`$1::jsonb)->>'chat_id'))::text AS ov, " +
         "core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb(" +
         (Get-UiKeysSql @('core.handoff.overview', 'core.handoff.btn_go')) + ")))->'t' AS t;") `
        ([ordered]@{
            domain  = "String(`$('Start').item.json.domain || '')"
            chat_id = "String(`$('Start').item.json.chat_id || '')"
        })
    $OV = "JSON.parse(`$('Read overview').item.json.ov || '{}')"
    $T  = "`$('Read overview').item.json.t"

    $ifOpen = Build-If 'Anything open?' @(440, 0) "={{ Number($OV.count || 0) > 0 }}" 'true' 'equals' 'boolean'

    $send = New-TelegramInlineKeyboardSendNode 'Send overview' @(660, -100) `
        (Get-UiTextExpr $T 'core.handoff.overview' @{ list = "($OV.items || []).map((x, i) => (i + 1) + '. ' + x).join('\n')" }) `
        @( @{ Text = (Get-UiTextExpr $T 'core.handoff.btn_go');
              Data = "={{ 'handoff:' + String(`$('Start').item.json.domain || '') + ':' + String($OV.max_task_id || '') }}" } ) `
        -ChatIdExpr "={{ String(`$('Start').item.json.chat_id || '') }}"
    $send['onError'] = 'continueRegularOutput'   # Komfort-Nachricht: ein Send-Fehler darf den Aufrufer (Publish) nie scheitern lassen

    $mark = Build-Pg 'Mark overview' @(770, -100) '=SELECT core.fn_handoff_overview_mark($1::jsonb) AS r;' `
        ([ordered]@{ domain = "String(`$('Start').item.json.domain || '')"; chat_id = "String(`$('Start').item.json.chat_id || '')"; max_task_id = "String($OV.max_task_id || '')" }) -ContinueOnError

    $retSent = Build-Return @(990, -100) @(
        ,@('ok', 'true', 'boolean')
        ,@('sent', "={{ !`$json.error }}", 'boolean')
        ,@('open_count', "={{ Number($OV.count || 0) }}", 'number')
    ) -Name 'Return sent'
    $retNone = Build-Return @(660, 120) @(
        ,@('ok', 'true', 'boolean')
        ,@('sent', 'false', 'boolean')
        ,@('open_count', '0', 'number')
    ) -Name 'Return nothing open'

    $sticky = Build-Sticky 'Doc Handoff-Uebersicht' @(120, -360) `
        'Übersicht vereinbarter Einträge (Seitenkanal-Versand ohne Write)' `
        'Read overview liest core.fn_handoff_overview (offene Aufgaben dieser Person und Domain, Person aus chat_id, nie LLM) und die zwei Texte in der Sprache des Empfängers. Nichts offen -> Return nothing open (sent false). Sonst Send overview: nummerierte Liste der Sätze und der Knopf Durchgehen = handoff:<domain>:<max_task_id> (Orchestrator: core.fn_handle_handoff_cb beansprucht nur bis max_task_id, danach startet der Buchhalter; jede Buchung kommt mit eigener Karte). Kein [Später]-Knopf: Nicht-Tippen ist später, die Aufgaben verfallen nicht. Bewusste enge Ausnahme zu tool = keine Seitenkanal-I/O (wie das Wächter-Angebot in agent.tool_publish_plan): reiner Hinweis, kein Domänen-Write, darum kein HITL-Gate. Send mit onError continue (Aufrufer Publish ist schon committet).' 340 600

    $nodes = @($trig, $read, $ifOpen, $send, $mark, $retSent, $retNone, $sticky)
    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'Read overview' ) ) }
        'Read overview'  = @{ main = @( ,@( E 'Anything open?' ) ) }
        'Anything open?' = @{ main = @(
            @( E 'Send overview' ),
            @( E 'Return nothing open' )
        ) }
        'Send overview'  = @{ main = @( ,@( E 'Mark overview' ) ) }
        'Mark overview'  = @{ main = @( ,@( E 'Return sent' ) ) }
    }
    return Build-Workflow 'agent.tool_send_handoff_overview' $nodes $conns @{ Internal = $true }
}
