#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
# agent.finance.tool_send_bank_todos: beantwortet "was muss ich bei der Bank einstellen?" deterministisch je Bank.
# Liest nur (finance.fn_bank_todo_groups: Sichtbarkeit und Rechte), kein Gate; jede Nachricht traegt den Knopf btodo.
function Build-SendBankTodos {
    $trig = Build-Trigger @()

    $keys = Get-UiKeysSql ($script:BankTodoTextKeys + $script:UiRenderKeys)
    $read = Build-Pg 'Read todos' @(220, 0) `
        ("=WITH g AS MATERIALIZED (SELECT finance.fn_bank_todo_groups((`$1::jsonb)->>'chat_id') AS r) " +
         "SELECT g.r::text AS groups, core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb($keys), 'doc', g.r))::text AS ui FROM g;") `
        ([ordered]@{ chat_id = "String(`$('Start').item.json.chat_id || '')" })

    $buildJs = (Get-UiRenderLibJs) + (Get-BankTodoMessageJs) + @'
const groups = JSON.parse($input.first().json.groups || '[]');
const U = uiRender(JSON.parse($input.first().json.ui || '{}'));
if (!Array.isArray(groups) || groups.length === 0) { return [{ json: { nothing: true } }]; }
return groups.map((g) => ({ json: bankTodoMessage(U, g, true) }));
'@
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(440, 0)
        id = (New-Id); name = 'Build messages'
    }
    $ifNothing = Build-If 'Nothing open?' @(660, 0) "={{ `$json.nothing === true }}" 'true' 'equals' 'boolean'
    $send = New-TelegramInlineKeyboardSendNode 'Send todo' @(880, 120) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_done }}'; Data = '={{ $json.data }}' } ) `
        -ChatIdExpr "={{ String(`$('Start').item.json.chat_id || '') }}"
    $send['onError'] = 'continueRegularOutput'
    $retNone = Build-Return @(880, -120) @(
        ,@('ok', 'true', 'boolean')
        ,@('sent', 'false', 'boolean')
        ,@('note', 'Nothing is open at the bank. Tell the user in one short sentence.', 'string')
    ) -Name 'Return nothing'
    $retSent = Build-Return @(1100, 120) @(
        ,@('ok', 'true', 'boolean')
        ,@('sent', 'true', 'boolean')
        ,@('note', 'The list per bank was already sent as separate messages with a done button. Do not repeat it; reply with at most one short sentence.', 'string')
    ) -Name 'Return sent'

    $sticky = Build-Sticky 'Doc Bank-Zettel' @(120, -360) `
        'Bank-Zettel auf Nachfrage (nur Lesen)' `
        'Read todos liest finance.fn_bank_todo_groups: Owner alles, erwachsenes Mitglied die eigenen, Kind nichts; Betrag, Rhythmus und Termine kommen aus der Kette, nie vom Modell. Je Bank und Inhaber eine Nachricht mit Knopf btodo:<erste-id>:<max-id>. Nichts offen -> ein Satz vom Modell. Schreibt nichts; erledigt wird erst durch den Knopf (finance.fn_handle_bank_todo_cb).' 300 520

    $nodes = @($trig, $read, $build, $ifNothing, $send, $retNone, $retSent, $sticky)
    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'Read todos' ) ) }
        'Read todos'     = @{ main = @( ,@( E 'Build messages' ) ) }
        'Build messages' = @{ main = @( ,@( E 'Nothing open?' ) ) }
        'Nothing open?'  = @{ main = @( @( E 'Return nothing' ), @( E 'Send todo' ) ) }
        'Send todo'      = @{ main = @( ,@( E 'Return sent' ) ) }
    }
    return Build-Workflow 'agent.finance.tool_send_bank_todos' $nodes $conns @{ Category = 'recurring' }
}
