#Requires -Version 5.1
# Definition agent.finance.cron_remind_bank_end -> Build-CronRemindBankEnd. Dot-gesourct von build.ps1.
# Deterministisch, kein LLM. Wer erinnert wird und das Merken entscheidet allein finance.fn_bank_end_claim; der Workflow
# rendert und sendet nur. Zwei Send-Knoten, weil die callback_data des Knopfs statisch sein muss (cron_toggle_lint).
function Build-CronRemindBankEnd {
    # Der Claim schreibt Latches -> finance_rw.
    $CRED_POSTGRES = $CRED_FINANCE_RW

    $trig = Build-ScheduleTrigger @(-900, 0) -ScheduleKey 'remind_bank_end'

    $gate = Build-Pg 'Cron enabled?' @(-720, 0) `
        ("SELECT core.fn_package_active('finance') AND (COALESCE(core.fn_config_get('finance','cron_enable','remind_bank_end') = 'true', false) " +
         "OR COALESCE(core.fn_config_get('finance','cron_enable','remind_bank_end_person') = 'true', false)) AS enabled")
    $gateIf = Build-If 'Cron on?' @(-540, 0) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'
    $gateOff = Build-NoOp 'Disabled' @(-540, 200)

    $claim = Build-Pg 'Claim due' @(-360, 0) `
        "WITH c AS MATERIALIZED (SELECT finance.fn_bank_end_claim() AS r) SELECT c.r::text AS r FROM c;"

    $splitJs = @'
let list = [];
try { list = JSON.parse($input.first().json.r || '[]'); } catch (e) { list = []; }
return (Array.isArray(list) ? list : []).map(m => ({ json: m }));
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-180, 0)
        id = (New-Id); name = 'Split messages'
    }

    $keys = Get-UiKeysSql (@('finance.dialog.bank_end_intro', 'finance.dialog.bank_end_howto', 'finance.dialog.bank_end_goal',
        'finance.dialog.bank_end_line_standing_order', 'finance.dialog.bank_end_line_standing_order_generic',
        'finance.dialog.bank_end_line_standing_order_unsure', 'finance.dialog.bank_end_line_standing_order_unsure_generic',
        'finance.dialog.bank_end_line_savings_plan', 'finance.dialog.bank_end_line_savings_plan_generic',
        'core.reminders.btn_off') + $script:UiRenderKeys)
    # chat_id leer (Owner-Sammel-Nachricht) = Owner-Sprache. Die Nachricht reist in der Zeile mit, damit Build message
    # nicht ueber Item-Paarung an sie kommen muss.
    $texts = Build-Pg 'Load texts' @(0, 0) `
        ("=SELECT core.fn_ui_texts_for(jsonb_strip_nulls(jsonb_build_object('chat_id', NULLIF((`$1::jsonb)->>'chat_id', ''), " +
         "'keys', to_jsonb($keys)))) AS ui, (`$1::jsonb)->'msg' AS msg;") `
        ([ordered]@{
            chat_id = "((`$json.chat_id === null || `$json.chat_id === undefined) ? '' : String(`$json.chat_id))"
            msg     = '$json'
        })

    $buildJs = (Get-UiRenderLibJs) + @'
