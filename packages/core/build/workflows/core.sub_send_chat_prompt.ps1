#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_send_chat_prompt (offene Frage: Karte senden, getippte Karte aendern) ----------------------------------
# Die eine Stelle, die Karten der offenen Frage (agent.chat_prompts) an Telegram gibt. Gerufen
# vom Orchestrator am Ende jedes Laufs (send_next, replied, run_started_at, agent = wer den Lauf beantwortet hat; bei Antwort-Knoepfen choice_json) und im
# Knopf-Arm q: (edit_* = getippte Karte aendern, note_text = Rueckfrage mit Eingabefeld, send_next = naechste Zeile des
# Stapels ohne Modell-Lauf). Ausgang: { sent } (eine Karte oder Antwort mit Knoepfen ist rausgegangen).
function Build-CoreSubSendChatPrompt {
    $trig = Build-Trigger @('replied', 'run_started_at', 'send_next', 'edit_message_id', 'edit_json', 'note_text', 'choice_json', 'agent') @(-1100, 0)

    # core.fn_next_chat_prompt aendert den Zustand (queued -> open, Sweep) -> Schreib-Cred. Die Karte kommt aus core.fn_render_prompt
    # schon in der Sprache des Chats. Fehlt die fn oder scheitert sie -> onError continue: nichts gesendet, die Antwort davor kam.
    $read = Build-Pg 'Read prompt' @(-880, 0) `
        ("=SELECT (CASE WHEN (`$1::jsonb)->>'send_next' = 'true' THEN core.fn_next_chat_prompt(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', " +
         "'replied', (`$1::jsonb)->>'replied' = 'true', 'run_started_at', NULLIF((`$1::jsonb)->>'run_started_at', ''), 'agent', NULLIF((`$1::jsonb)->>'agent', ''))) ELSE jsonb_build_object('send', false) END)::text AS r;") `
        ([ordered]@{
            chat_id        = "String(`$('Start').first().json.chat_id || '')"
            replied        = "String(`$('Start').first().json.replied || '')"
            run_started_at = "String(`$('Start').first().json.run_started_at || '')"
            send_next      = "String(`$('Start').first().json.send_next || '')"
            agent          = "String(`$('Start').first().json.agent || '')"
        }) -ContinueOnError

    $buildJs = (Get-CardRenderJs) + @'

const S = $('Start').first().json;
const parse = (s, d) => { try { return s ? JSON.parse(s) : d; } catch (e) { return d; } };
const r = parse($json.r, {}) || {};
const C = cardRender();
// Antwort-Knoepfe (core.fn_create_choice_prompt) haengen an der Antwort des Beraters selbst; sonst die faellige Karte.
const ch = parse(S.choice_json, null);
let send = null;
if (ch && ch.prompt_id && String(ch.text || '').trim()) send = { id: ch.prompt_id, html: C.esc(String(ch.text).trim()), rows: ch.buttons };
else if (r.send === true && r.prompt_id && r.card) send = { id: r.prompt_id, html: C.html(r.card), rows: r.buttons };
// Die n8n-Tastatur hat feste Plaetze: erlaubt sind 1-3 Knoepfe in einer Reihe oder 1-3 Reihen mit je einem Knopf;
// jede andere Form wird zu einem Knopf je Reihe (hoechstens drei).
let rows = (send && Array.isArray(send.rows)) ? send.rows.filter((x) => Array.isArray(x) && x.length) : [];
let shape = rows.map((x) => x.length).join('+');
if (rows.length && !['1', '2', '3', '1+1', '1+1+1'].includes(shape)) { rows = rows.flat().slice(0, 3).map((b) => [b]); shape = rows.map((x) => x.length).join('+'); }
const buttons = rows.flat().map((b) => ({ text: String((b && b.text) || '?'), data: String((b && b.data) || '').slice(0, 64) }));
const editId = String(S.edit_message_id || '');
const ed = parse(S.edit_json, null);
const editHtml = (ed && editId) ? (C.fromEntities(ed.text, ed.entities) + (String(ed.append || '').trim() ? '\n\n' + C.esc(String(ed.append).trim()) : '')) : '';
const note = String(S.note_text || '').trim();
const stale = (Array.isArray(r.stale) ? r.stale : []).filter((x) => x && x.message_id && x.card)
  .map((x) => ({ message_id: String(x.message_id), html: C.html(x.card) }));
