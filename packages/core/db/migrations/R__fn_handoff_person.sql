-- ============================================================
-- core.fn_handoff_person(p_chat_id) — Person einer vereinbarten Plan-Aufgabe (agent.handoff_tasks) aus der chat_id
--   Numerische chat_id -> person_id des aufgeloesten Senders (agent.fn_resolve_sender), unbekannt -> NULL.
--   Nicht-numerisch und nicht leer (E2E-Sentinel 'test_e2e...') -> der Owner (agent.fn_owner_person_id), damit der
--   E2E-Pfad des Beraters dieselbe Kette laeuft wie produktiv. Leer/NULL -> NULL. Nie vom LLM.
--   Konsumenten: agent.fn_advisor_save_section (Anlage), core.fn_handoff_overview, core.fn_handoff_task_check,
--   core.fn_cancel_handoff_task. Tests: tests/db/core/test_fn_handoff_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_person(p_chat_id text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_sender jsonb;
BEGIN
    IF COALESCE(p_chat_id, '') ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(p_chat_id::bigint);
        IF COALESCE((v_sender->>'found')::boolean, false) THEN
            RETURN v_sender->>'person_id';
        END IF;
        RETURN NULL;
    END IF;
    IF btrim(COALESCE(p_chat_id, '')) = '' THEN
        RETURN NULL;
    END IF;
    RETURN agent.fn_owner_person_id();
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_person(text) FROM public;
