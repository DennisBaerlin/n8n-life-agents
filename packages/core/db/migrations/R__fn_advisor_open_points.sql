-- ============================================================
-- core.fn_advisor_open_points(p_domain, p_chat_id) — bewusst offene Punkte eines Plans (READ)
--   Offene Punkte leben im Thema (interview_state.<abschnitt>.topics[].open_points, ohne Themen am Abschnitt), keine eigene
--   Tabelle; Ids vergibt agent.fn_advisor_save_section. Gelesen wird der Entwurf, ohne Entwurf der aktive Plan, ueber
--   core.fn_advisor_read_plan (dieselbe Personen-Regel: household -> Haushalts-Plan, per_user -> der Sender).
--   Verbraucher: Kontext-Kopf des Beraters, Themen-Karte ("Noch offen"), Schlussprüfung (Art open_point), Stand.
--   Rueckgabe jsonb [{id, text, section_key, topic}] (topic NULL am Abschnitt), nur ungeschlossene, nach id.
--   SECURITY DEFINER (liest agent.advisor_plans ueber das Lesefenster), STABLE, search_path gepinnt; EXECUTE an die
--   Paket-Rollen (core.fn_provision_package_roles) und die Host-Cred; bewusst nicht core_ro (Frei-SQL laese sonst Plan-Texte).
--   Hilfs-fns derselben Familie: core.fn_plan_open_points(state) (alle Punkte eines interview_state, auch geschlossene) und
--   core.fn_plan_close_points(state, ids, by) (setzt resolved_at/resolved_by; Aufrufer prueft die Ids vorher),
--   core.fn_plan_merge_points(bisherige, neue) (anhaengen ohne Dublette eines noch offenen Texts).
--   Tests: tests/db/core/test_fn_advisor_save_section_fields.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_open_points(p_state jsonb)
RETURNS TABLE (id int, text text, section_key text, topic text, resolved boolean)
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT (o->>'id')::int, o->>'text', s.key, NULL::text, o ? 'resolved_at'
      FROM jsonb_each(CASE WHEN jsonb_typeof(p_state) = 'object' THEN p_state ELSE '{}'::jsonb END) AS s,
           jsonb_array_elements(CASE WHEN jsonb_typeof(s.value->'open_points') = 'array' THEN s.value->'open_points' ELSE '[]'::jsonb END) AS o
    UNION ALL
    SELECT (o->>'id')::int, o->>'text', s.key, t->>'topic', o ? 'resolved_at'
      FROM jsonb_each(CASE WHEN jsonb_typeof(p_state) = 'object' THEN p_state ELSE '{}'::jsonb END) AS s,
           jsonb_array_elements(CASE WHEN jsonb_typeof(s.value->'topics') = 'array' THEN s.value->'topics' ELSE '[]'::jsonb END) AS t,
           jsonb_array_elements(CASE WHEN jsonb_typeof(t->'open_points') = 'array' THEN t->'open_points' ELSE '[]'::jsonb END) AS o;
$$;

CREATE OR REPLACE FUNCTION core.fn_plan_close_list(p_list jsonb, p_ids int[], p_by text)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(jsonb_agg(CASE WHEN (o->>'id')::int = ANY (p_ids) AND NOT o ? 'resolved_at'
                                   THEN o || jsonb_build_object('resolved_at', now(), 'resolved_by', p_by) ELSE o END
                              ORDER BY i), '[]'::jsonb)
      FROM jsonb_array_elements(p_list) WITH ORDINALITY AS x(o, i);
$$;

CREATE OR REPLACE FUNCTION core.fn_plan_close_points(p_state jsonb, p_ids int[], p_by text)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(jsonb_object_agg(s.key, CASE WHEN jsonb_typeof(s.value) <> 'object' THEN s.value ELSE
               s.value
               || CASE WHEN jsonb_typeof(s.value->'open_points') = 'array'
                       THEN jsonb_build_object('open_points', core.fn_plan_close_list(s.value->'open_points', p_ids, p_by))
                       ELSE '{}'::jsonb END
               || CASE WHEN jsonb_typeof(s.value->'topics') = 'array'
                       THEN jsonb_build_object('topics', COALESCE((
                              SELECT jsonb_agg(CASE WHEN jsonb_typeof(t->'open_points') = 'array'
                                                    THEN t || jsonb_build_object('open_points', core.fn_plan_close_list(t->'open_points', p_ids, p_by))
                                                    ELSE t END ORDER BY i)
                                FROM jsonb_array_elements(s.value->'topics') WITH ORDINALITY AS x(t, i)), '[]'::jsonb))
                       ELSE '{}'::jsonb END
           END), '{}'::jsonb)
      FROM jsonb_each(p_state) AS s;
$$;

-- core.fn_plan_merge_points(bisherige, neue): haengt neue offene Punkte an; ein neuer mit dem Text eines noch offenen
-- (ohne Gross-/Kleinschreibung) entfaellt (ein Vorschlag, der nach einer Anmerkung neu kommt, traegt seine Punkte erneut mit).
CREATE OR REPLACE FUNCTION core.fn_plan_merge_points(p_old jsonb, p_new jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(CASE WHEN jsonb_typeof(p_old) = 'array' THEN p_old END, '[]'::jsonb)
        || COALESCE((SELECT jsonb_agg(n ORDER BY i) FROM jsonb_array_elements(COALESCE(p_new, '[]'::jsonb)) WITH ORDINALITY AS x(n, i)
                      WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_old) = 'array' THEN p_old ELSE '[]'::jsonb END) o
                                         WHERE NOT o ? 'resolved_at' AND lower(btrim(o->>'text')) = lower(btrim(n->>'text')))), '[]'::jsonb);
$$;

CREATE OR REPLACE FUNCTION core.fn_advisor_open_points(p_domain text, p_chat_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_state jsonb;
BEGIN
    SELECT rp.interview_state INTO v_state
      FROM core.fn_advisor_read_plan(p_domain, p_chat_id) rp
     ORDER BY (rp.status = 'draft') DESC LIMIT 1;
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', o.id, 'text', o.text, 'section_key', o.section_key, 'topic', o.topic)
                                      ORDER BY o.id)
                       FROM core.fn_plan_open_points(v_state) o WHERE NOT o.resolved), '[]'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_open_points(text, text) FROM public;
