-- ============================================================
-- fn_advisor_plan_changes (READ, STABLE — was ein Entwurf gegenueber dem aktiven Plan aendert)
--   Vergleicht den Plan p_plan_id (Entwurf) mit dem aktiven Plan derselben (Domain, Person), Abschnitt fuer Abschnitt in
--   Katalog-Reihenfolge (core.fn_advisor_parts, danach uebrige Schluessel alphabetisch wie agent.fn_advisor_compose_plan_md).
--   Haben beide Seiten Themen (oder fehlt der Abschnitt auf einer Seite ganz): je Thema das Label als neu, geaendert oder
--   entfallen (Identitaet lower(btrim(topic)) wie fn_advisor_save_section). Hat nur eine Seite Themen (Altbestand mit
--   content) oder keine: der Abschnitt als Ganzes mit seinem Anzeigenamen (<paket>.plan_section.<key>), nie dem Schluessel.
--   Verglichen wird nur, was ins Plan-Dokument geht (agent.fn_advisor_topic_norm): Text, why, data ohne as_of, Texte der
--   ungeloesten offenen Punkte; saved_at, Punkt-ids und Stempel zaehlen nicht. Nicht-Objekte im Zustand werden uebergangen.
--   Quelle der Zeile "Aenderungen" der Veroeffentlichungs-Karte und der gespeicherten Aenderungs-Zusammenfassung
--   (agent.fn_advisor_publish_plan): das Modell kopiert keine Themen-Liste.
--   Eingabe: p_plan_id (Pflicht), p_lang (Sprache des Textes; NULL = Sprache des Owners).
--   Rueckgabe: jsonb {first, new[], changed[], removed[], text} (text = core.tpl.plan_changes_first | _none | Teile
--     _new/_changed/_removed mit ' · ', je Art hoechstens sechs Labels plus core.tpl.plan_changes_more {n});
--     unbekannte plan_id -> NULL.
--   Tests: tests/db/core/test_fn_advisor_plan_changes.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_advisor_topic_norm(t jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'content', btrim(COALESCE(t->>'content', t->>'legacy_content', '')),
        'why',     btrim(COALESCE(t->>'why', '')),
        'data',    COALESCE((SELECT jsonb_object_agg(k, CASE WHEN jsonb_typeof(v) = 'object' THEN v - 'as_of' ELSE v END)
                               FROM jsonb_each(CASE WHEN jsonb_typeof(t->'data') = 'object' THEN t->'data' ELSE '{}'::jsonb END) x(k, v)), '{}'::jsonb),
        'open',    COALESCE((SELECT jsonb_agg(btrim(o->>'text') ORDER BY btrim(o->>'text'))
                               FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t->'open_points') = 'array' THEN t->'open_points' ELSE '[]'::jsonb END) o
                              WHERE jsonb_typeof(o) = 'object' AND NOT o ? 'resolved_at'), '[]'::jsonb));
$$;

