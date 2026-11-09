#Requires -Version 5.1
# Definition agent.advisor.cron_drift_check -> Build-CronAdvisorDriftCheck. Dot-gesourct von build.ps1.
# TAEGLICHER Drift-Waechter der generischen Core-Advisor-Engine (schedule.drift_check 10:00, beim
# Einspielen aus core.config eingesetzt). Iteriert core.advisors, rechnet Soll-Ist-Drift + Staleness, LATCHT (geteilte core.notification_state):
# nur eine NEU gebreachte Metrik schickt eine Message, ein stiller Lauf bleibt stumm (kein Tages-Spam).
# Opt-in ueber F9 (cron_enable.drift_check, default 'false' bis ein Plan publiziert ist). Geteilter Schwanz
# in New-AdvisorCron (cron.advisor_common.ps1). Laeuft 10:00 VOR cron_review (10:05) -> Breaches werden zuerst
# vom Drift-Cron gefangen + gelatcht, der spaetere Voll-Review verschluckt keinen Alarm.
function Build-CronAdvisorDriftCheck {
    # EINE Zeile: alle NEU gebreachten alert-Objekte (paket-gelieferte msg-Struktur) ueber ALLE Advisor x Personen.
    # P2b-2: per-Person-Faecherung via dem geteilten Get-AdvisorFanoutCte-Kopf (per_user je Person, household NULL).
    # MATERIALIZED CTE -> die VOLATILE Eval-fn (schreibt Latch) laeuft EXAKT 1x je (Advisor, Person); ohne neue
    # Breaches -> '[]'. jsonb als ::text (n8n-Pg-Node-Quirk: jsonb robust ueber JSON.parse, Muster Monitor-Cron).
    # alerts werden ueber (Domain x Person) flachgezogen (jsonb_agg = je Element eine eigene Zeile, kein Collapse).
    # Textkatalog Phase C: die Texte (Owner-Sprache; Keys = die festen + alle tpl-Keys der Alerts) kommen in DERSELBEN
    # Anweisung wie der Latch — ein Ladefehler rollt den Latch zurueck (nie "gemeldet", ohne verschickt zu sein).
    $cte = Get-AdvisorFanoutCte
    $keys = Get-UiKeysSql (@('core.advisor.drift_title', 'core.advisor.first_run_intro', 'core.advisor.drift_cta') + $script:AdvisorChromeKeys + $script:UiRenderKeys)
    $evalSql = @"
=WITH $cte,
ev AS MATERIALIZED (
  SELECT person_name, core.fn_advisor_review_evaluate(domain, person_id, '{}'::jsonb) AS r FROM pids
),
agg AS (
  SELECT COALESCE(jsonb_agg(al || jsonb_build_object('person_name', ev.person_name)), '[]'::jsonb) AS alerts,
         COALESCE(bool_or((ev.r->>'first_run')::boolean), false) AS first_run
  FROM ev CROSS JOIN LATERAL jsonb_array_elements(ev.r->'alerts') al
),
cap AS MATERIALIZED (
  SELECT core.fn_advisor_alerts_cap(agg.alerts, agg.first_run) AS c, agg.first_run FROM agg
)
SELECT (cap.c->'alerts')::text AS alerts, cap.first_run, (cap.c->'more_line')::text AS more_line,
       core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys), 'doc', cap.c))::text AS ui
FROM cap;
"@

    $buildJs = (Get-UiRenderLibJs) + @'
const alerts = JSON.parse($input.first().json.alerts || '[]');
const ui = JSON.parse($input.first().json.ui || '{}');
const U = uiRender(ui);
'@ + (Get-AdvisorChromeJs) + @'
if (!Array.isArray(alerts) || alerts.length === 0) {
  return [{ json: Object.assign({ det_text: '', report: false }, chrome) }];
}
const L = [U.t($input.first().json.first_run === true ? 'core.advisor.first_run_intro' : 'core.advisor.drift_title'), ''];
const moreLine = JSON.parse($input.first().json.more_line || 'null');
// msg = Struktur der Paket-Review-fn (Textkatalog Phase C); text/label nur noch Rueckfall fuer aeltere Pakete
// Roter Faden: per_user-Domaenen (career) nennen die Person (Vorname), um die es geht; Haushalt ohne Praefix.
for (const a of alerts) { L.push('• ' + (a.person_name ? a.person_name + ': ' : '') + (Array.isArray(a.msg) ? U.msg(a.msg) : (a.text || a.label || a.metric_key))); }
// Gibt es einen Rest, ersetzt sein Hinweis den Schlusssatz (Nachricht bleibt kurz).
L.push('', moreLine ? U.msg([moreLine]) : U.t('core.advisor.drift_cta'));
return [{ json: Object.assign({ det_text: L.join('\n'), report: true }, chrome) }];
'@

    $sticky = 'Täglicher Drift-Wächter (schedule.drift_check 10:00, aus core.config, änderbar per lifeagents config set). Iteriert core.advisors, rechnet Soll-Ist-Drift + Staleness, LATCHT (geteilte core.notification_state, source=advisor:domain): nur eine NEU gebreachte Metrik schickt -> stiller Lauf = keine Message (kein Tages-Spam), Re-Arm wenn wieder im Band. F9-Gate (Cron on?): core.fn_package_active(core) AND core.fn_config_get(core,cron_enable,drift_check)=true (DB entscheidet, fail-closed; default false = opt-in bis ein Plan publiziert ist). Läuft 10:00 VOR cron_review (10:05) -> Breaches zuerst hier gefangen + gelatcht. Grenze je Nachricht über core.fn_advisor_alerts_cap: höchstens 5 Punkte, beim ersten Lauf 3 mit eigenem Titel; Gekürztes verliert seinen Merker und kommt an den Folgetagen, das Wichtigste zuerst. Was der Owner beim Eintragen schon gehört hat (told_keys), meldet der Wächter nicht. Build message rendert die paket-gelieferte alert.msg-Struktur in Owner-Sprache (geteilter Renderer, Zahlen per Intl; Texte aus derselben Anweisung wie der Latch); Phrase formuliert in dieser Sprache um (model.advisor_review, jede Zahl wörtlich), onError continue -> deterministischer Fallback.'

    return New-AdvisorCron `
        -WorkflowName  'agent.advisor.cron_drift_check' `
        -ScheduleKey   'drift_check' `
        -CronEnableKey 'drift_check' `
        -EvalSql       $evalSql `
        -BuildJs       $buildJs `
        -SendNodeName  'Send drift' `
        -StickyBody    $sticky
}
