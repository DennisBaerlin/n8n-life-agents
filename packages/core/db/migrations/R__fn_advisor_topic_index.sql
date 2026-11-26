-- ============================================================
-- core.fn_advisor_topic_index(p_domain, p_chat_id) — alle Themen aller Abschnitte eines Plans (READ)
--   Damit der Lesedurchgang der Schlussprüfung Doppelungen ueber Abschnitte hinweg sieht (ein Thema unter neuer
--   Bezeichnung in einem anderen Teil). Eigene fn statt Spalte an core.fn_advisor_read_plan: deren RETURNS TABLE liesse
--   sich nur per DROP erweitern, und ein DROP verloere die Grants an die Paket-Rollen bis zum naechsten Provision.
--   Gelesen wird der Entwurf, ohne Entwurf der aktive Plan (Personen-Regel ueber core.fn_advisor_read_plan).
--   Rueckgabe jsonb [{section_key, topic}] in Abschnitts- und Themen-Reihenfolge (Abschnitte alphabetisch).
--   SECURITY DEFINER, STABLE, search_path gepinnt; EXECUTE an die Paket-Rollen (core.fn_provision_package_roles).
--   Tests: tests/db/core/test_fn_advisor_save_section_fields.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_topic_index(p_domain text, p_chat_id text DEFAULT NULL)
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
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('section_key', s.key, 'topic', t->>'topic') ORDER BY s.key, i)
          FROM jsonb_each(CASE WHEN jsonb_typeof(v_state) = 'object' THEN v_state ELSE '{}'::jsonb END) AS s,
               jsonb_array_elements(CASE WHEN jsonb_typeof(s.value->'topics') = 'array' THEN s.value->'topics' ELSE '[]'::jsonb END)
                   WITH ORDINALITY AS x(t, i)), '[]'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_topic_index(text, text) FROM public;
