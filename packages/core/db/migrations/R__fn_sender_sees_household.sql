-- ============================================================
-- core.fn_sender_sees_household(p_chat_id text) — sieht der Absender den Haushalt? (READ)
--   Die eine Regel fuer den Chat: das Tor im Vermittler (agent.sub_dispatch_agent), das Eingangs-Gate des Monitors, die
--   Wahl des Hilfe-Agent-Knotens, core.fn_fetch_context und die Trigger-fns fragen hier. Der Rollenteil ist allein
--   core.fn_app_sees_household (Allow-List owner/partner, dieselbe Regel wie die Mini-App).
--   Eingabe: p_chat_id = chat_id aus dem Agent-/Werkzeug-Start (produktiv die numerische telegram_user_id).
--   RUECKGABE boolean, nie NULL:
--     '^[0-9]{1,18}$' -> fn_app_sees_household(person_id aus agent.fn_resolve_sender); unbekannt -> false;
--     '^test_'        -> true (Test-Sentinel der Agent-Harnesses, deren chat_ids so heissen);
--     alles andere (NULL, leer, negativ/Gruppe, ueberlang, Leerzeichen, Buchstaben) -> false.
--   Bewusst anders als agent.fn_check_write_permission (adults_only laesst NULL/unbekannt durch: dort entscheidet danach
--   das HITL-Gate) und core.fn_plan_adult_recipients (nur partner: Empfaenger einer Info, nicht Sichtrecht).
--   SECURITY DEFINER (fn_app_sees_household ist REVOKE PUBLIC, fn_resolve_sender liest agent.*), search_path gepinnt,
--   REVOKE PUBLIC; EXECUTE an core_ro (Hilfe-Agent-Read, Monitor-Gate) in util_create_core_ro.sql.
--   Tests: tests/db/core/test_fn_sender_sees_household.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_sender_sees_household(p_chat_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_chat_id ~ '^test_' THEN
        RETURN true;
    END IF;
    IF p_chat_id IS NULL OR p_chat_id !~ '^[0-9]{1,18}$' THEN
        RETURN false;
    END IF;
    RETURN COALESCE(core.fn_app_sees_household(agent.fn_resolve_sender(p_chat_id::bigint)->>'person_id'), false);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_sender_sees_household(text) FROM public;
