#Requires -Version 5.1
# Definition agent.career.cron_score_jobs -> Build-CronScoreJobs. Dot-gesourct von build.ps1.
# WS-2 Job-Matching + P2b-2 Multi-Person + V005 MULTI-SOURCE: der werktägliche Job-Scan PRO PERSON aus
# MEHREREN Quellen (Bundesagentur keyless + Adzuna + JSearch). Person-Reminder (Roter Faden Paket B: cron_enable.score_jobs=true
# = Konsolen-Notschalter; je Person rem:on|off:score_jobs -> agent.reminder_prefs, cron_labels.person). Pfad:
# F9-Gate -> Personen mit aktivem career_planning enumerieren (agent.fn_context_persons('career_planning'),
# je Person die eigene chat_id via agent.fn_person_chat_id; ungepairte Person -> raus; per-Quelle Enable-Flags
# + source-partitionierter known-Set) -> Loop persons (splitInBatches v3): JE PERSON Kriterien/Profil/Praeferenzen
# am Suffix career_planning__<pid> usw. -> Have criteria? -> Build query (baut EINE gemeinsame Query -> je Quelle
# eine URL) -> Fetch BA / Fetch Adzuna / Fetch JSearch (linear, jeder onError=continue+retry = graceful degrade;
# fehlender Key -> Cred-Fehler faellt in onError -> Quelle still uebersprungen) -> Normalize postings (EIN Code-Node:
# je Quelle EIGENER try/catch + Parse in die normalisierte Form + Dedup gegen den EIGENEN known-Set der Quelle;
# disabled -> uebersprungen; merge; ephemerer Per-Run-Index i) -> EIN gebatchter Cheap-Scorer (model.job_scorer,
# Claude via New-AnthropicMessagesNode, Structured Output) je Person ueber ALLE Quellen (echot den integer-Index i) -> career.fn_record_job_match je
# Treffer (source/board/external_id, person_id TRUSTED CRON) -> je Treffer >= Schwelle (Top max_per_run GLOBAL
# ueber alle Quellen) + 1 Serendipity eine Karte mit 👍/👎 + Abschalten-Knopf an die EIGENE chat_id (Karte zeigt
# "via <board>" nur fuer jsearch). Danach zurueck in den Loop (naechste Person).
# ROLLE: laeuft unter dem Haupt-RW-Credential (Build-Pg-Default) — liest agent.core_contexts + core.config +
#   schreibt career.* (deterministische, entwickler-geschriebene SQL, kein LLM-SELECT).
# PRIVACY: career_profile/career_preferences (PII) gehen NUR in den Scorer-Prompt -> bezahlte Anthropic-API (trainiert nicht). Die
#   Aggregatoren bekommen NUR die oeffentliche Query (Rolle+Ort), KEIN PII.
# BOARD-HERKUNFT je Quelle (V005): jsearch -> board IMMER aus job_publisher; adzuna -> NULL by design (Adzuna
#   legt kein Board offen); bundesagentur -> NULL. DEDUP: (source, external_id, person_id) source-skopiert.
function Build-CronScoreJobs {
    $trig = Build-ScheduleTrigger @(-1780, 0) -ScheduleKey 'score_jobs'

    # --- F9 Cron-Gating: nur wenn career aktiv UND cron_enable.score_jobs (Notschalter; je Person filtert Enumerate persons) -> sonst No-op (fail-closed).
    $gate = Build-Pg 'Cron enabled?' @(-1560, 0) `
        "=SELECT core.fn_package_active('career') AND COALESCE(core.fn_config_get('career','cron_enable','score_jobs') = 'true', false) AS enabled" `
        $null
    $ifEnabled = Build-If 'Cron on?' @(-1340, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-1120, 200)

    # --- Scorer-Modell (model.job_scorer) bei JEDEM Lauf aus core.config — VOR der Personen-Enumeration (deren SQL
    #     hat keine Eingangs-Bezuege); der Scorer-HTTP-Knoten liest es je Person per .first().
    $loadModel = New-ModelConfigNode -Position @(-1230, -180) -Keys @( ,@('career', 'job_scorer') )

    # --- P2b-2 Person-Enumeration: EINE Zeile JE Person mit aktivem career_planning. V005 Multi-Source: je Person
    #     die per-Quelle Enable-Flags (sources_enabled, Default true wenn Key fehlt) + der SOURCE-PARTITIONIERTE
    #     known-Set (known = {source: [external_id, …]}) -> jede Quelle dedupt gegen ihre EIGENEN known-ids (BA-refnr /
    #     Adzuna-id / JSearch-job_id sind verschiedene Schluesselraeume; ein source-blinder known-Set unterdrueckte
    #     sonst faelschlich einen echten Treffer einer anderen Quelle). threshold/max_per_run runtime aus core.config.
    $enumerate = Build-Pg 'Enumerate persons' @(-1120, 0) @'
=SELECT
  p.person_id,
  agent.fn_person_chat_id(p.person_id) AS chat_id,
  -- Textkatalog Phase C: Prompt-Label der Empfaenger-Sprache fuer die Scorer-Begruendung ("ko (한국어)", eine Adresse:
  -- agent.fn_ui_texts_for; Empfaenger = die Person hinter ihrer chat_id, Kette Person -> Owner -> en)
  agent.fn_ui_texts_for(jsonb_build_object('chat_id', agent.fn_person_chat_id(p.person_id)))->>'language_label' AS language_label,
  (SELECT metadata->'facts' FROM agent.core_contexts WHERE name = 'career_planning__'    || p.person_id) AS planning,
  (SELECT metadata->'facts' FROM agent.core_contexts WHERE name = 'career_profile__'      || p.person_id) AS profile,
  (SELECT metadata->'facts' FROM agent.core_contexts WHERE name = 'career_preferences__'  || p.person_id) AS preferences,
  COALESCE(NULLIF(core.fn_config_get('career','career','job_score_threshold'),''),'3')::int AS threshold,
  COALESCE(NULLIF(core.fn_config_get('career','career','job_max_per_run'),''),'7')::int      AS max_per_run,
  jsonb_build_object(
    'bundesagentur', COALESCE(NULLIF(core.fn_config_get('career','career','job_source_bundesagentur'),'') = 'true', true),
    'adzuna',        COALESCE(NULLIF(core.fn_config_get('career','career','job_source_adzuna'),'')        = 'true', true),
    'jsearch',       COALESCE(NULLIF(core.fn_config_get('career','career','job_source_jsearch'),'')       = 'true', true)
  ) AS sources_enabled,
  COALESCE(
    (SELECT jsonb_object_agg(source, ids)
     FROM (SELECT source, array_agg(external_id) AS ids
           FROM career.job_matches
           WHERE external_id IS NOT NULL AND person_id = p.person_id
           GROUP BY source) s),
    '{}'::jsonb) AS known
FROM agent.fn_context_persons('career_planning') p
WHERE agent.fn_person_chat_id(p.person_id) IS NOT NULL
  -- Roter Faden Paket B: Job-Vorschlaege je Person (rem:on|off:score_jobs -> agent.reminder_prefs, Default aus)
  AND core.fn_reminder_allowed('score_jobs', p.person_id)
'@ $null

    # --- Loop persons (splitInBatches): EINE Person je Iteration -> die nachgelagerten $('Node').first()-Refs
    #     bleiben iterations-lokal korrekt. Jeder Terminal-Zweig kehrt zur Loop-Node zurueck. person_id + chat_id
    #     werden durch die Kette GEFAEDELT (nicht per loop-item-Lineage), weil der Record-Postgres-Node das Item ersetzt.
    $loop = Build-Loop 'Loop persons' @(-900, 0)
    $done = Build-NoOp 'Done' @(-680, -260)

    # Kriterien vorhanden? (mindestens eine Zielrolle) -> sonst diese Person ueberspringen (zurueck in den Loop).
    $ifCriteria = Build-If 'Have criteria?' @(-680, 0) `
        '={{ $json.planning && Array.isArray($json.planning.target_roles) && $json.planning.target_roles.length > 0 }}' 'true' 'equals' 'boolean'

    # --- EINE gemeinsame Query aus den Kriterien der AKTUELLEN Person (was/wo URL-encoded; umkreis default 50) ->
    #     je Quelle eine URL. v1: erste Zielrolle + erster Ort. Kontext (profile/preferences/planning/known/
    #     sources_enabled/person_id/chat_id) wird mitgefuehrt. Die Aggregator-URLs tragen KEINE Keys (die kommen
    #     aus der gebundenen Credential: Adzuna app_id/app_key als httpCustomAuth-qs; JSearch x-rapidapi-key Header).
    $buildQueryJs = @'
const plan = $json.planning || {};
const roles = Array.isArray(plan.target_roles) ? plan.target_roles : [];
const was = roles.length ? String(roles[0].title || '').trim() : '';
const locs = Array.isArray(plan.target_locations) ? plan.target_locations : [];
const wo = locs.length ? String(locs[0] || '').trim() : '';
const umkreis = Number(plan.search_radius_km) > 0 ? Math.round(Number(plan.search_radius_km)) : 50;
const enc = encodeURIComponent;

// Bundesagentur (keyless; X-API-Key oeffentliche Konstante am Node)
const baP = ['size=25', 'page=1'];
if (was) baP.push('was=' + enc(was));
if (wo) { baP.push('wo=' + enc(wo)); baP.push('umkreis=' + umkreis); }
const ba_url = 'https://rest.arbeitsagentur.de/jobboerse/jobsuche-service/pc/v6/jobs?' + baP.join('&');

// Adzuna DE (app_id/app_key aus der httpCustomAuth-Cred -> NICHT in der URL). distance = km.
const adzP = ['results_per_page=50', 'max_days_old=14', 'sort_by=date', 'content-type=application/json'];
if (was) adzP.push('what=' + enc(was));
if (wo) { adzP.push('where=' + enc(wo)); adzP.push('distance=' + umkreis); }
const adzuna_url = 'https://api.adzuna.com/v1/api/jobs/de/search/1?' + adzP.join('&');

// JSearch (Google-for-Jobs; x-rapidapi-key aus der httpHeaderAuth-Cred, Host-Header am Node). Ort in die Query.
const jsQuery = (was || 'Job') + (wo ? (' in ' + wo + ', Germany') : ', Germany');
const jsP = ['query=' + enc(jsQuery), 'country=de', 'language=de', 'page=1', 'num_pages=1', 'date_posted=week'];
const jsearch_url = 'https://jsearch.p.rapidapi.com/search?' + jsP.join('&');

return [{ json: { ba_url, adzuna_url, jsearch_url,
  profile: $json.profile || {}, preferences: $json.preferences || {}, planning: plan,
  threshold: $json.threshold, max_per_run: $json.max_per_run,
  known: $json.known || {}, sources_enabled: $json.sources_enabled || {},
  person_id: $json.person_id, chat_id: $json.chat_id } }];
'@
    $buildQuery = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildQueryJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-460, 0)
        id = (New-Id); name = 'Build query'
    }

    # --- Fetch BA (keyless, X-API-Key = oeffentliche Konstante, KEIN Credential). onError continue + retry.
    $fetchBa = [ordered]@{
        parameters = [ordered]@{
            method = 'GET'
            url = "={{ `$('Build query').first().json.ba_url }}"
            sendHeaders = $true
            headerParameters = [ordered]@{ parameters = @( [ordered]@{ name = 'X-API-Key'; value = 'jobboerse-jobsuche' } ) }
            options = [ordered]@{ timeout = 15000; response = [ordered]@{ response = [ordered]@{ responseFormat = 'json' } } }
        }
        type = 'n8n-nodes-base.httpRequest'; typeVersion = 4.4; position = @(-240, -160)
        id = (New-Id); name = 'Fetch BA'
        onError = 'continueRegularOutput'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 3000
    }

    # --- Fetch Adzuna (httpCustomAuth: app_id/app_key als qs aus der Cred). Fehlt der Key -> Cred-Fehler faellt in
    #     onError -> Quelle still uebersprungen (BA/JSearch laufen weiter). onError continue + retry.
    $fetchAdz = [ordered]@{
        parameters = [ordered]@{
            method = 'GET'
            url = "={{ `$('Build query').first().json.adzuna_url }}"
            authentication = 'genericCredentialType'
            genericAuthType = 'httpCustomAuth'
            options = [ordered]@{ timeout = 15000; response = [ordered]@{ response = [ordered]@{ responseFormat = 'json' } } }
        }
        type = 'n8n-nodes-base.httpRequest'; typeVersion = 4.4; position = @(-240, 0)
        id = (New-Id); name = 'Fetch Adzuna'
        onError = 'continueRegularOutput'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 3000
        credentials = @{ httpCustomAuth = $CRED_ADZUNA }
    }

    # --- Fetch JSearch (httpHeaderAuth: x-rapidapi-key aus der Cred; x-rapidapi-host nicht-geheim am Node).
    $fetchJs = [ordered]@{
        parameters = [ordered]@{
            method = 'GET'
            url = "={{ `$('Build query').first().json.jsearch_url }}"
            authentication = 'genericCredentialType'
            genericAuthType = 'httpHeaderAuth'
            sendHeaders = $true
            headerParameters = [ordered]@{ parameters = @( [ordered]@{ name = 'x-rapidapi-host'; value = 'jsearch.p.rapidapi.com' } ) }
            options = [ordered]@{ timeout = 15000; response = [ordered]@{ response = [ordered]@{ responseFormat = 'json' } } }
        }
        type = 'n8n-nodes-base.httpRequest'; typeVersion = 4.4; position = @(-240, 160)
        id = (New-Id); name = 'Fetch JSearch'
        onError = 'continueRegularOutput'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 3000
        credentials = @{ httpHeaderAuth = $CRED_JSEARCH }
    }

    # --- Normalize+Merge+Dedup: EIN Code-Node. Je Quelle EIGENER try/catch (eine Quelle mit Schema-Drift/Fehler
    #     killt die anderen NICHT) + defensive Shape-Pruefung -> normalisierte Posting-Form
    #     {source, board, external_id, title, employer, location, url, raw}. url VERBATIM aus dem Quell-Link
    #     (Adzuna redirect_url, JSearch job_apply_link — Aggregator-ToS + tote Self-URL vermeiden; BA konstruiert
    #     jobdetail/<refnr>). board: jsearch=job_publisher (immer), sonst NULL by design. Dedup je Quelle gegen ihren
    #     EIGENEN known-Set. sources_enabled: eine disabled Quelle wird ignoriert. Danach ephemerer Per-Run-Index i.
    $normalizeJs = @'
