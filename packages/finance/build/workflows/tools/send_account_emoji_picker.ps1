#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
# agent.finance.tool_send_account_emoji_picker: schickt dem Owner die Knopf-Liste fuer das Konto-Zeichen. Liest nur, kein Gate;
# gespeichert wird erst durch den Tipp (finance.fn_handle_account_emoji_cb). Keine approval_matrix-Zeile (Verb send, schreibt nichts).
function Build-SendAccountEmojiPicker {
    $trig = Build-Trigger @('account_name')

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', NULL, TRUE);" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })
    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'
    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    $read = Build-Pg 'Read picker' @(660, 0) `
        "=SELECT finance.fn_account_emoji_picker((`$1::jsonb)->>'chat_id', ((`$1::jsonb)->>'account_id')::int) AS r;" `
        ([ordered]@{ chat_id = "String(`$('Start').item.json.chat_id || '')"; account_id = '$(''Resolve Account'').item.json.id' })
    $ifOk = Build-If 'Picker allowed?' @(880, 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $errRefused = Build-ToolError 'Picker refused' @(1100, 200) "={{ `$('Read picker').item.json.r.reason }}"

    $send = New-TelegramChoiceCardSendNode 'Send picker' @(1100, 0) "`$('Read picker').item.json.r.card" `
        -ChatIdExpr "={{ String(`$('Start').item.json.chat_id || '') }}"
    $ret = Build-Return @(1320, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('sent', 'true', 'boolean')
        ,@('note', 'The list of signs was already sent as a message with buttons. Do not list signs yourself; reply with at most one short sentence.', 'string')
    )

    $sticky = Build-Sticky 'Doc Zeichen-Liste' @(220, -340) `
        'Knopf-Liste fürs Konto-Zeichen (nur Lesen)' `
        'Auf Wunsch ohne genanntes Zeichen. finance.fn_account_emoji_picker entscheidet nach Rolle: Owner bekommt Seite 0 als Knöpfe (zwei Spalten, darunter „Weitere Zeichen vorschlagen“), Mitglied {ok:false} mit der Liste als Text, weil ein Tipp ohne zweite Person direkt speichern würde. Weitere Seiten laufen ohne KI über den Orchestrator-Zweig Choice card?. Der Tipp speichert in finance.fn_handle_account_emoji_cb ohne Karte (Ausnahme in docs/reference/packages.md).' 300 520

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct, $read, $ifOk, $errRefused, $send, $ret, $sticky)
    $conns = [ordered]@{
        'Start'           = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account' = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?' = @{ main = @( @( E 'Read picker' ), @( E 'Account ambiguous' ) ) }
        'Read picker'     = @{ main = @( ,@( E 'Picker allowed?' ) ) }
        'Picker allowed?' = @{ main = @( @( E 'Send picker' ), @( E 'Picker refused' ) ) }
        'Send picker'     = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.finance.tool_send_account_emoji_picker' $nodes $conns @{ Category = 'accounts' }
}
