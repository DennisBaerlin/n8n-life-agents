#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_plan_rollout_next (Geführte Abfolge) --------
# Die eine Stelle, die nach dem Veroeffentlichen den naechsten Schritt sendet: Laufende jeder Orchestrator-Antwort und taeglicher Nachzuegler.
# Eingang: chat_id, footer_key, skip. Jeder Knoten laeuft mit onError continue: nichts hier darf eine Antwort an den Nutzer beschaedigen.
function Build-CoreSubPlanRolloutNext {
    $start = [ordered]@{
        parameters  = [ordered]@{ workflowInputs = [ordered]@{ values = @(
            [ordered]@{ name = 'chat_id' }, [ordered]@{ name = 'footer_key' }, [ordered]@{ name = 'skip' } ) } }
        type = 'n8n-nodes-base.executeWorkflowTrigger'; typeVersion = 1.1; position = @(-1100, 0); id = (New-Id); name = 'Start'
    }
    $skip = Build-If 'Run?' @(-880, 0) "={{ String(`$json.skip) !== 'true' }}" 'true' 'equals' 'boolean'
    $end = Build-NoOp 'Skipped' @(-660, 200)
    $claim = Build-Pg 'Claim' @(-660, 0) '=SELECT core.fn_plan_rollout_claim($1::jsonb)::text AS r;' `
        ([ordered]@{ chat_id = "String(`$('Start').first().json.chat_id || '')" }) -ContinueOnError

    $splitJs = @"
let r = {};
try { r = JSON.parse(`$input.first().json.r || '{}'); } catch (e) { r = {}; }
const list = Array.isArray(r.messages) ? r.messages : [];
const footer = String(`$('Start').first().json.footer_key || '');
return list.filter(m => Array.isArray(m.buttons) && m.buttons.length > 0).map(m => ({ json: Object.assign({}, m, {
  chat_id: String(m.chat_id), footer_key: footer,
  keys: [...new Set([...(m.msg || []).map(x => x.value), ...m.buttons.map(b => b.text_key), ...(footer ? [footer] : [])])]
}) }));
"@
    $split = [ordered]@{ parameters = [ordered]@{ jsCode = $splitJs }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-440, 0); id = (New-Id); name = 'Split messages'; onError = 'continueRegularOutput' }

    $keysExpr = Get-UiKeysSql $script:UiRenderKeys
    $load = Build-Pg 'Load texts' @(-220, 0) `
        ("=SELECT core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', ((`$1::jsonb)->'ui_keys') || to_jsonb($keysExpr)))::text AS ui;") `
        ([ordered]@{ chat_id = '$json.chat_id'; ui_keys = '$json.keys' }) -ContinueOnError

    $buildJs = (Get-UiRenderLibJs) + @'

const m = $('Split messages').item.json;
const U = uiRender(JSON.parse($json.ui || '{}'));
let text = U.msg(m.msg || []);
if (m.footer_key) text += '\n\n' + U.t(m.footer_key);
const buttons = (m.buttons || []).map(b => ({ text: U.t(b.text_key), data: String(b.data) }));
return { json: { chat_id: m.chat_id, text, buttons, latches: (m.latches && m.latches.length) ? m.latches : (m.latch ? [m.latch] : []),
  memory_agent: String(m.memory_agent || ''), msg: m.msg || [] } };
