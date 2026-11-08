-- ============================================================
-- fn_advisor_save_section (ATOMIC WRITE — Interview-Sektion in den Draft-Plan)
--   Upsertet EINE Interview-Sektion in interview_state des Draft-Plans der Domain;
--   existiert kein Draft, wird er angelegt (version = MAX(version)+1 der Domain —
--   die DB zaehlt, nicht das LLM). Aufgerufen vom HITL-gegateten Tool
--   agent.tool_save_plan_section (domain ist dort FIXER Binding-Input, nie $fromAI).
--   P0c PERSON-SCOPE (Paritaet fn_set_context_facts): Plan-Schluessel = (domain, person_id). household-Domains
--   (finance/financial_planning) -> person_id NULL (ein Haushalts-Plan); per_user (career/career_planning,
--   core.context_scopes) -> person_id = der Sender selbst (own_user_only), aus der chat_id via fn_resolve_sender
--   (NIE LLM); unaufgeloester Sender bei per_user -> {ok:false}. Permission via fn_check_write_permission
--   (owner_only delegiert byte-gleich an fn_sender_is_member -> finance unveraendert).
--   Eingabe jsonb: domain (Pflicht — Phase B: kein 'finance'-Default mehr; ein leeres domain landete vorher
--     still im Finanzplan), chat_id (Identitaet), section_key (Pflicht, freier Text),
--     section_content (Pflicht, Klartext der Sektion bzw. des Themas in der Sprache der Antwort des Beraters; die Karte zeigt ihn ganz),
--     topic (optional, 1..60 Zeichen nach btrim): Thema innerhalb des Abschnitts. Gesetzt -> Upsert in
--       interview_state[key].topics[] als {topic, content, data, saved_at} (Reihenfolge der ersten Speicherung; gleiche
--       Bezeichnung ohne Gross-/Kleinschreibung ersetzt das Thema mitsamt data). Abschnitts-data = legacy_data || Themen-data
--       (derselbe Top-Block in zwei Themen -> code block_in_two_topics). Ein Alt-content des Abschnitts wandert beim ersten
--       Themen-Save nach legacy_content (Alt-data nach legacy_data) und die Karte bekommt die Notiz core.hitl.plan_legacy_replaced.
--       Ohne topic: content/data/saved_at wie bisher gesetzt, topics und legacy_* bleiben.
--     Laengen-Gesetz: core.config <paket>.advisor.topic_max_chars (Paket der Domain aus core.advisors, E2E-Domain -> echte
--       Domain). Gesetzt -> ohne topic code topic_required, Text laenger -> code topic_too_long {max, length}; ohne Wert keine Regel.
--     section_data (optional, leerer String = nicht angegeben; jsonb-Objekt ODER JSON-String — String wird geparst; relative Zeitangaben in
--       *_date/since loest core.fn_resolve_fact_dates auf, jedes Top-Level-Objekt bekommt as_of = heute von der fn),
--     plan_name (optional, nur bei Draft-Neuanlage),
--     handoff_tasks (optional, Array ODER JSON-String, leerer String = keine): im Abschnitt vereinbarte Eintraege fuer den
--       Buchhalter, je {kind: savings_goal|savings_plan|recurring_payment|recurring_transfer|other, payload (Objekt, rohe
--       Nutzerwerte, optional), text (Alltags-Satz, 1..300 Zeichen)}. Angegeben (auch '[]') ersetzt es die OFFENEN Aufgaben:
--       mit topic die des Themas plus die themenlosen des Abschnitts, ohne topic alle des Abschnitts; weggelassen bleiben sie
--       unveraendert; working/done/cancelled bleiben immer. Person = Sender (core.fn_handoff_person), package = Paket der
--       Plan-Domain (core.advisors, E2E-Domain -> echte Domain).
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, plan_id, version, status:'draft',
--     draft_created, sections, section_count, topics, topic_replaced, handoff_task_count, card_lines} (Post-State: welche
--     Sektionen der Draft JETZT hat; topics = Themen-Bezeichnungen des Abschnitts in Reihenfolge; topic_replaced und
--     draft_created = DB-entschieden; card_lines = Notiz core.hitl.plan_legacy_replaced beim Abloesen eines Alt-Texts und je
--     Aufgabe eine Kartenzeile core.hitl.handoff_planned {text}).
--   Korrigierbar (fehlendes domain, leerer section_key/-content, topic ueber 60 Zeichen, topic_required, topic_too_long,
--     block_in_two_topics, invalides section_data-JSON, ungueltige handoff_tasks, Person nicht aufloesbar) -> {ok:false, reason
--     [, code]} OHNE Write (kein RAISE -> kein Owner-Alert).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_advisor_save_section(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_domain  TEXT := NULLIF(trim(COALESCE(p->>'domain', '')), '');
    v_key     TEXT := trim(COALESCE(p->>'section_key', ''));
    v_content TEXT := COALESCE(p->>'section_content', '');
    v_data    JSONB;
    v_plan_id INT;
    v_version INT;
    v_created BOOLEAN := false;
    v_state   JSONB;
    v_keys    JSONB;
    -- P0c Person-Scope (Paritaet fn_set_context_facts): v_ctx = Plan-Context der Domain (core.advisors),
    -- v_scope/v_perm aus core.context_scopes; per_user -> v_pid (Sender selbst) aus der nicht-spoofbaren chat_id.
    v_ctx     TEXT;
    v_scope   TEXT;
    v_perm    TEXT;
    v_pid     TEXT;
    v_err     TEXT;
    v_tasks   JSONB := '[]'::jsonb;
    v_given   BOOLEAN := false;   -- handoff_tasks angegeben (auch leer '[]') -> ersetzt; weggelassen -> offene bleiben
    v_hpid    TEXT;
    v_pkg     TEXT;
    v_bad     TEXT;
    v_topic   TEXT := NULLIF(btrim(COALESCE(p->>'topic', '')), '');
    v_max     INT;
    v_sec     JSONB;               -- bisheriges Abschnitts-Objekt
    v_topics  JSONB;
    v_idx     INT;                 -- 0-basierter Index des ersetzten Themas, NULL = neues Thema
    v_legacy  BOOLEAN := false;    -- dieser Save loest einen Alt-content ab -> Kartennotiz
BEGIN
    IF v_domain IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'domain is required (the advisor tool binding passes it as a fixed input)');
    END IF;
    -- P0c: Plan-Context der Domain (Domain->Context-Map aus der Registry; Fallback v_domain||'_planning' fuer
    -- E2E-Sentinel-Domains ohne advisors-Zeile) -> dessen scope/write_permission steuert household vs per_user.
    v_ctx := COALESCE((SELECT plan_context FROM core.advisors WHERE domain = v_domain), v_domain || '_planning');
    SELECT cs.scope, cs.write_permission INTO v_scope, v_perm
    FROM core.context_scopes cs WHERE cs.context_name = v_ctx;
    v_scope := COALESCE(v_scope, 'household');
    v_perm  := COALESCE(v_perm, 'owner_only');

    -- per_user -> Ziel-Person == Sender (own_user_only), aus der chat_id (Numerik-Guard, NIE LLM).
    IF v_scope = 'per_user' AND p->>'chat_id' ~ '^[0-9]+$' THEN
        v_pid := agent.fn_resolve_sender((p->>'chat_id')::bigint) ->> 'person_id';
    END IF;
    -- per_user FAIL-CLOSED (das echte Gate fuer unaufgeloeste Sender, VOR Permission & Write).
    IF v_scope = 'per_user' AND v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'cannot resolve person for per-user plan');
    END IF;

    -- WS-5b/P0c: Schreib-Permission generisch aus der Registry (ersetzt den fn_sender_is_member-Hardcode;
    -- financial_planning->owner_only delegiert byte-gleich an fn_sender_is_member, career_planning->own_user_only).
    -- Identitaet aus der chat_id, NIE LLM. {ok:false} VOR jedem Write (RAISE-frei -> kein Owner-Alert).
    v_err := agent.fn_check_write_permission(v_perm, p->>'chat_id', v_pid);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_err);
    END IF;

    IF v_key = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'section_key must be non-empty');
    END IF;
    IF trim(v_content) = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'section_content must be non-empty');
    END IF;
    IF length(v_topic) > 60 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'topic_label_too_long',
            'reason', 'topic must be a short label of at most 60 characters');
    END IF;

    -- Paket der Plan-Domain (E2E-Domain -> echte Domain): Lifecycle-Owner der Aufgaben und Quelle des Laengen-Gesetzes.
    v_pkg := COALESCE((SELECT a.package FROM core.advisors a WHERE a.domain = regexp_replace(v_domain, '^__e2e_(.+)__$', '\1')), 'core');
    v_max := NULLIF(substring(core.fn_config_get(v_pkg, 'advisor', 'topic_max_chars') FROM '^\s*(\d+)\s*$'), '')::int;
    IF v_max IS NOT NULL AND v_topic IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'topic_required',
            'reason', 'topic is required: save this section topic by topic, one short topic label per save');
    END IF;
    IF v_max IS NOT NULL AND length(v_content) > v_max THEN
        RETURN jsonb_build_object('ok', false, 'code', 'topic_too_long', 'max', v_max, 'length', length(v_content),
            'reason', format('section_content has %s characters, at most %s per topic: split it into smaller topics', length(v_content), v_max));
    END IF;

    -- section_data: jsonb-Objekt direkt; JSON-String parsen (LLM-Output -> Parse-Fehler sind
    -- KORRIGIERBAR, kein RAISE). Leerer String = nicht angegeben: das Tool-Binding liefert ihn beim Weglassen.
    IF p ? 'section_data' AND jsonb_typeof(p->'section_data') IS DISTINCT FROM 'null'
       AND btrim(COALESCE(p->>'section_data', '')) <> '' THEN
        IF jsonb_typeof(p->'section_data') = 'string' THEN
            BEGIN
                v_data := (p->>'section_data')::jsonb;
            EXCEPTION WHEN OTHERS THEN
                RETURN jsonb_build_object('ok', false,
                    'reason', 'section_data is not valid JSON: ' || left(p->>'section_data', 120));
            END;
        ELSE
            v_data := p->'section_data';
        END IF;
    END IF;

    -- handoff_tasks: Array oder JSON-String (Tool-Binding liefert Strings); jede Zeile pruefen, bevor irgendetwas schreibt
    -- (die Tabellen-CHECKs sind der Backstop, ihr RAISE kaeme als Owner-Alert statt als Rueckfrage).
    IF p ? 'handoff_tasks' AND jsonb_typeof(p->'handoff_tasks') IS DISTINCT FROM 'null'
       AND btrim(COALESCE(p->>'handoff_tasks', '')) <> '' THEN
        v_given := true;
        IF jsonb_typeof(p->'handoff_tasks') = 'string' THEN
            BEGIN
                v_tasks := (p->>'handoff_tasks')::jsonb;
            EXCEPTION WHEN OTHERS THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'handoff_tasks is not valid JSON: ' || left(p->>'handoff_tasks', 120));
            END;
        ELSE
            v_tasks := p->'handoff_tasks';
        END IF;
        IF jsonb_typeof(v_tasks) IS DISTINCT FROM 'array' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'handoff_tasks must be a JSON array of {kind, payload, text}');
        END IF;
        SELECT string_agg(format('#%s: %s', i, why), '; ') INTO v_bad
        FROM (
            SELECT i, CASE
                WHEN jsonb_typeof(t) IS DISTINCT FROM 'object' THEN 'not an object'
                WHEN COALESCE(t->>'kind', '') NOT IN ('savings_goal', 'savings_plan', 'recurring_payment', 'recurring_transfer', 'other')
                    THEN 'kind must be savings_goal|savings_plan|recurring_payment|recurring_transfer|other'
                WHEN btrim(COALESCE(t->>'text', '')) = '' THEN 'text is empty'
                WHEN length(t->>'text') > 300 THEN 'text is longer than 300 characters'
                WHEN t ? 'payload' AND jsonb_typeof(t->'payload') NOT IN ('object', 'null') THEN 'payload must be a JSON object'
            END AS why
            FROM jsonb_array_elements(v_tasks) WITH ORDINALITY AS x(t, i)
        ) c WHERE why IS NOT NULL;
        IF v_bad IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'handoff_tasks rejected: ' || v_bad);
        END IF;
    END IF;
    v_hpid := core.fn_handoff_person(p->>'chat_id');
    IF jsonb_array_length(v_tasks) > 0 AND v_hpid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'cannot resolve the person for the handoff tasks');
    END IF;

    -- WP3: relative Zeitangaben (*_date / since) rechnet die DB; as_of jedes Top-Level-OBJEKT-Blocks stempelt die fn
    -- (Provenienz-Stempel: "Stand der Erhebung" = Tag des Sektions-Saves; ein vom LLM mitgeschicktes as_of zaehlt nicht).
    IF jsonb_typeof(v_data) = 'object' THEN
        v_data := core.fn_resolve_fact_dates(v_data);
        SELECT COALESCE(jsonb_object_agg(k, CASE WHEN jsonb_typeof(v) = 'object'
                                                 THEN v || jsonb_build_object('as_of', to_char(core.fn_today(), 'YYYY-MM-DD'))
                                                 ELSE v END), '{}'::jsonb)
          INTO v_data
          FROM jsonb_each(v_data) AS x(k, v);
    END IF;

    -- Draft der (Domain, Person) sperren (genau einer moeglich — Partial-UNIQUE (domain, person_id)) oder anlegen.
    -- person_id IS NOT DISTINCT FROM v_pid: household (v_pid NULL) trifft die NULL-Zeilen, per_user die Person.
    SELECT id, version, interview_state INTO v_plan_id, v_version, v_state
    FROM agent.advisor_plans
    WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_pid AND status = 'draft'
    FOR UPDATE;

    IF NOT FOUND THEN
        SELECT COALESCE(MAX(version), 0) + 1 INTO v_version
        FROM agent.advisor_plans WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_pid;

        INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
        VALUES (
            v_domain, v_pid,
            COALESCE(NULLIF(trim(p->>'plan_name'), ''), initcap(v_domain) || ' Plan v' || v_version),
            'draft',
            v_version
        )
        RETURNING id, interview_state INTO v_plan_id, v_state;
        v_created := true;
    END IF;

    v_sec := CASE WHEN jsonb_typeof(v_state->v_key) = 'object' THEN v_state->v_key ELSE '{}'::jsonb END;
    IF v_topic IS NULL THEN
        -- Abschnitt als Ganzes (Key ueberschreiben = bewusste Korrektur des Interviews); Themen und Alt-Text bleiben.
        v_sec := (v_sec - 'content' - 'data' - 'saved_at')
              || jsonb_strip_nulls(jsonb_build_object('content', v_content, 'data', v_data, 'saved_at', now()));
    ELSE
        v_topics := CASE WHEN jsonb_typeof(v_sec->'topics') = 'array' THEN v_sec->'topics' ELSE '[]'::jsonb END;
        SELECT (i - 1)::int INTO v_idx FROM jsonb_array_elements(v_topics) WITH ORDINALITY AS x(t, i)
         WHERE lower(btrim(t->>'topic')) = lower(v_topic) LIMIT 1;
        -- Ein Top-Block gehoert genau einem Thema (der Merge zur Abschnitts-data verloere sonst still eine Haelfte).
        IF jsonb_typeof(v_data) = 'object' THEN
            SELECT string_agg(DISTINCT k, ', ') INTO v_bad
              FROM jsonb_array_elements(v_topics) WITH ORDINALITY AS x(t, i), jsonb_object_keys(v_data) AS k
             WHERE (i - 1) IS DISTINCT FROM v_idx AND jsonb_typeof(t->'data') = 'object' AND t->'data' ? k;
            IF v_bad IS NOT NULL THEN
                RETURN jsonb_build_object('ok', false, 'code', 'block_in_two_topics',
                    'reason', format('facts block "%s" already belongs to another topic of this section: send it with that topic', v_bad));
            END IF;
        END IF;
        IF v_sec ? 'content' THEN
            v_legacy := true;
            v_sec := (v_sec - 'content')
                  || jsonb_build_object('legacy_content', concat_ws(E'\n\n', v_sec->>'legacy_content', v_sec->>'content'));
            IF jsonb_typeof(v_sec->'data') = 'object' THEN
                v_sec := v_sec || jsonb_build_object('legacy_data', COALESCE(v_sec->'legacy_data', '{}'::jsonb) || (v_sec->'data'));
            END IF;
        END IF;
        -- Ein Block, den ein Thema sendet, gehoert ab jetzt dem Thema: aus legacy_data entfernen, sonst kaeme er zurueck,
        -- sobald das Thema ihn wieder weglaesst. Nie von einem Thema gesendete Alt-Bloecke bleiben als Rueckfall.
        IF jsonb_typeof(v_data) = 'object' AND jsonb_typeof(v_sec->'legacy_data') = 'object' THEN
            v_sec := v_sec || jsonb_build_object('legacy_data',
                (v_sec->'legacy_data') - ARRAY(SELECT jsonb_object_keys(v_data)));
        END IF;
        IF v_idx IS NULL THEN
            v_topics := v_topics || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'topic', v_topic, 'content', v_content, 'data', v_data, 'saved_at', now())));
        ELSE
            v_topics := jsonb_set(v_topics, ARRAY[v_idx::text], jsonb_strip_nulls(jsonb_build_object(
                'topic', v_topic, 'content', v_content, 'data', v_data, 'saved_at', now())));
        END IF;
        -- Abschnitts-data abgeleitet (Publish, Plan-Luecken und Review lesen <key>.data): Alt-Bloecke, die ein Thema
        -- ueberschreibt, weichen dem Thema; data schreibt nur diese fn.
        v_data := COALESCE(v_sec->'legacy_data', '{}'::jsonb)
               || COALESCE((SELECT jsonb_object_agg(e.key, e.value)
                              FROM jsonb_array_elements(v_topics) AS x(t), jsonb_each(t->'data') AS e
                             WHERE jsonb_typeof(t->'data') = 'object'), '{}'::jsonb);
        v_sec := (v_sec - 'data' - 'topics')
              || jsonb_build_object('topics', v_topics, 'saved_at', now())
              || CASE WHEN v_data = '{}'::jsonb THEN '{}'::jsonb ELSE jsonb_build_object('data', v_data) END;
    END IF;
    v_state := jsonb_set(v_state, ARRAY[v_key], v_sec, true);

    UPDATE agent.advisor_plans SET interview_state = v_state WHERE id = v_plan_id;

    -- Vereinbarte Aufgaben: nur wenn angegeben die offenen ersetzen (beanspruchte und geschlossene bleiben). Mit Thema die
    -- des Themas plus die themenlosen des Abschnitts (vor den Themen vereinbart; das Thema traegt jetzt die volle Liste).
    -- Weggelassen = unveraendert: eine Prosa-Korrektur ohne den optionalen Parameter darf nichts Vereinbartes loeschen.
    IF v_given THEN
        DELETE FROM agent.handoff_tasks
         WHERE domain = v_domain AND section_key = v_key AND status = 'open' AND person_id IS NOT DISTINCT FROM v_hpid
           AND (v_topic IS NULL OR topic IS NULL OR lower(topic) = lower(v_topic));
    END IF;
    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, payload, text)
    SELECT v_domain, v_pkg, v_hpid, v_key, v_topic, t->>'kind', COALESCE(NULLIF(t->'payload', 'null'::jsonb), '{}'::jsonb), btrim(t->>'text')
    FROM jsonb_array_elements(v_tasks) WITH ORDINALITY AS x(t, i) ORDER BY i;

    SELECT COALESCE(jsonb_agg(k ORDER BY k), '[]'::jsonb) INTO v_keys
    FROM jsonb_object_keys(v_state) AS k;

    RETURN jsonb_build_object(
        'ok', true,
        'plan_id', v_plan_id,
        'version', v_version,
        'status', 'draft',
        'draft_created', v_created,
        'sections', v_keys,
        'section_count', jsonb_array_length(v_keys),
        'topics', COALESCE((SELECT jsonb_agg(t->'topic' ORDER BY i)
                              FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_sec->'topics') = 'array' THEN v_sec->'topics' ELSE '[]'::jsonb END)
                                   WITH ORDINALITY AS x(t, i)), '[]'::jsonb),
        'topic_replaced', v_idx IS NOT NULL,
        'handoff_task_count', jsonb_array_length(v_tasks),
        'card_lines', CASE WHEN v_legacy THEN jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.plan_legacy_replaced'))
                           ELSE '[]'::jsonb END
                   || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_planned',
                                    'params', jsonb_build_object('text', btrim(t->>'text'))) ORDER BY i)
                                FROM jsonb_array_elements(v_tasks) WITH ORDINALITY AS x(t, i)), '[]'::jsonb)
    );
END;
$$;
