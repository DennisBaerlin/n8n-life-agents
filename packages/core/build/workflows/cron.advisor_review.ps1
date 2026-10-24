#Requires -Version 5.1
# Definition agent.advisor.cron_review -> Build-CronAdvisorReview. Dot-gesourct von build.ps1.
# QUARTALSWEISER Voll-Review der generischen Core-Advisor-Engine (schedule.plan_review, beim Einspielen aus core.config eingesetzt).
# Iteriert core.advisors und schickt je Advisor den UNBEDINGTEN Voll-Digest (kein Latch — periodischer
# Voll-Report). Loest funktional den retired finance-Cron agent.finance_advisor.cron_plan_review ab.
# Opt-in ueber F9 (cron_enable.plan_review, default 'false'). Geteilter Schwanz in New-AdvisorCron.
# Nutzt denselben Eval-Pfad (core.fn_advisor_review_evaluate) und liest NUR die digest.lines — der Latch-Write
# der fn ist hier ein harmloser Seiteneffekt (cron_drift_check 10:00 < cron_review 10:05 faengt Breaches zuerst).
function Build-CronAdvisorReview {
    # EINE Zeile: je (Advisor, Person) die paket-gelieferte digest.lines-Struktur (finance.fn_advisor_review baut sie).
    # Der Cron kennt KEINE Paket-Felder. P2b-2: per-Person-Faecherung via dem geteilten Get-AdvisorFanoutCte-Kopf ->
    # jede Person bekommt ihren eigenen Digest (person_id im build_object, damit Digests gleicher Domain NICHT
    # kollabieren). household-Domains -> person_id NULL (NULLS FIRST = stabile Reihenfolge). jsonb als ::text
    # (n8n-Pg-Node-Quirk, Muster Monitor-Cron). Textkatalog Phase C: Texte (Owner-Sprache, alle tpl-Keys der Digests)
    # in DERSELBEN Anweisung wie der Latch-Seiteneffekt der Eval-fn.
    $cte = Get-AdvisorFanoutCte
    $keys = Get-UiKeysSql ($script:AdvisorChromeKeys + $script:UiRenderKeys)
    $evalSql = @"
=WITH $cte,
ev AS MATERIALIZED (
  SELECT domain, person_id, person_name, core.fn_advisor_review_evaluate(domain, person_id, '{}'::jsonb) AS r FROM pids
),
agg AS (
  SELECT COALESCE(
           jsonb_agg(jsonb_build_object('domain', domain, 'person_id', person_id, 'lines', r->'digest'->'lines',
                                        'text', r->'digest'->>'text',
                                        'person_name', person_name)
                     ORDER BY domain, person_id NULLS FIRST),
           '[]'::jsonb) AS digests
  FROM ev
)
SELECT agg.digests::text AS digests,
       core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys), 'doc', agg.digests))::text AS ui
FROM agg;
"@

    $buildJs = (Get-UiRenderLibJs) + @'
const digests = JSON.parse($input.first().json.digests || '[]');
const ui = JSON.parse($input.first().json.ui || '{}');
const U = uiRender(ui);
'@ + (Get-AdvisorChromeJs) + @'
// lines = Struktur der Paket-Review-fn (Textkatalog Phase C); text nur noch Rueckfall fuer aeltere Pakete
const parts = (Array.isArray(digests) ? digests : [])
  .map(d => { const b = (d && Array.isArray(d.lines)) ? U.lines(d.lines).trim() : (d && d.text ? String(d.text).trim() : '');
              // Roter Faden: per_user-Digests (career) tragen den Vornamen der Person als Kopfzeile.
              return (b && d && d.person_name) ? (d.person_name + ':\n' + b) : b; })
  .filter(Boolean);
if (parts.length === 0) { return [{ json: Object.assign({ det_text: '', report: false }, chrome) }]; }
return [{ json: Object.assign({ det_text: parts.join('\n\n----------\n\n'), report: true }, chrome) }];
'@

    $sticky = 'Quartalsweiser Voll-Review (schedule.plan_review aus core.config, EMPFOHLEN quartalsweise). Iteriert core.advisors und schickt je Advisor den UNBEDINGTEN Voll-Digest (kein Latch — periodischer Voll-Report; Build message setzt report=true, sobald die digest.lines mindestens eine Zeile ergeben; ein älteres Paket ohne lines liefert noch digest.text). Löst den retired paket-eigenen Plan-Review-Cron ab (seit WS2 generisch). F9-Gate (Cron on?): core.fn_package_active(core) AND core.fn_config_get(core,cron_enable,plan_review)=true (fail-closed; default false = opt-in). Nutzt denselben Eval-Pfad core.fn_advisor_review_evaluate und rendert NUR die digest.lines-Struktur in Owner-Sprache (geteilter Renderer, Zahlen per Intl) — der Latch-Write ist ein harmloser Seiteneffekt (cron_drift_check 10:00 < cron_review 10:05 fängt Breaches zuerst). Phrase formuliert in dieser Sprache um (model.advisor_review, jede Zahl wörtlich), onError continue -> deterministischer Fallback.'

    return New-AdvisorCron `
        -WorkflowName  'agent.advisor.cron_review' `
        -ScheduleKey   'plan_review' `
        -CronEnableKey 'plan_review' `
        -EvalSql       $evalSql `
        -BuildJs       $buildJs `
        -SendNodeName  'Send review' `
        -StickyBody    $sticky
}
