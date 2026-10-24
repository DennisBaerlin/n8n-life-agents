-- ============================================================
-- fn_delete_hitl_pending (Karte-offen-Sperre, Fix C)
--   Der Orchestrator ruft sie nach seiner Antwort: loescht die FREIGEGEBENEN Zeilen (released_at gesetzt) des
--   Chats — die Kette hinter der Karte ist dann fertig, ihr Chat-Gedaechtnis geschrieben. Offene Karten
--   (released_at NULL) bleiben unberuehrt. Nicht-numerische chat_id = no-op. Idempotent.
--   p: { chat_id }
--   RUECKGABE: {ok:true, removed}  (removed = es war eine freigegebene Zeile da)
--   Tests: tests/db/core/test_fn_hitl_pending.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_delete_hitl_pending(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_n int;
BEGIN
    IF COALESCE(p->>'chat_id', '') !~ '^-?[0-9]+$' THEN
        RETURN jsonb_build_object('ok', true, 'removed', false);
    END IF;

    DELETE FROM agent.hitl_pending
     WHERE chat_id = (p->>'chat_id')::bigint AND released_at IS NOT NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'removed', v_n > 0);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_delete_hitl_pending(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_delete_hitl_pending(JSONB) FROM context_ro;
    END IF;
END $$;
