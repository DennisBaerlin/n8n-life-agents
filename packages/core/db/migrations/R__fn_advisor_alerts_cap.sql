-- ============================================================
-- core.fn_advisor_alerts_cap (Punkte-Grenze je Waechter-Nachricht)
--   Sortiert die Alarme einer Nachricht ueber alle Domains und Personen (priority DESC, fehlend = 50, dann Eingang) und
--   behaelt 3 Punkte, wenn ein Lauf der Nachricht first_run ist, sonst 5. Gekuerzte Punkte verlieren ihre in diesem Lauf
--   frisch gesetzten Merker (_latched aus core.fn_advisor_review_evaluate) und gelten am naechsten Lauf wieder als neu.
--   Eingaben: p_alerts (jsonb-Array), p_first_run. Rueckgabe: {alerts:[ohne _latched], more_count, more_line} mit
--   more_line = fertiges tpl der Hinweiszeile (Einzahl/Mehrzahl waehlt die DB), NULL ohne Rest.
--   Seiteneffekt: core.fn_notify_resolve je gekuerztem Merker. SECURITY INVOKER wie der Evaluate-Aufrufer (Haupt-RW-Cron).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_alerts_cap(p_alerts jsonb, p_first_run boolean DEFAULT FALSE)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog
AS $$
DECLARE
    v_limit int := CASE WHEN p_first_run THEN 3 ELSE 5 END;
    v_kept  jsonb := '[]'::jsonb;
    v_more  int := 0;
    r       record;
    v_lat   jsonb;
BEGIN
    FOR r IN
        SELECT a, row_number() OVER (ORDER BY COALESCE((a->>'priority')::numeric, 50) DESC, ord) AS rn
        FROM jsonb_array_elements(COALESCE(p_alerts, '[]'::jsonb)) WITH ORDINALITY t(a, ord)
        ORDER BY rn
    LOOP
        IF r.rn <= v_limit THEN
            v_kept := v_kept || (r.a - '_latched');
        ELSE
            v_more := v_more + 1;
            FOR v_lat IN SELECT * FROM jsonb_array_elements(COALESCE(r.a->'_latched', '[]'::jsonb)) LOOP
                PERFORM core.fn_notify_resolve(v_lat->>'source', v_lat->>'key');
            END LOOP;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('alerts', v_kept, 'more_count', v_more,
        'more_line', CASE WHEN v_more > 0 THEN core.fn_ui_tpl(
            CASE WHEN v_more = 1 THEN 'core.advisor.more_one' ELSE 'core.advisor.more_count' END,
            jsonb_build_object('n', core.fn_ui_num(v_more))) END);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_alerts_cap(jsonb, boolean) FROM public;
