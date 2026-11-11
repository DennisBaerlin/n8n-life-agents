-- ============================================================
-- finance.fn_sender_sees_household(p_chat_id text) — Tor „Haushalts-Sicht“ vor agent.finance und agent.finance_advisor (READ)
--   Sieht der Absender die Haushaltsfinanzen im Chat? Dieselbe Regel wie die Mini-App: core.fn_app_sees_household
--   (Allow-List owner/partner). Beide Finanz-Agenten fragen hier vor jedem LLM-Lauf; false -> fester Hinweis, kein Werkzeug.
--   Eingabe: p_chat_id = die chat_id aus dem Agent-Start (produktiv numerisch = telegram_user_id des Absenders, Gruppen
--   enden vorher im Orchestrator).
--   RUECKGABE boolean, nie NULL: nicht-numerische chat_id (Test-Sentinel der Agent-Tiers, z. B. test_ac01) -> true;
--   positive Zahl -> fn_app_sees_household(person_id aus agent.fn_resolve_sender); negative (Gruppe) oder ueberlange Zahl,
--   unbekannt, NULL, leer -> false.
--   SECURITY DEFINER (fn_app_sees_household ist REVOKE PUBLIC, fn_resolve_sender liest agent.*), gepinnter search_path,
--   REVOKE PUBLIC; Aufrufer ist der Gate-Knoten mit der Haupt-Credential.
--   Tests: tests/db/finance/test_fn_sender_sees_household.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_sender_sees_household(p_chat_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_chat_id IS NULL OR p_chat_id = '' THEN
        RETURN false;
    END IF;
    -- Nur eine Kennung ohne jede Ziffernform ist Test-Sentinel; negative (Gruppen) oder ueberlange Zahlen sperren.
    IF p_chat_id !~ '^-?[0-9]+$' THEN
        RETURN true;
    END IF;
    IF p_chat_id !~ '^[0-9]{1,18}$' THEN
        RETURN false;
    END IF;
    RETURN COALESCE(core.fn_app_sees_household(agent.fn_resolve_sender(p_chat_id::bigint)->>'person_id'), false);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_sender_sees_household(text) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_ro') THEN
        REVOKE ALL ON FUNCTION finance.fn_sender_sees_household(text) FROM finance_ro;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'finance_rw') THEN
        REVOKE ALL ON FUNCTION finance.fn_sender_sees_household(text) FROM finance_rw;
    END IF;
END $$;
