-- ============================================================
-- fn_insurance_period_amount (IMMUTABLE, rein) — Beitrag JE ABBUCHUNG aus der Jahrespraemie
--   Die EINE Adresse fuer die Raten-Ableitung einer Versicherung (vorher doppelt als n8n-Rechen-Node in
--   tool_create_insurance + tool_set_insurance, im Import gar nicht -> Vorzeichen-/Betragsfehler).
--   Exakte Umkehrung von fn_monthly_equivalent (365,25-Tage-Basis): fn_monthly_equivalent(-Ergebnis,
--   interval, unit) = -Jahrespraemie/12 fuer jede Kadenz -> recurring_payments.monthly_equivalent und
--   insurances.monthly_equivalent (GENERATED annual/12) laufen nicht auseinander.
--     day:   annual * interval * 1      / 365.25
--     week:  annual * interval * 7      / 365.25
--     month: annual * interval / 12     (= 30.4375 / 365.25)
--     year:  annual * interval
--   RUECKGABE: POSITIVER Betrag (2 Nachkommastellen); der Aufrufer bucht ihn als Ausgabe (negativ).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_insurance_period_amount(
    p_annual numeric, p_interval int, p_unit finance.schedule_unit
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT ROUND(
        p_annual * GREATEST(COALESCE(p_interval, 1), 1) * CASE p_unit
            WHEN 'day'   THEN 1.0
            WHEN 'week'  THEN 7.0
            WHEN 'month' THEN finance.fn_days_per_month()
            WHEN 'year'  THEN 365.25
        END / 365.25, 2);
$$;