const bq = $('Build query').first().json;
const enabled = bq.sources_enabled || {};
const known = bq.known || {};
const knownSet = (src) => new Set((Array.isArray(known[src]) ? known[src] : []).map(String));
function fetchJson(node) { try { const it = $(node).first(); return (it && it.json) ? it.json : null; } catch (e) { return null; } }
const postings = [];

// --- Bundesagentur ---
if (enabled.bundesagentur !== false) {
  try {
    const resp = fetchJson('Fetch BA');
    const list = (resp && Array.isArray(resp.stellenangebote)) ? resp.stellenangebote : [];
    const kn = knownSet('bundesagentur');
    for (const j of list) {
      const eid = (j && j.refnr != null) ? String(j.refnr) : null;
      if (!eid || kn.has(eid)) continue;
      const ort = (j.arbeitsort && (j.arbeitsort.ort || j.arbeitsort.plz)) ? [j.arbeitsort.ort, j.arbeitsort.plz].filter(Boolean).join(' ') : null;
      postings.push({ source: 'bundesagentur', board: null, external_id: eid,
        title: String(j.titel || j.beruf || 'Stelle'),
        employer: j.arbeitgeber ? String(j.arbeitgeber) : null, location: ort,
        url: 'https://www.arbeitsagentur.de/jobsuche/jobdetail/' + encodeURIComponent(eid),
        raw: { entry: j.eintrittsdatum || null, published: j.aktuelleVeroeffentlichungsdatum || null, beruf: j.beruf || null } });
    }
  } catch (e) { /* BA -> skip */ }
}

