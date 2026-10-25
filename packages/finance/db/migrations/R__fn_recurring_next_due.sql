-- ============================================================
-- fn_recurring_next_due (READ HELPER, WP2 "Finanzen schlank")
--   Der naechste noch nicht erledigte Termin des KOPF-Glieds einer Raten-Kette ab p_on: der erste Rasterpunkt
--   (fn_schedule_occurrences, Rhythmus des Kopfs) mit d >= max(p_on, juengster erledigter Termin + 1, valid_from).
--   Ueberfaellige, noch nicht gebuchte Termine VOR p_on bleiben damit beim alten Betrag (Reviewer: sie wurden fast sicher
--   noch zum alten Betrag abgebucht). Default-Stichtag einer Raten-/Beitragsaenderung (fn_change_owned_recurring:
--   fn_set_loan, fn_set_insurance). NULL, wenn im Suchfenster (zwei Perioden + ein Monat) kein Termin liegt.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_next_due(p_rp_id int, p_on date)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT min(o.d)
    FROM finance.recurring_payments r
    CROSS JOIN LATERAL (SELECT GREATEST(p_on, finance.fn_recurring_last_done(r.id) + 1, r.valid_from) AS s) f
    CROSS JOIN LATERAL finance.fn_schedule_occurrences(
        r.first_payment_date, r.schedule_interval, r.schedule_unit, r.schedule_day_of_month, r.schedule_days_of_month,
        f.s, f.s + (ceil(finance.fn_period_months(r.schedule_interval, r.schedule_unit) * 2 * 31)::int + 31)) AS o(d)
    WHERE r.id = finance.fn_recurring_lineage_head(p_rp_id)
      AND (r.valid_to IS NULL OR o.d < r.valid_to);
$$;
