-- ============================================================
-- fn_loan_period_months (READ HELPER) -- Monate je Raten-Periode einer Kredit-rp
--   Die EINE Adresse des Perioden-Faktors fuer den Zins einer Kreditrate: fn_get_loan_payment_split (Karte, Erinnerung,
--   Buchung; Audit Paket 2: eine Quartalsrate traegt drei Monatszinsen) und fn_set_loan (Guard "Rate deckt den Zins",
--   Live-Befund 2026-10-24). Kadenz der rp (interval x unit, day/week ueber fn_days_per_month normalisiert); ohne rp
--   (NULL / nicht gefunden) = 1 Monat.
--   Test: tests/db/finance/test_fn_loan_period_months.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_loan_period_months(p_rp_id int)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT GREATEST(rp.schedule_interval, 1) * CASE rp.schedule_unit
                   WHEN 'day'   THEN 1.0 / finance.fn_days_per_month()
                   WHEN 'week'  THEN 7.0 / finance.fn_days_per_month()
                   WHEN 'month' THEN 1.0
                   WHEN 'year'  THEN 12.0
               END
        FROM finance.recurring_payments rp WHERE rp.id = p_rp_id), 1);
$$;
