-- ============================================================
-- fn_schedule_dom_reason (READ HELPER) -- korrigierbarer Grund fuer einen ungueltigen Buchungstag
--   Die EINE Adresse des Fehlertexts (vorher 11 wortgleiche Kopien in den create_/set_-fns): NULL = gueltig
--   (fn_valid_schedule_dom), sonst der EN-Grund mit den erlaubten Werten 1-28, -1 (Monatsletzter), -2 (vorletzter Tag).
--   Aufrufer: fn_create_{insurance,pension,loan,savings_plan,savings_goal,recurring_transfer,recurring_payment},
--   fn_set_{loan,insurance,recurring_payment}, fn_interest_terms_reason (dort -2 vorher eigens abgelehnt).
--   plpgsql: alle Aufrufer liegen alphabetisch davor (late-bound); ruft selbst fn_valid_schedule_dom (spaeter, late-bound).
--   Test: tests/db/finance/test_schedule_dom_domain.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_schedule_dom_reason(p_dom int)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF finance.fn_valid_schedule_dom(p_dom) THEN
        RETURN NULL;
    END IF;
    RETURN 'Booking day ' || p_dom || ' is invalid - allowed are 1-28, -1 (last day of the month) or -2 (second-to-last '
        || 'day of the month); for the 29th/30th/31st use -1 (last day of the month).';
END;
$$;
