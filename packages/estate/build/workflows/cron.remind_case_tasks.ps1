#Requires -Version 5.1
# Definition agent.estate.cron_remind_case_tasks -> Build-EstateCronRemindCaseTasks. Dot-gesourct von build.ps1.
# WS-3: taeglicher Fristen-Reminder des Ereignisfalls. No-op ohne offenen Fall; faellige/ueberfaellige
# offene Tasks (3-Tage-Vorlauf) als EINE aggregierte Karte an den Owner, mit est:-Buttons fuer die
# oberste (dringlichste) Aufgabe. Latch je Task (core.fn_should_notify, Cooldown 3 Tage) -> kein
# taegliches Spam derselben Task; ueberfaellige Tasks werden periodisch (nach dem Cooldown) neu erinnert.
# KEINE monitor_triggers-Zeilen (Massen-Instanziierung; Cron-vs-Trigger-Gesetz). Default AN (always-on):
# cron_enable.remind_case_tasks=true, KEIN Chat-Toggle (nur Konsole; cron_toggle_lint-always-on-Muster).
# Cred = estate_rw (estate-Read + fn_should_notify/fn_package_active/fn_config_get/fn_household_persons-Grants).
function Build-EstateCronRemindCaseTasks {
    $CRED_POSTGRES = $CRED_ESTATE_RW

    $trig = Build-ScheduleTrigger @(-1100, 0) -ScheduleKey 'remind_case_tasks'

    # F9-Gate (WS-1/Phase 4a): nur wenn Paket aktiv UND cron_enable -> sonst No-op (fail-closed).
    $gate = Build-Pg 'Cron enabled?' @(-880, 0) `
        "=SELECT core.fn_package_active('estate') AND COALESCE(core.fn_config_get('estate','cron_enable','remind_case_tasks') = 'true', false) AS enabled" `
        $null
    $ifEnabled = Build-If 'Cron on?' @(-660, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-440, 200)

    # Faellige/ueberfaellige offene Tasks offener Faelle einsammeln + je Task latchen (Cooldown 3 Tage).
    # MATERIALIZED -> fn_should_notify laeuft EXAKT 1x je faelliger Task (Latch-Seiteneffekt deterministisch).
    # Die Texte (Owner-Sprache, core.fn_ui_texts_for) kommen in DERSELBEN Anweisung wie der Latch: ein Ladefehler
    # rollt den Latch mit zurueck (nie "gemeldet", ohne verschickt zu sein). Datum ROH (ISO) -> Anzeige per Intl.
    $keys = Get-UiKeysSql (@('estate.dialog.case_tasks_title', 'estate.dialog.case_task_overdue', 'estate.dialog.case_task_due',
        'estate.dialog.case_tasks_more', 'estate.dialog.btn_done', 'estate.dialog.btn_not_applicable',
        'estate.dialog.subject_fallback') + $script:UiRenderKeys)
    $collect = Build-Pg 'Collect due tasks' @(-440, 0) `
        @"
=WITH due AS (
  SELECT ct.id, ct.title, ct.due_date, ct.hardness, hp.full_name AS subject
  FROM estate.case_tasks ct
  JOIN estate.cases c ON c.id = ct.case_id AND c.status = 'open'
  LEFT JOIN LATERAL (SELECT full_name FROM core.fn_household_persons() WHERE person_id = c.subject_person_id) hp ON true
  WHERE ct.status = 'open' AND ct.due_date IS NOT NULL AND ct.due_date <= CURRENT_DATE + 3
),
latched AS MATERIALIZED (
  SELECT d.*, core.fn_should_notify('estate', 'case_task:' || d.id, INTERVAL '3 days') AS notify FROM due d
)
SELECT COALESCE(jsonb_agg(jsonb_build_object(
         'id', l.id, 'title', l.title, 'subject', l.subject,
         'due_date', l.due_date, 'overdue', l.due_date < CURRENT_DATE, 'hardness', l.hardness)
         ORDER BY (l.hardness = 'critical') DESC, l.due_date) FILTER (WHERE l.notify), '[]'::jsonb) AS tasks,
       core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys))) AS ui
FROM latched l;
"@ `
        $null

    # Texte im Owner-Locale (geteilter Renderer); Titel/Namen = gespeicherte Daten (Originalsprache).
    $buildJs = (Get-UiRenderLibJs) + @'
const U = uiRender($json.ui || {});
const tasks = ($json.tasks) || [];
if (!tasks.length) { return [{ json: { count: 0, top_id: '', message: '' } }]; }
const mark = { critical: '‼️', recommended: '•', optional: '·' };
const lines = tasks.map(t => (mark[t.hardness] || '•') + ' ' + t.title + ' (' + (t.subject || U.t('estate.dialog.subject_fallback')) + ') — '
  + U.fill(U.t(t.overdue ? 'estate.dialog.case_task_overdue' : 'estate.dialog.case_task_due'), { date: { kind: 'date', value: t.due_date } }));
const header = U.fill(U.t('estate.dialog.case_tasks_title'), { count: tasks.length });
const foot = tasks.length > 1 ? '\n\n' + U.t('estate.dialog.case_tasks_more') : '';
return [{ json: { count: tasks.length, top_id: String(tasks[0].id), message: header + '\n' + lines.join('\n') + foot,
  btn_done: U.t('estate.dialog.btn_done'), btn_skip: U.t('estate.dialog.btn_not_applicable') } }];
'@
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-220, 0)
        id = (New-Id); name = 'Build reminder'
    }

    $ifAny = Build-If 'Anything due?' @(0, 0) '={{ $json.count }}' '1' 'largerEqual' 'number'
    $quiet = Build-NoOp 'Nothing due' @(180, 200)

    # EINE aggregierte Karte an den Owner; est:-Buttons fuer die OBERSTE Aufgabe (Trauer-UX "eine naechste
    # Aufgabe"). callback_data est:done:<id>/est:skip:<id> -> core.callback_handlers 'est' ->
    # estate.fn_handle_case_task_callback (owner-first). Text escapt der Helper.
    $send = New-TelegramInlineKeyboardSendNode 'Send reminder' @(220, 0) `
        "={{ `$json.message }}" `
        @( @{ Text = "={{ `$json.btn_done }}"; Data = "=est:done:{{ `$json.top_id }}" },
           @{ Text = "={{ `$json.btn_skip }}"; Data = "=est:skip:{{ `$json.top_id }}" } )

    $stickyOverview = Build-Sticky 'Überblick' @(-1140, -320) `
        'agent.estate.cron_remind_case_tasks — täglicher Fristen-Reminder (always-on)' `
        'Schedule (schedule.remind_case_tasks, Default 10:00) -> Cron enabled? (fn_package_active(estate) AND cron_enable.remind_case_tasks; Default true always-on, KEIN Chat-Toggle) -> Collect due tasks (offene fällige/überfällige Tasks offener Fälle, 3-Tage-Vorlauf; je Task Latch core.fn_should_notify Cooldown 3 Tage -> kein tägliches Spam, überfällige werden periodisch neu erinnert) -> Build reminder (EINE aggregierte Karte, dringlichste zuerst; Texte + Knöpfe in Owner-Sprache aus derselben Collect-Anweisung wie der Latch, core.fn_ui_texts_for; Datum per Intl) -> Anything due? -> Send (est:-Buttons für die OBERSTE Aufgabe: est:done/est:skip -> core.callback_handlers est -> estate.fn_handle_case_task_callback, owner-first). No-op ohne offenen Fall/ohne fällige Tasks. KEINE monitor_triggers-Zeilen (Cron-vs-Trigger-Gesetz). Cred estate_rw.' 340 720

    $nodes = @($trig, $gate, $ifEnabled, $off, $collect, $build, $ifAny, $quiet, $send, $stickyOverview)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Collect due tasks' ),
            @( E 'Disabled' )
        ) }
        'Collect due tasks'           = @{ main = @( ,@( E 'Build reminder' ) ) }
        'Build reminder'              = @{ main = @( ,@( E 'Anything due?' ) ) }
        'Anything due?'               = @{ main = @(
            @( E 'Send reminder' ),
            @( E 'Nothing due' )
        ) }
    }
    return Build-Workflow 'agent.estate.cron_remind_case_tasks' $nodes $conns
}
