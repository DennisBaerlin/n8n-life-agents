-- ============================================================
-- fn_advisor_save_section (ATOMIC WRITE — Interview-Sektion in den Draft-Plan)
--   Upsertet eine Interview-Sektion in interview_state des Draft-Plans der Domain;
--   existiert kein Draft, wird er angelegt (version = MAX(version)+1 der Domain —
--   die DB zaehlt, nicht das LLM). Aufgerufen vom HITL-gegateten Tool
--   agent.tool_save_plan_section (domain ist dort fixer Binding-Input, nie $fromAI).
--   Person-Scope (Paritaet fn_set_context_facts): Plan-Schluessel = (domain, person_id). household-Domains
--   (finance/financial_planning) -> person_id NULL (ein Haushalts-Plan); per_user (career/career_planning,
--   core.context_scopes) -> person_id = der Sender selbst (own_user_only), aus der chat_id via fn_resolve_sender
--   (nie LLM); unaufgeloester Sender bei per_user -> {ok:false}. Permission via fn_check_write_permission
--   (owner_only delegiert an fn_sender_is_member).
--   Eingabe jsonb: domain (Pflicht, kein Default; ein leeres domain landete sonst still im Finanzplan), chat_id (Identitaet),
--     section_key (Pflicht; gegen den Textkatalog des Pakets geprueft, s. u.),
--     section_content (Pflicht, Klartext der Sektion bzw. des Themas in der Sprache der Antwort des Beraters; die Karte zeigt ihn ganz),
--     topic (optional, 1..60 Zeichen nach btrim): Thema innerhalb des Abschnitts. Gesetzt -> Upsert in
--       interview_state[key].topics[] als {topic, content, data, saved_at} (Reihenfolge der ersten Speicherung; gleiche
--       Bezeichnung ohne Gross-/Kleinschreibung ersetzt das Thema mitsamt data). Abschnitts-data = legacy_data || Themen-data
--       (derselbe Top-Block in zwei Themen -> code block_in_two_topics). Ein Alt-content des Abschnitts wandert beim ersten
--       Themen-Save nach legacy_content (Alt-data nach legacy_data) und die Karte bekommt die Notiz core.hitl.plan_legacy_replaced.
--       Ohne topic: content/data/saved_at des Abschnitts werden gesetzt, topics und legacy_* bleiben.
--     Laengen-Gesetz: core.config <paket>.advisor.topic_max_chars (Paket der Domain aus core.advisors, E2E-Domain -> echte
--       Domain). Gesetzt -> ohne topic code topic_required, Text laenger -> code topic_too_long {max, length}; ohne Wert keine Regel.
--     section_data (optional, leerer String = nicht angegeben; jsonb-Objekt ODER JSON-String — String wird geparst; relative Zeitangaben in
--       *_date/since loest core.fn_resolve_fact_dates auf, jedes Top-Level-Objekt bekommt as_of = heute von der fn),
--     plan_name (optional, nur bei Draft-Neuanlage),
--     why (optional, <= 400 Zeichen): Hintergrund mit Quelle, am Thema (ohne topic am Abschnitt) gespeichert; jeder Save setzt ihn neu.
--     open_points (optional, Array ODER JSON-String, je Text oder {text}, 1..200 Zeichen): was das Thema bewusst offen laesst;
--       die DB vergibt Ids (hoechste Id des Entwurfs + 1) und haengt sie an die offenen Punkte des Themas an (ein erneuter Save
--       ohne open_points behaelt sie). resolves (optional, [id]): schliesst offene Punkte beliebiger Themen des Entwurfs
--       (resolved_at, resolved_by '<abschnitt>/<thema>').
--     replaces_topic (optional, nur mit topic): Bezeichnung des Themas dieses Abschnitts, das unter topic ersetzt wird (seine
--       Stelle, seine offenen Punkte; offene/beanspruchte Aufgaben ziehen auf die neue Bezeichnung um).
--     Schriftzeichen-Gesetz: ein Wort aus lateinischen und anderen Buchstaben (core.fn_mixed_script_word) in content, why,
--       open_points oder einem Aufgaben-Text -> code mixed_script {word}.
--     handoff_tasks (optional, Array ODER JSON-String, leerer String = keine): im Abschnitt vereinbarte Eintraege fuer den
--       Buchhalter, je {kind: savings_goal|savings_plan|recurring_payment|recurring_transfer|other, payload (Objekt, rohe
--       Nutzerwerte, optional), text (Alltags-Satz, 1..300 Zeichen)}. Angegeben (auch '[]') ersetzt es die OFFENEN Aufgaben:
--       mit topic die des Themas plus die themenlosen des Abschnitts, ohne topic alle des Abschnitts; weggelassen bleiben sie
--       unveraendert; working/done/cancelled bleiben immer. Person = Sender (core.fn_handoff_person), package = Paket der
--       Plan-Domain (core.advisors, E2E-Domain -> echte Domain).
--   Rueckgabe-Vertrag: Erfolg -> {ok:true, plan_id, version, status:'draft',
--     draft_created, sections, section_count, topics, topic_replaced, open_points [{id, text}] (ungeschlossene des gespeicherten
--     Themas), handoff_task_count, card_lines} (Post-State: welche
--     Sektionen der Draft JETZT hat; topics = Themen-Bezeichnungen des Abschnitts in Reihenfolge; topic_replaced und
--     draft_created = DB-entschieden; card_lines = Notiz core.hitl.plan_legacy_replaced beim Abloesen eines Alt-Texts und je
--     Aufgabe eine Kartenzeile core.hitl.handoff_planned {text}).
--     section_key gegen den Textkatalog: fuehrt das Paket der Domain Abschnitts-Keys (core.ui_texts <paket>.plan_section.<key>),
--       ist nur einer davon erlaubt, sonst code unknown_section_key + valid_keys (Tippfehler legte sonst einen Phantom-Abschnitt
--       an). Fuehrt der Katalog keine (Test-DB ohne Seed, Paket ohne Plan), bleibt der Key frei. Keys mit Praefix annex_ (Anbauten,
--       ^annex_[a-z0-9_]{1,40}$) sind immer erlaubt.
--   Korrigierbar (fehlendes domain, leerer section_key/-content, unknown_section_key, topic ueber 60 Zeichen (code topic_label_too_long), topic_required, topic_too_long,
--     block_in_two_topics, why_too_long, open_point_too_long, unknown_open_point {open}, unknown_topic {topics}, topic_exists,
--     mixed_script {word}, invalides section_data-JSON, ungueltige handoff_tasks, Person nicht aufloesbar) -> {ok:false, reason
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
    -- Person-Scope (Paritaet fn_set_context_facts): v_ctx = Plan-Context der Domain (core.advisors),
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
    v_valid   JSONB;               -- gueltige Abschnitts-Keys der Domaene aus dem Textkatalog, NULL = Katalog fuehrt keine
    v_topic  TEXT := NULLIF(btrim(COALESCE(p->>'topic', '')), '');
    v_max     INT;
    v_sec     JSONB;               -- bisheriges Abschnitts-Objekt
    v_topics  JSONB;
    v_idx     INT;                 -- 0-basierter Index des ersetzten Themas, NULL = neues Thema
    v_legacy  BOOLEAN := false;    -- dieser Save loest einen Alt-content ab -> Kartennotiz
    v_why     TEXT := NULLIF(btrim(COALESCE(p->>'why', '')), '');
    v_replace TEXT := NULLIF(btrim(COALESCE(p->>'replaces_topic', '')), '');
    v_ops     JSONB := '[]'::jsonb;   -- neue offene Punkte als Texte
    v_res     JSONB := '[]'::jsonb;   -- zu schliessende Ids
    v_old     JSONB;                  -- bisheriges Ziel-Objekt (Thema bzw. Abschnitt): traegt seine offenen Punkte weiter
    v_next    INT;
    v_word    TEXT;
    v_rep_idx INT;
BEGIN
    IF v_domain IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'domain is required (the advisor tool binding passes it as a fixed input)');
    END IF;
    -- Plan-Context der Domain (Domain->Context-Map aus der Registry; Fallback v_domain||'_planning' fuer
    -- E2E-Sentinel-Domains ohne advisors-Zeile) -> dessen scope/write_permission steuert household vs per_user.
    v_ctx := COALESCE((SELECT plan_context FROM core.advisors WHERE domain = v_domain), v_domain || '_planning');
    SELECT cs.scope, cs.write_permission INTO v_scope, v_perm
    FROM core.context_scopes cs WHERE cs.context_name = v_ctx;
    v_scope := COALESCE(v_scope, 'household');
    v_perm  := COALESCE(v_perm, 'owner_only');

    -- per_user -> Ziel-Person == Sender (own_user_only), aus der chat_id (Numerik-Guard, nie LLM).
    IF v_scope = 'per_user' AND p->>'chat_id' ~ '^[0-9]+$' THEN
        v_pid := agent.fn_resolve_sender((p->>'chat_id')::bigint) ->> 'person_id';
    END IF;
    -- per_user fail-closed (das echte Gate fuer unaufgeloeste Sender, vor Permission und Write).
    IF v_scope = 'per_user' AND v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'cannot resolve person for per-user plan');
    END IF;

    -- Schreib-Permission generisch aus der Registry (financial_planning->owner_only, career_planning->own_user_only).
    -- Identitaet aus der chat_id, nie LLM. {ok:false} vor jedem Write (RAISE-frei -> kein Owner-Alert).
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
    -- Abschnitts-Keys der Domaene = Katalog-Keys <paket>.plan_section.<key> (dieselben, die die Karte beschriftet).
    -- Fuehrt das Paket keine (Test-/E2E-Domain ohne Katalog, Paket ohne Plan), bleibt der Key frei.
    SELECT jsonb_agg(sk ORDER BY sk) INTO v_valid FROM (
        SELECT DISTINCT substr(t.key, length(v_pkg) + 15) AS sk FROM core.ui_texts t
         WHERE t.package = v_pkg AND t.key ~ ('^' || v_pkg || '\.plan_section\.[a-z0-9_]+$')) k;
    -- Anbauten (Abschnitts-Keys mit Praefix annex_) stehen nicht im festen Katalog.
    IF v_valid IS NOT NULL AND NOT (v_valid ? v_key) AND v_key !~ '^annex_[a-z0-9_]{1,40}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_section_key', 'valid_keys', v_valid,
            'reason', format('unknown section_key "%s": use exactly one of the plan section keys of this plan', v_key));
    END IF;
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
    -- korrigierbar, kein RAISE). Leerer String = nicht angegeben: das Tool-Binding liefert ihn beim Weglassen.
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
    -- Felder neben dem Text: why (aufklappbarer Hintergrund), open_points (bewusst Offenes, die DB vergibt Ids), resolves.
    IF length(v_why) > 400 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'why_too_long', 'max', 400, 'length', length(v_why),
            'reason', 'why must be at most 400 characters: keep only the background and its source');
    END IF;
    BEGIN
        v_ops := core.fn_jsonb_list(p->'open_points');
        v_res := core.fn_jsonb_list(p->'resolves');
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'open_points and resolves must be JSON arrays');
    END;
    SELECT COALESCE(jsonb_agg(btrim(CASE WHEN jsonb_typeof(e) = 'object' THEN e->>'text' ELSE e #>> '{}' END) ORDER BY i), '[]'::jsonb)
      INTO v_ops FROM jsonb_array_elements(v_ops) WITH ORDINALITY AS x(e, i);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_ops) t WHERE t = '' OR length(t) > 200) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'open_point_too_long', 'max', 200,
            'reason', 'each open point must be 1-200 characters');
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res) e WHERE (e #>> '{}') !~ '^\s*[0-9]{1,9}\s*$') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_open_point', 'reason', 'resolves must list open point ids (numbers)');
    END IF;
    SELECT w INTO v_word FROM (
        SELECT core.fn_mixed_script_word(t) AS w, n FROM (
            SELECT v_content AS t, 1 AS n UNION ALL SELECT v_why, 2
            UNION ALL SELECT x, 3 FROM jsonb_array_elements_text(v_ops) x
            UNION ALL SELECT t->>'text', 4 FROM jsonb_array_elements(v_tasks) t) s) m
     WHERE w IS NOT NULL ORDER BY n LIMIT 1;
    IF v_word IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'mixed_script', 'word', v_word,
            'reason', format('the word "%s" mixes Latin letters with another script: write it in one script', v_word));
    END IF;
    IF v_replace IS NOT NULL AND v_topic IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_topic', 'topics', '[]'::jsonb,
            'reason', 'replaces_topic needs a topic: the new label of the replaced topic');
    END IF;

    v_hpid := core.fn_handoff_person(p->>'chat_id');
    IF jsonb_array_length(v_tasks) > 0 AND v_hpid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'cannot resolve the person for the handoff tasks');
    END IF;

    -- Relative Zeitangaben (*_date / since) rechnet die DB; as_of jedes Top-Level-Objekt-Blocks stempelt die fn
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

    IF NOT FOUND AND jsonb_array_length(v_res) > 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_open_point', 'open', '[]'::jsonb,
            'reason', 'resolves names open points that do not exist in this draft');
    END IF;
    IF NOT FOUND AND v_replace IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_topic', 'topics', '[]'::jsonb,
            'reason', format('replaces_topic "%s" is not a topic of this section', v_replace));
    END IF;
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

    -- resolves schliesst offene Punkte jedes Themas des Entwurfs (ein spaeteres Thema klaert, was ein frueheres offen liess).
    IF jsonb_array_length(v_res) > 0 THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_res) r
                    WHERE NOT EXISTS (SELECT 1 FROM core.fn_plan_open_points(v_state) o
                                       WHERE o.id = btrim(r)::int AND NOT o.resolved)) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'unknown_open_point',
                'open', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', o.id, 'text', o.text) ORDER BY o.id)
                                    FROM core.fn_plan_open_points(v_state) o WHERE NOT o.resolved), '[]'::jsonb),
                'reason', 'resolves names an open point that does not exist or is already closed: use an id from the open list');
        END IF;
        v_state := core.fn_plan_close_points(v_state, ARRAY(SELECT btrim(r)::int FROM jsonb_array_elements_text(v_res) r),
                                             concat_ws('/', v_key, v_topic));
    END IF;
    -- Ids fortlaufend je Entwurf; geschlossene zaehlen mit, damit keine Id zweimal vorkommt.
    SELECT COALESCE(max(o.id), 0) + 1 INTO v_next FROM core.fn_plan_open_points(v_state) o;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', v_next + i::int - 1, 'text', t) ORDER BY i), '[]'::jsonb)
      INTO v_ops FROM jsonb_array_elements_text(v_ops) WITH ORDINALITY AS x(t, i);

    v_sec := CASE WHEN jsonb_typeof(v_state->v_key) = 'object' THEN v_state->v_key ELSE '{}'::jsonb END;
    IF v_topic IS NULL THEN
        -- Abschnitt als Ganzes (Key ueberschreiben = bewusste Korrektur des Interviews); Themen und Alt-Text bleiben.
        v_ops := core.fn_plan_merge_points(v_sec->'open_points', v_ops);
        v_sec := (v_sec - 'content' - 'data' - 'saved_at' - 'why' - 'open_points')
              || jsonb_strip_nulls(jsonb_build_object('content', v_content, 'why', v_why, 'data', v_data, 'saved_at', now(),
                     'open_points', CASE WHEN v_ops <> '[]'::jsonb THEN v_ops END));
    ELSE
        v_topics := CASE WHEN jsonb_typeof(v_sec->'topics') = 'array' THEN v_sec->'topics' ELSE '[]'::jsonb END;
        SELECT (i - 1)::int INTO v_idx FROM jsonb_array_elements(v_topics) WITH ORDINALITY AS x(t, i)
         WHERE lower(btrim(t->>'topic')) = lower(v_topic) LIMIT 1;
        -- replaces_topic: neue Bezeichnung an der Stelle des alten Themas statt eines zweiten Themas.
        IF v_replace IS NOT NULL THEN
            SELECT (i - 1)::int INTO v_rep_idx FROM jsonb_array_elements(v_topics) WITH ORDINALITY AS x(t, i)
             WHERE lower(btrim(t->>'topic')) = lower(v_replace) LIMIT 1;
            IF v_rep_idx IS NULL THEN
                RETURN jsonb_build_object('ok', false, 'code', 'unknown_topic',
                    'topics', COALESCE((SELECT jsonb_agg(t->'topic' ORDER BY i) FROM jsonb_array_elements(v_topics) WITH ORDINALITY AS x(t, i)), '[]'::jsonb),
                    'reason', format('replaces_topic "%s" is not a topic of this section: use one of the listed labels', v_replace));
            END IF;
            IF v_idx IS NOT NULL AND v_idx <> v_rep_idx THEN
                RETURN jsonb_build_object('ok', false, 'code', 'topic_exists',
                    'reason', format('topic "%s" already exists in this section: replace that one or pick another label', v_topic));
            END IF;
            v_replace := v_topics->v_rep_idx->>'topic';
            v_idx := v_rep_idx;
        END IF;
        v_ops := core.fn_plan_merge_points(v_topics->v_idx->'open_points', v_ops);
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
        v_old := jsonb_strip_nulls(jsonb_build_object('topic', v_topic, 'content', v_content, 'why', v_why, 'data', v_data,
                     'saved_at', now(), 'open_points', CASE WHEN v_ops <> '[]'::jsonb THEN v_ops END));
        IF v_idx IS NULL THEN
            v_topics := v_topics || jsonb_build_array(v_old);
        ELSE
            v_topics := jsonb_set(v_topics, ARRAY[v_idx::text], v_old);
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

    -- Ersetztes Thema: vereinbarte, noch nicht erledigte Aufgaben ziehen mit (Endzustaende sind unveraenderlich).
    IF v_replace IS NOT NULL AND lower(v_replace) <> lower(v_topic) THEN
        UPDATE agent.handoff_tasks SET topic = v_topic
         WHERE domain = v_domain AND section_key = v_key AND status IN ('open', 'working')
           AND person_id IS NOT DISTINCT FROM v_hpid AND lower(topic) = lower(v_replace);
    END IF;

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
        'open_points', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', o->'id', 'text', o->'text') ORDER BY (o->>'id')::int)
                                   FROM jsonb_array_elements(v_ops) o WHERE NOT o ? 'resolved_at'), '[]'::jsonb),
        'handoff_task_count', jsonb_array_length(v_tasks),
        'card_lines', CASE WHEN v_legacy THEN jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.plan_legacy_replaced'))
                           ELSE '[]'::jsonb END
                   || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_planned',
                                    'params', jsonb_build_object('text', btrim(t->>'text'))) ORDER BY i)
                                FROM jsonb_array_elements(v_tasks) WITH ORDINALITY AS x(t, i)), '[]'::jsonb)
    );
END;
$$;
