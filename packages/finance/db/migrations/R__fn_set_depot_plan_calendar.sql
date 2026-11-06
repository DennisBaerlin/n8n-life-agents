-- ============================================================
-- fn_set_depot_plan_calendar (INTERNAL HELPER — not tool-facing)
--   Speichert den von fn_resolve_plan_schedule bestimmten Depot-Kalender (calendar) am Depot, wenn er neu ist
--   (calendar_changed: Nutzer-Antwort oder Vorbelegung fn_broker_plan_days). Die EINE Schreibstelle fuer
--   accounts.plan_execution_days aus dem Sparplan-Pfad (fn_create_savings_plan, fn_set_savings_plan); laeuft im
--   selben Write wie der Sparplan (Probelauf rollt ihn mit zurueck).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_depot_plan_calendar(p_depot_id int, p_sched jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF (p_sched->>'calendar_changed')::boolean THEN
        UPDATE finance.accounts
        SET plan_execution_days = finance.fn_jsonb_smallint_array(p_sched->'calendar')
        WHERE id = p_depot_id;
    END IF;
END;
$$;
