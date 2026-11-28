-- ============================================================
-- fn_recurring_chain_ended (READ HELPER, STABLE) -- ist eine Raten-Kette am Tag p_on beendet?
--   Die eine Adresse fuer "beendet, also beim Reaktivieren fortsetzen" (fn_set_savings_plan, fn_set_savings_goal,
--   fn_set_pension). Beendet = kein Glied der Kette laeuft am Tag p_on oder kommt noch:
--   jedes Glied hat ein Ende, das erreicht ist (valid_to <= p_on) oder leer ist (valid_to <= valid_from).
--   Am valid_to des Kopfs allein laesst sich das nicht ablesen: beim Schliessen einer Kette mit geplanter Aenderung
--   (fn_end_recurring_chain) wird der kuenftige Kopf ein leeres Glied mit einem Datum in der Zukunft.
--   Eingabe: p_rp_id (beliebiges Glied), p_on. Rueckgabe: boolean; unbekannte id -> false.
--   Tests: tests/db/finance/test_fn_recurring_chain_ended.sql, tests/db/finance/test_prop_reactivate_vs_preview.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_chain_ended(p_rp_id int, p_on date)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(bool_and(r.valid_to IS NOT NULL AND (r.valid_to <= p_on OR r.valid_to <= r.valid_from)), false)
    FROM finance.recurring_payments r
    WHERE r.id IN (SELECT finance.fn_recurring_lineage(p_rp_id));
$$;
