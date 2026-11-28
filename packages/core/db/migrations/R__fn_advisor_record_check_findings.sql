-- ============================================================
-- agent.fn_advisor_record_check_findings(p) — Funde eines Lesedurchgangs der Schlusspruefung ablegen (WRITE: nur
--   agent.chat_prompts; der Plan bleibt unberuehrt)
--   Das Modell liest den Entwurf einmal je Durchgang und liefert alle echten Funde (Werkzeug tool_record_check_findings,
--   ohne Gate: Arbeitsnotiz); die Datenbank fuehrt danach Punkt fuer Punkt als Stapel der Art finding (ohne Modell-Lauf
--   zwischen den Punkten). Die DB ergaenzt, was sie selbst weiss: ungeschlossene offene Punkte (open_point) und Teile ohne
--   Inhalt (missing_part, core.fn_advisor_parts).
--   Eingabe p: {domain, chat_id, findings (Array oder JSON-String, auch []) je {category: contradiction|missing,
--     ref_a {section_key, topic}, quote_a (1..300, woertlich im Text dieses Themas), ref_b?, quote_b? (Pflicht bei
--     contradiction), proposal? {section_key, topic, content, …Felder von fn_advisor_save_section} | question? (1..300);
--     einer von beiden ist Pflicht}}.
--   Pruefung vor jedem Write: Entwurf der Domaene (Personen-Regel wie fn_advisor_save_section, Schreibrecht ueber
--     agent.fn_check_write_permission) -> sonst no_draft bzw. no_permission; je Fund invalid_finding {index}, quote_not_found
--     {index}, proposal_rejected {index, save_code, reason} (Probelauf von fn_advisor_save_section, zurueckgerollt).
--   Durchgang = hoechster bisheriger + 1, hoechstens core.config advisor.check_max_passes (Default 2), sonst
--     check_passes_exhausted. Wartende/offene Zeilen eines frueheren Durchgangs werden superseded.
--   Stapel (ein batch): Uebersicht (ord 0, payload.role overview, Knoepfe go/pause, Zaehlwerte je Art; im letzten
--     Durchgang ab dem zweiten core.prompt.check_last_pass), dann je Punkt eine Zeile in der Reihenfolge contradiction -> missing ->
--     missing_part -> open_point (Kopf core.prompt.finding_head {k, n, kind}; Zitate mit Herkunft; Vorschlag bzw. Frage;
--     Knoepfe accept (nur mit Vorschlag) / keep / note). payload je Punkt: {pass, category, text (<= 300, fuer die
--     Version), ref_a, quote_a, ref_b, quote_b, proposal, question, section_key, open_point_id, label}.
--   Rueckgabe {ok:true, pass, last_pass, counts {contradiction, missing, missing_part, open_point}, prompt_ids} |
--     {ok:false, code, reason[, index | max]}; codes invalid_input, no_permission, no_draft, invalid_finding, quote_not_found,
--     proposal_rejected, check_passes_exhausted {max}.
--   Familie: agent.fn_prompt_answer_finding(p) = answer_fn der Art finding. Uebersicht: go -> next (ohne Punkte:
--     continue mit Auftrag "veroeffentlichen"), pause -> none. Punkt: accept speichert den Vorschlag ueber
--     fn_advisor_save_section mit der chat_id des Tippenden (abgelehnt -> Zeile superseded, continue mit Grund), outcome
--     resolved + changed; keep -> outcome accepted (open_point: deferred). Danach: weitere Punkte des Durchgangs -> next;
--     sonst continue mit festem Auftrag: zweiter (letzter) Durchgang, wenn ein Punkt Themen geaendert hat und die Grenze
--     nicht erreicht ist, sonst "Pruefung fertig, Veroeffentlichen vorschlagen".
--   VOLATILE, INVOKER (Host-Cred), search_path gepinnt.
--   Tests: tests/db/core/test_fn_advisor_record_check_findings.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_advisor_record_check_findings(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain text := NULLIF(btrim(COALESCE(p->>'domain', '')), '');
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_dom    text;
    v_agent  text;
    v_pkg    text;
    v_ctx    text;
    v_scope  text;
    v_perm   text;
    v_target text;
    v_pid    text;
    v_lang   text;
    v_err    text;
    v_plan   agent.advisor_plans%ROWTYPE;
    v_list   jsonb;
    v_f      jsonb;
    v_i      int := 0;
    v_r      jsonb;
    v_fail   jsonb;
    v_pass   int;
    v_max    int;
    v_items  jsonb := '[]'::jsonb;   -- {category, ...} in Anzeige-Reihenfolge
    v_batch  uuid := gen_random_uuid();
    v_ids    jsonb := '[]'::jsonb;
    v_id     bigint;
    v_lines  jsonb;
    v_n      int;
    v_k      int := 0;
    v_cnt    jsonb;
BEGIN
    IF v_domain IS NULL OR NOT core.fn_chat_id_ok(v_chat) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_input', 'reason', 'domain and chat_id are required');
    END IF;
    v_dom := regexp_replace(v_domain, '^__e2e_(.+)__$', '\1');
    SELECT a.advisor_agent, a.package, a.plan_context INTO v_agent, v_pkg, v_ctx FROM core.advisors a WHERE a.domain = v_dom;
    v_ctx := COALESCE(v_ctx, v_domain || '_planning');
    SELECT cs.scope, cs.write_permission INTO v_scope, v_perm FROM core.context_scopes cs WHERE cs.context_name = v_ctx;
    v_pid := core.fn_chat_person(v_chat)->>'person_id';
    IF COALESCE(v_scope, 'household') = 'per_user' THEN
        v_target := v_pid;
        IF v_target IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'no_draft', 'reason', 'cannot resolve person for per-user plan');
        END IF;
    END IF;
    v_err := agent.fn_check_write_permission(COALESCE(v_perm, 'owner_only'), v_chat, v_target);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_permission', 'reason', v_err);
    END IF;
    SELECT * INTO v_plan FROM agent.advisor_plans
     WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_target AND status = 'draft' FOR UPDATE;
    IF NOT FOUND OR v_agent IS NULL OR v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_draft', 'reason', 'there is no plan draft to check');
    END IF;
    v_lang := agent.fn_person_lang(v_pid)->>'lang';
    BEGIN
        v_list := core.fn_jsonb_list(p->'findings');
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_finding', 'reason', 'findings must be a JSON array');
    END;

    -- Funde pruefen (Zitat woertlich im genannten Thema, Vorschlag im Probelauf).
    FOR v_f IN SELECT e FROM jsonb_array_elements(v_list) e LOOP
        v_i := v_i + 1;
        IF jsonb_typeof(v_f) <> 'object' OR COALESCE(v_f->>'category', '') NOT IN ('contradiction', 'missing')
           OR btrim(COALESCE(v_f->>'quote_a', '')) = '' OR length(v_f->>'quote_a') > 300 OR length(COALESCE(v_f->>'quote_b', '')) > 300
           OR (v_f->>'category' = 'contradiction' AND btrim(COALESCE(v_f->>'quote_b', '')) = '')
           OR (jsonb_typeof(v_f->'proposal') IS DISTINCT FROM 'object' AND btrim(COALESCE(v_f->>'question', '')) = '')
           OR length(COALESCE(v_f->>'question', '')) > 300 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_finding', 'index', v_i,
                'reason', format('finding #%s needs category contradiction|missing, ref_a + quote_a (contradiction also ref_b + quote_b, quotes <= 300) and a proposal or a question', v_i));
        END IF;
        IF NOT core.fn_plan_quote_found(v_plan.interview_state, v_f->'ref_a', v_f->>'quote_a')
           OR (btrim(COALESCE(v_f->>'quote_b', '')) <> '' AND NOT core.fn_plan_quote_found(v_plan.interview_state, v_f->'ref_b', v_f->>'quote_b')) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'quote_not_found', 'index', v_i,
                'reason', format('finding #%s: the quote is not word for word in the named topic; copy it exactly from the draft', v_i));
        END IF;
        IF jsonb_typeof(v_f->'proposal') = 'object' THEN
            v_fail := NULL;
            BEGIN
                v_r := agent.fn_advisor_save_section(jsonb_build_object('domain', v_domain, 'chat_id', v_chat)
                         || core.fn_prompt_save_params(v_f->'proposal'));
                IF (v_r->>'ok')::boolean IS NOT TRUE THEN
                    v_fail := v_r;
                END IF;
                RAISE EXCEPTION USING ERRCODE = 'LA001', MESSAGE = 'check proposal dry run';
            EXCEPTION WHEN SQLSTATE 'LA001' THEN
                NULL;
            END;
            IF v_fail IS NOT NULL THEN
                RETURN jsonb_build_object('ok', false, 'code', 'proposal_rejected', 'index', v_i,
                    'save_code', v_fail->>'code', 'reason', format('finding #%s: the proposal would be rejected: %s', v_i, v_fail->>'reason'));
            END IF;
        END IF;
    END LOOP;

    v_max := core.fn_advisor_check_max_passes();
    SELECT COALESCE(max((c.payload->>'pass')::int), 0) + 1 INTO v_pass FROM agent.chat_prompts c
     WHERE c.plan_id = v_plan.id AND c.kind = 'finding' AND c.status <> 'superseded';
    IF v_pass > v_max THEN
        RETURN jsonb_build_object('ok', false, 'code', 'check_passes_exhausted', 'max', v_max,
            'reason', format('the final check already had %s passes: whatever is still open stays deliberately open; propose publishing', v_max));
    END IF;

    -- Punkte in Anzeige-Reihenfolge: Modell-Funde, dann die DB-eigenen.
    v_items := COALESCE((SELECT jsonb_agg(e ORDER BY CASE e->>'category' WHEN 'contradiction' THEN 1 ELSE 2 END, n)
                           FROM jsonb_array_elements(v_list) WITH ORDINALITY AS x(e, n)), '[]'::jsonb)
            || COALESCE((SELECT jsonb_agg(jsonb_build_object('category', 'missing_part', 'section_key', e->>'section_key') ORDER BY (e->>'n')::int)
                           FROM jsonb_array_elements(core.fn_advisor_parts(v_domain)) e
                          WHERE NOT COALESCE((jsonb_typeof(v_plan.interview_state->(e->>'section_key')->'topics') = 'array'
                                      AND jsonb_array_length(v_plan.interview_state->(e->>'section_key')->'topics') > 0)
                                     OR btrim(COALESCE(v_plan.interview_state->(e->>'section_key')->>'content', '')) <> '', false)), '[]'::jsonb)
            || COALESCE((SELECT jsonb_agg(jsonb_build_object('category', 'open_point', 'id', o.id, 'text', o.text,
                                                             'section_key', o.section_key, 'topic', o.topic) ORDER BY o.id)
                           FROM core.fn_plan_open_points(v_plan.interview_state) o WHERE NOT o.resolved), '[]'::jsonb);
    v_n := jsonb_array_length(v_items);
    SELECT jsonb_build_object(
             'contradiction', count(*) FILTER (WHERE e->>'category' = 'contradiction'),
             'missing',       count(*) FILTER (WHERE e->>'category' = 'missing'),
             'missing_part',  count(*) FILTER (WHERE e->>'category' = 'missing_part'),
             'open_point',    count(*) FILTER (WHERE e->>'category' = 'open_point'))
      INTO v_cnt FROM jsonb_array_elements(v_items) e;

    PERFORM pg_advisory_xact_lock(hashtext('chat_prompt:' || v_chat));
    UPDATE agent.chat_prompts SET status = 'superseded', decided_at = clock_timestamp()
     WHERE plan_id = v_plan.id AND kind = 'finding' AND status IN ('queued', 'open');

    -- Uebersicht (Ziellinie): Zaehlwerte aus der DB, Wortlaut im Katalog.
    v_lines := jsonb_build_array(jsonb_build_object('kind', 'head', 'key',
                   CASE WHEN v_pass > 1 AND v_pass >= v_max THEN 'core.prompt.check_last_pass' ELSE 'core.prompt.check_head' END,
                   'params', jsonb_build_object('n', v_n)))
            || CASE WHEN v_n = 0 THEN jsonb_build_array(jsonb_build_object('kind', 'text', 'key', 'core.prompt.check_clean'))
                    ELSE jsonb_build_array(jsonb_build_object('kind', 'text', 'key', 'core.prompt.check_intro'),
                             jsonb_build_object('kind', 'row', 'key', 'core.prompt.check_step_points',
                                 'params', v_cnt || jsonb_build_object('n', v_n))) END
            || jsonb_build_array(jsonb_build_object('kind', 'row', 'key', 'core.prompt.check_step_publish'),
                   jsonb_build_object('kind', 'row', 'key', 'core.prompt.check_step_enter',
                       'params', jsonb_build_object('n', (SELECT count(*) FROM agent.handoff_tasks t
                                                           WHERE t.domain = v_domain AND t.status IN ('open', 'working')
                                                             AND (v_target IS NULL OR t.person_id = v_target)))),
                   jsonb_build_object('kind', 'text', 'key', 'core.prompt.check_question'));
    INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, plan_id, batch_id, ord, status, card, options, payload)
    VALUES (v_chat, v_pid, v_agent, 'finding', v_plan.id, v_batch, 0, 'queued', jsonb_build_object('lines', v_lines),
            '[{"key":"go","label_key":"core.prompt.button.go"},{"key":"pause","label_key":"core.prompt.button.pause"}]'::jsonb,
            jsonb_build_object('pass', v_pass, 'role', 'overview', 'points', v_n, 'label', format('final check pass %s', v_pass)))
    RETURNING id INTO v_id;
    v_ids := v_ids || to_jsonb(v_id);

    FOR v_f IN SELECT e FROM jsonb_array_elements(v_items) e LOOP
        v_k := v_k + 1;
        v_lines := jsonb_build_array(jsonb_build_object('kind', 'head', 'key', 'core.prompt.finding_head',
                       'params', jsonb_build_object('k', v_k, 'n', v_n,
                           'kind', core.fn_ui_text(CASE v_f->>'category' WHEN 'contradiction' THEN 'core.prompt.finding_kind.contradiction' WHEN 'missing' THEN 'core.prompt.finding_kind.missing'
                                                        WHEN 'missing_part' THEN 'core.prompt.finding_kind.missing_part' ELSE 'core.prompt.finding_kind.open_point' END, v_lang))));
        IF v_f->>'category' IN ('contradiction', 'missing') THEN
            v_lines := v_lines
                || jsonb_build_array(jsonb_build_object('kind', 'quote', 'key', 'core.prompt.finding_at',
                       'params', jsonb_build_object('where', core.fn_ui_text(v_pkg || '.plan_section.' || (v_f->'ref_a'->>'section_key'), v_lang)
                                                             || COALESCE(' · ' || (v_f->'ref_a'->>'topic'), ''))),
                       jsonb_build_object('kind', 'quote', 'text', v_f->>'quote_a'))
                || CASE WHEN btrim(COALESCE(v_f->>'quote_b', '')) <> '' THEN jsonb_build_array(
                       jsonb_build_object('kind', 'quote', 'key', 'core.prompt.finding_at',
                           'params', jsonb_build_object('where', core.fn_ui_text(v_pkg || '.plan_section.' || (v_f->'ref_b'->>'section_key'), v_lang)
                                                                 || COALESCE(' · ' || (v_f->'ref_b'->>'topic'), ''))),
                       jsonb_build_object('kind', 'quote', 'text', v_f->>'quote_b')) ELSE '[]'::jsonb END
                || CASE WHEN jsonb_typeof(v_f->'proposal') = 'object'
                        THEN jsonb_build_array(jsonb_build_object('kind', 'label', 'key', 'core.prompt.finding_proposal'),
                                 jsonb_build_object('kind', 'text', 'text', COALESCE(v_f->'proposal'->>'content', v_f->'proposal'->>'section_content')))
                        ELSE jsonb_build_array(jsonb_build_object('kind', 'text', 'text', v_f->>'question')) END;
        ELSIF v_f->>'category' = 'missing_part' THEN
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'text', 'key', 'core.prompt.finding_missing_part',
                           'params', jsonb_build_object('section', core.fn_ui_text(v_pkg || '.plan_section.' || (v_f->>'section_key'), v_lang))));
        ELSE
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'text', 'text', v_f->>'text'),
                           jsonb_build_object('kind', 'quote', 'key', 'core.prompt.finding_at',
                               'params', jsonb_build_object('where', core.fn_ui_text(v_pkg || '.plan_section.' || (v_f->>'section_key'), v_lang)
                                                                     || COALESCE(' · ' || (v_f->>'topic'), ''))));
        END IF;
        INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, plan_id, batch_id, ord, status, card, options, payload)
        VALUES (v_chat, v_pid, v_agent, 'finding', v_plan.id, v_batch, v_k, 'queued', jsonb_build_object('lines', v_lines),
                CASE WHEN jsonb_typeof(v_f->'proposal') = 'object'
                     THEN '[{"key":"accept","label_key":"core.prompt.button.accept_proposal"},{"key":"keep","label_key":"core.prompt.button.keep"},{"key":"note","label_key":"core.prompt.button.note"}]'::jsonb
                     ELSE '[{"key":"keep","label_key":"core.prompt.button.keep"},{"key":"note","label_key":"core.prompt.button.note"}]'::jsonb END,
                jsonb_strip_nulls(jsonb_build_object('pass', v_pass, 'category', v_f->>'category',
                    'text', left(CASE v_f->>'category'
                                     WHEN 'missing_part' THEN 'missing part: ' || (v_f->>'section_key')
                                     WHEN 'open_point' THEN 'open: ' || (v_f->>'text')
                                     ELSE COALESCE(v_f->>'question', v_f->'proposal'->>'content', v_f->'proposal'->>'section_content') END, 300),
                    'ref_a', v_f->'ref_a', 'quote_a', v_f->>'quote_a', 'ref_b', v_f->'ref_b', 'quote_b', v_f->>'quote_b',
                    'proposal', CASE WHEN jsonb_typeof(v_f->'proposal') = 'object' THEN core.fn_prompt_save_params(v_f->'proposal') END,
                    'question', v_f->>'question', 'section_key', v_f->>'section_key', 'open_point_id', v_f->'id',
                    'label', format('check point %s of %s (%s)', v_k, v_n, v_f->>'category'))))
        RETURNING id INTO v_id;
        v_ids := v_ids || to_jsonb(v_id);
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'pass', v_pass, 'last_pass', v_pass >= v_max, 'counts', v_cnt, 'prompt_ids', v_ids);
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_advisor_record_check_findings(jsonb) FROM public;

