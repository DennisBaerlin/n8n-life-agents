-- ============================================================
-- fn_interest_terms_reason (READ HELPER) -- Guard der Zins-Konditionen (Import-Haertung 2026-10-22)
--   EINE Adresse fuer fn_create_account (erste Zinszeile) und fn_interest_rate_preview (set_account_interest + Karte):
--   NULL = Konditionen gueltig, sonst der korrigierbare Grund (EN). Spiegel der CHECKs auf account_interest_rates:
--     * schedule_unit = Enum finance.schedule_unit (fn_enum_reason)
--     * Buchungstag 1-28 | -1 (finance_air_schedule_dom_chk): -2 (vorletzter Tag) gilt nur fuer Zahlungen und wird hier
--       eigens abgelehnt (das Zins-Raster fn_interest_grid_* kennt nur -1); sonst Text aus fn_schedule_dom_reason
--     * Gutschrift-Tag (posting_day_of_month) NUR 1-28 (finance_air_posting_dom_chk, V018): Arrears bucht am n-ten
--       des Folgemonats (fn_interest_due_open); -1 laege dort VOR dem Periodenende und rechnete still falsch
--     * Day-Count-Konvention in finance_air_day_count_chk (30E/360, ACT/365, ACT/360)
--   plpgsql statt sql: der Body referenziert fn_schedule_dom_reason (alphabetisch SPAETERES R__) -> bei Frisch-Install
--   wuerde eine sql-Function beim CREATE validiert und scheitern; plpgsql loest erst beim Aufruf auf.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_terms_reason(p_unit text, p_dom smallint, p_pdom smallint, p_conv text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN COALESCE(
        finance.fn_enum_reason('finance.schedule_unit'::regtype, p_unit, 'interest credit unit'),
        CASE WHEN p_dom = -2 THEN
            'Crediting day -2 (second-to-last day of the month) is not supported for interest - interest is credited '
            || 'at the period end (-1) or on a fixed day 1-28.' END,
        finance.fn_schedule_dom_reason(p_dom),
        CASE WHEN p_pdom IS NOT NULL AND p_pdom NOT BETWEEN 1 AND 28 THEN
            'Posting day ' || p_pdom || ' is invalid - interest paid in arrears is credited on day 1-28 of the following '
            || 'month (the last day of the month is not supported here).' END,
        CASE WHEN NULLIF(p_conv, '') IS NOT NULL AND p_conv NOT IN ('30E/360', 'ACT/365', 'ACT/360') THEN
            'Unknown day count convention "' || p_conv || '" - allowed values: 30E/360, ACT/365, ACT/360.' END);
END;
$$;
