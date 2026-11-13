-- ============================================================
-- agent.fn_get_hitl_repeat_blocked (read-only, Wiederhol-Sperre des HITL-Gates)
--   Wurde dieselbe Karte im laufenden Vorgang dieses Chats schon nicht bestaetigt? Treffer nur bei gleichem Ursprungs-Chat,
--   gleichem Schluessel (agent.fn_hitl_repeat_key) und nicht abgelaufener Zeile (expires_at ist die Wahrheit). Das Gate
--   sendet dann keine Karte und liefert {approved:false, repeat_blocked:true}. Eine nicht-numerische chat_id (Test-Sentinel)
--   oder ein fehlendes Summary sperrt nie. plpgsql, weil agent.fn_hitl_repeat_key alphabetisch spaeter kommt.
--   Eingabe p: {chat_id, summary}
--   Rueckgabe: boolean
--   Tests: tests/db/core/test_fn_hitl_pending.sql; Gate-Rolle tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_get_hitl_repeat_blocked(p jsonb)
RETURNS boolean
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_key text := agent.fn_hitl_repeat_key(p->'summary');
BEGIN
    IF v_key IS NULL OR COALESCE(p->>'chat_id', '') !~ '^-?[0-9]+$' THEN
        RETURN false;
    END IF;
    RETURN EXISTS (
        SELECT 1 FROM agent.hitl_pending
         WHERE chat_id = (p->>'chat_id')::bigint AND decline_key = v_key AND expires_at > now());
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_get_hitl_repeat_blocked(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_get_hitl_repeat_blocked(JSONB) FROM context_ro;
    END IF;
END $$;