-- core.fn_plan_quote_found(state, ref, quote): steht quote woertlich (Leerraum zusammengefasst) im Text des Themas
-- ref {section_key, topic} bzw. ohne topic im Abschnitts-Text?
CREATE OR REPLACE FUNCTION core.fn_plan_quote_found(p_state jsonb, p_ref jsonb, p_quote text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(btrim(p_quote) <> '' AND position(
               regexp_replace(btrim(p_quote), '\s+', ' ', 'g') IN regexp_replace(
                   COALESCE(CASE WHEN NULLIF(btrim(COALESCE(p_ref->>'topic', '')), '') IS NULL
                                 THEN concat_ws(' ', p_state->(p_ref->>'section_key')->>'content', p_state->(p_ref->>'section_key')->>'legacy_content')
                                 ELSE (SELECT t->>'content' FROM jsonb_array_elements(
                                           CASE WHEN jsonb_typeof(p_state->(p_ref->>'section_key')->'topics') = 'array'
                                                THEN p_state->(p_ref->>'section_key')->'topics' ELSE '[]'::jsonb END) t
                                        WHERE lower(btrim(t->>'topic')) = lower(btrim(p_ref->>'topic')) LIMIT 1) END, ''),
                   '\s+', ' ', 'g')) > 0, false);
$$;

-- core.fn_prompt_save_params(t): ein Thema in die Eingabe-Form von fn_advisor_save_section (content -> section_content;
-- domain/chat_id kommen immer vom Aufrufer, nie aus dem Modell-Objekt).
CREATE OR REPLACE FUNCTION core.fn_prompt_save_params(p_topic jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT (p_topic - 'domain' - 'chat_id' - 'content')
           || jsonb_build_object('section_content', COALESCE(p_topic->>'content', p_topic->>'section_content', ''));
$$;

CREATE OR REPLACE FUNCTION agent.fn_prompt_answer_finding(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_row     jsonb := p->'prompt';
    v_pay     jsonb := p->'prompt'->'payload';
    v_id      bigint := (p->'prompt'->>'id')::bigint;
    v_plan    int := (p->'prompt'->>'plan_id')::int;
    v_pass    int := (p->'prompt'->'payload'->>'pass')::int;
    v_key     text := p->>'key';
    v_lang    text := p->>'lang';
    v_chat    text := p->>'chat_id';
    v_domain  text;
    v_r       jsonb;
    v_out     jsonb;
    v_max     int;
    v_changed boolean;
BEGIN
    SELECT ap.domain INTO v_domain FROM agent.advisor_plans ap WHERE ap.id = v_plan;
    IF v_pay->>'role' = 'overview' THEN
        IF v_key = 'pause' THEN
            RETURN jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.paused', v_lang), 'then', 'none');
        END IF;
        IF COALESCE((v_pay->>'points')::int, 0) > 0 THEN
            RETURN jsonb_build_object('ok', true, 'then', 'next');
        END IF;
        RETURN jsonb_build_object('ok', true, 'then', 'continue', 'continue', jsonb_build_object('agent', v_row->>'agent', 'as', 'task',
            'text', 'The final check found nothing to clear. Propose to publish the plan now (tool_publish_plan).'));
    END IF;

    IF v_key = 'accept' AND jsonb_typeof(v_pay->'proposal') = 'object' THEN
        v_r := agent.fn_advisor_save_section(jsonb_build_object('domain', v_domain, 'chat_id', v_chat) || (v_pay->'proposal'));
        IF (v_r->>'ok')::boolean IS NOT TRUE THEN
            UPDATE agent.chat_prompts SET status = 'superseded', decided_at = clock_timestamp() WHERE id = v_id;
            RETURN jsonb_build_object('ok', false, 'reason', 'save_failed',
                'toast', core.fn_ui_text('core.toast.prompt_save_failed', v_lang), 'then', 'continue',
                'continue', jsonb_build_object('agent', v_row->>'agent', 'as', 'task',
                    'text', format('Saving the proposal of check point "%s" failed (%s): %s Propose a corrected change for this point.',
                                   v_pay->>'text', COALESCE(v_r->>'code', 'rejected'), v_r->>'reason')));
        END IF;
        UPDATE agent.chat_prompts SET payload = payload || '{"outcome":"resolved","changed":true}' WHERE id = v_id;
        v_out := jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.accepted', v_lang));
    ELSIF v_key = 'keep' THEN
        UPDATE agent.chat_prompts
           SET payload = payload || jsonb_build_object('outcome', CASE WHEN v_pay->>'category' = 'open_point' THEN 'deferred' ELSE 'accepted' END)
         WHERE id = v_id;
        v_out := jsonb_build_object('ok', true, 'append', core.fn_ui_text('core.prompt.kept', v_lang));
    ELSE
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_option');
    END IF;

    IF EXISTS (SELECT 1 FROM agent.chat_prompts c WHERE c.plan_id = v_plan AND c.kind = 'finding' AND c.status = 'queued'
                  AND (c.payload->>'pass')::int = v_pass) THEN
        RETURN v_out || jsonb_build_object('then', 'next');
    END IF;
    v_max := core.fn_advisor_check_max_passes();
    SELECT bool_or(COALESCE((c.payload->>'changed')::boolean, false)) INTO v_changed FROM agent.chat_prompts c
     WHERE c.plan_id = v_plan AND c.kind = 'finding' AND (c.payload->>'pass')::int = v_pass AND c.status <> 'superseded';
    IF COALESCE(v_changed, false) AND v_pass < v_max THEN
        RETURN v_out || jsonb_build_object('then', 'continue', 'continue', jsonb_build_object('agent', v_row->>'agent', 'as', 'task',
            'text', 'Check points changed the plan. Run the second and last check pass: read the whole draft once more and call '
                    || 'tool_record_check_findings with every remaining contradiction or gap ([] if none). Write nothing else.'));
    END IF;
    RETURN v_out || jsonb_build_object('then', 'continue', 'continue', jsonb_build_object('agent', v_row->>'agent', 'as', 'task',
        'text', 'The final check is complete; anything still open stays deliberately open. Propose to publish the plan now (tool_publish_plan).'));
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_prompt_answer_finding(jsonb) FROM public;
