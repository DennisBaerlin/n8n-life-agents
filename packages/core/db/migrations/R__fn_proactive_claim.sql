-- ============================================================
-- core.fn_proactive_claim(person, slot, class) (WRITE -- darf diese ungefragte Nachricht heute raus?)
--   Der eine Budget-Weg: direkt vor dem Versand oder Merker-Schreiben aufrufen, wenn die Meldung feststeht. Budget und
--   Pause gehoeren dem Empfaenger. Ein belegter Slot gibt true ohne neuen Zaehler (ein Cron, mehrere Items = eine Nachricht).
--   Eingabe: p_person_id (NULL = Owner), p_slot, p_class:
--     normal   = gegen general.proactive_daily_max; abgewiesen -> core.proactive_deferred merkt den ersten Tag, nach
--                general.proactive_age_days wie priority (fn_proactive_has_room ist die Regel);
--     priority = nie abgewiesen, zaehlt mit, Pause gilt;
--     deadline = wie priority, Pause gilt nicht.
--   Rueckgabe boolean. In der Pause false ohne Eintrag (Meldung kommt beim naechsten regulaeren Lauf). Nie RAISE, Fehler
--   oder unbekannte Klasse -> true (eine Stoerung des Budgets darf keine Meldung verschlucken).
--   Advisory-Lock je Person gegen parallele Crons; raeumt Zeilen aelter als 7 Tage. Zaehltag core.fn_today().
--   DEFINER (Checkliste .claude/rules/sql.md): Paket-Rollen haben kein Tabellenrecht; EXECUTE in fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_proactive_claim.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_proactive_claim(p_person_id text, p_slot text, p_class text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_person text;
    v_today  date := core.fn_today();
BEGIN
    v_person := COALESCE(p_person_id, agent.fn_owner_person_id());
    IF v_person IS NULL OR p_slot IS NULL OR p_class IS NULL OR p_class NOT IN ('normal', 'priority', 'deadline') THEN RETURN true; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('core.proactive:' || v_person, 0));

    DELETE FROM core.proactive_budget WHERE person_id = v_person AND day < v_today - 7;
    DELETE FROM core.proactive_deferred WHERE person_id = v_person AND last_rejected < v_today - 7;

    IF p_class <> 'deadline' AND EXISTS (SELECT 1 FROM agent.reminder_pause WHERE person_id = v_person AND until_date >= v_today) THEN
        RETURN false;
    END IF;
    IF EXISTS (SELECT 1 FROM core.proactive_budget WHERE person_id = v_person AND day = v_today AND slot = p_slot) THEN
        RETURN true;
    END IF;
    IF p_class = 'normal' AND NOT core.fn_proactive_has_room(v_person, p_slot) THEN
        INSERT INTO core.proactive_deferred AS d (person_id, slot, since, last_rejected) VALUES (v_person, p_slot, v_today, v_today)
        ON CONFLICT (person_id, slot) DO UPDATE
           SET since = CASE WHEN d.last_rejected < v_today - 1 THEN v_today ELSE d.since END, last_rejected = v_today;
        RETURN false;
    END IF;

    INSERT INTO core.proactive_budget (person_id, day, slot, class) VALUES (v_person, v_today, p_slot, p_class)
    ON CONFLICT (person_id, day, slot) DO NOTHING;
    DELETE FROM core.proactive_deferred WHERE person_id = v_person AND slot = p_slot;
    RETURN true;
EXCEPTION WHEN OTHERS THEN
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_proactive_claim(text, text, text) FROM public;
