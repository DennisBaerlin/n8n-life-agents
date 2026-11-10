#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
# agent.finance.tool_send_recurring_suggestions: schickt je offenem, noch nicht gesendetem Dauerauftrags-Vorschlag des Chats
# eine Nachricht mit [Uebernehmen] [Nicht uebernehmen] (Analog tool_send_bank_todos). Schreibt keine Domaenen-Daten, kein Gate:
# angelegt wird erst per Knopf (finance.fn_handle_recurring_suggestion_cb). Haupt-Credential wie das Analog (die Queue loest den
# Empfaenger ueber agent.fn_resolve_sender auf).
function Build-SendRecurringSuggestions {
    $trig = Build-Trigger @()

    $read = Build-Pg 'Read queue' @(220, 0) `
        "=WITH q AS MATERIALIZED (SELECT finance.fn_get_recurring_suggestion_queue(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id')) AS r) SELECT q.r::text AS r FROM q;" `
        ([ordered]@{ chat_id = "String(`$('Start').item.json.chat_id || '')" })

    $splitJs = @'
let q = {};
try { q = JSON.parse($input.first().json.r || '{}'); } catch (e) { q = {}; }
const items = Array.isArray(q.items) ? q.items : [];
if (items.length === 0) { return [{ json: { nothing: true } }]; }
return items.map((i) => ({ json: i }));
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(440, 0)
        id = (New-Id); name = 'Split messages'
    }
    $ifNothing = Build-If 'Nothing to send?' @(660, 0) "={{ `$json.nothing === true }}" 'true' 'equals' 'boolean'
    $send = New-TelegramInlineKeyboardSendNode 'Send suggestion' @(880, 120) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_accept }}'; Data = '={{ $json.data_ok }}' }, @{ Text = '={{ $json.btn_decline }}'; Data = '={{ $json.data_no }}' } ) `
        -ChatIdExpr "={{ String(`$('Start').item.json.chat_id || '') }}"
    $send['onError'] = 'continueRegularOutput'

    # Sende-Ergebnisse ueber pairedItem den Vorschlaegen zuordnen; ein Fehler (z. B. 429) bleibt ungestempelt und geht beim
    # naechsten Aufruf erneut. Ein Item -> genau ein Record- und ein Return-Lauf.
    $collectJs = @'
let q = {};
try { q = JSON.parse($('Read queue').first().json.r || '{}'); } catch (e) { q = {}; }
const msgs = $('Split messages').all();
const sent = [];
if ($('Send suggestion').isExecuted) {
  for (const it of $('Send suggestion').all()) {
    if (it.json && it.json.error) continue;
    const p = it.pairedItem;
    const idx = Array.isArray(p) ? (p[0] || {}).item : (p || {}).item;
    const m = msgs[typeof idx === 'number' ? idx : -1];
    if (m && m.json && m.json.id) sent.push({ id: m.json.id, version: m.json.version });
  }
}
return [{ json: { sent, rejected: Array.isArray(q.rejected) ? q.rejected : [], more: q.more || 0,
  open_count: q.open_count || 0, tried: msgs.filter((m) => !m.json.nothing).length } }];
'@
    $collect = [ordered]@{
        parameters = [ordered]@{ jsCode = $collectJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(1100, 0)
        id = (New-Id); name = 'Collect results'
    }
    $record = Build-Pg 'Record sent' @(1320, 0) "=SELECT finance.fn_record_recurring_suggestions_sent(`$1::jsonb) AS r;" ([ordered]@{
        chat_id  = "String(`$('Start').first().json.chat_id || '')"
        sent     = "`$('Collect results').first().json.sent"
        rejected = "`$('Collect results').first().json.rejected"
    })
    $C = "`$('Collect results').first().json"
    $ret = Build-Return @(1540, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('sent', "={{ $C.sent.length }}", 'number')
        ,@('failed', "={{ $C.tried - $C.sent.length }}", 'number')
        ,@('open_count', "={{ $C.open_count - $C.rejected.length }}", 'number')
        ,@('more', "={{ $C.more }}", 'number')
        ,@('note', "={{ $C.sent.length > 0 ? 'The suggestions were already sent as separate messages with the buttons add / do not add. Do not repeat or list them; reply with at most one short sentence' + ($C.more > 0 ? ' and say that ' + $C.more + ' more follow when the user asks for the open suggestions.' : '.') + ($C.tried > $C.sent.length ? ' Some could not be sent right now; they go out on the next call.' : '') : ($C.open_count - $C.rejected.length > 0 ? 'All open suggestions are already above in the chat with their buttons. Say so in one short sentence.' : 'There are no open suggestions. Say so in one short sentence.') }}", 'string')
    )

    $sticky = Build-Sticky 'Doc Vorschlags-Nachrichten' @(120, -380) `
        'Dauerauftrags-Vorschläge als Knopf-Nachrichten (schreibt keine Domänen-Daten)' `
        'Read queue = finance.fn_get_recurring_suggestion_queue: offene, noch nicht gesendete Vorschläge des Chats, sichere zuerst, dann nach Betrag, höchstens 10 je Aufruf (more = Rest); Kinder bekommen nichts. Je Zeile prüft ein Probelauf der Anlege-fn (core.fn_dry_run); lehnt er ab, geht die Zeile nicht raus (rejected -> declined). Der Text kommt fertig aus der DB in der Sprache des Empfängers, die Knöpfe tragen nur rsug:ok|no:<id>:<version>. Collect results ordnet die Sende-Ergebnisse per pairedItem zu; Record sent stempelt einmal (sent_version), ein Sende-Fehler bleibt offen und geht beim nächsten Aufruf. Angelegt wird erst per Knopf (finance.fn_handle_recurring_suggestion_cb): Werte aus der DB, nie vom Modell.' 300 560

    $nodes = @($trig, $read, $split, $ifNothing, $send, $collect, $record, $ret, $sticky)
    $conns = [ordered]@{
        'Start'            = @{ main = @( ,@( E 'Read queue' ) ) }
        'Read queue'       = @{ main = @( ,@( E 'Split messages' ) ) }
        'Split messages'   = @{ main = @( ,@( E 'Nothing to send?' ) ) }
        'Nothing to send?' = @{ main = @( @( E 'Collect results' ), @( E 'Send suggestion' ) ) }
        'Send suggestion'  = @{ main = @( ,@( E 'Collect results' ) ) }
        'Collect results'  = @{ main = @( ,@( E 'Record sent' ) ) }
        'Record sent'      = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.finance.tool_send_recurring_suggestions' $nodes $conns @{ Category = 'recurring' }
}
