#Requires -Version 5.1
# Definition agent.career.cron_refresh_market_signals -> Build-CronRefreshMarketSignals. Dot-gesourct von build.ps1.
# WS-4 Markt-Signale: der deterministische Stellen-Nachfrage-Refresh. ALWAYS-ON-Cron (cron_enable.refresh_
# market_signals=true default; nur Konsole, KEINE Chat-Buttons — Muster finance.cron_refresh_market_prices,
# das Markt-Daten-Plumbing). Pfad: F9-Gate -> Kriterien laden (career_planning: primaere Rolle title, erster
# Ort) -> Have criteria? -> Jobsuche /pc/v6/jobs?size=1 -> maxErgebnisse (KEYLESS, oeffentliche X-API-Key-
# Konstante jobboerse-jobsuche; size=1 = nur die Zahl) -> career.fn_upsert_market_signals (datierter Cache).
# KEIN LLM, KEIN paid Key, KEIN PII (nur oeffentlicher Rollen-Titel/Ort). Den Trend liest der Renderer via
# career.fn_market_trend (Posting-Count ueber die Zeit). Laeuft unter dem Haupt-RW-Credential (Build-Pg-
# Default — liest agent.core_contexts, schreibt career.market_signals; deterministische SQL, kein LLM-SELECT).
# (Das amtliche GEHALTSBAND ist v1 NICHT hier: der Entgeltatlas blockt den automatischen Zugriff (403, tote
#  Community-Keys) -> Gehalt liefert der Advisor on-demand via web_search; strukturiertes Band via Destatis
#  GENESIS = BACKLOG.)
function Build-CronRefreshMarketSignals {

    $trig = Build-ScheduleTrigger @(-1120, 0) -ScheduleKey 'refresh_market_signals'

    # --- F9 Cron-Gating (always-on: Default true; nur Konsole abschaltbar) -> sonst No-op (fail-closed).
    $gate = Build-Pg 'Cron enabled?' @(-900, 0) `
        "=SELECT core.fn_package_active('career') AND COALESCE(core.fn_config_get('career','cron_enable','refresh_market_signals') = 'true', false) AS enabled" `
        $null
    $ifEnabled = Build-If 'Cron on?' @(-680, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-460, 200)

    # --- Kriterien ALLER aktiven Personen laden (Host-RW; agent.core_contexts). role_title -> Posting-Query
    #     'was'; location (target_locations[0]) -> Posting-Ort 'wo'.
    # P2b-2 Multi-Person: ueber agent.fn_context_persons('career_planning') faechern -> je Person die primaere
    #      Ziel-Rolle am Suffix career_planning__<pid> -> als EIN aggregiertes, auf (Rolle, Ort) DEDUPLIZIERTES
    #      pairs-Array (jsonb_agg DISTINCT) -> EIN Code-Node iteriert (kein splitInBatches: market_signals ist
    #      household-global, keine Sends/kein person_id; Parität zur Single-Node-Struktur). DISTINCT verhindert
    #      einen Doppel-API-Call, wenn zwei Personen dieselbe (Rolle, Ort) anpeilen. Keine Person/kein Plan ->
    #      pairs=[] -> 'Have criteria?' faellt graceful auf 'No criteria' (kein API-Call).
    $loadCtx = Build-Pg 'Load context' @(-460, 0) @'
=SELECT COALESCE(
         jsonb_agg(DISTINCT jsonb_build_object('role', role_title, 'loc', COALESCE(location, '')))
           FILTER (WHERE role_title IS NOT NULL AND btrim(role_title) <> ''),
         '[]'::jsonb) AS pairs
FROM (
  SELECT
    (SELECT metadata->'facts'->'target_roles'->0->>'title' FROM agent.core_contexts WHERE name = 'career_planning__' || p.person_id) AS role_title,
    (SELECT metadata->'facts'->'target_locations'->>0       FROM agent.core_contexts WHERE name = 'career_planning__' || p.person_id) AS location
  FROM agent.fn_context_persons('career_planning') p
) s
'@ $null

    # Kriterien vorhanden? (mindestens ein (Rolle, Ort)-Paar) -> sonst still beenden (kein API-Call ohne Rolle).
    $ifCriteria = Build-If 'Have criteria?' @(-240, 0) `
        '={{ Array.isArray($json.pairs) && $json.pairs.length > 0 }}' 'true' 'equals' 'boolean'
    $noCrit = Build-NoOp 'No criteria' @(-20, 200)

    # --- EIN Code-Node, KEYLESS (Muster cron_refresh_market_prices, kein LLM): holt die oeffentliche
    #     Bundesagentur-Jobsuche via this.helpers.httpRequest (try/catch = graceful degrade) und baut die
    #     signals-Payload fuer fn_upsert_market_signals. size=1 -> wir brauchen nur maxErgebnisse (die Gesamtzahl).
    $fetchJs = @'
const pairs = ($('Load context').first().json.pairs) || [];
const signals = [];

// Je (Rolle, Ort)-Paar EIN Posting-Count via Jobsuche maxErgebnisse (keyless, oeffentliche X-API-Key-Konstante;
// size=1 = nur die Zahl). Die Paare sind in SQL bereits auf DISTINCT (Rolle, Ort) dedupliziert -> kein Doppel-
// API-Call. Ein Ausfall je Paar -> still uebersprungen, die anderen Paare laufen weiter.
for (const pr of pairs) {
  const role = String((pr && pr.role) || '').trim();
  const loc  = String((pr && pr.loc) || '').trim();
  if (!role) continue;
  try {
    const params = ['size=1', 'page=1'];
    params.push('was=' + encodeURIComponent(role));
    if (loc) params.push('wo=' + encodeURIComponent(loc));
    const jres = await this.helpers.httpRequest({
      url: 'https://rest.arbeitsagentur.de/jobboerse/jobsuche-service/pc/v6/jobs?' + params.join('&'),
      headers: { 'X-API-Key': 'jobboerse-jobsuche' }, json: true, timeout: 15000 });
    const cnt = (jres && jres.maxErgebnisse != null) ? Number(jres.maxErgebnisse) : NaN;
    if (Number.isFinite(cnt) && cnt >= 0) {
      signals.push({ kind: 'postings', primary: role, secondary: loc, postings_count: Math.round(cnt),
                     raw: { maxErgebnisse: Math.round(cnt) } });
    }
  } catch (e) { /* API-Ausfall fuer dieses Paar -> still */ }
}

return [{ json: { signals } }];
'@
    $fetch = [ordered]@{
        parameters = [ordered]@{ jsCode = $fetchJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-20, 0)
        id = (New-Id); name = 'Fetch market data'
        onError = 'continueRegularOutput'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 3000
    }

    # --- Upsert via career.fn_upsert_market_signals (datierter Cache; still-guarded, kein RAISE).
    $upsert = Build-Pg 'Upsert signals' @(200, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM career.fn_upsert_market_signals(`$1::jsonb) AS r;" `
        ([ordered]@{ signals = '$json.signals' })

    # --- Stickies ---
    $stOverview = Build-Sticky 'Überblick' @(-1160, -380) `
        'Stellen-Nachfrage-Refresh (ALWAYS-ON-Cron, deterministisch, KEIN LLM/KEIN paid Key)' `
        ('F9-Gate (career aktiv UND cron_enable.refresh_market_signals=true — always-on, nur Konsole abschaltbar, KEINE Chat-Buttons; Muster finance.cron_refresh_market_prices) -> Kriterien ALLER aktiven Personen laden (P2b-2: agent.fn_context_persons(career_planning) -> je Person primäre Rolle/Ort am Suffix career_planning__<pid> -> EIN auf (Rolle, Ort) DEDUPLIZIERTES pairs-Array; market_signals ist household-global -> kein splitInBatches/kein person_id/keine Sends) -> Have criteria? (kein Paar -> still) -> EIN Code-Node iteriert die Paare + holt KEYLESS je Paar die öffentliche Bundesagentur-Jobsuche /pc/v6/jobs?size=1 -> maxErgebnisse (Posting-Count, X-API-Key=jobboerse-jobsuche, öffentliche Konstante; DISTINCT -> kein Doppel-Call). try/catch je Paar = graceful degrade. -> career.fn_upsert_market_signals (datierter Cache career.market_signals, scope_key via fn_market_scope_key aus rohen Feldern). Den Trend liest der Renderer via career.fn_market_trend (Posting-Count über die Zeit). ROLLE: Haupt-RW-Cred (liest agent.core_contexts, schreibt career.market_signals; deterministische SQL, kein LLM-SELECT). PRIVACY: KEIN PII (nur öffentlicher Rollen-Titel/Ort), KEIN paid Key. GEHALTSBAND v1 NICHT hier (Entgeltatlas 403 -> Gehalt on-demand via web_search; strukturiertes Band Destatis GENESIS = BACKLOG).') 360 940

    $stTrend = Build-Sticky 'Trend braucht Historie' @(-20, 200) `
        'Keyless (öffentliche X-API-Key-Konstante, kein Secret); der Trend braucht >= 2 wöchentliche Messungen' `
        'Der Posting-Count braucht nur den Rollen-Titel (+Ort) -> der Trend läuft beim Erst-Setup ~1-2 Wochen als nackter Count an (career.fn_market_trend: erst ab der 2. Messung ein Delta). Ein reiner Wert ginge nicht -> dedizierte datierte Cache-Tabelle career.market_signals (Muster finance.market_prices).' 320 560

    $nodes = @($trig, $gate, $ifEnabled, $off, $loadCtx, $ifCriteria, $noCrit, $fetch, $upsert,
               $stOverview, $stTrend)

    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'   = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'        = @{ main = @(
            @( E 'Load context' ),
            @( E 'Disabled' )
        ) }
        'Load context'    = @{ main = @( ,@( E 'Have criteria?' ) ) }
        'Have criteria?'  = @{ main = @(
            @( E 'Fetch market data' ),
            @( E 'No criteria' )
        ) }
        'Fetch market data' = @{ main = @( ,@( E 'Upsert signals' ) ) }
    }
    return Build-Workflow 'agent.career.cron_refresh_market_signals' $nodes $conns
}
