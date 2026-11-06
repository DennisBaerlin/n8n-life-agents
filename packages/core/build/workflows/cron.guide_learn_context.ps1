#Requires -Version 5.1
# Definition agent.guide.cron_learn_context -> Build-CronGuideLearnContext. Dot-gesourct von build.ps1.
# OPT-IN Tages-Lern-Loop (Phase C): sichtet die juengste Owner-Chat-Historie und SCHLAEGT dauerhaft
# relevante Erkenntnisse als HITL-Kandidaten VOR. Hoechstes Risiko der Roadmap = Auto-Memory-Writes,
# darum die strukturelle Leitplanke: dieser Cron schreibt AUSSCHLIESSLICH guide_learn_candidates +
# guide_learn_watermark (via agent.fn_record_learn_candidates) und NIE agent.core_contexts (M1) - der
# einzige core_contexts-Schreibpfad ist die owner-gegatete Approve-fn (Per-Eintrag-Callback learn:ok).
#
# Ablauf: scheduleTrigger -> F9-Gate (fn_package_active(core) AND cron_enable.learn_context='true') ->
#   core.fn_collect_chat_since() (per-Tabelle id>Watermark, nur human, test%-Filter) -> kein Material? Ende
#   -> Standard-Model-Selector-Buendel (model.learn_context, runtime-einstellbar wie die Agenten, R2) ->
#   chainLlm-Extraktion (Rohwerte, keine gerechneten Werte) -> agent.fn_record_learn_candidates (atomar:
#   Denylist/Allowlist/NOOP/Dedup x3/Cap/Idempotenz + Watermark-Vorschub derselben Tx) -> bei new_pending>0
#   Intro-Karte (mit "Lernen aus"-Knopf) + je Kandidat eine Karte mit [Speichern]=learn:ok:<id>
#   [Verwerfen]=learn:no:<id]. Kein Send-and-Wait (asynchroner Nudge -> uebersehene Karte != Ablehnung).
# Privacy (operative Vorbedingung): die Extraktion laeuft ueber die bezahlte Anthropic-API (model.learn_context, Claude;
#   kein Training auf Kundeninhalten - Privacy-Hard-Rule fuer Finanzdaten) - wie Vision.
# Cron-Credential = Haupt-Owner-Credential (Build-Pg-Default = WRITE): sieht agent.*_chat_memory cross-schema
#   + schreibt guide_learn_*. errorWorkflow setzt Build-Workflow automatisch.
function Build-CronGuideLearnContext {

    # 1) Schedule (Platzhalter; der Installer setzt schedule.learn_context aus core.config ein)
    $trig = Build-ScheduleTrigger @(-1320, 0) -ScheduleKey 'learn_context'

    # 2) F9-Gate (DB entscheidet, fail-closed; Toggle: lifeagents config set cron_enable learn_context true)
    $gate = Build-Pg 'Cron enabled?' @(-1100, 0) `
        "=SELECT core.fn_package_active('core') AND COALESCE(core.fn_config_get('core','cron_enable','learn_context') = 'true', false) AS enabled" `
        $null
    $ifEnabled = Build-If 'Cron on?' @(-880, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-880, 200)

    # 3) Collect (read-only): rows (fuer das LLM) + watermarks (MAX id je Quelltabelle) + count.
    #    MATERIALIZED -> die STABLE Collect-fn laeuft EXAKT 1x (Muster Advisor-Cron); jsonb als ::text
    #    (n8n-Pg-Node-Quirk: jsonb robust ueber JSON.parse im Code-Node).
    $collectSql = @'
=WITH c AS MATERIALIZED (SELECT * FROM core.fn_collect_chat_since())
SELECT
  COALESCE(jsonb_agg(jsonb_build_object('agent_name', c.agent_name, 'source_id', c.source_id, 'content', c.content)
                     ORDER BY c.agent_name, c.source_id), '[]'::jsonb)::text AS rows,
  COALESCE((SELECT jsonb_agg(jsonb_build_object('agent_name', s.a, 'last_seen_id', s.m))
            FROM (SELECT c2.agent_name AS a, max(c2.source_id) AS m FROM c c2 GROUP BY c2.agent_name) s),
           '[]'::jsonb)::text AS watermarks,
  count(*)::int AS n,
  -- Install-UX-Phase 6: die erlaubten Ziel-Kontexte kommen aus DENSELBEN Guards wie der Schreibpfad
  -- (fact: core.fn_facts_context_allowed = family + household-Fakten-Kontexte AKTIVER Pakete; note:
  -- core.fn_note_context_allowed) — kein Paket-Literal im Prompt, kein Vorschlag fuer ein inaktives Paket.
  (SELECT string_agg(x.n, ', ' ORDER BY x.n) FROM (SELECT 'family' AS n UNION SELECT v.context_name FROM core.context_validators v WHERE core.fn_facts_context_allowed(v.context_name)) x) AS fact_contexts,
  (SELECT string_agg(cc.name, ', ' ORDER BY cc.name) FROM agent.core_contexts cc WHERE core.fn_note_context_allowed(cc.name)) AS note_contexts,
  -- Textkatalog Phase C: Karten-/Knopf-Texte + Owner-Sprache (fuer die rationale) — read-only, VOR jedem Write
  core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb(__LEARN_KEYS__)))::text AS ui
