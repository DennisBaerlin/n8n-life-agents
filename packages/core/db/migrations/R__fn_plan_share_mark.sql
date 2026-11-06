-- ============================================================
-- core.fn_plan_share_mark(p) — zugestellte Plan-Nachrichten als "informiert" merken (Plan teilen, 2026-10-28)
--   Der Sub core.sub_share_plan ruft sie NACH den Sends mit den Personen, deren Nachricht zugestellt wurde. Je Person
--   core.fn_should_notify('plan_news', '<pid>:<domain>:p<plan_id>') (NULL-TTL, einmal je Person und Plan-Version).
--   Gescheiterte Sends werden nicht gemerkt -> ein zweiter Owner-Tipp erreicht sie noch. Bricht der Lauf zwischen Send
--   und Merken ab, kann eine Person die Nachricht doppelt bekommen (lieber doppelt als nie).
--   p: { domain, plan_id, person_ids:[...] }   RUECKGABE: {ok:true, marked}. Nie RAISE.
--   VOLATILE, SECURITY DEFINER, search_path gepinnt; EXECUTE nur die Host-Cred (REVOKE PUBLIC).
--   Tests: tests/db/core/test_fn_plan_share_targets.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_share_mark(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain text := COALESCE(p->>'domain', '');
    v_plan   text := COALESCE(p->>'plan_id', '');
    v_pid    text;
    v_n      int := 0;
BEGIN
    IF v_plan !~ '^[0-9]{1,9}$' OR v_domain !~ '^[a-z][a-z0-9_]*$' OR jsonb_typeof(p->'person_ids') IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object('ok', true, 'marked', 0);
    END IF;
    FOR v_pid IN SELECT jsonb_array_elements_text(p->'person_ids') LOOP
        CONTINUE WHEN v_pid !~ '^[a-z0-9_]+$';
        IF core.fn_should_notify('plan_news', v_pid || ':' || v_domain || ':p' || v_plan) THEN
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'marked', v_n);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_plan_share_mark(jsonb) FROM public;