const LINE = {
  standing_order: { bank: 'finance.dialog.bank_end_line_standing_order', generic: 'finance.dialog.bank_end_line_standing_order_generic' },
  unsure: { bank: 'finance.dialog.bank_end_line_standing_order_unsure', generic: 'finance.dialog.bank_end_line_standing_order_unsure_generic' },
  savings_plan: { bank: 'finance.dialog.bank_end_line_savings_plan', generic: 'finance.dialog.bank_end_line_savings_plan_generic' },
};
return $input.all().map(({ json: row }) => {
  const U = uiRender(row.ui || {});
  const msg = row.msg || {};
  const isOwner = msg.recipient === 'owner';
  const lines = (Array.isArray(msg.items) ? msg.items : []).map((r) => {
    const group = r.kind === 'savings_plan' ? 'savings_plan' : (r.execution === 'unknown' ? 'unsure' : 'standing_order');
    const parts = [];
    if (isOwner && r.holder_name) parts.push(r.holder_name);
    if (r.goal) parts.push(U.fill(U.t('finance.dialog.bank_end_goal'), { goal: r.goal }));
    return U.fill(U.t(LINE[group][r.bank ? 'bank' : 'generic']), {
      name: r.name, extra: parts.length ? ' (' + parts.join(', ') + ')' : '', to: r.to_name, bank: r.bank,
      amount: { kind: 'money', value: r.amount, currency: r.currency }, date: { kind: 'date', value: r.last_due } });
  });
  return { json: { is_owner: isOwner, chat_id: msg.chat_id,
    message: U.t('finance.dialog.bank_end_intro') + '\n\n' + lines.join('\n') + '\n\n' + U.t('finance.dialog.bank_end_howto'),
    btn_off: U.t('core.reminders.btn_off') } };
});
'@
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(200, 0)
        id = (New-Id); name = 'Build message'
    }

    $ifOwner = Build-If 'Owner message?' @(400, 0) "={{ `$json.is_owner }}" 'true' 'equals' 'boolean'
    $sendOwner = New-TelegramInlineKeyboardSendNode 'Send owner' @(620, -120) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_off }}'; Data = 'cron_off:remind_bank_end' } )
    $sendOwner['onError'] = 'continueRegularOutput'
    $sendPerson = New-TelegramInlineKeyboardSendNode 'Send person' @(620, 120) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_off }}'; Data = 'rem:off:remind_bank_end_person' } ) `
        -ChatIdExpr '={{ String($json.chat_id) }}'
    $sendPerson['onError'] = 'continueRegularOutput'

    $stickyOverview = Build-Sticky 'Überblick' @(-920, -420) -Header 'Ablauf' `
        'Erinnerung: Auftrag bei der Bank beenden (täglich, kein LLM)' `
        'Täglich 10:35 (schedule.remind_bank_end, im Erinnerungs-Fenster). Der Bot notiert Daueraufträge und Sparpläne nur; ohne eingetragenes Ende bucht die Bank weiter. finance.fn_bank_end_claim liefert je Empfänger eine Nachricht: fällig 3 bis 60 Tage nach der letzten Ausführung, nur aktive Aufträge bei Bank oder Broker (nie Handüberweisung, Lastschrift, Kredit-Rate). Fällig beim ersten Lauf nach dem Update: alles, was in den letzten 60 Tagen endete. Split messages -> Load texts (Sprache des Empfängers) -> Build message -> Owner oder Person -> Send.' 340 620

    $stickyGate = Build-Sticky 'Gate' @(-560, -420) `
        'Paket aktiv UND mindestens ein Schalter an' `
        'Läuft, solange cron_enable.remind_bank_end (Owner) oder cron_enable.remind_bank_end_person (Mitglieder) an ist; beide aus -> No-op. Wer konkret eine Nachricht bekommt, entscheidet fn_bank_end_claim über core.fn_reminder_allowed je Empfänger: aus heißt für ihn weder Nachricht noch Merker. Ein UND hier würde die Mitglieder mit abschalten, wenn nur der Owner seine Sammel-Nachricht abstellt.' 300 460

    $stickyRecipients = Build-Sticky 'Empfänger und Merker' @(-220, -420) `
        'Owner sammelt, Mitglied bekommt seine eigenen' `
        'Owner: Sammel-Nachricht mit allen fälligen Aufträgen, Inhaber in Klammern, Knopf cron_off:remind_bank_end (Default-Chat, auch ohne Eintrag in der Personenliste). Erwachsenes, gekoppeltes Mitglied: eigene Nachricht in seiner Sprache, Knopf rem:off:remind_bank_end_person. Kinder nie, der Owner als Inhaber nur einmal. Merker je Auftrag, Termin und Empfänger, gesetzt VOR dem Senden: Ein Telegram-Fehler verliert diese eine Nachricht (lieber einmal zu wenig als täglich doppelt); Send onError=continue, damit die anderen trotzdem rausgehen. Beendet jemand im Bot mit Termin in der Vergangenheit, hat die Karte es dem Owner schon gesagt: sein Merker steht, der Inhaber bekommt seine Erinnerung trotzdem.' 340 700

    $stickyAfter = Build-Sticky 'Danach' @(380, -420) `
        'Im Bot ist nichts zu tun' `
        'Der Nutzer beendet den Auftrag bei der Bank; im Bot ändert sich nichts. Soll er weiterlaufen, sagt er dem Bot das neue Ende: Der neue letzte Termin ist ein neuer Merker, die Erinnerung kommt nach dem neuen Ende wieder.' 280 420

    $nodes = @($trig, $gate, $gateIf, $gateOff, $claim, $split, $texts, $build, $ifOwner, $sendOwner, $sendPerson,
        $stickyOverview, $stickyGate, $stickyRecipients, $stickyAfter)
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
    return (Build-Workflow 'agent.finance.cron_remind_bank_end' $nodes $conns)
}
