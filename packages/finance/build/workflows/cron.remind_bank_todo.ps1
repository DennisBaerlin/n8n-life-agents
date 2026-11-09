#Requires -Version 5.1
# Definition agent.finance.cron_remind_bank_todo -> Build-CronRemindBankTodo. Dot-gesourct von build.ps1.
# Deterministisch, kein LLM. Wer was bekommt und das Merken entscheidet allein finance.fn_bank_todo_claim. Zwei Send-Knoten,
# weil die callback_data des Abschalten-Knopfs statisch sein muss (cron_toggle_lint).
$script:BankTodoTextKeys = @(
    'finance.bank_todo.intro', 'finance.bank_todo.intro_generic', 'finance.bank_todo.nudge', 'finance.bank_todo.nudge_generic',
    'finance.bank_todo.howto', 'finance.bank_todo.btn_done', 'finance.bank_todo.btn_done_generic', 'core.reminders.btn_off')

function Get-BankTodoMessageJs {
    @'
function bankTodoMessage(U, g, isOwner) {
  const bank = g.bank || '';
  const head = g.nudge ? (bank ? 'finance.bank_todo.nudge' : 'finance.bank_todo.nudge_generic')
                       : (bank ? 'finance.bank_todo.intro' : 'finance.bank_todo.intro_generic');
  const holder = (isOwner && g.holder_name) ? ' (' + g.holder_name + ')' : '';
  const L = [U.fill(U.t(head), { bank, holder }), ''];
  (Array.isArray(g.items) ? g.items : []).forEach((it, i) => L.push((i + 1) + '. ' + U.msg(it.line)));
  L.push('', U.t('finance.bank_todo.howto'));
  return { message: L.join('\n'), btn_done: U.fill(U.t(bank ? 'finance.bank_todo.btn_done' : 'finance.bank_todo.btn_done_generic'), { bank }),
           data: 'btodo:' + g.first_id + ':' + g.max_id, btn_off: U.t('core.reminders.btn_off') };
}
'@
}

function Build-CronRemindBankTodo {
    # Der Claim schreibt Merker und first_sent_at -> finance_rw.
    $CRED_POSTGRES = $CRED_FINANCE_RW

    $trig = Build-ScheduleTrigger @(-900, 0) -ScheduleKey 'remind_bank_todo'

    $gate = Build-Pg 'Cron enabled?' @(-720, 0) `
        ("SELECT core.fn_package_active('finance') AND (COALESCE(core.fn_config_get('finance','cron_enable','remind_bank_todo') = 'true', false) " +
         "OR COALESCE(core.fn_config_get('finance','cron_enable','remind_bank_todo_person') = 'true', false)) AS enabled")
    $gateIf = Build-If 'Cron on?' @(-540, 0) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'
    $gateOff = Build-NoOp 'Disabled' @(-540, 200)

    $claim = Build-Pg 'Claim due' @(-360, 0) `
        "WITH c AS MATERIALIZED (SELECT finance.fn_bank_todo_claim() AS r) SELECT c.r::text AS r FROM c;"

    $splitJs = @'
let list = [];
try { list = JSON.parse($input.first().json.r || '[]'); } catch (e) { list = []; }
const out = [];
for (const m of (Array.isArray(list) ? list : [])) {
  for (const g of (Array.isArray(m.groups) ? m.groups : [])) { out.push({ json: { recipient: m.recipient, chat_id: m.chat_id, group: g } }); }
}
return out;
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-180, 0)
        id = (New-Id); name = 'Split messages'
    }

    $keys = Get-UiKeysSql ($script:BankTodoTextKeys + $script:UiRenderKeys)
    # chat_id leer (Owner-Nachricht) = Owner-Sprache; line-Keys kommen ueber doc mit.
    $texts = Build-Pg 'Load texts' @(0, 0) `
        ("=SELECT core.fn_ui_texts_for(jsonb_strip_nulls(jsonb_build_object('chat_id', NULLIF((`$1::jsonb)->>'chat_id', ''), " +
         "'keys', to_jsonb($keys), 'doc', (`$1::jsonb)->'msg'->'group'))) AS ui, (`$1::jsonb)->'msg' AS msg;") `
        ([ordered]@{
            chat_id = "((`$json.chat_id === null || `$json.chat_id === undefined) ? '' : String(`$json.chat_id))"
            msg     = '$json'
        })

    $buildJs = (Get-UiRenderLibJs) + (Get-BankTodoMessageJs) + @'
