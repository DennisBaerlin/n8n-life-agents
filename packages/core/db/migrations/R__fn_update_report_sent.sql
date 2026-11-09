-- ============================================================
-- core.fn_update_report_sent(p) (Write)
--   Der root-Runner vermerkt die erfolgreiche Zustellung einer Ergebnis-Meldung, erst nach Telegram-2xx: eine verlorene
--   Meldung waere schlimmer als eine seltene doppelte (Telegram kennt keinen Schutz gegen doppeltes Senden).
--   p: {id}
--   RUECKGABE: {ok:true, changed} | {ok:false, reason:'invalid'}. Nie RAISE. INVOKER (root ueber runuser postgres).
--   Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_update_report_sent(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id   bigint;
    v_done bigint;
BEGIN
    BEGIN
        v_id := (p->>'id')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_id := NULL;
    END;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
    END IF;
    UPDATE core.update_requests SET report_state = 'sent'
     WHERE id = v_id AND report_state = 'due'
    RETURNING id INTO v_done;
    RETURN jsonb_build_object('ok', true, 'changed', v_done IS NOT NULL);
END;
$$;
