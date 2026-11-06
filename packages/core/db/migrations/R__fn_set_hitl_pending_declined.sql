-- ============================================================
-- agent.fn_set_hitl_pending_declined (Wiederhol-Sperre: Karte nicht bestaetigt)
--   Das HITL-Gate agent.tool_human_approval ruft sie an jedem Ausgang ohne Bestaetigung (Abbrechen ODER abgelaufen, das Gate
--   unterscheidet es nicht) mit seiner eigenen Execution-id: ALLE Zeilen dieser Execution bekommen den Schluessel der Karte
--   (agent.fn_hitl_repeat_key). Der Lebenszyklus bleibt der der Zeile: Der Orchestrator loescht sie nach seiner Antwort,
--   sonst verfaellt sie mit expires_at. Leser: agent.fn_get_hitl_repeat_blocked.
--   Fail-open wie die ganze Sperre: kein RAISE, ein Fehler kostet nur eine zweite Karte.
--   p: {execution_id, summary}
--   RUECKGABE: {ok:true, rows} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_hitl_pending.sql; Gate-Rolle tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_hitl_pending_declined(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_ex   text := NULLIF(btrim(COALESCE(p->>'execution_id', '')), '');
    v_rows int;
BEGIN
    IF v_ex IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'missing_execution_id');
    END IF;
    UPDATE agent.hitl_pending SET decline_key = agent.fn_hitl_repeat_key(p->'summary') WHERE execution_id = v_ex;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'rows', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_set_hitl_pending_declined(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_set_hitl_pending_declined(JSONB) FROM context_ro;
    END IF;
END $$;