'@
    $build = [ordered]@{ parameters = [ordered]@{ mode = 'runOnceForEachItem'; jsCode = $buildJs }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(0, 0); id = (New-Id); name = 'Build message'; onError = 'continueRegularOutput' }

    $two = Build-If 'Two buttons?' @(220, 0) '={{ ($json.buttons || []).length >= 2 }}' 'true' 'equals' 'boolean'
    $chat = "={{ String(`$('Build message').item.json.chat_id) }}"
    $text = "={{ `$('Build message').item.json.text }}"
    $sendOne = New-TelegramInlineKeyboardSendNode 'Send one' @(440, 120) $text @(
        @{ Text = "={{ `$('Build message').item.json.buttons[0].text }}"; Data = "={{ `$('Build message').item.json.buttons[0].data }}" } ) -ChatIdExpr $chat
    $sendTwo = New-TelegramInlineKeyboardSendNode 'Send two' @(440, -120) $text @(
        @{ Text = "={{ `$('Build message').item.json.buttons[0].text }}"; Data = "={{ `$('Build message').item.json.buttons[0].data }}" },
        @{ Text = "={{ `$('Build message').item.json.buttons[1].text }}"; Data = "={{ `$('Build message').item.json.buttons[1].data }}" } ) -ChatIdExpr $chat
    foreach ($n in @($sendOne, $sendTwo)) { $n['onError'] = 'continueRegularOutput' }

    $sent = Build-If 'Sent?' @(660, 0) '={{ !$json.error }}' 'true' 'equals' 'boolean'
    $latchParam = [ordered]@{ latches = "`$('Build message').item.json.latches" }
    $commit = Build-Pg 'Commit latch' @(880, -120) "=SELECT count(core.fn_notify_commit(x->>'source', x->>'key')) AS n FROM jsonb_array_elements((`$1::jsonb)->'latches') x;" $latchParam -ContinueOnError
    $reset = Build-Pg 'Reset latch' @(880, 120) "=SELECT count(core.fn_notify_resolve(x->>'source', x->>'key')) AS n FROM jsonb_array_elements((`$1::jsonb)->'latches') x;" $latchParam -ContinueOnError
    $note = Build-Pg 'Note turn' @(1100, -120) `
        "=SELECT agent.fn_note_proactive_turn(`$1::jsonb) AS a, agent.fn_note_proactive_turn((`$1::jsonb) || '{`"agent`":`"orchestrator`"}'::jsonb) AS b WHERE ((`$1::jsonb)->>'agent') <> '';" `
        ([ordered]@{ chat_id = "`$('Build message').item.json.chat_id"; agent = "`$('Build message').item.json.memory_agent"; msg = "`$('Build message').item.json.msg" }) -ContinueOnError

    $sticky = Build-Sticky 'Überblick' @(-1140, -420) 'Geführte Abfolge: genau ein nächster Schritt' `
        'Gerufen am Ende jedes Orchestrator-Laufs (Run plan rollout) und täglich vom Nachzügler (agent.advisor.cron_plan_rollout). Skip true: nichts. Claim = core.fn_plan_rollout_claim: Schalter, offene Karte, Entwurf der letzten 2 Stunden, dann core.fn_plan_rollout_next je Domain; ein zweiter gleichzeitiger Lauf bekommt nichts. Texte in der Sprache des Empfängers, Fußzeile nur im Nachzügler. n8n legt die Knopfzahl je Node fest, darum zwei Sende-Knoten (Paket-Schritte schicken höchstens zwei). Nach dem Senden schreibt Commit latch den Merker fest; scheitert das Senden, setzt Reset latch zurück; stirbt der Lauf dazwischen, läuft die Frist von 30 Minuten aus und der Schritt kommt wieder. Note turn trägt eine einladende Nachricht als Katalog-Schlüssel ins Gedächtnis von Agent und Router, nie als freier Text. Alle Knoten mit onError continue: Ein Fehler hier darf nie die Antwort an den Nutzer stören.' 340 460

    $nodes = @($start, $skip, $end, $claim, $split, $load, $build, $two, $sendOne, $sendTwo, $sent, $commit, $reset, $note, $sticky)
    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'Run?' ) ) }
        'Run?'           = @{ main = @( @( E 'Claim' ), @( E 'Skipped' ) ) }
        'Claim'          = @{ main = @( ,@( E 'Split messages' ) ) }
        'Split messages' = @{ main = @( ,@( E 'Load texts' ) ) }
        'Load texts'     = @{ main = @( ,@( E 'Build message' ) ) }
        'Build message'  = @{ main = @( ,@( E 'Two buttons?' ) ) }
        'Two buttons?'   = @{ main = @( @( E 'Send two' ), @( E 'Send one' ) ) }
        'Send one'       = @{ main = @( ,@( E 'Sent?' ) ) }
        'Send two'       = @{ main = @( ,@( E 'Sent?' ) ) }
        'Sent?'          = @{ main = @( @( E 'Commit latch' ), @( E 'Reset latch' ) ) }
        'Commit latch'   = @{ main = @( ,@( E 'Note turn' ) ) }
    }
    return Build-Workflow 'core.sub_plan_rollout_next' $nodes $conns
}