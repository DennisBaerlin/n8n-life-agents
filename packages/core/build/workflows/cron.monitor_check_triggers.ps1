#Requires -Version 5.1
# Definition agent.monitor.cron_check_triggers -> Build-CronMonitorCheckTriggers. Dot-gesourct von build.ps1.
# HEARTBEAT des generischen Trigger-Monitorings: laeuft stuendlich (schedule.monitor_triggers,
# beim Einspielen aus core.config eingesetzt — nur der AUFLOESUNGSBODEN; die per-Trigger-Frequenz lebt als
# check_interval/next_check_at an der Trigger-Zeile, Due-Selection in agent.fn_monitor_due).
# Kill-Switch feature.monitor_triggers zur LAUFZEIT (default true — ohne Trigger-Zeilen
# natuerlicherweise stumm). NUR die web_search-Beschaffung laeuft im Canvas (Claude-web_search-HTTP
# je faelligem Web-Trigger, strikter JSON-Vertrag, deterministischer Parse); sql/none/Paket-
# Methoden beschafft fn_monitor_evaluate selbst (sql unter SET LOCAL ROLE core_ro). Vergleich/
# Latch/Ratchet/Advance = rein deterministisch in der fn. EINE kombinierte Telegram-Message
# (deterministisch formatiert, KEIN LLM-Phrasing — Alert-Wortlaut muss exakt sein);
# stiller Lauf = keine Message.
function Build-CronMonitorCheckTriggers {

    $trig = Build-ScheduleTrigger @(-1100, 0) -ScheduleKey 'monitor_triggers'

    # Kill-Switch zur LAUFZEIT (default true; abschalten = Config-Zeile + re-seed, kein Rebuild)
    $flag = Build-Pg 'Read feature flag' @(-880, 0) `
        "=SELECT COALESCE((SELECT value FROM core.config WHERE category = 'feature' AND key = 'monitor_triggers'), 'true') AS flag;" `
        $null
    $ifEnabled = Build-If 'Enabled?' @(-660, 0) '={{ $json.flag }}' 'true' 'equals' 'string'
    $off = Build-NoOp 'Disabled' @(-440, 200)

    # NUR die faelligen WEB-Trigger (sql/none/Paket-Methoden beschafft die fn selbst).
    # alwaysOutputData: 0 Treffer -> EIN leeres Item -> der 'Web items?'-IF routet es auf
    # den Direkt-Pfad, damit Evaluate auch ohne Web-Trigger laeuft (date/sql/Paket-Methode faellig!).
    $due = Build-Pg 'Load due web triggers' @(-440, 0) `
        "=SELECT run_ts::text AS run_ts, id, label, acquisition_spec->>'prompt' AS prompt FROM agent.fn_monitor_due(NOW()) WHERE acquisition_method = 'web_search';" `
        $null
    $due['alwaysOutputData'] = $true

    # Exklusive Branches (kein Merge-Node noetig): ENTWEDER alle echten Web-Items (true)
    # ODER genau das eine leere Item (false) — Evaluate laeuft dadurch exakt 1x.
    $ifItems = Build-If 'Web items?' @(-220, 0) '={{ $json.id || 0 }}' '0' 'larger' 'number'

    # Modell der Wert-Beschaffung (model.monitor_acquisition) bei JEDEM Lauf aus core.config — VOR der Due-Abfrage
    # (deren SQL hat keine Eingangs-Bezuege), damit der HTTP-Knoten es je Item per .first() liest.
    $loadModel = New-MonitorModelConfigNode -Pos @(-550, -180)

    $acquire = New-MonitorAcquireHttpNode 'Acquire web value' @(0, -140) "`$json.prompt"

    # Parse je Item (Stufe 1 der Validierungs-Kaskade); trigger_id via pairedItem-Kette,
    # NIE durchs Modell (Modell-Output ist untrusted).
    $shapeJs = Get-MonitorShapeJs -PerItem -ResultExprJs 'return { json: { observation: Object.assign({ trigger_id: $(''Load due web triggers'').item.json.id }, obs) } };'
    $shape = [ordered]@{
        parameters = [ordered]@{ mode = 'runOnceForEachItem'; jsCode = $shapeJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(180, -140)
        id = (New-Id); name = 'Shape web observations'
    }

    $collect = [ordered]@{
        parameters = [ordered]@{ jsCode = @'
const items = $input.all();
return [{ json: {
  run_ts: $('Load due web triggers').first().json.run_ts,
  observations: items.map(i => i.json.observation)
} }];
'@ }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(360, -140)
        id = (New-Id); name = 'Collect observations'
    }

    # EINE atomare Auswertung (sql/Paket-Methoden-Beschaffung + Validierung + Latch/Ratchet/Advance off-canvas).
    # Textkatalog Phase C: die Texte (Owner-Sprache, core.fn_ui_texts_for) in DERSELBEN Anweisung wie Latch/Advance —
    # ein Ladefehler rollt die Auswertung zurueck (nie "ausgeloest", ohne gemeldet zu sein). Paketnamen der Advisor-
    # Hinweise als <pkg>.package.name (Liste build-time aus den Manifest-advisors-Bloecken, $AdvisorDomainList).
    $monKeys = @('core.monitor.title', 'core.monitor.fired', 'core.monitor.date_reached', 'core.monitor.drawdown',
        'core.monitor.threshold', 'core.monitor.threshold_previous', 'core.monitor.source', 'core.monitor.source_as_of',
        'core.monitor.action', 'core.monitor.advisor_hint', 'core.monitor.info', 'core.monitor.date_warning',
        'core.monitor.value_as_of', 'core.monitor.problems', 'core.monitor.problem', 'core.monitor.repair',
        'core.monitor.fired_note') + $script:UiRenderKeys +
        @($AdvisorDomainList | ForEach-Object { "$($_.Package).package.name" } | Select-Object -Unique)
    $keys = Get-UiKeysSql $monKeys
    $evaluate = Build-Pg 'Evaluate (atomic)' @(540, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'checked')::int AS checked, jsonb_array_length(r->'fired')::int AS fired_count, jsonb_array_length(r->'info')::int AS info_count, jsonb_array_length(r->'problems')::int AS problem_count, (r->'fired')::text AS fired, (r->'info')::text AS info, (r->'problems')::text AS problems, core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys)))::text AS ui FROM agent.fn_monitor_evaluate(`$1::jsonb) AS r;" `
        ([ordered]@{
            now          = '($json.run_ts || null)'
            observations = '($json.observations || [])'
        })

    $ifReport = Build-If 'Anything to report?' @(720, 0) `
        '={{ ($json.fired_count || 0) + ($json.info_count || 0) + ($json.problem_count || 0) }}' '0' 'larger' 'number'
    $quiet = [ordered]@{ parameters = @{}; type = 'n8n-nodes-base.noOp'; typeVersion = 1
        position = @(900, 200); id = (New-Id); name = 'Quiet run' }

    # Deterministische Message in Owner-Sprache (geteilter Renderer; Zahlen/Daten per Intl); Domain->Paket-Map
    # BUILD-TIME aus den Manifest-advisors-Bloecken ($AdvisorDomainList — Wert-Fragen -> Fach-Advisor des Pakets,
    # Mechanik/Reparatur -> Monitor-Agent), der Paketname zur Laufzeit aus dem Katalog. Kein LLM: Alert-Wortlaut exakt.
    $domainJson = '{' + (($AdvisorDomainList | ForEach-Object {
        (ConvertTo-Json $_.Domain) + ':' + (ConvertTo-Json $_.Package) }) -join ',') + '}'
    $jsBuild = (Get-UiRenderLibJs) + @'
const m = $input.first().json;
const fired = JSON.parse(m.fired || '[]');
const info = JSON.parse(m.info || '[]');
const problems = JSON.parse(m.problems || '[]');
const U = uiRender(JSON.parse(m.ui || '{}'));
const domainPackage = __DOMAIN_PACKAGE__;
// Werte exakt (bis 6 Nachkommastellen, keine erzwungenen Nullen) im Owner-Locale; Nicht-Zahlen roh
const nv = (v) => U.isEmpty(v) ? '-' : (isFinite(Number(v)) ? Number(v).toLocaleString(U.loc, { maximumFractionDigits: 6 }) : String(v));
const withUnit = (v, unit) => nv(v) + (unit ? ' ' + unit : '');
const d = (iso) => U.date(iso);
const L = [U.t('core.monitor.title')];
if (fired.length) {
  L.push(''); L.push(U.t('core.monitor.fired'));
  for (const f of fired) {
    let detail;
    if (f.trigger_type === 'date') detail = U.fill(U.t('core.monitor.date_reached'), { date: d(f.due_date) });
    else if (f.trigger_type === 'drawdown') detail = U.fill(U.t('core.monitor.drawdown'), { pct: nv(f.drawdown_observed),
      reference: withUnit(f.reference_value, f.unit), value: withUnit(f.value, f.unit) });
    else detail = U.fill(U.t((f.previous_value !== undefined && f.previous_value !== null) ? 'core.monitor.threshold_previous' : 'core.monitor.threshold'),
      { value: withUnit(f.value, f.unit), comparator: (f.comparator === 'lte' ? '<=' : '>='), threshold: nv(f.threshold_value), previous: nv(f.previous_value) });
    L.push('• ' + f.label + ': ' + detail);
    if (f.source_url) L.push('  ' + U.fill(U.t(f.as_of ? 'core.monitor.source_as_of' : 'core.monitor.source'), { url: f.source_url, date: d(f.as_of) }));
    if (f.action_note) L.push('  ' + U.fill(U.t('core.monitor.action'), { note: f.action_note }));
    const pkg = domainPackage[f.domain];
    if (pkg) L.push('  -> ' + U.fill(U.t('core.monitor.advisor_hint'), { package: U.t(pkg + '.package.name') }));
  }
}
if (info.length) {
  L.push(''); L.push(U.t('core.monitor.info'));
  for (const i of info) {
    if (i.kind === 'date_warning') L.push('• ' + i.label + ': ' + U.fill(U.t('core.monitor.date_warning'), { days: nv(i.days_left), date: d(i.due_date) }) + (i.action_note ? ' - ' + i.action_note : ''));
    else L.push('• ' + i.label + ': ' + ((i.value !== undefined && i.value !== null) ? withUnit(i.value, i.unit) : '-')
      + (i.as_of ? ' ' + U.fill(U.t('core.monitor.value_as_of'), { date: d(i.as_of) }) : '') + (i.action_note ? ' - ' + i.action_note : ''));
  }
}
if (problems.length) {
  L.push(''); L.push(U.t('core.monitor.problems'));
  for (const p of problems) {
    L.push('• ' + p.label + ': ' + U.fill(U.t('core.monitor.problem'), { since: p.first_fail ? d(p.first_fail) : '?', streak: nv(p.fail_streak), reason: p.reason || '' }));
    L.push('  ' + U.fill(U.t('core.monitor.repair'), { label: p.label }));
  }
}
if (fired.length) { L.push(''); L.push(U.t('core.monitor.fired_note')); }
return [{ json: { message: L.join('\n') } }];
'@
    $jsBuild = $jsBuild.Replace('__DOMAIN_PACKAGE__', $domainJson)
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsBuild }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(900, 0)
        id = (New-Id); name = 'Build message'
    }

    # Deterministischer Text mit DB-Werten (Trigger-Labels!) -> zentrales Escape via Helper
    # (ein Label mit '_' haette den Alert vorher gecrasht — Gotcha "can't parse entities").
    $send = New-TelegramSendNode 'Send alerts' @(1080, 0) '={{ $json.message }}'

    $stickyOverview = Build-Sticky 'Überblick' @(-1140, -420) `
        'Heartbeat des generischen Trigger-Monitorings (deterministisch)' `
        'Stündlicher Heartbeat (schedule.monitor_triggers aus core.config) = nur AUFLÖSUNGSBODEN — die Frequenz JEDES Triggers lebt als check_interval/next_check_at an der Zeile (agent.monitor_triggers); fn_monitor_due selektiert Fällige. Kill-Switch feature.monitor_triggers zur LAUFZEIT (default true; ohne Trigger natürlicherweise stumm). Leerer Lauf = 1 SELECT, kein LLM, keine Message. Trigger anlegen/ändern/reparieren NUR über die HITL-Tools des Monitor-Agenten (Fach-Advisor: nur create, domain = sein Paket).' 300 600

    $stickyAcq = Build-Sticky 'Doc Beschaffung' @(-20, -420) `
        'Wert-Beschaffung: nur WEB im Canvas, Rest in der fn' `
        'Load due web triggers liefert NUR fällige web_search-Trigger; je Item ein Claude-web_search-HTTP-Call (model.monitor_acquisition, bei JEDEM Lauf von Load model config aus core.config gelesen, strikter JSON-Vertrag im System-Prompt, gespeicherter Prompt WÖRTLICH als User-Content, max 2 Calls/Tag/Trigger via DB-CHECK >= 12h). Shape: deterministischer Parse (Fences strippen, erster balancierter JSON-Block, value finite number; trigger_id via pairedItem-Kette, NIE durchs Modell). sql (SET LOCAL ROLE core_ro) / Paket-Methoden (Registry core.monitor_acquisition_methods -> acquire_fn des Pakets; Paket fehlt/inaktiv -> Trigger GEPARKT, kein Fehlerpfad) / none beschafft fn_monitor_evaluate SELBST. Exklusive IF-Branches statt Merge: entweder echte Web-Items ODER das eine alwaysOutputData-Leeritem -> Evaluate läuft exakt 1x.' 320 560

    $stickyEval = Build-Sticky 'Doc Evaluate' @(480, -420) `
        'fn_monitor_evaluate (atomar, off-canvas) — die Schritte' `
        '1. Due-Set unter FOR UPDATE NEU berechnen (TOCTOU: disabled/editiert zählt Row-Wahrheit; nicht verfügbare Paket-Methode -> geparkt). 2. Beschaffung sql/none/Paket-Methoden in der fn. 3. Validierungs-Kaskade fn_validate_observation: numerisch -> Unit-Echo (expected_unit, nur web) -> Bounds (min/max_plausible) -> Jump-Guard (max_jump_pct vs. letzter sauberer Wert). 4. Observation-Log IMMER (agent.monitor_observations, Audit). 5. dirty: fail_streak++, Problem-Alarm bei monitor.fail_alert_streak + Vielfachen; last_value/Ratchet UNBERÜHRT. 6. clean: threshold gte/lte-Latch; drawdown Ratchet GREATEST + dd%-Latch; date Warn-Info (kein Latch) + Latch am due_date; recurring_info latcht NIE. 7. next_check_at IMMER advancen (fn_next_check, anker-erhaltend). Datum = core.fn_today (Haushalts-Zeitzone der DB-Sitzung). Message deterministisch (kein LLM) in Owner-Sprache: Texte aus derselben Evaluate-Anweisung (core.fn_ui_texts_for), Zahlen/Daten per Intl; Domain->Paket-Map build-time aus den Manifest-advisors-Blöcken, der Paketname zur Laufzeit aus dem Katalog: fired in einer Advisor-Domain -> Berater dieses Pakets, Probleme -> Monitor-Agent.' 360 640

    $nodes = @($trig, $flag, $ifEnabled, $off, $loadModel, $due, $ifItems, $acquire, $shape, $collect,
               $evaluate, $ifReport, $quiet, $build, $send,
               $stickyOverview, $stickyAcq, $stickyEval)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Read feature flag' ) ) }
        'Read feature flag'           = @{ main = @( ,@( E 'Enabled?' ) ) }
        'Enabled?'                    = @{ main = @(
            @( E 'Load model config' ),
            @( E 'Disabled' )
        ) }
        'Load model config'           = @{ main = @( ,@( E 'Load due web triggers' ) ) }
        'Load due web triggers'       = @{ main = @( ,@( E 'Web items?' ) ) }
        'Web items?'                  = @{ main = @(
            @( E 'Acquire web value' ),
            @( E 'Evaluate (atomic)' )
        ) }
        'Acquire web value'           = @{ main = @( ,@( E 'Shape web observations' ) ) }
        'Shape web observations'      = @{ main = @( ,@( E 'Collect observations' ) ) }
        'Collect observations'        = @{ main = @( ,@( E 'Evaluate (atomic)' ) ) }
        'Evaluate (atomic)'           = @{ main = @( ,@( E 'Anything to report?' ) ) }
        'Anything to report?'         = @{ main = @(
            @( E 'Build message' ),
            @( E 'Quiet run' )
        ) }
        'Build message'               = @{ main = @( ,@( E 'Send alerts' ) ) }
    }
    return Build-Workflow 'agent.monitor.cron_check_triggers' $nodes $conns
}
