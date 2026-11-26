-- ============================================================
-- core.fn_chat_person(p_chat_id) — Person eines Chats fuer die offene Frage und das Plan-Gespraech (READ)
--   Numerische chat_id (echter Telegram-Chat) -> agent.fn_resolve_sender. Test-Sentinel der Agent-Suiten ('test_…', z. B.
--   test_e2e_…, gleiche Regel wie core.fn_handoff_person) -> der Owner (agent.fn_owner_person_id), damit Agent-Tests dieselbe
--   Kette laufen wie produktiv. Alles andere -> nicht gefunden. Nie vom LLM.
--   Die zulaessige Form steht zusaetzlich als CHECK an agent.chat_prompts.chat_id (core.fn_chat_id_ok).
--   Rueckgabe {found, person_id, role[, test:true]}.
--   Familie: core.fn_chat_id_ok(p_chat_id) -> boolean (numerisch bis 18 Stellen oder Test-Sentinel).
--   Tests: tests/db/core/test_chat_prompts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_chat_id_ok(p_chat_id text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(p_chat_id ~ '^([0-9]{1,18}|test_[A-Za-z0-9_-]{1,60})$', false);
$$;

CREATE OR REPLACE FUNCTION core.fn_chat_person(p_chat_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pid text;
BEGIN
    IF COALESCE(p_chat_id, '') ~ '^[0-9]{1,18}$' THEN
        RETURN agent.fn_resolve_sender(p_chat_id::bigint);
    END IF;
    IF core.fn_chat_id_ok(p_chat_id) THEN
        v_pid := agent.fn_owner_person_id();
        RETURN jsonb_build_object('found', v_pid IS NOT NULL, 'person_id', v_pid, 'role', 'owner', 'test', true);
    END IF;
    RETURN jsonb_build_object('found', false);
END;
$$;
