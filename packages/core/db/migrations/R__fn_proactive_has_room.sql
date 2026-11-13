-- ============================================================
-- fn_proactive_has_room (READ, SECURITY DEFINER) — hat ein normaler Slot heute noch Platz?
--   Die eine Regel fuer normal, auch von core.fn_proactive_claim genutzt. Fuer Wege, die vor teurer Beschaffung wissen
--   muessen, ob eine Meldung ueberhaupt raus darf (fn_monitor_due, fn_monitor_evaluate).
--   Eingabe: p_person_id (NULL = Owner), p_slot. Rueckgabe boolean: false bei laufender Pause oder wenn der Slot heute
--   schon belegt ist (Kein zweiter Lauf am Tag); true, wenn verschiedene Slots heute < general.proactive_daily_max oder
--   der Slot seit general.proactive_age_days ohne Unterbrechung wartet. Fehler -> true (fail-open). Schreibt nichts.
--   DEFINER: Aufrufer sind core.fn_proactive_claim und die Monitor-fns unter der Haupt-Credential; kein Grant an Paket-Rollen.
--   Tests: tests/db/core/test_fn_proactive_has_room.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_proactive_has_room(p_person_id text, p_slot text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_person text := COALESCE(p_person_id, agent.fn_owner_person_id());
    v_today  date := core.fn_today();
    v_max    int;
    v_age    int;
BEGIN
    IF EXISTS (SELECT 1 FROM agent.reminder_pause WHERE person_id = v_person AND until_date >= v_today) THEN RETURN false; END IF;
    IF EXISTS (SELECT 1 FROM core.proactive_budget WHERE person_id = v_person AND day = v_today AND slot = p_slot) THEN RETURN false; END IF;
    BEGIN
        v_max := core.fn_config_get('core', 'general', 'proactive_daily_max')::int;
    EXCEPTION WHEN OTHERS THEN v_max := NULL; END;
    BEGIN
        v_age := core.fn_config_get('core', 'general', 'proactive_age_days')::int;
    EXCEPTION WHEN OTHERS THEN v_age := NULL; END;
    IF (SELECT count(*) FROM core.proactive_budget WHERE person_id = v_person AND day = v_today) < GREATEST(COALESCE(v_max, 2), 0) THEN RETURN true; END IF;
    RETURN EXISTS (SELECT 1 FROM core.proactive_deferred WHERE person_id = v_person AND slot = p_slot AND since <= v_today - GREATEST(COALESCE(v_age, 3), 1) AND last_rejected >= v_today - 1);
EXCEPTION WHEN OTHERS THEN
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_proactive_has_room(text, text) FROM public;