FROM c;
'@
    $collectSql = $collectSql.Replace('__LEARN_KEYS__', (Get-UiKeysSql @('core.learn.intro', 'core.learn.btn_off', 'core.learn.fact_new',
        'core.learn.fact_update', 'core.learn.note', 'core.learn.btn_save', 'core.learn.btn_discard')))
    $collect = Build-Pg 'Collect chat' @(-660, 0) $collectSql $null
    $ifMaterial = Build-If 'New material?' @(-440, 0) '={{ $json.n }}' '1' 'gte' 'number'
    $noMaterial = Build-NoOp 'No new chat' @(-440, 200)

    # 4) Modell-Config (speist den Standard-Selektor; runtime-einstellbar wie die Agenten, R2)
    $loadModel = New-ModelConfigNode -Position @(-220, 0) -Keys @( ,@('core', 'learn_context') )

    # 5) Extraktions-Prompt deterministisch bauen (Code) - Rohwerte, KEINE gerechneten Werte (R5-B/M2).
    $promptJs = @'
const rows = $('Collect chat').item.json.rows || '[]';
const factCtx = $('Collect chat').item.json.fact_contexts || 'family';
const noteCtx = $('Collect chat').item.json.note_contexts || 'family';
// rationale erscheint auf der Lern-Karte des Owners -> in seiner Sprache (Textkatalog Phase C); value bleibt verbatim
let ui = {};
try { ui = JSON.parse($('Collect chat').item.json.ui || '{}'); } catch (e) { ui = {}; }
const lang = ui.language_label || 'en';
const instr = [
  'You extract DURABLE, long-term-relevant facts and insights from a household\'s recent chat with their personal assistants (finances, career, estate planning and more), to build a private long-term memory.',
  'Input: a JSON array of recent USER messages, each { agent_name, source_id, content }.',
  'Emit ONE candidate per genuinely durable item worth remembering long-term. Two kinds:',
  '- target_kind "fact": a structured household fact for a known slot. context_name MUST be one of: ' + factCtx + ' ("family" = person identity / household; any other = the per-person facts profile of an installed package). Provide person_slug (the lowercase person id), field (e.g. birth_date, last_name, citizenship, language) and value = the RAW value the user stated, verbatim in the language the user used (never translated). Exception: field language = the code (__LANG_CODES__). NEVER a computed/derived value (no ages, calendar years, projections, nominal amounts) - only the raw fact.',
  '- target_kind "note": a richer insight that fits no fixed slot (plans, preferences, life events, intentions). context_name MUST be one of: ' + noteCtx + '. value = a short note (one sentence) in the language of the source message. For notes NEVER include computed or derived numbers.',
  'For EACH candidate copy agent_name and source_id VERBATIM from the source message it came from (so the same item is never relearned).',
  'Only emit clearly durable items - skip small talk, questions, transient details, and anything already obvious. If nothing is worth remembering, return [].',
  'Return ONLY a JSON array, no prose and no markdown code fences:',
  '[{ "target_kind": "fact|note", "context_name": "...", "person_slug": "...", "field": "...", "value": "...", "agent_name": "...", "source_id": 123, "rationale": "..." }]',
  'rationale = a short phrase in the language ' + lang + ': what you learned and from which message.'
].join('\n');
return [{ json: { prompt: instr + '\n\nRecent user messages (JSON):\n' + rows } }];
'@
    $buildPrompt = [ordered]@{
        parameters = [ordered]@{ jsCode = $promptJs.Replace('__LANG_CODES__', $LanguageCodes) }   # Sprachcodes aus dem Core-Manifest
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(0, 0)
        id = (New-Id); name = 'Build prompt'
    }

    # 6) Extraktion (chainLlm); onError continue -> LLM-Fehler => keine Kandidaten, Watermark laeuft trotzdem.
    $extract = [ordered]@{
        parameters = [ordered]@{ promptType = 'define'; text = '={{ $json.prompt }}' }
        type = '@n8n/n8n-nodes-langchain.chainLlm'; typeVersion = 1.7; position = @(220, 0)
        id = (New-Id); name = 'Extract candidates'
        onError = 'continueRegularOutput'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 2000
    }
    # Standard-Model-Selector-Buendel (je Chat-Modell ein Node + Selector), model.learn_context -> runtime-einstellbar (R2).
    $selector = New-ModelSelectorBundle -ConfigField 'model.learn_context' -ConfigNodeName 'Load model config' `
        -AgentNodeName 'Extract candidates' -SelectorPos @(220, 360) -ModelRowPos @(-120, 520) -Effort medium

    # 7) Payload bauen: LLM-JSON robust parsen + Watermarks aus Collect anhaengen (-> fn_record-Input).
    $payloadJs = @'
let raw = ($input.first().json && $input.first().json.text) || '';
raw = String(raw).replace(/^\s*```(?:json)?/i, '').replace(/```\s*$/i, '').trim();
let candidates = [];
try { const p = JSON.parse(raw); if (Array.isArray(p)) candidates = p; } catch (e) { candidates = []; }
let watermarks = [];
try { watermarks = JSON.parse($('Collect chat').item.json.watermarks || '[]'); } catch (e) { watermarks = []; }
return [{ json: { candidates: candidates, watermarks: watermarks } }];
'@
    $buildPayload = [ordered]@{
        parameters = [ordered]@{ jsCode = $payloadJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(440, 0)
        id = (New-Id); name = 'Build payload'
    }

    # 8) Atomar versionieren (Denylist/Allowlist/NOOP/Dedup x3/Cap/Idempotenz + Watermark-Vorschub).
    $record = Build-Pg 'Record candidates' @(660, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'new_pending')::int AS new_pending, (r->'inserted')::text AS inserted FROM agent.fn_record_learn_candidates(`$1::jsonb) AS r;" `
        ([ordered]@{
            candidates = "`$('Build payload').item.json.candidates"
            watermarks = "`$('Build payload').item.json.watermarks"
        })
    $ifPending = Build-If 'New pending?' @(880, 0) '={{ $json.new_pending }}' '1' 'gte' 'number'
    $nothingNew = Build-NoOp 'Nothing new' @(880, 200)

    # 9) Intro-Karte (einmal) mit karten-weitem "Lernen aus"-Knopf (cron_off:learn_context).
    # Texte aus 'Collect chat' (Owner-Sprache, Textkatalog Phase C).
    $UI = "JSON.parse(`$('Collect chat').first().json.ui || '{}').t"
    $sendIntro = New-TelegramInlineKeyboardSendNode 'Send intro' @(1100, 0) `
        (Get-UiTextExpr $UI 'core.learn.intro' @{ count = "`$('Record candidates').item.json.new_pending" }) `
        @( @{ Text = (Get-UiTextExpr $UI 'core.learn.btn_off'); Data = 'cron_off:learn_context' } )

    # 10) Je gespeichertem Kandidat eine Zeile bauen -> eigene Karte mit [Speichern]/[Verwerfen].
    $cardsJs = (Get-UiRenderLibJs) + @'