return { json: {
  chat_id: String(S.chat_id || ''), edit_message_id: editId, edit_html: editHtml, note_html: note ? C.esc(note) : '',
  send: !!send, id: send ? send.id : null, html: send ? send.html : '', shape: send ? shape : '', buttons, stale
} };
'@
    $build = [ordered]@{ parameters = [ordered]@{ mode = 'runOnceForEachItem'; jsCode = $buildJs }; type = 'n8n-nodes-base.code'; typeVersion = 2
                         position = @(-660, 0); id = (New-Id); name = 'Build prompt'; onError = 'continueRegularOutput' }

    $B = "`$('Build prompt').first().json"
    $chat = "={{ String($B.chat_id) }}"
    $ifEdit = Build-If 'Edit tapped?' @(-440, 0) "={{ !!$B.edit_html }}" 'true' 'equals' 'boolean'
    $edit = New-TelegramEditMessageNode 'Edit tapped card' @(-220, -120) -ChatIdExpr $chat -MessageIdExpr "={{ $B.edit_message_id }}" `
        -TextExpr "={{ $B.edit_html }}" -Html
    $ifNote = Build-If 'Note?' @(0, 0) "={{ !!$B.note_html }}" 'true' 'equals' 'boolean'
    $note = New-TelegramSendNode 'Send note' @(220, -120) "={{ $B.note_html }}" -ChatIdExpr $chat -NoEscape -ParseMode 'HTML' `
        -ForceReply -OnError 'continueRegularOutput'
    $ifSend = Build-If 'Send?' @(440, 0) "={{ $B.send === true }}" 'true' 'equals' 'boolean'
    $shapes = @('1', '2', '3', '1+1', '1+1+1')
    $count = Build-Switch 'Buttons' @(660, -120) @($shapes | ForEach-Object {
        @{ Left = "={{ $B.shape === '$_' }}"; Type = 'boolean'; Op = 'equals'; Right = 'true'; OutputKey = ('s' + ($_ -replace '\+', '_')) }
    })
    $text = "={{ $B.html }}"
    $btn = { param($i) @{ Text = "={{ $B.buttons[$i].text }}"; Data = "={{ $B.buttons[$i].data }}" } }
    $sends = @(
        (New-TelegramInlineKeyboardSendNode 'Send card 1' @(880, -520) $text @( (& $btn 0) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramInlineKeyboardSendNode 'Send card 2' @(880, -380) $text @( (& $btn 0), (& $btn 1) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramInlineKeyboardSendNode 'Send card 3' @(880, -240) $text @( (& $btn 0), (& $btn 1), (& $btn 2) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramInlineKeyboardSendNode 'Send card 1+1' @(880, -100) $text -Rows @( @( (& $btn 0) ), @( (& $btn 1) ) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramInlineKeyboardSendNode 'Send card 1+1+1' @(880, 40) $text -Rows @( @( (& $btn 0) ), @( (& $btn 1) ), @( (& $btn 2) ) ) -ChatIdExpr $chat -NoEscape -ParseMode 'HTML'),
        (New-TelegramSendNode 'Send card plain' @(880, 180) $text -ChatIdExpr $chat -NoEscape -ParseMode 'HTML')
    )
    foreach ($n in $sends) { $n['onError'] = 'continueRegularOutput' }
    $record = Build-Pg 'Record message' @(1100, -120) '=SELECT core.fn_chat_prompt_sent($1::jsonb) AS r, NULLIF(($1::jsonb)->>''message_id'', '''') AS message_id;' `
        ([ordered]@{ prompt_id = "String($B.id)"; message_id = "String(((`$json.result) || {}).message_id || '')" }) -ContinueOnError

    # Alte Nachrichten, deren Knoepfe veraltet sind (die DB nennt sie mit ihrer Karte): ohne Knoepfe neu zeichnen. n8n kennt kein
    # editMessageReplyMarkup, Knoepfe entfernen geht nur mit Text.
    $ifStale = Build-If 'Stale?' @(1320, 0) "={{ ($B.stale || []).length > 0 }}" 'true' 'equals' 'boolean'
    $splitStale = [ordered]@{ parameters = [ordered]@{ jsCode = "return ($B.stale || []).map((x) => ({ json: x }));" }
                              type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(1540, -120); id = (New-Id); name = 'Split stale' }
    $clearStale = New-TelegramEditMessageNode 'Clear stale buttons' @(1760, -120) -ChatIdExpr $chat -MessageIdExpr '={{ $json.message_id }}' `
        -TextExpr '={{ $json.html }}' -Html
    # sent = Telegram hat die Nachricht angenommen (message_id da), nicht nur geplant: sonst sendet der Orchestrator den festen Hinweis.
    $result = Build-Set 'Result' @(1980, 0) @( ,@('sent', "={{ `$('Record message').isExecuted && !!((`$('Record message').first().json || {}).message_id) }}", 'boolean') )
    $result['executeOnce'] = $true

    $sticky = Build-Sticky 'Überblick' @(-1140, -500) -Header 'Ablauf' 'Offene Frage: Karte senden und getippte Karte ändern' `
        ('Die eine Stelle, die Karten der offenen Frage (agent.chat_prompts) sendet; der Orchestrator ruft sie am Ende jedes Laufs und im Knopf-Arm q:. ' +
         'Read prompt: core.fn_next_chat_prompt (nur bei send_next; agent = wer den Lauf beantwortet hat, ein pausierter Stapel kommt erst nach einem Lauf desselben Beraters; eine wartende Zeile wird offen und gesendet, eine offene nach einer Antwort dieses Laufs erneut, damit die offene Frage unten steht; eine Auswahl-Frage, deren Senden nie bestätigt wurde, ersetzt sie nach 10 Minuten, damit die Schlange weiterläuft). Die Karte (core.fn_render_prompt) kommt fertig übersetzt als Zeilen. ' +
         'Build prompt: der gemeinsame Renderer (Get-CardRenderJs) macht daraus Telegram-HTML und escapt jeden Wert. Hat der Berater Antwort-Knöpfe geschrieben (choice_json aus core.fn_create_choice_prompt), geht seine Antwort selbst mit den Knöpfen raus. ' +
         'Reihenfolge: getippte Karte ändern (Text samt Formatierung aus der Telegram-Nachricht, Zusatz wie „✓ Übernommen“, Knöpfe weg) -> Rückfrage „Was soll anders sein?“ mit Eingabefeld (ForceReply) -> neue Karte; die Knopf-Form (1 bis 3 in einer Reihe oder je einer pro Reihe) wählt den passenden Send-Knoten, weil die n8n-Tastatur feste Plätze hat -> Record message (core.fn_chat_prompt_sent merkt die Nachricht) -> Clear stale buttons: alte Nachrichten mit veralteten Knöpfen ohne Knöpfe neu zeichnen. ' +
         'Jeder Knoten onError continue: ein Fehler hier kostet nur die Karte, nie die Antwort davor. Result.sent sagt dem Orchestrator, ob etwas rausging (sonst sendet er bei leerer Berater-Antwort den festen Hinweis).') 420 620

    $nodes = @($trig, $read, $build, $ifEdit, $edit, $ifNote, $note, $ifSend, $count) + $sends + @($record, $ifStale, $splitStale, $clearStale, $result, $sticky)
    $conns = [ordered]@{
        'Start'            = @{ main = @( ,@( E 'Read prompt' ) ) }
        'Read prompt'      = @{ main = @( ,@( E 'Build prompt' ) ) }
        'Build prompt'     = @{ main = @( ,@( E 'Edit tapped?' ) ) }
        'Edit tapped?'     = @{ main = @( @( E 'Edit tapped card' ), @( E 'Note?' ) ) }
        'Edit tapped card' = @{ main = @( ,@( E 'Note?' ) ) }
        'Note?'            = @{ main = @( @( E 'Send note' ), @( E 'Send?' ) ) }
        'Send note'        = @{ main = @( ,@( E 'Send?' ) ) }
        'Send?'            = @{ main = @( @( E 'Buttons' ), @( E 'Stale?' ) ) }
        'Buttons'          = @{ main = @( @( E 'Send card 1' ), @( E 'Send card 2' ), @( E 'Send card 3' ), @( E 'Send card 1+1' ), @( E 'Send card 1+1+1' ), @( E 'Send card plain' ) ) }
        'Record message'   = @{ main = @( ,@( E 'Stale?' ) ) }
        'Stale?'           = @{ main = @( @( E 'Split stale' ), @( E 'Result' ) ) }
        'Split stale'      = @{ main = @( ,@( E 'Clear stale buttons' ) ) }
        'Clear stale buttons' = @{ main = @( ,@( E 'Result' ) ) }
    }
    foreach ($n in $sends) { $conns[$n.name] = @{ main = @( ,@( E 'Record message' ) ) } }
    return Build-Workflow 'core.sub_send_chat_prompt' $nodes $conns
}
