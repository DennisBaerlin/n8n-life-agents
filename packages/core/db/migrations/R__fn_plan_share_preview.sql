-- ============================================================
-- core.fn_plan_share_preview(p_domain, p_version, p_chat_id) — Owner-Karte "Erwachsene informieren?" (2026-10-28)
--   Gerufen von agent.tool_publish_plan nach einem erfolgreichen Publish (read-only). shareable gdw der Betrachter der
--   Owner ist, p_version die aktive Version des Haushalts-Plans der Domain ist (core.fn_household_plan_active) und es
--   mindestens einen Empfaenger gibt (core.fn_plan_adult_recipients). names = Vornamen fuer den Kartentext.
--   RUECKGABE: {shareable, names:[...]} — nie RAISE (die Karte ist Komfort, das Publish ist schon geschehen).
--   STABLE, SECURITY DEFINER, search_path gepinnt; LANGUAGE plpgsql.
--   Tests: tests/db/core/test_fn_plan_share_targets.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_share_preview(p_domain text, p_version int, p_chat_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_names jsonb;
BEGIN
    IF p_chat_id IS NULL OR p_chat_id !~ '^[0-9]{1,18}$'
       OR (agent.fn_resolve_sender(p_chat_id::bigint)->>'role') IS DISTINCT FROM 'owner'
       OR NOT EXISTS (SELECT 1 FROM core.fn_household_plan_active(p_domain) h WHERE h.version = p_version) THEN
        RETURN jsonb_build_object('shareable', false, 'names', '[]'::jsonb);
    END IF;
    SELECT COALESCE(jsonb_agg(r.first_name ORDER BY r.person_id), '[]'::jsonb) INTO v_names
    FROM core.fn_plan_adult_recipients(p_domain) r;
    RETURN jsonb_build_object('shareable', jsonb_array_length(v_names) > 0, 'names', v_names);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_plan_share_preview(text, int, text) FROM public;
