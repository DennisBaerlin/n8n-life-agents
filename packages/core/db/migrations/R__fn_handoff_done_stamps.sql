-- ============================================================
-- core.fn_handoff_done_stamps (Lesefenster fuer Paket-Rollen)
--   closed_at aller erledigten Uebergabe-Aufgaben einer Domain. Rueckfall fuer Bank-Punkte von vor dem Verweis
--   finance.bank_todos.handoff_task_id: ein Bank-Punkt aus demselben Durchgehen traegt denselben Zeitstempel, weil Write und
--   Abschluss in einer Transaktion laufen (now()). Eingabe: p_domain. Rueckgabe: setof timestamptz.
--   SECURITY DEFINER: <pkg>_rw sieht agent.handoff_tasks nicht; EXECUTE in fn_provision_package_roles.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_done_stamps(p_domain text)
RETURNS SETOF timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT closed_at FROM agent.handoff_tasks WHERE domain = p_domain AND status = 'done' AND closed_at IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION core.fn_handoff_done_stamps(text) FROM public;

-- ============================================================
-- core.fn_handoff_done_ids (Lesefenster fuer Paket-Rollen)
--   ids aller erledigten Uebergabe-Aufgaben einer Domain; ein Paket erkennt daran, was aus einem abgeschlossenen Eintragen
--   stammt (finance.bank_todos.handoff_task_id). Eingabe: p_domain. Rueckgabe: setof int.
--   SECURITY DEFINER wie oben; EXECUTE in fn_provision_package_roles. Tests: tests/db/finance/test_fn_plan_rollout.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_done_ids(p_domain text)
RETURNS SETOF int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT id FROM agent.handoff_tasks WHERE domain = p_domain AND status = 'done';
$$;

REVOKE ALL ON FUNCTION core.fn_handoff_done_ids(text) FROM public;
