-- ============================================================
-- fn_recurring_owner (WEM GEHOERT EINE DAUERZAHLUNG?)
--   Die EINE Abfrage, ob eine recurring_payments-Zeile einer Entitaet gehoert: 'insurance' | 'loan' | 'pension' |
--   'savings_goal' | 'savings_plan' | NULL (freistehend). Konsumenten: fn_delete_recurring_payment (Entitaets-Zahlung
--   nur ueber das Tool der Entitaet aenderbar), fn_set_recurring_payment (dito) + fn_recurring_name_check (Namenssperre nur
--   fuer freistehende). Besitzer zeigen auf den KOPF der Vorgaenger-Kette -> jedes Glied wird ueber den Kopf erkannt (WP2:
--   ein noch laufendes Vorgaenger-Glied einer Kredit-/Versicherungs-Kette galt sonst als freistehend).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_owner(p_rp_id int)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    WITH h AS (SELECT finance.fn_recurring_lineage_head(p_rp_id) AS id)
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM finance.insurances    WHERE recurring_payment_id = (SELECT id FROM h)) THEN 'insurance'
        WHEN EXISTS (SELECT 1 FROM finance.loans         WHERE recurring_payment_id = (SELECT id FROM h)) THEN 'loan'
        WHEN EXISTS (SELECT 1 FROM finance.pension       WHERE recurring_payment_id = (SELECT id FROM h)) THEN 'pension'
        WHEN EXISTS (SELECT 1 FROM finance.savings_goals WHERE recurring_payment_id = (SELECT id FROM h)) THEN 'savings_goal'
        WHEN EXISTS (SELECT 1 FROM finance.savings_plans WHERE recurring_payment_id = (SELECT id FROM h)) THEN 'savings_plan'
        ELSE NULL END;
$$;