const ins = JSON.parse($('Record candidates').item.json.inserted || '[]');
let ui = {};
try { ui = JSON.parse($('Collect chat').first().json.ui || '{}'); } catch (e) { ui = {}; }
const { t, fill } = uiRender(ui);
const out = [];
for (const c of ins) {
  let line;
  if (c.target_kind === 'fact') {
    line = fill(t(c.kind === 'update' ? 'core.learn.fact_update' : 'core.learn.fact_new'),
      { context: c.context_name, person: c.person_slug, field: c.field, value: c.proposed_value });
  } else {
    line = fill(t('core.learn.note'), { context: c.context_name, value: c.proposed_value });
  }
  if (c.rationale) { line = line + '\n(' + c.rationale + ')'; }
  out.push({ json: { id: c.id, line: line, btn_save: t('core.learn.btn_save'), btn_discard: t('core.learn.btn_discard') } });
}
return out;
'@
    $buildCards = [ordered]@{
        parameters = [ordered]@{ jsCode = $cardsJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(1320, 0)
        id = (New-Id); name = 'Build cards'
    }
    $sendCard = New-TelegramInlineKeyboardSendNode 'Send card' @(1540, 0) `
        "={{ `$json.line }}" `
        @(
            @{ Text = "={{ `$json.btn_save }}"; Data = "={{ 'learn:ok:' + `$json.id }}" }
            @{ Text = "={{ `$json.btn_discard }}"; Data = "={{ 'learn:no:' + `$json.id }}" }
        )

    # --- Stickies (Pflicht: Ablauf + off-canvas fn-Logik + M1 + Privacy sichtbar machen) ---
    $stOverview = Build-Sticky 'Überblick' @(-1360, -420) `
        'Opt-in Tages-Lern-Loop (Phase C): schlägt nur vor, schreibt NIE core_contexts (M1)' `
        ('Sichtet täglich (schedule.learn_context) die jüngste Owner-Chat-Historie und SCHLÄGT dauerhaft relevante Erkenntnisse als Kandidaten VOR. STRUKTURELLE Leitplanke gegen das Auto-Memory-Risiko: dieser Cron schreibt AUSSCHLIESSLICH agent.guide_learn_candidates + guide_learn_watermark (via agent.fn_record_learn_candidates) und NIE agent.core_contexts (M1, lint-erzwungen). Der EINZIGE core_contexts-Schreibpfad ist die owner-gegatete Approve-fn (Orchestrator-Callback learn:ok:<id>). Opt-in: cron_enable.learn_context default false; aktiviert am Onboarding-Ende ([Lernen aktivieren]) oder per Konsole. PRIVACY: die Extraktion läuft über die bezahlte Anthropic-API (model.learn_context, Claude) -> Privacy-Hard-Rule erfüllt (kein Training auf Kundeninhalten, Finanzdaten).') 360 760 'Lern-Loop'

    $stGate = Build-Sticky 'Doc F9-Gate' @(-1120, -210) `
        'Opt-in F9-Gate (fail-closed)' `
        ('core.fn_package_active(core) AND core.fn_config_get(core,cron_enable,learn_context)=true. Fehlende Zeile -> NULL -> COALESCE false (fail-closed). Toggle ohne Rebuild: lifeagents config set cron_enable learn_context true, oder der "Lernen aus"-Knopf an der Karte (cron_off:learn_context -> Orchestrator-Callback -> core.fn_set_cron_enable).') 220 520 'Ablauf'

    $stCollect = Build-Sticky 'Doc Collect' @(-700, -210) `
        'core.fn_collect_chat_since (off-canvas) + Watermark' `
        ('Liefert je Quelltabelle (ALLE agent.*_chat_memory ausser orchestrator = Duplikat-Quelle; dynamisch, ein neuer Paket-Agent dockt ohne Edit an) die NEUEN Owner-Nachrichten: id>guide_learn_watermark.last_seen_id, nur message type=human + nicht-leerer data.content, NUR die Session des Owners (Owner ungepairt -> nichts, fail-closed; Mitglieder- und Harness-Sessions raus). Fehlende Watermark = 0 (eine neue Agent-Tabelle zählt ab ihrem ersten Gespräch); die einmalige Startmarke der mit Phase B neu hinzugekommenen Quellen setzt core:V023 (keine Alt-Historie ans Modell). New material? prüft count -> kein neues Material -> Ende (kein LLM-Cost). Der Watermark-Vorschub passiert NICHT hier, sondern atomar in fn_record_learn_candidates (derselben Tx wie der Insert -> at-most-once-lossy).') 360 520 'Ablauf'

    $stRecord = Build-Sticky 'Doc Record' @(560, -300) `
        'agent.fn_record_learn_candidates (off-canvas, EINE Tx)' `
        ('Das LLM liefert nur Rohwerte; slot_key/kind/expires_at leitet die DB ab. Pro Kandidat: (a) fact -> Kontext-Prüfung core.fn_facts_context_allowed (family + household-Fakten-Kontexte AKTIVER Pakete; dieselbe Liste bekommt das LLM schon im Prompt, Collect chat) + Denylist-Vorfilter (kanonische fn_validate_household_facts -> abgeleitete Felder raus); note -> Knowledge-Allowlist core.fn_note_context_allowed (managed_by=agent + kuratierte Liste). (b) NOOP vs gespeicherte facts / "## Gelernt"-Substring. (c) Dedup x3: in-batch, vs pending, vs kürzlich rejected (<expiry_days = durable Rejection-Memory). (d) Cap LIMIT learn_context.daily_cap des Kalendertags (Prio update>new). (e) Insert ON CONFLICT (agent,source,slot) DO NOTHING (Idempotenz). (f) Watermark GREATEST je agent_name. pg_advisory_xact_lock serialisiert Doppelläufe.') 360 700 'DB-Automatik'

    $stCard = Build-Sticky 'Doc Karten' @(1080, -300) `
        'Per-Eintrag-HITL (kein Send-and-Wait)' `
        ('new_pending>0 -> EINE Intro-Karte mit karten-weitem [Lernen aus]=cron_off:learn_context, dann je gespeichertem Kandidat (fn-Rückgabe inserted[]) eine Karte mit [Speichern]=learn:ok:<id> [Verwerfen]=learn:no:<id>. Die Callbacks löst der Orchestrator (deterministisch, owner_only) -> learn:ok dispatcht nach target_kind (fact->fn_set_context_facts | note->core.fn_append_context_note). ASYNCHRONER Nudge: KEIN Send-and-Wait -> eine übersehene Karte ist KEINE Ablehnung; Kandidaten bleiben pending bis expires_at.') 360 600 'Ablauf'

    $nodes = @(
        $trig, $gate, $ifEnabled, $off, $collect, $ifMaterial, $noMaterial,
        $loadModel, $buildPrompt, $extract, $buildPayload, $record, $ifPending, $nothingNew,
        $sendIntro, $buildCards, $sendCard,
        $stOverview, $stGate, $stCollect, $stRecord, $stCard
    ) + $selector.Nodes

    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Collect chat' ),
            @( E 'Disabled' )
        ) }
        'Collect chat'                = @{ main = @( ,@( E 'New material?' ) ) }
        'New material?'               = @{ main = @(
            @( E 'Load model config' ),
            @( E 'No new chat' )
        ) }
        'Load model config'           = @{ main = @( ,@( E 'Build prompt' ) ) }
        'Build prompt'                = @{ main = @( ,@( E 'Extract candidates' ) ) }
        'Extract candidates'          = @{ main = @( ,@( E 'Build payload' ) ) }
        'Build payload'               = @{ main = @( ,@( E 'Record candidates' ) ) }
        'Record candidates'           = @{ main = @( ,@( E 'New pending?' ) ) }
        'New pending?'                = @{ main = @(
            @( E 'Send intro' ),
            @( E 'Nothing new' )
        ) }
        'Send intro'                  = @{ main = @( ,@( E 'Build cards' ) ) }
        'Build cards'                 = @{ main = @( ,@( E 'Send card' ) ) }
    }
    foreach ($k in $selector.Connections.Keys) { $conns[$k] = $selector.Connections[$k] }

    return Build-Workflow 'agent.guide.cron_learn_context' $nodes $conns
}
