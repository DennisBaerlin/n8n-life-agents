-- ============================================================
-- fn_interest_schedule_reason (READ HELPER) -- Pflicht-Kadenz einer Zinszeile (Live-Befund 2026-10-24)
--   EINE Adresse fuer fn_create_account (erste Zinszeile, auch Import ueber fn_import_bundle) und
--   fn_interest_rate_preview (set_account_interest + Karte), angewandt auf die WIRKSAMEN Werte (nach dem Erben der
--   offenen Zeile). NULL = Kadenz vollstaendig, sonst der korrigierbare Grund (EN, nennt die Feldnamen des Tools).
--   Vorher erfand die DB still 'year' (Trade-Republic-Cashkonten liefen jaehrlich statt monatlich). Regeln:
--     * Rhythmus (unit) ist Pflicht -- nie angenommen; der Agent schlaegt die Konditionen nach oder fragt.
--     * Intervall >= 1.
--     * month -> Tag Pflicht: -1 (Ende des Monats/Quartals/Halbjahres, Kalender-Raster) oder fester Tag 1-28;
--       -1 nur mit n in {1,2,3,4,6,12} (Kalender-Perioden, fn_interest_grid_is_calendar).
--     * year  -> Tag leer (= Jahrestag des Starts) oder -1 (= 31.12.); ein fester Tag wuerde nicht wirken.
--     * day/week -> kein Tag.
--   Bewusst KEIN spiegelnder CHECK: ein (NOT VALID) CHECK wuerde auch das UPDATE valid_to von Altzeilen (z. B. month
--   ohne Tag) bei einem reinen Satzwechsel blockieren; schedule_unit NOT NULL bleibt der strukturelle Backstop.
--   p_fields: 'account' (interest_credit_*-Felder von tool_create_account) | 'rate' (schedule_*-Felder von
--   tool_set_account_interest).
--   plpgsql: Aufrufer liegen alphabetisch davor (fn_create_account, fn_interest_rate_preview) -> late-bound.
--   Tests: tests/db/finance/test_fn_create_account.sql, tests/db/finance/test_fn_set_account_interest.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_schedule_reason(
    p_unit finance.schedule_unit, p_interval int, p_dom int, p_fields text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_unit_f TEXT := CASE p_fields WHEN 'rate' THEN 'schedule_unit' ELSE 'interest_credit_unit' END;
    v_int_f  TEXT := CASE p_fields WHEN 'rate' THEN 'schedule_interval' ELSE 'interest_credit_interval' END;
    v_dom_f  TEXT := CASE p_fields WHEN 'rate' THEN 'schedule_day_of_month' ELSE 'interest_credit_day_of_month' END;
BEGIN
    IF p_unit IS NULL THEN
        RETURN 'The interest crediting rhythm (' || v_unit_f || ': day/week/month/year) is missing - it is never assumed. '
            || 'Look up the provider''s published conditions (web_search) or ask the user how often interest is credited.';
    END IF;
    IF COALESCE(p_interval, 1) < 1 THEN
        RETURN 'The crediting interval (' || v_int_f || ') must be at least 1, got ' || p_interval || '.';
    END IF;
    IF p_unit = 'month' AND p_dom IS NULL THEN
        RETURN 'Monthly crediting needs the crediting day (' || v_dom_f || '): -1 = at the end of the month (or quarter/'
            || 'half-year with ' || v_int_f || ' 3/6), or a fixed day 1-28. Look it up or ask the user.';
    END IF;
    IF p_unit = 'month' AND p_dom = -1 AND NOT finance.fn_interest_grid_is_calendar(COALESCE(p_interval, 1), p_unit, p_dom) THEN
        RETURN 'Crediting at the period end (' || v_dom_f || ' -1) works for ' || v_int_f || ' 1, 2, 3, 4, 6 or 12 months '
            || '(calendar periods), got ' || p_interval || '. Use one of these or a fixed day 1-28.';
    END IF;
    IF p_unit = 'year' AND p_dom IS NOT NULL AND p_dom <> -1 THEN
        RETURN 'For yearly crediting ' || v_dom_f || ' is -1 (on 31 December) or empty (on the anniversary of the start '
            || 'date); a fixed day ' || p_dom || ' is not supported.';
    END IF;
    IF p_unit IN ('day', 'week') AND p_dom IS NOT NULL THEN
        RETURN 'Daily or weekly crediting takes no crediting day - leave ' || v_dom_f || ' empty.';
    END IF;
    RETURN NULL;
END;
$$;