CREATE OR REPLACE FUNCTION agent.fn_advisor_plan_changes(p_plan_id int, p_lang text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_plan   agent.advisor_plans%ROWTYPE;
    v_found  boolean;
    v_dst    jsonb;
    v_ast    jsonb;
    v_pkg    text;
    v_lang   text := COALESCE(p_lang, agent.fn_person_lang(agent.fn_owner_person_id())->>'lang');
    v_keys   text[];
    v_k      text;
    v_d      jsonb;
    v_a      jsonb;
    v_dt     jsonb;
    v_at     jsonb;
    v_lbl    text;
    v_new    jsonb := '[]'::jsonb;
    v_chg    jsonb := '[]'::jsonb;
    v_rem    jsonb := '[]'::jsonb;
    v_parts  text[] := '{}';
    v_kind   text;
    v_list   jsonb;
BEGIN
    SELECT * INTO v_plan FROM agent.advisor_plans WHERE id = p_plan_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT a.interview_state, true INTO v_ast, v_found FROM agent.advisor_plans a
     WHERE a.domain = v_plan.domain AND a.person_id IS NOT DISTINCT FROM v_plan.person_id AND a.status = 'active' AND a.id <> v_plan.id;
    IF v_found IS NOT TRUE THEN
        RETURN jsonb_build_object('first', true, 'new', '[]'::jsonb, 'changed', '[]'::jsonb, 'removed', '[]'::jsonb,
                                  'text', core.fn_ui_text('core.tpl.plan_changes_first', v_lang));
    END IF;
    v_dst := CASE WHEN jsonb_typeof(v_plan.interview_state) = 'object' THEN v_plan.interview_state ELSE '{}'::jsonb END;
    v_ast := CASE WHEN jsonb_typeof(v_ast) = 'object' THEN v_ast ELSE '{}'::jsonb END;
    v_pkg := COALESCE((SELECT a.package FROM core.advisors a WHERE a.domain = regexp_replace(v_plan.domain, '^__e2e_(.+)__$', '\1')), 'core');
    v_keys := ARRAY(SELECT e->>'section_key' FROM jsonb_array_elements(core.fn_advisor_parts(v_plan.domain)) e ORDER BY (e->>'n')::int)
           || ARRAY(SELECT DISTINCT s FROM (SELECT jsonb_object_keys(v_dst) UNION SELECT jsonb_object_keys(v_ast)) x(s)
                     WHERE NOT s = ANY (ARRAY(SELECT e->>'section_key' FROM jsonb_array_elements(core.fn_advisor_parts(v_plan.domain)) e))
                     ORDER BY s);

    FOREACH v_k IN ARRAY v_keys LOOP
        v_d  := CASE WHEN jsonb_typeof(v_dst->v_k) = 'object' THEN v_dst->v_k END;
        v_a  := CASE WHEN jsonb_typeof(v_ast->v_k) = 'object' THEN v_ast->v_k END;
        v_dt := CASE WHEN jsonb_typeof(v_d->'topics') = 'array' AND jsonb_array_length(v_d->'topics') > 0 THEN v_d->'topics' END;
        v_at := CASE WHEN jsonb_typeof(v_a->'topics') = 'array' AND jsonb_array_length(v_a->'topics') > 0 THEN v_a->'topics' END;
        IF (v_dt IS NOT NULL OR v_d IS NULL) AND (v_at IS NOT NULL OR v_a IS NULL) THEN
            -- Themen-Ebene (eine fehlende Seite = keine Themen)
            WITH d AS (SELECT t->>'topic' AS label, lower(btrim(t->>'topic')) AS id, agent.fn_advisor_topic_norm(t) AS body, i
                         FROM jsonb_array_elements(COALESCE(v_dt, '[]'::jsonb)) WITH ORDINALITY AS x(t, i) WHERE jsonb_typeof(t) = 'object'),
                 a AS (SELECT t->>'topic' AS label, lower(btrim(t->>'topic')) AS id, agent.fn_advisor_topic_norm(t) AS body, i
                         FROM jsonb_array_elements(COALESCE(v_at, '[]'::jsonb)) WITH ORDINALITY AS x(t, i) WHERE jsonb_typeof(t) = 'object')
            SELECT v_new || COALESCE((SELECT jsonb_agg(d.label ORDER BY d.i) FROM d WHERE NOT EXISTS (SELECT 1 FROM a WHERE a.id = d.id)), '[]'::jsonb),
                   v_chg || COALESCE((SELECT jsonb_agg(d.label ORDER BY d.i) FROM d JOIN a ON a.id = d.id WHERE a.body IS DISTINCT FROM d.body), '[]'::jsonb),
                   v_rem || COALESCE((SELECT jsonb_agg(a.label ORDER BY a.i) FROM a WHERE NOT EXISTS (SELECT 1 FROM d WHERE d.id = a.id)), '[]'::jsonb)
              INTO v_new, v_chg, v_rem;
        ELSE
            -- Abschnitts-Ebene: nur eine Seite hat Themen (Altbestand) oder keine
            v_lbl := core.fn_ui_text(v_pkg || '.plan_section.' || v_k, v_lang);
            IF v_a IS NULL THEN
                v_new := v_new || to_jsonb(v_lbl);
            ELSIF v_d IS NULL THEN
                v_rem := v_rem || to_jsonb(v_lbl);
            ELSIF (SELECT COALESCE(jsonb_agg(agent.fn_advisor_topic_norm(t) ORDER BY i), agent.fn_advisor_topic_norm(v_d))
                  FROM jsonb_array_elements(COALESCE(v_dt, '[]'::jsonb)) WITH ORDINALITY AS x(t, i))
               IS DISTINCT FROM
               (SELECT COALESCE(jsonb_agg(agent.fn_advisor_topic_norm(t) ORDER BY i), agent.fn_advisor_topic_norm(v_a))
                  FROM jsonb_array_elements(COALESCE(v_at, '[]'::jsonb)) WITH ORDINALITY AS x(t, i)) THEN
                v_chg := v_chg || to_jsonb(v_lbl);
            END IF;
        END IF;
    END LOOP;

    FOREACH v_kind IN ARRAY ARRAY['new', 'changed', 'removed'] LOOP
        v_list := CASE v_kind WHEN 'new' THEN v_new WHEN 'changed' THEN v_chg ELSE v_rem END;
        CONTINUE WHEN jsonb_array_length(v_list) = 0;
        v_parts := v_parts || core.fn_ui_text(CASE v_kind WHEN 'new' THEN 'core.tpl.plan_changes_new' WHEN 'changed' THEN 'core.tpl.plan_changes_changed'
                                                       ELSE 'core.tpl.plan_changes_removed' END, v_lang, jsonb_build_object('topics',
            (SELECT string_agg(l, ', ' ORDER BY i) FROM jsonb_array_elements_text(v_list) WITH ORDINALITY AS x(l, i) WHERE i <= 6)
            || CASE WHEN jsonb_array_length(v_list) > 6
                    THEN ' ' || core.fn_ui_text('core.tpl.plan_changes_more', v_lang, jsonb_build_object('n', jsonb_array_length(v_list) - 6))
                    ELSE '' END));
    END LOOP;

    RETURN jsonb_build_object('first', false, 'new', v_new, 'changed', v_chg, 'removed', v_rem,
        'text', CASE WHEN cardinality(v_parts) = 0 THEN core.fn_ui_text('core.tpl.plan_changes_none', v_lang)
                     ELSE array_to_string(v_parts, ' · ') END);
END;
$$;
