-- ============================================================
-- agent.fn_monitor_needs_room(type, due_date, warn_days, today) (READ -- braucht dieser Trigger einen Budget-Platz?)
--   true fuer recurring_info und fuer ein Datum im Warnfenster vor der Frist. Faellige Daten (deadline), Daten vor dem
--   Warnfenster und Wert-Trigger: false. Die eine Adresse fuer fn_monitor_due und fn_monitor_evaluate.
--   Tests: tests/db/core/test_fn_monitor_evaluate.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_needs_room(p_type text, p_due date, p_warn int, p_today date)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_type = 'recurring_info'
        OR (p_type = 'date' AND p_today < p_due AND COALESCE(p_warn, 0) > 0 AND p_today >= p_due - p_warn);
$$;
