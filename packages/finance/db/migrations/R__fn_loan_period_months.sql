-- ============================================================
-- fn_loan_period_months (READ HELPER) -- Monate je Raten-Periode einer Kredit-rp
--   Der Perioden-Faktor fuer den Zins einer Kreditrate: fn_get_loan_payment_split (Karte, Erinnerung, Buchung; Audit
--   Paket 2: eine Quartalsrate traegt drei Monatszinsen) und fn_set_loan (Guard "Rate deckt den Zins", Live-Befund
--   2026-10-24). Kadenz der rp ueber die eine Formel finance.fn_period_months (Init, WP2; auch die Restschuld-Vorschau
--   rechnet damit); ohne rp (NULL / nicht gefunden) = 1 Monat.
--   Test: tests/db/finance/test_fn_loan_period_months.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_loan_period_months(p_rp_id int)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT finance.fn_period_months(rp.schedule_interval, rp.schedule_unit)
        FROM finance.recurring_payments rp WHERE rp.id = p_rp_id), 1);
$$;
