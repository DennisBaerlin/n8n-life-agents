-- ============================================================
-- core.fn_render_prompt(p_id) — Karte und Knoepfe einer offenen Frage, fertig in der Sprache des Chats (READ)
--   Rendert die Karten-Spezifikation agent.chat_prompts.card beim Senden (nie beim Anlegen): Spezifikations-Zeilen
--   {kind, text} | {kind, key, params} | {kind:'expand', title|title_key, text} | {kind:'facts', domain, section_key}.
--     text-Zeilen laufen durch core.fn_render_plan_text, key-Zeilen durch core.fn_ui_text (Sprache der Person des Chats);
--     facts = "Stand heute" der Paket-fn core.advisors.section_facts_fn(section_key, chat_id) als hoechstens 6 Zitat-
--     Zeilen mit Kopfzeile core.prompt.facts_head; fehlt die fn, wirft sie oder liefert sie nichts -> keine Zeilen
--     (die Karte bleibt).
--   Knoepfe aus options [{key, label | label_key}] mit data (= callback_data) q:<id>:<key>; alle in einer Reihe, wenn es
--   hoechstens drei sind und ihre Beschriftungen zusammen hoechstens 36 Zeichen haben, sonst einer je Reihe.
--   Rueckgabe {card:{lines:[{kind, text[, title]}]}, buttons:[[{text, data}]]} | NULL (unbekannte id). Klartext: Escaping
--   und Telegram-Format macht der Renderer im Orchestrator (Vertrag der Zeilenarten: head, quote, label, text, expand, row,
--   total, warning, hint).
--   STABLE, INVOKER (Host-Cred), search_path gepinnt. plpgsql: ruft alphabetisch spaetere R__-fns (late-bound).
--   Tests: tests/db/core/test_chat_prompts.sql, tests/db/core/test_fn_advisor_propose_topics.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_render_prompt(p_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_row   agent.chat_prompts%ROWTYPE;
    v_lang  text;
    v_lines jsonb := '[]'::jsonb;
    l       jsonb;
    v_fn    regprocedure;
    v_facts jsonb;
    v_btns  jsonb;
BEGIN
    SELECT * INTO v_row FROM agent.chat_prompts WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    v_lang := agent.fn_person_lang(v_row.person_id)->>'lang';

    FOR l IN SELECT e FROM jsonb_array_elements(COALESCE(v_row.card->'lines', '[]'::jsonb)) AS x(e) LOOP
        IF l->>'kind' = 'facts' THEN
            v_facts := NULL;
            BEGIN
                v_fn := to_regprocedure((SELECT a.section_facts_fn FROM core.advisors a
                                          WHERE a.domain = regexp_replace(l->>'domain', '^__e2e_(.+)__$', '\1')) || '(text,text)');
                IF v_fn IS NOT NULL THEN
                    EXECUTE format('SELECT %s($1, $2)', v_fn::regproc) INTO v_facts USING l->>'section_key', v_row.chat_id;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                v_facts := NULL;
            END;
            IF jsonb_typeof(v_facts) = 'array' AND jsonb_array_length(v_facts) > 0 THEN
                v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'quote',
                               'text', core.fn_ui_text('core.prompt.facts_head', v_lang)))
                        || (SELECT jsonb_agg(jsonb_build_object('kind', 'quote', 'text', concat_ws(': ', f->>'label', f->>'value')) ORDER BY i)
                              FROM jsonb_array_elements(v_facts) WITH ORDINALITY AS y(f, i) WHERE i <= 6);
            END IF;
        ELSIF l->>'kind' = 'expand' THEN
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'expand',
                'title', COALESCE(l->>'title', core.fn_ui_text(l->>'title_key', v_lang, COALESCE(l->'params', '{}'::jsonb))),
                'text', core.fn_render_plan_text(l->>'text', v_lang)));
        ELSE
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', COALESCE(l->>'kind', 'text'),
                'text', CASE WHEN l ? 'text' THEN core.fn_render_plan_text(l->>'text', v_lang)
                             ELSE core.fn_ui_text(l->>'key', v_lang, COALESCE(l->'params', '{}'::jsonb)) END));
        END IF;
    END LOOP;

    SELECT jsonb_agg(jsonb_build_object('text', COALESCE(o->>'label', core.fn_ui_text(o->>'label_key', v_lang)),
                                        'data', format('q:%s:%s', v_row.id, o->>'key')) ORDER BY i)
      INTO v_btns FROM jsonb_array_elements(v_row.options) WITH ORDINALITY AS x(o, i);
    v_btns := COALESCE(v_btns, '[]'::jsonb);
    IF jsonb_array_length(v_btns) <= 3
       AND (SELECT COALESCE(sum(length(b->>'text')), 0) FROM jsonb_array_elements(v_btns) b) <= 36 THEN
        v_btns := CASE WHEN jsonb_array_length(v_btns) = 0 THEN '[]'::jsonb ELSE jsonb_build_array(v_btns) END;
    ELSE
        v_btns := (SELECT jsonb_agg(jsonb_build_array(b) ORDER BY i) FROM jsonb_array_elements(v_btns) WITH ORDINALITY AS x(b, i));
    END IF;
    RETURN jsonb_build_object('card', jsonb_build_object('lines', v_lines), 'buttons', v_btns);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_render_prompt(bigint) FROM public;