return $input.all().map(({ json: row }) => {
  const U = uiRender(row.ui || {});
  const msg = row.msg || {};
  const isOwner = msg.recipient === 'owner';
  return { json: Object.assign({ is_owner: isOwner, chat_id: msg.chat_id }, bankTodoMessage(U, msg.group || {}, isOwner)) };
});
'@
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(200, 0)
        id = (New-Id); name = 'Build message'
    }

    $ifOwner = Build-If 'Owner message?' @(400, 0) "={{ `$json.is_owner }}" 'true' 'equals' 'boolean'
    $sendOwner = New-TelegramInlineKeyboardSendNode 'Send owner' @(620, -120) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_done }}'; Data = '={{ $json.data }}' },
           @{ Text = '={{ $json.btn_off }}'; Data = 'cron_off:remind_bank_todo' } )
    $sendOwner['onError'] = 'continueRegularOutput'
    $sendPerson = New-TelegramInlineKeyboardSendNode 'Send person' @(620, 120) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_done }}'; Data = '={{ $json.data }}' },
           @{ Text = '={{ $json.btn_off }}'; Data = 'rem:off:remind_bank_todo_person' } ) `
        -ChatIdExpr '={{ String($json.chat_id) }}'
    $sendPerson['onError'] = 'continueRegularOutput'

    $stickyOverview = Build-Sticky 'Überblick' @(-920, -420) -Header 'Ablauf' `
        'Bank-Zettel: was der Nutzer bei der Bank einstellen muss (täglich, kein LLM)' `
        'Täglich (schedule.remind_bank_todo, im Erinnerungs-Fenster). Eine Aktion im Bot wird nicht automatisch bei der Bank wirksam: Dauerauftrag und Sparplan richtet der Nutzer selbst ein. finance.fn_bank_todo_claim liefert je Empfänger die fälligen Punkte, je Bank eine Nachricht: Neues ab 20 Stunden, Nachfassen an Tag 7 und 21 (config finance.bank_todo_nudge_days). Sichtbar bleibt nur, was die Kette noch verlangt; eine gebuchte Zahlung beendet den Punkt von selbst.' 320 520

    $stickyGate = Build-Sticky 'Gate' @(-560, -420) `
        'Paket aktiv UND mindestens ein Schalter an' `
        'Läuft, solange cron_enable.remind_bank_todo (Owner) oder cron_enable.remind_bank_todo_person (Mitglieder) an ist; beide aus -> No-op. Wer konkret etwas bekommt, entscheidet der Claim mit core.fn_reminder_allowed; wer heute nicht darf, bekommt den Merker nicht und verliert nichts.' 300 320

    $stickyRecipients = Build-Sticky 'Empfänger und Knöpfe' @(-220, -420) `
        'Owner alles, Mitglied die eigenen' `
        'Owner: alle Punkte, Inhaber in Klammern, Knopf cron_off:remind_bank_todo (Default-Chat). Erwachsenes, gekoppeltes Mitglied: die eigenen, Knopf rem:off:remind_bank_todo_person. Kinder nie. Der Knopf btodo:<erste-id>:<max-id> schließt sichtbare Punkte derselben Bank und desselben Inhabers (finance.fn_handle_bank_todo_cb).' 300 380

    $nodes = @($trig, $gate, $gateIf, $gateOff, $claim, $split, $texts, $build, $ifOwner, $sendOwner, $sendPerson, $stickyOverview, $stickyGate, $stickyRecipients)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @( @( E 'Claim due' ), @( E 'Disabled' ) ) }
        'Claim due'                   = @{ main = @( ,@( E 'Split messages' ) ) }
        'Split messages'              = @{ main = @( ,@( E 'Load texts' ) ) }
        'Load texts'                  = @{ main = @( ,@( E 'Build message' ) ) }
        'Build message'               = @{ main = @( ,@( E 'Owner message?' ) ) }
        'Owner message?'              = @{ main = @( @( E 'Send owner' ), @( E 'Send person' ) ) }
    }
    return (Build-Workflow 'agent.finance.cron_remind_bank_todo' $nodes $conns)
}