// --- Adzuna (board NULL by design: Adzuna legt kein Original-Board offen) ---
if (enabled.adzuna !== false) {
  try {
    const resp = fetchJson('Fetch Adzuna');
    const list = (resp && Array.isArray(resp.results)) ? resp.results : [];
    const kn = knownSet('adzuna');
    for (const j of list) {
      const eid = (j && j.id != null) ? String(j.id) : null;
      if (!eid || kn.has(eid)) continue;
      postings.push({ source: 'adzuna', board: null, external_id: eid,
        title: String(j.title != null ? j.title : 'Stelle'),
        employer: (j.company && j.company.display_name) ? String(j.company.display_name) : null,
        location: (j.location && j.location.display_name) ? String(j.location.display_name) : null,
        url: j.redirect_url ? String(j.redirect_url) : null,
        raw: { created: j.created || null, salary_min: (j.salary_min != null ? j.salary_min : null), salary_max: (j.salary_max != null ? j.salary_max : null), category: (j.category && j.category.label) || null } });
    }
  } catch (e) { /* Adzuna -> skip, andere laufen weiter */ }
}

// --- JSearch (board = job_publisher, IMMER gesetzt: LinkedIn/Indeed/…) ---
if (enabled.jsearch !== false) {
  try {
    const resp = fetchJson('Fetch JSearch');
    const list = (resp && Array.isArray(resp.data)) ? resp.data : [];
    const kn = knownSet('jsearch');
    for (const j of list) {
      const eid = (j && j.job_id != null) ? String(j.job_id) : null;
      if (!eid || kn.has(eid)) continue;
      const ort = [j.job_city, j.job_country].filter(Boolean).join(', ') || null;
      postings.push({ source: 'jsearch', board: j.job_publisher ? String(j.job_publisher) : null, external_id: eid,
        title: String(j.job_title != null ? j.job_title : 'Stelle'),
        employer: j.employer_name ? String(j.employer_name) : null, location: ort,
        url: j.job_apply_link ? String(j.job_apply_link) : null,
        raw: { posted: j.job_posted_at || null, remote: (j.job_is_remote != null ? j.job_is_remote : null), etype: j.job_employment_type || null } });
    }
  } catch (e) { /* JSearch -> skip */ }
}

