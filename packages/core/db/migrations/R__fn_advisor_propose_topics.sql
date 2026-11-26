-- ============================================================
-- agent.fn_advisor_propose_topics(p) — Themen eines Plan-Teils als Karte vorschlagen (WRITE: nur agent.chat_prompts)
--   Das Werkzeug tool_propose_plan_topics (ohne Gate) legt
--   die Themen als offene Frage der Art topic an; erst der Tipp [Übernehmen] speichert (agent.fn_prompt_answer_topic), und
--   zwar genau die Themen dieser Zeile. Der Plan selbst bleibt bis dahin unberuehrt.
--   Probelauf: jedes Thema laeuft der Reihe nach durch agent.fn_advisor_save_section (alle Gesetze: Key, Laenge, why,
--   offene Punkte, Schriftzeichen, Aufgaben, Rechte) und wird danach vollstaendig zurueckgerollt (auch ein neu angelegter
--   Entwurf). Die erste Ablehnung kommt unveraendert mit topic_index (1-basiert) zurueck, es entsteht keine Zeile.
--   Eingabe p: {domain, chat_id (Identitaet, nie LLM), section_key, topics (Array oder JSON-String, 1..8 Objekte je {topic,
--     content, why?, open_points?, resolves?, replaces_topic?, handoff_tasks?, section_data?} — die Felder von
--     fn_advisor_save_section), one_card (bool: alle Themen in einer Karte, z. B. Bestandsplan "Stimmt so"), more_in_part (bool:
--     im selben Teil folgen weitere Themen; der Auftrag nach dem letzten Tipp lautet dann "weitere Themen dieses Teils")}.
--   Karten: ohne one_card je Thema eine Zeile (ein Stapel, ord), sonst eine; Spezifikation Kopf core.prompt.topic_head {k, m,
--     section} (Teil k von m aus core.fn_advisor_parts), auf der ersten Karte "Stand heute" (facts), Text, aufklappbar Warum,
--     je Aufgabe core.prompt.topic_enter_later, je neuem offenen Punkt core.prompt.topic_open_point, Hinweis
--     core.prompt.topic_hint; Knoepfe accept/note. Eine Karte ueber 3500 Zeichen Inhalt -> code too_long (Telegram 4096).
--   Ersetzt: die offene Frage desselben Agenten (Art topic oder choice) samt wartendem Rest ihres Stapels, dazu alle
--     wartenden Themen-Karten des Agenten im Chat (superseded).
--   Rueckgabe {ok:true, plan_id (bestehender Entwurf oder null), prompt_ids, cards, deferred_entries [{text, reason}] (zurueckgestellte
--     Eintraege des Probelaufs, reason = Katalog <paket>.handoff.blocked.<code> in der Sprache der Person)} | {ok:false, code, reason, topic_index?,
--     …Felder der Ablehnung}; codes: invalid_input, invalid_topics, unknown_domain, unknown_chat, too_long + alle von
--     fn_advisor_save_section. Echte Fehler (RAISE) gehen durch.
--   Familie: agent.fn_prompt_answer_topic(p) = answer_fn der Art topic (Tipp accept): speichert alle Themen der Zeile in
--     einer Transaktion (eines abgelehnt -> keines, Zeile superseded, {ok:false, then:'continue', continue:{agent, as:'task',
--     text}} mit dem Grund); ok -> append core.prompt.accepted, then 'next' solange im Chat noch Fragen warten, sonst
--     'continue' mit festem Auftrag an den Berater.
--   VOLATILE, INVOKER (Host-Cred des Werkzeugs bzw. des Dispatchers), search_path gepinnt.
--   Tests: tests/db/core/test_fn_advisor_propose_topics.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_advisor_propose_topics(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain  text := NULLIF(btrim(COALESCE(p->>'domain', '')), '');
    v_chat    text := COALESCE(p->>'chat_id', '');
    v_key     text := btrim(COALESCE(p->>'section_key', ''));
    v_one     boolean := COALESCE(NULLIF(p->>'one_card', '')::boolean, false);
    v_more    boolean := COALESCE(NULLIF(p->>'more_in_part', '')::boolean, false);
    v_topics  jsonb;
    v_norm    jsonb := '[]'::jsonb;   -- die Themen genau so, wie der Tipp sie speichert
    v_saved   jsonb := '[]'::jsonb;   -- Probelauf-Ergebnisse je Thema (Ids neuer offener Punkte)
    v_fail    jsonb;
    v_t       jsonb;
    v_r       jsonb;
    v_agent   text;
    v_pkg     text;
    v_pid     text;
    v_lang    text;
    v_parts   jsonb;
    v_k       int;
    v_sect    text;
    v_plan    int;
    v_batch   uuid := gen_random_uuid();
    v_groups  jsonb;
    v_g       jsonb;
    v_lines   jsonb;
    v_ids     jsonb := '[]'::jsonb;
    v_id      bigint;
    v_open    agent.chat_prompts%ROWTYPE;
    i         int;
    gi        int := 0;
BEGIN
    IF v_domain IS NULL OR NOT core.fn_chat_id_ok(v_chat) OR v_key = '' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_input', 'reason', 'domain, chat_id and section_key are required');
    END IF;
    BEGIN
        v_topics := core.fn_jsonb_list(p->'topics');
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_topics', 'reason', 'topics must be a JSON array of topic objects');
    END;
    IF jsonb_array_length(v_topics) NOT BETWEEN 1 AND 8
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_topics) t WHERE jsonb_typeof(t) <> 'object') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_topics',
            'reason', 'topics must list 1-8 objects {topic, content, …}: one object per topic of this part');
    END IF;
    SELECT a.advisor_agent, a.package INTO v_agent, v_pkg
      FROM core.advisors a WHERE a.domain = regexp_replace(v_domain, '^__e2e_(.+)__$', '\1');
    IF v_agent IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_domain', 'reason', 'domain has no advisor');
    END IF;
    v_pid := core.fn_chat_person(v_chat)->>'person_id';
    IF v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_chat', 'reason', 'chat is not a known person');
    END IF;
    v_lang := agent.fn_person_lang(v_pid)->>'lang';

    -- Normalform je Thema = Eingabe von fn_advisor_save_section (content -> section_content).
    SELECT jsonb_agg(((t - 'domain' - 'chat_id' - 'section_key' - 'content')
                      || jsonb_build_object('section_content', COALESCE(t->>'content', t->>'section_content', ''))) ORDER BY n)
      INTO v_norm FROM jsonb_array_elements(v_topics) WITH ORDINALITY AS x(t, n);

    -- Probelauf: der Reihe nach speichern (spaetere Themen sehen fruehere), dann alles zurueckrollen.
    BEGIN
        FOR i IN 0 .. jsonb_array_length(v_norm) - 1 LOOP
            v_r := agent.fn_advisor_save_section(jsonb_build_object('domain', v_domain, 'chat_id', v_chat, 'section_key', v_key)
                                                 || (v_norm->i));
            IF (v_r->>'ok')::boolean IS NOT TRUE THEN
                v_fail := v_r || jsonb_build_object('topic_index', i + 1);
                EXIT;
            END IF;
            v_saved := v_saved || jsonb_build_array(v_r);
        END LOOP;
        RAISE EXCEPTION USING ERRCODE = 'LA001', MESSAGE = 'propose_topics dry run';
    EXCEPTION WHEN SQLSTATE 'LA001' THEN
        NULL;
    END;
    IF v_fail IS NOT NULL THEN
        RETURN v_fail;
    END IF;

    v_parts := core.fn_advisor_parts(v_domain);
    SELECT (e->>'n')::int INTO v_k FROM jsonb_array_elements(v_parts) e WHERE e->>'section_key' = v_key;
    v_sect := core.fn_ui_text(v_pkg || '.plan_section.' || v_key, v_lang);
    SELECT ap.id INTO v_plan FROM agent.advisor_plans ap
     WHERE ap.domain = v_domain AND ap.status = 'draft' AND (ap.person_id IS NULL OR ap.person_id = v_pid)
     ORDER BY ap.person_id NULLS LAST LIMIT 1;

    -- Karten: ohne one_card je Thema eine Gruppe, sonst eine Gruppe mit allen Themen.
    v_groups := CASE WHEN v_one THEN jsonb_build_array((SELECT jsonb_agg(n - 1 ORDER BY n) FROM generate_series(1, jsonb_array_length(v_norm)) n))
                     ELSE (SELECT jsonb_agg(jsonb_build_array(n - 1) ORDER BY n) FROM generate_series(1, jsonb_array_length(v_norm)) n) END;
    FOR v_g IN SELECT e FROM jsonb_array_elements(v_groups) e LOOP
        gi := gi + 1;
        -- Grob wie gerendert: Texte, Aufgaben- und Offen-Zeilen je Thema plus Platz fuer Kopf, "Stand heute" (bis 6 Zeilen) und Hinweis.
        IF (SELECT sum(length(COALESCE(v_norm->(x #>> '{}')::int->>'section_content', '')) + length(COALESCE(v_norm->(x #>> '{}')::int->>'why', ''))
                       + length(COALESCE(v_norm->(x #>> '{}')::int->>'topic', '')) + 120
                       + COALESCE((SELECT sum(length(COALESCE(h->>'text', '')) + 40) FROM jsonb_array_elements(core.fn_jsonb_list(v_norm->(x #>> '{}')::int->'handoff_tasks')) h), 0)
                       + COALESCE((SELECT sum(length(COALESCE(o->>'text', o #>> '{}', '')) + 20) FROM jsonb_array_elements(core.fn_jsonb_list(v_norm->(x #>> '{}')::int->'open_points')) o), 0))
              FROM jsonb_array_elements(v_g) x) + 500 > 3500 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'too_long',
                'reason', 'the card is longer than one Telegram message: shorten the topics or send them without one_card');
        END IF;
    END LOOP;

    PERFORM pg_advisory_xact_lock(hashtext('chat_prompt:' || v_chat));
    SELECT * INTO v_open FROM agent.chat_prompts
     WHERE chat_id = v_chat AND status = 'open' AND agent = v_agent AND kind IN ('topic', 'choice') FOR UPDATE;
    IF FOUND THEN
        UPDATE agent.chat_prompts SET status = 'superseded', decided_at = clock_timestamp()
         WHERE id = v_open.id OR (v_open.kind = 'topic' AND batch_id = v_open.batch_id AND status = 'queued');
    END IF;
    UPDATE agent.chat_prompts SET status = 'superseded', decided_at = clock_timestamp()
     WHERE chat_id = v_chat AND agent = v_agent AND kind = 'topic' AND status = 'queued';

    gi := 0;
    FOR v_g IN SELECT e FROM jsonb_array_elements(v_groups) e LOOP
        gi := gi + 1;
        v_lines := jsonb_build_array(jsonb_build_object('kind', 'head', 'key', 'core.prompt.topic_head',
                       'params', jsonb_build_object('k', v_k, 'm', jsonb_array_length(v_parts), 'section', v_sect)));
        IF gi = 1 THEN
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'facts', 'domain', v_domain, 'section_key', v_key));
        END IF;
        IF jsonb_array_length(v_g) > 1 THEN
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'label', 'key', 'core.prompt.topic_keep_many'));
        END IF;
        FOR i IN SELECT (x #>> '{}')::int FROM jsonb_array_elements(v_g) x LOOP
            v_t := v_norm->i;
            v_lines := v_lines
                || CASE WHEN jsonb_array_length(v_g) > 1 THEN jsonb_build_array(jsonb_build_object('kind', 'label', 'text', v_t->>'topic'))
                        ELSE jsonb_build_array(jsonb_build_object('kind', 'label', 'key', 'core.prompt.topic_keep',
                                 'params', jsonb_build_object('topic', v_t->>'topic'))) END
                || jsonb_build_array(jsonb_build_object('kind', 'text', 'text', v_t->>'section_content'))
                || CASE WHEN NULLIF(btrim(COALESCE(v_t->>'why', '')), '') IS NOT NULL
                        THEN jsonb_build_array(jsonb_build_object('kind', 'expand', 'title_key', 'core.prompt.topic_why', 'text', btrim(v_t->>'why')))
                        ELSE '[]'::jsonb END
                || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'text', 'key', 'core.prompt.topic_enter_later',
                                                                 'params', jsonb_build_object('text', btrim(h->>'text'))) ORDER BY n)
                               FROM jsonb_array_elements(core.fn_jsonb_list(v_t->'handoff_tasks')) WITH ORDINALITY AS y(h, n)), '[]'::jsonb)
                || COALESCE((SELECT jsonb_agg(jsonb_build_object('kind', 'text', 'key', 'core.prompt.topic_open_point',
                                                                 'params', jsonb_build_object('text', CASE WHEN jsonb_typeof(o) = 'object' THEN btrim(o->>'text') ELSE btrim(o #>> '{}') END)) ORDER BY n)
                               FROM jsonb_array_elements(core.fn_jsonb_list(v_t->'open_points')) WITH ORDINALITY AS y(o, n)), '[]'::jsonb);
        END LOOP;
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'hint', 'key', 'core.prompt.topic_hint'));
        INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, plan_id, batch_id, ord, status, card, options, payload)
        VALUES (v_chat, v_pid, v_agent, 'topic', v_plan, v_batch, gi, 'queued', jsonb_build_object('lines', v_lines),
                '[{"key":"accept","label_key":"core.prompt.button.accept"},{"key":"note","label_key":"core.prompt.button.note"}]'::jsonb,
                jsonb_build_object('domain', v_domain, 'section_key', v_key, 'more_in_part', v_more,
                    'topics', (SELECT jsonb_agg(v_norm->((x #>> '{}')::int)) FROM jsonb_array_elements(v_g) x),
                    'label', v_key || ': ' || (SELECT string_agg(v_norm->((x #>> '{}')::int)->>'topic', ', ') FROM jsonb_array_elements(v_g) x)))
        RETURNING id INTO v_id;
        v_ids := v_ids || to_jsonb(v_id);
    END LOOP;
    -- "geht noch nicht": Eintraege, die der Probelauf zurueckstellte, mit dem Satz des Pakets (der Berater sagt es in einem Satz)
    RETURN jsonb_build_object('ok', true, 'plan_id', v_plan, 'prompt_ids', v_ids, 'cards', jsonb_array_length(v_ids),
        'deferred_entries', COALESCE((SELECT jsonb_agg(jsonb_build_object('text', d->>'text',
                                         'reason', core.fn_ui_text(v_pkg || '.handoff.blocked.' || (d->>'blocked_code'), v_lang)) ORDER BY s.n, d.n)
                                       FROM jsonb_array_elements(v_saved) WITH ORDINALITY AS s(r, n),
                                            jsonb_array_elements(COALESCE(s.r->'deferred', '[]'::jsonb)) WITH ORDINALITY AS d(d, n)), '[]'::jsonb));
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_advisor_propose_topics(jsonb) FROM public;

CREATE OR REPLACE FUNCTION agent.fn_prompt_answer_topic(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_row  jsonb := p->'prompt';
    v_pay  jsonb := p->'prompt'->'payload';
    v_lang text  := p->>'lang';
    v_chat text  := p->>'chat_id';
    v_r    jsonb;
    v_err  jsonb;
    i      int;
BEGIN
    IF p->>'key' IS DISTINCT FROM 'accept' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_option');
    END IF;
    BEGIN
        FOR i IN 0 .. jsonb_array_length(COALESCE(v_pay->'topics', '[]'::jsonb)) - 1 LOOP
            v_r := agent.fn_advisor_save_section(jsonb_build_object('domain', v_pay->>'domain', 'chat_id', v_chat,
                                                                    'section_key', v_pay->>'section_key') || (v_pay->'topics'->i));
            IF (v_r->>'ok')::boolean IS NOT TRUE THEN
                v_err := v_r || jsonb_build_object('topic_index', i + 1);
                RAISE EXCEPTION USING ERRCODE = 'LA002', MESSAGE = 'topic save rejected';
            END IF;
        END LOOP;
    EXCEPTION WHEN SQLSTATE 'LA002' THEN
        UPDATE agent.chat_prompts SET status = 'superseded', decided_at = clock_timestamp() WHERE id = (v_row->>'id')::bigint;
        RETURN jsonb_build_object('ok', false, 'reason', 'save_failed',
            'toast', core.fn_ui_text('core.toast.prompt_save_failed', v_lang), 'then', 'continue',
            'continue', jsonb_build_object('agent', v_row->>'agent', 'as', 'task',
                'text', format('Saving the topic card for part %s failed (topic %s, %s): %s Propose the topics again, corrected.',
                               v_pay->>'section_key', v_err->>'topic_index', COALESCE(v_err->>'code', 'rejected'), v_err->>'reason')));
    END;
    IF EXISTS (SELECT 1 FROM agent.chat_prompts c WHERE c.chat_id = v_chat AND c.status = 'queued') THEN
        RETURN jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.accepted', v_lang), 'then', 'next');
    END IF;
    RETURN jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.accepted', v_lang), 'then', 'continue',
        'continue', jsonb_build_object('agent', v_row->>'agent', 'as', 'task',
            'text', format('The user accepted the topic card for part %s (%s). %s',
                           v_pay->>'section_key', (SELECT string_agg(t->>'topic', ', ') FROM jsonb_array_elements(v_pay->'topics') t),
                           CASE WHEN COALESCE((v_pay->>'more_in_part')::boolean, false)
                                THEN 'Propose the remaining topics of the same part now.'
                                ELSE 'Continue the plan conversation with the next step.' END)));
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_prompt_answer_topic(jsonb) FROM public;
