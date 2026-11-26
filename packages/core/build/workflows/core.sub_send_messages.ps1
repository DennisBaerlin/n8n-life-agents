#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_send_messages (fertige Nachrichten mit Knoepfen senden) ------------------------------------------------
# Sendet eine Liste {chat_id, text, buttons:[[{text,data}]]}, die eine DB-fn fertig gebaut hat (KI-Pause:
# core.fn_llm_incident_note, core.fn_llm_probe_result, Antwort von core.fn_handle_llm_cb). Gerufen vom Orchestrator und von
# core.sub_llm_probe. Eingang messages = JSON-Text (der Aufruf-Knoten wandelt Felder in Text). Ausgang je Nachricht das
# Telegram-Ergebnis; ein Sendefehler bricht nicht ab (onError continue), die uebrigen gehen trotzdem raus.
function Build-CoreSubSendMessages {
    $trig = Build-Trigger @('messages') @(-880, 0)

    # Tastaturen sind in n8n statisch: erlaubte Formen 0, 1, 2 (eine Reihe), 1+1 (zwei Reihen); jede andere Form wird zu einem
    # Knopf je Reihe (hoechstens zwei). Text als HTML-Plain (& < > escapt, parse_mode HTML wie die Relay-Kette).
    $splitJs = @'
let list = [];
try { list = JSON.parse(String($('Start').first().json.messages || '[]')); } catch (e) { list = []; }
if (!Array.isArray(list)) list = [];
const esc = (s) => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
return list.filter((m) => m && String(m.chat_id || '').match(/^-?[0-9]{1,18}$/) && String(m.text || '').trim()).map((m) => {
  let rows = Array.isArray(m.buttons) ? m.buttons.filter((r) => Array.isArray(r) && r.length) : [];
  let shape = rows.map((r) => r.length).join('+');
  if (rows.length && !['1', '2', '1+1'].includes(shape)) { rows = rows.flat().slice(0, 2).map((b) => [b]); shape = rows.map((r) => r.length).join('+'); }
  const buttons = rows.flat().map((b) => ({ text: String((b && b.text) || '?'), data: String((b && b.data) || '').slice(0, 64) }));
  return { json: { chat_id: String(m.chat_id), html: esc(String(m.text).trim()), shape: shape || '0', buttons } };
});
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-660, 0)
        id = (New-Id); name = 'Split messages'
    }
    $shape = Build-Switch 'Buttons' @(-440, 0) @(
        @{ Left = "={{ `$json.shape === '1' }}"; Type = 'boolean'; Op = 'equals'; Right = 'true'; OutputKey = 's1' }
        @{ Left = "={{ `$json.shape === '2' }}"; Type = 'boolean'; Op = 'equals'; Right = 'true'; OutputKey = 's2' }
        @{ Left = "={{ `$json.shape === '1+1' }}"; Type = 'boolean'; Op = 'equals'; Right = 'true'; OutputKey = 's1_1' }
    )
    $chat = "={{ String(`$json.chat_id) }}"
    $text = "={{ `$json.html }}"
    $btn = { param($i) @{ Text = "={{ `$json.buttons[$i].text }}"; Data = "={{ `$json.buttons[$i].data }}" } }
    $sends = @(
        (New-TelegramInlineKeyboardSendNode 'Send 1' @(-220, -240) $text @( (& $btn 0) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramInlineKeyboardSendNode 'Send 2' @(-220, -80) $text @( (& $btn 0), (& $btn 1) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramInlineKeyboardSendNode 'Send 1+1' @(-220, 80) $text -Rows @( @( (& $btn 0) ), @( (& $btn 1) ) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramSendNode 'Send plain' @(-220, 240) $text -ChatIdExpr $chat -NoEscape -ParseMode 'HTML')
    )
    foreach ($n in $sends) { $n['onError'] = 'continueRegularOutput' }

    $sticky = Build-Sticky 'Überblick' @(-900, -520) -Header 'Ablauf' `
        'core.sub_send_messages — fertige Nachrichten mit Knöpfen senden (kein LLM)' `
        'Start (messages = JSON-Text einer Liste {chat_id, text, buttons}) -> Split messages (je Nachricht ein Item; ungültige chat_id oder leerer Text fällt weg; Text als HTML-Plain escapt) -> Buttons (Form der Tastatur: 1 Knopf, 2 nebeneinander, 2 untereinander, sonst ohne) -> Send 1 / Send 2 / Send 1+1 / Send plain. n8n-Tastaturen haben feste Plätze, darum eine Sende-Node je Form; eine andere Form wird zu höchstens zwei Knöpfen untereinander. Texte und Knöpfe baut die DB fertig in der Sprache des Empfängers (KI-Pause: core.fn_llm_incident_note, core.fn_llm_probe_result, core.fn_handle_llm_cb). Sendefehler: onError continue, die übrigen Nachrichten gehen trotzdem raus.' 420 420

    $nodes = @($trig, $split, $shape) + $sends + @($sticky)
    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'Split messages' ) ) }
        'Split messages' = @{ main = @( ,@( E 'Buttons' ) ) }
        'Buttons'        = @{ main = @( @( E 'Send 1' ), @( E 'Send 2' ), @( E 'Send 1+1' ), @( E 'Send plain' ) ) }
    }
    return Build-Workflow 'core.sub_send_messages' $nodes $conns
}
