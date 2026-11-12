-- ============================================================
-- core.fn_sender_is_household_restricted(p_chat_id text) — ist der Absender eine bekannte Person ohne Haushalts-Sicht? (READ)
--   Backstop der Werkzeug-fns (Monitor-Trigger): sperrt nur eine aufgeloeste Person, die den Haushalt nicht sieht (Kind,
--   Rolle fehlt). Unbekannte oder nicht-numerische chat_ids laesst sie durch: echte Unbekannte erreichen kein Werkzeug (das
--   Sender-Gate des Orchestrators endet vorher), und die Werkzeug-Harnesses arbeiten mit Test-chat_ids ohne Person. Das
--   fail-closed-Tor vor Agenten bleibt core.fn_sender_sees_household (Vermittler, Monitor-Eingang, Hilfe-Agent).
--   RUECKGABE boolean, nie NULL. SECURITY DEFINER, search_path gepinnt, REVOKE PUBLIC (Aufrufer: DEFINER-/Host-fns).
--   Tests: tests/db/core/test_monitor_child_view.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_sender_is_household_restricted(p_chat_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_sender jsonb;
BEGIN
    IF p_chat_id IS NULL OR p_chat_id !~ '^[0-9]{1,18}$' THEN
        RETURN false;
    END IF;
    v_sender := agent.fn_resolve_sender(p_chat_id::bigint);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN false;
    END IF;
    RETURN NOT COALESCE(core.fn_app_sees_household(v_sender->>'person_id'), false);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_sender_is_household_restricted(text) FROM public;
