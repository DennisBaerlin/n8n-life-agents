-- ============================================================
-- fn_recurring_effective (READ, STABLE) -- das massgebliche Glied einer Raten-Kette fuer „laeuft oder kommt"
--   = das am Tag p_on gueltige Glied ([valid_from, valid_to)); gilt heute keins (Kette noch nicht gestartet oder Luecke
--   zwischen zwei Gliedern), das NAECHSTE startende Glied (kleinstes valid_from > p_on), nicht der Kopf -> eine kuenftige
--   Kette mit geplanter Aenderung zeigt den Startbetrag. Eine beendete Kette liefert ihren Kopf (Aufrufer filtern
--   valid_to). Anders als fn_recurring_current (faellt auf den Kopf zurueck).
--   Konsumenten: fn_account_flows, fn_standing_orders.
--   RUECKGABE: recurring_payments.id | NULL (unbekannte id)
--   Tests: tests/db/finance/test_fn_recurring_effective.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_effective(p_rp_id int, p_on date)
RETURNS int
LANGUAGE sql STABLE AS $$
    WITH l AS (
        SELECT r.id, r.valid_from, r.valid_to FROM finance.recurring_payments r
        WHERE r.id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
    )
    SELECT COALESCE(
        (SELECT l.id FROM l WHERE l.valid_from <= p_on AND (l.valid_to IS NULL OR l.valid_to > p_on)
          ORDER BY l.valid_from DESC, l.id DESC LIMIT 1),
        (SELECT l.id FROM l WHERE l.valid_from > p_on ORDER BY l.valid_from, l.id LIMIT 1),
        finance.fn_recurring_lineage_head(p_rp_id));
$$;
