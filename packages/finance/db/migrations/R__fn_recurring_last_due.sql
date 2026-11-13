-- ============================================================
-- fn_recurring_last_due (READ HELPER, STABLE)
--   Der letzte Termin einer endenden Raten-Kette: groesster Rasterpunkt des Kopf-Glieds (fn_schedule_occurrences,
--   Rhythmus des Kopfs) in [valid_from, valid_to). NULL, wenn die Kette offen ist (Kopf ohne valid_to) oder vor ihrem
--   Ende kein Termin liegt. Eine kuenftige Betragsaenderung (Split) ist kein Ende: der Kopf laeuft weiter.
--   Eingabe: p_rp_id (beliebiges Glied der Kette). Rueckgabe: date.
--   Die eine Adresse fuer "letzte Ausfuehrung" (nie valid_to - 1: ein vom Nutzer genanntes Ende liegt selten auf
--   einem Termin). Konsumenten: fn_account_funding (drawdown/inflow_ends), fn_transfer_free_end, fn_advisor_review
--   (standing_order_ending).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_last_due(p_rp_id int)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT max(o.d)
    FROM finance.recurring_payments r
    CROSS JOIN LATERAL finance.fn_schedule_occurrences(
        r.first_payment_date, r.schedule_interval, r.schedule_unit, r.schedule_day_of_month, r.schedule_days_of_month,
        r.valid_from, r.valid_to - 1) AS o(d)
    WHERE r.id = finance.fn_recurring_lineage_head(p_rp_id)
      AND r.valid_to IS NOT NULL;
$$;