const indexed = postings.map((p, i) => Object.assign({ i }, p));
return [{ json: { postings: indexed,
  profile: bq.profile || {}, preferences: bq.preferences || {}, planning: bq.planning || {},
  threshold: bq.threshold, max_per_run: bq.max_per_run, person_id: bq.person_id, chat_id: bq.chat_id } }];
'@
    $normalize = [ordered]@{
        parameters = [ordered]@{ jsCode = $normalizeJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-20, 0)
        id = (New-Id); name = 'Normalize postings'
    }
    $ifNew = Build-If 'Any new?' @(200, 0) '={{ $json.postings.length > 0 }}' 'true' 'equals' 'boolean'

    # --- Gebatchter Cheap-Scorer: EIN Claude-Call (geteilter Baustein New-AnthropicMessagesNode, Denk-Tiefe
    #     niedrig) bewertet ALLE neuen Postings DIESER Person 1..4 gegen Profil + Praeferenzen + Planung. Antwort
    #     per Structured Output (output_config.format) als {scores:[{i,score,reasoning}]}. Echot den integer-Index i
    #     (kollisionsfrei ueber Quellen — external_id-Strings verschiedener Quellen koennten kollidieren).
    $sysText = 'You rate how well each job posting fits a candidate, for a job-change copilot. For EACH posting output an integer score from 1 to 4 (1 = poor fit, 2 = weak, 3 = good, 4 = excellent) and ONE short reasoning sentence, written in the language named in the user message (the candidate language). Weigh: the candidate current role, skills and experience (profile); the target roles, industries and locations (planning); and the learned likes/dislikes (preferences) - a disliked aspect or industry lowers the score, a preferred aspect raises it. Return one entry per posting in scores, using the exact integer index i of each posting.'
    $scoreSchema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
            scores = [ordered]@{
                type = 'array'
                items = [ordered]@{
                    type = 'object'
                    properties = [ordered]@{
                        i = [ordered]@{ type = 'integer' }
                        score = [ordered]@{ type = 'integer' }
                        reasoning = [ordered]@{ type = 'string' }
                    }
                    required = @('i', 'score', 'reasoning')
                    additionalProperties = $false
                }
            }
        }
        required = @('scores')
        additionalProperties = $false
    }
    $contentJs = "'Candidate profile: ' + JSON.stringify(`$json.profile || {}) + '\nTarget roles, industries and locations (planning): ' + JSON.stringify(`$json.planning || {}) + '\nLearned preferences (likes/dislikes from feedback): ' + JSON.stringify(`$json.preferences || {}) + '\nJob postings to score (each has an index i): ' + JSON.stringify(`$json.postings) + '\nCandidate language for the reasoning sentences: ' + (`$('Loop persons').first().json.language_label || 'en') + '\nScore each posting now.'"
    $score = New-AnthropicMessagesNode -Name 'Score postings' -Position @(420, 0) -ConfigModelKey 'job_scorer' -System $sysText `
        -ContentJs $contentJs -Effort low -JsonSchema $scoreSchema -TimeoutMs 120000

    # --- Scores zuruecksortieren (per Index i): ALLE gescort + recorded, surface = Top max_per_run >= Schwelle
    #     GLOBAL ueber ALLE Quellen + genau 1 Serendipity (hoechstes unter Schwelle). Fehlt ein Score -> Default 1.
    #     source/board/external_id/person_id/chat_id auf JEDES Posting-Item faedeln (Record liest sie aus $json;
    #     Send liest chat_id/board via $('Apply scores').item — der Record-Postgres-Node ersetzt $json durch sein Ergebnis).
    $applyJs = (Get-AnthropicResultJs) + @'
const r = $('Score postings').first().json;
const prep = $('Normalize postings').first().json;
const postings = prep.postings || [];
const threshold = Number(prep.threshold) || 3;
const maxPerRun = Number(prep.max_per_run) || 7;
let scores = [];
try {
  const res = anthropicText(r);
  const parsed = res.ok ? JSON.parse(stripFences(res.text)) : [];
  scores = Array.isArray(parsed) ? parsed : ((parsed && parsed.scores) || []);
} catch (e) { scores = []; }
const byIdx = {};
for (const s of (Array.isArray(scores) ? scores : [])) { if (s && s.i != null) byIdx[String(s.i)] = s; }
const scored = postings.map(p => {
  const s = byIdx[String(p.i)] || {};
  const sc = Number(s.score);
  return Object.assign({}, p, { score: (sc >= 1 && sc <= 4) ? Math.round(sc) : 1, score_reasoning: (s.reasoning ? String(s.reasoning) : null) });
});
const above = scored.filter(p => p.score >= threshold).sort((a, b) => b.score - a.score);
const surfaceSet = new Set(above.slice(0, maxPerRun).map(p => p.i));
const below = scored.filter(p => p.score < threshold).sort((a, b) => b.score - a.score);
const serenIdx = below.length ? below[0].i : null;
return scored.map(p => ({ json: {
  source: p.source, board: p.board,
  person_id: prep.person_id, chat_id: prep.chat_id,
  external_id: p.external_id, title: p.title, employer: p.employer, location: p.location, url: p.url,
  score: p.score, score_reasoning: p.score_reasoning,
  is_serendipity: (p.i === serenIdx),
  surface: surfaceSet.has(p.i) || (p.i === serenIdx),
  raw: p.raw || {}
} }));
'@
    $apply = [ordered]@{
        parameters = [ordered]@{ jsCode = $applyJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(640, 0)
        id = (New-Id); name = 'Apply scores'
    }

    # --- Je Posting upserten (career.fn_record_job_match, source/board/external_id + score + person_id TRUSTED CRON).
    #     Liefert job_match_id fuer die Karten-callback_data. Laeuft per-Item (n8n: ein Node, N Items -> N Aufrufe).
    $record = Build-Pg 'Record match' @(860, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'job_match_id')::bigint AS job_match_id, (r->>'created')::boolean AS created FROM career.fn_record_job_match(`$1::jsonb) AS r;" `
        ([ordered]@{
            source         = '$json.source'
            board          = '$json.board'
            external_id    = '$json.external_id'
            person_id      = '$json.person_id'
            title          = '$json.title'
            employer       = '$json.employer'
            location       = '$json.location'
            url            = '$json.url'
            score          = '$json.score'
            score_reasoning = '$json.score_reasoning'
            is_serendipity = '$json.is_serendipity'
            raw            = '$json.raw'
        })

    # Nur surface=true UND erfolgreich recorded -> Karte (Top-Treffer + Serendipity); der Rest ist recorded
    # (Advisor sieht ihn via read_job_matches). Das `Record match`.ok-Gate verhindert eine Karte mit job:up:null-Button.
    $ifSurface = Build-If 'Surface?' @(1080, 0) "={{ `$('Record match').item.json.ok === true && `$('Apply scores').item.json.surface === true }}" 'true' 'equals' 'boolean'

    # --- EINE Karte je Posting an die EIGENE chat_id der Person: Sub agent.career.sub_send_job_card (Textkatalog Phase C:
    #     Texte in der Sprache der Person, deterministisch testbar ueber den Harness). Je gesurftem Item ein Aufruf mit
    #     den Karten-Feldern (Apply scores) + der job_match_id (Record match) fuer die 👍/👎-callback_data.
    $cardId = Get-RequiredWorkflowId 'agent.career.sub_send_job_card' 'Build-CareerCronScoreJobs'
    $card = Build-CallWorkflow 'Send card' @(1300, 0) $cardId 'agent.career.sub_send_job_card' ([ordered]@{
        chat_id        = "={{ `$('Apply scores').item.json.chat_id }}"
        job_match_id   = "={{ `$('Record match').item.json.job_match_id }}"
        is_serendipity = "={{ `$('Apply scores').item.json.is_serendipity }}"
        score          = "={{ `$('Apply scores').item.json.score }}"
        title          = "={{ `$('Apply scores').item.json.title }}"
        employer       = "={{ `$('Apply scores').item.json.employer || '' }}"
        location       = "={{ `$('Apply scores').item.json.location || '' }}"
        board          = "={{ `$('Apply scores').item.json.board || '' }}"
        url            = "={{ `$('Apply scores').item.json.url || '' }}"
        reasoning      = "={{ `$('Apply scores').item.json.score_reasoning || '' }}"
    })

    # --- Stickies ---
    $stOverview = Build-Sticky 'Überblick' @(-1820, -420) `
        'Werktäglicher MULTI-SOURCE Job-Scan PRO PERSON (Bundesagentur + Adzuna + JSearch; Opt-in-Cron, Claude-Scorer)' `
        ('F9-Gate (career aktiv UND cron_enable.score_jobs=true = Konsolen-Notschalter für alle; JE PERSON schaltet rem:on|off:score_jobs, Roter Faden Paket B) -> Load model config (model.job_scorer bei JEDEM Lauf aus core.config; Wechsel: lifeagents config set model job_scorer <key>) -> Enumerate persons (agent.fn_context_persons(career_planning), nur Personen mit core.fn_reminder_allowed(score_jobs, person); je Person Suffix-Kontexte career_planning__/career_profile__/career_preferences__<pid> + eigene chat_id via agent.fn_person_chat_id; per-Quelle Enable-Flags sources_enabled + SOURCE-PARTITIONIERTER known-Set {source:[external_id]}; threshold/max_per_run aus core.config) -> Loop persons (splitInBatches) -> Have criteria? -> Build query (EINE gemeinsame Query Rolle/Ort -> je Quelle eine URL; die Aggregator-Keys stehen NUR in der Cred, nicht in der URL) -> Fetch BA (keyless) / Fetch Adzuna (httpCustomAuth) / Fetch JSearch (httpHeaderAuth), linear, jeder onError=continue+retry (fehlender Key -> Cred-Fehler fällt in onError -> Quelle still übersprungen) -> Normalize postings: je Quelle EIGENER try/catch, parse -> normalisierte Form, url VERBATIM aus dem Quell-Link, board (jsearch=job_publisher, sonst NULL), Dedup gegen den EIGENEN known-Set der Quelle, disabled -> ignoriert, merge + ephemerer Index i -> Score postings: EIN gebatchter Claude-Call (model.job_scorer, Denk-Tiefe niedrig, Structured Output {scores:[{i,score,reasoning}]}) bewertet ALLE neuen Postings DIESER Person 1..4, echot den Index i -> Apply scores -> Record match je Posting (career.fn_record_job_match, source/board/external_id, person_id TRUSTED CRON) -> Surface? (Top max_per_run >= Schwelle GLOBAL über alle Quellen + 1 Serendipity) -> Send card an die EIGENE chat_id (via <board> nur bei jsearch). ROLLE: Haupt-RW-Cred. PRIVACY: Profil/Präferenzen (PII) NUR in den Scorer (bezahlte Anthropic-API, kein Training auf Inhalten); die Aggregatoren bekommen NUR Rolle+Ort, kein PII.') 420 1100

    $stSources = Build-Sticky 'Multi-Source: 3 Quellen -> EIN Digest' @(-240, -320) `
        'Bundesagentur (keyless) + Adzuna (StepStone/DE) + JSearch (LinkedIn) -> Normalize merged + dedupt je Quelle' `
        'Drei feste Quell-Nodes (linear, jeder onError=continue+retry). Adzuna = httpCustomAuth (app_id/app_key als qs aus der Cred); JSearch = httpHeaderAuth (x-rapidapi-key aus der Cred, x-rapidapi-host am Node). Fehlt ein Key -> Cred-Fehler -> onError -> Quelle still übersprungen (BA läuft immer). Normalize: je Quelle EIGENER try/catch (eine kaputte Quelle killt die anderen NICHT); Dedup gegen den SOURCE-PARTITIONIERTEN known-Set (BA-refnr / Adzuna-id / JSearch-job_id = verschiedene Schlüsselräume -> ein source-blinder Set unterdrückte fälschlich echte Treffer). url je Quelle VERBATIM aus dem gelieferten Link (Adzuna redirect_url, JSearch job_apply_link — Aggregator-ToS; BA konstruiert jobdetail/<refnr>). board: NUR jsearch (job_publisher, IMMER); adzuna legt KEIN Board offen (NULL by design), BA/forwarded NULL. Per-Quelle abschaltbar via core.config career.job_source_<src> (Konsole; die Fetch läuft weiter, das Ergebnis wird in Normalize ignoriert — Quota-Skip-der-Call ist BACKLOG).' 380 640

    $stCap = Build-Sticky 'Cap = Karten-Drossel GLOBAL (kein Datenverlust)' @(640, -300) `
        'Apply scores: ALLE gescort + recorded; surface drosselt nur die Sends (Top max_per_run + 1 Serendipity über ALLE Quellen)' `
        'Der Scorer echot den ephemeren Per-Run-Index i (nicht external_id -> keine Cross-Quellen-Kollision im Mapping). Es werden ALLE neuen Postings via career.fn_record_job_match recorded (Dedup verhindert künftiges Re-Scoring; UPSERT-Key (source, external_id, person_id)). surface=true nur für die Top max_per_run (>= Schwelle) GLOBAL über alle Quellen + GENAU 1 Serendipity (höchstes UNTER der Schwelle). Überzählige >= Schwelle sind RECORDED (kein stiller Verlust) -> der Advisor zeigt sie via read_job_matches (career.fn_read_job_matches). Fehlt ein Score -> Default 1. source/board/external_id/person_id/chat_id werden durch die Kette gefädelt, weil der Record-Postgres-Node das Item ersetzt.' 340 620

    $stCard = Build-Sticky 'Treffer-Karte (Feedback-Loop, per-Person)' @(1300, -300) `
        'Send card = Sub agent.career.sub_send_job_card je Treffer an die EIGENE chat_id (Texte in der Sprache der Person)' `
        'Der Sub rendert die Karte (Textkatalog: Kopf, "via <board>" nur bei jsearch, Feedback-Hinweis, Abschalten-Knopf in der Sprache der Person; die Scorer-Begründung schreibt das Modell schon in dieser Sprache, language_label aus Enumerate persons). Buttons: 👍 -> job:up:<job_match_id>, 👎 -> job:down:<job_match_id> (dynamisch; der Orchestrator dispatcht den job:-Prefix generisch an career.fn_handle_job_feedback -> status interested/dismissed, Eigentümer-Check person_id=sender). Abschalten -> cron_off:score_jobs (statisch, cron_toggle_lint). chat_id = $(Apply scores).item.json.chat_id (per Person, NICHT __OWNER_CHAT_ID__). Der Karten-TEXT zeigt "🔗 via <board>" NUR wenn ein Board offengelegt ist (jsearch -> "via LinkedIn"); adzuna-Treffer (auch StepStone-Inhalte) tragen KEIN Board-Label (Adzuna verrät es nicht). Die optionale Freitext-Grund-Einladung steht im Karten-TEXT -> Advisor ordnet den Grund der zuletzt bewerteten Stelle zu -> set_career_preferences (HITL owner_only).' 340 640

    $nodes = @($trig, $gate, $ifEnabled, $off, $loadModel, $enumerate, $loop, $done, $ifCriteria, $buildQuery,
               $fetchBa, $fetchAdz, $fetchJs, $normalize, $ifNew, $score, $apply, $record, $ifSurface, $card,
               $stOverview, $stSources, $stCap, $stCard)

    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'   = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'        = @{ main = @(
            @( E 'Load model config' ),
            @( E 'Disabled' )
        ) }
        'Load model config' = @{ main = @( ,@( E 'Enumerate persons' ) ) }
        'Enumerate persons' = @{ main = @( ,@( E 'Loop persons' ) ) }
        'Loop persons'    = @{ main = @(
            @( E 'Done' ),            # main[0] = done (alle Personen verarbeitet)
            @( E 'Have criteria?' )   # main[1] = Loop-Body (aktuelle Person)
        ) }
        'Have criteria?'  = @{ main = @(
            @( E 'Build query' ),
            @( E 'Loop persons' )     # keine Zielrolle -> Person skippen, naechste
        ) }
        'Build query'     = @{ main = @( ,@( E 'Fetch BA' ) ) }
        'Fetch BA'        = @{ main = @( ,@( E 'Fetch Adzuna' ) ) }
        'Fetch Adzuna'    = @{ main = @( ,@( E 'Fetch JSearch' ) ) }
        'Fetch JSearch'   = @{ main = @( ,@( E 'Normalize postings' ) ) }
        'Normalize postings' = @{ main = @( ,@( E 'Any new?' ) ) }
        'Any new?'        = @{ main = @(
            @( E 'Score postings' ),
            @( E 'Loop persons' )     # nichts Neues fuer diese Person -> naechste
        ) }
        'Score postings'  = @{ main = @( ,@( E 'Apply scores' ) ) }
        'Apply scores'    = @{ main = @( ,@( E 'Record match' ) ) }
        'Record match'    = @{ main = @( ,@( E 'Surface?' ) ) }
        'Surface?'        = @{ main = @(
            @( E 'Send card' ),
            @( E 'Loop persons' )     # recorded, nicht gesurft -> naechste
        ) }
        'Send card'       = @{ main = @( ,@( E 'Loop persons' ) ) }
    }
    return Build-Workflow 'agent.career.cron_score_jobs' $nodes $conns
}
