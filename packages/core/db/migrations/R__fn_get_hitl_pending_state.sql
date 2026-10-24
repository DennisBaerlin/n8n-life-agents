-- ============================================================
-- fn_get_hitl_pending_state (Karte-offen-Sperre, Fix C — read-only)
--   Zustand des Chats fuer den Orchestrator-Pre-Router ('Card open check', core_ro). DIE eine Stelle der
--   Ablauf-Logik (expires_at > now()): 'own' = mindestens eine Karte im Chat selbst offen (auch kurz nach dem
--   Tipp, solange die Kette noch antwortet); 'other' = nur Freigaben durch jemand anderen offen; NULL = frei.
--   SECURITY INVOKER: core_ro hat SELECT auf agent.* (util_create_core_ro.sql). NULL-Chat -> NULL.
--   RUECKGABE: text ('own' | 'other' | NULL)
--   Tests: tests/db/core/test_fn_hitl_pending.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_get_hitl_pending_state(p_chat_id bigint)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN bool_or(own_card) THEN 'own' ELSE 'other' END
      FROM agent.hitl_pending
     WHERE p_chat_id IS NOT NULL AND chat_id = p_chat_id AND expires_at > now()
    HAVING count(*) > 0;
$$;

REVOKE ALL ON FUNCTION agent.fn_get_hitl_pending_state(bigint) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_get_hitl_pending_state(BIGINT) FROM context_ro;
    END IF;
END $$;
