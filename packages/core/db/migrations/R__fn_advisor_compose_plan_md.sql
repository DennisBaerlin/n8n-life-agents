-- ============================================================
-- agent.fn_advisor_compose_plan_md(p_plan_id, p_reminders) — der Plan-Text aus den gespeicherten Themen (READ)
--   Beim Veroeffentlichen setzt die DB plan_md zusammen; das Modell schreibt den ganzen Plan nicht mehr (ein grosser Plan
--   passt nicht in eine Modell-Antwort: abgeschnitten, neu angesetzt, bis zur Iterations-Grenze).
--   Aufbau: "# <plan_name>", je Teil in der Reihenfolge von core.fn_advisor_parts "## <Abschnitts-Name>" (Katalog
--   <paket>.plan_section.<key> in der Sprache der Plan-Person, beim Haushalts-Plan des Owners), darunter je Thema
--   "### <Thema>", Text, Zeile core.plan_md.why {text} und je offenem Punkt core.plan_md.open_point {text}; ein Abschnitt
--   ohne Themen mit content, sonst legacy_content, dazu dieselben Zeilen fuer why und offene Punkte am Abschnitt; ein Teil
--   ohne Inhalt mit core.plan_md.part_open (sichtbar statt Luecke).
--   Abschnitte ausserhalb der Teile folgen alphabetisch. Danach, wenn p_reminders Eintraege hat (die reminders des Publish,
--   [{label, remind_on ISO, deadline?}]), der Abschnitt core.plan_md.dates_head mit je Termin core.plan_md.date_line bzw. bei
--   deadline core.plan_md.date_deadline {date, label} in Datums-Reihenfolge, nur aus der Liste. Am Ende der feste Satz core.plan_md.footer.
--   Rueckgabe text (NULL bei unbekannter plan_id). Der Aufrufer (agent.fn_advisor_publish_plan) entfernt wie bisher einen
--   "## Gelernt"-Block aus dem Text und haengt den gespeicherten an.
--   STABLE, INVOKER, search_path gepinnt; plpgsql (late-bound).
--   Tests: tests/db/core/test_fn_advisor_compose_plan_md.sql
-- ============================================================
DROP FUNCTION IF EXISTS agent.fn_advisor_compose_plan_md(int);
CREATE OR REPLACE FUNCTION agent.fn_advisor_compose_plan_md(p_plan_id int, p_reminders jsonb DEFAULT '[]'::jsonb)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_plan  agent.advisor_plans%ROWTYPE;
    v_pkg   text;
    v_lang  text;
    v_state jsonb;
    v_keys  text[];
    v_k     text;
    v_sec   jsonb;
    v_blocks jsonb;
    v_body  text;
    v_parts text[] := '{}';
    v_dates text;
BEGIN
    SELECT * INTO v_plan FROM agent.advisor_plans WHERE id = p_plan_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    v_pkg   := COALESCE((SELECT a.package FROM core.advisors a WHERE a.domain = regexp_replace(v_plan.domain, '^__e2e_(.+)__$', '\1')), 'core');
    v_lang  := agent.fn_person_lang(COALESCE(v_plan.person_id, agent.fn_owner_person_id()))->>'lang';
    v_state := CASE WHEN jsonb_typeof(v_plan.interview_state) = 'object' THEN v_plan.interview_state ELSE '{}'::jsonb END;
    v_keys  := ARRAY(SELECT e->>'section_key' FROM jsonb_array_elements(core.fn_advisor_parts(v_plan.domain)) e ORDER BY (e->>'n')::int)
            || ARRAY(SELECT s FROM jsonb_object_keys(v_state) s
                      WHERE NOT s = ANY (ARRAY(SELECT e->>'section_key' FROM jsonb_array_elements(core.fn_advisor_parts(v_plan.domain)) e))
                      ORDER BY s);
    FOREACH v_k IN ARRAY v_keys LOOP
        v_sec := CASE WHEN jsonb_typeof(v_state->v_k) = 'object' THEN v_state->v_k ELSE '{}'::jsonb END;
        -- ein Abschnitt ohne Themen ist ein Block ohne Ueberschrift (topic fehlt -> concat_ws laesst die Zeile weg)
        v_blocks := CASE WHEN jsonb_typeof(v_sec->'topics') = 'array' AND jsonb_array_length(v_sec->'topics') > 0 THEN v_sec->'topics'
                         ELSE jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                                  'content', COALESCE(NULLIF(btrim(COALESCE(v_sec->>'content', '')), ''), NULLIF(btrim(COALESCE(v_sec->>'legacy_content', '')), ''),
                                                      core.fn_ui_text('core.plan_md.part_open', v_lang)),
                                  'why', v_sec->'why', 'open_points', v_sec->'open_points'))) END;
        SELECT string_agg(concat_ws(E'\n\n',
                   '### ' || (t->>'topic'),
                   t->>'content',
                   CASE WHEN btrim(COALESCE(t->>'why', '')) <> '' THEN core.fn_ui_text('core.plan_md.why', v_lang, jsonb_build_object('text', t->>'why')) END,
                   (SELECT string_agg('- ' || core.fn_ui_text('core.plan_md.open_point', v_lang, jsonb_build_object('text', o->>'text')), E'\n' ORDER BY (o->>'id')::int)
                      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t->'open_points') = 'array' THEN t->'open_points' ELSE '[]'::jsonb END) o
                     WHERE NOT o ? 'resolved_at')), E'\n\n' ORDER BY i)
          INTO v_body
          FROM jsonb_array_elements(v_blocks) WITH ORDINALITY AS x(t, i);
        v_parts := v_parts || ('## ' || core.fn_ui_text(v_pkg || '.plan_section.' || v_k, v_lang) || E'\n\n' || v_body);
    END LOOP;
    -- Termine nur aus der Liste (Rohwerte, geprueft von core.fn_plan_sync im selben Publish); unlesbare Eintraege fehlen hier,
    -- der Publish lehnt sie dort ohnehin ab.
    SELECT string_agg('- ' || core.fn_ui_text(CASE WHEN COALESCE((r->>'deadline')::boolean, false) THEN 'core.plan_md.date_deadline' ELSE 'core.plan_md.date_line' END,
                                v_lang, jsonb_build_object('date', core.fn_ui_date((r->>'remind_on')::date), 'label', btrim(r->>'label'))),
                      E'\n' ORDER BY (r->>'remind_on')::date, btrim(r->>'label'))
      INTO v_dates
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_reminders) = 'array' THEN p_reminders ELSE '[]'::jsonb END) r
     WHERE jsonb_typeof(r) = 'object' AND COALESCE(r->>'remind_on', '') ~ '^\d{4}-\d{2}-\d{2}$' AND btrim(COALESCE(r->>'label', '')) <> ''
       AND pg_input_is_valid(r->>'remind_on', 'date');   -- die Form allein laesst den 30. Februar durch, der Cast wuerfe
    IF v_dates IS NOT NULL THEN
        v_parts := v_parts || ('## ' || core.fn_ui_text('core.plan_md.dates_head', v_lang) || E'\n\n' || v_dates);
    END IF;
    RETURN '# ' || v_plan.plan_name || E'\n\n' || array_to_string(v_parts, E'\n\n')
        || E'\n\n' || core.fn_ui_text('core.plan_md.footer', v_lang);
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_advisor_compose_plan_md(int, jsonb) FROM public;
