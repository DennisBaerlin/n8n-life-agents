-- ============================================================
-- core.fn_handoff_tasks_read(p_ids) — publiziertes Lesefenster der vereinbarten Plan-Aufgaben fuer den Buchhalter
--   Der Buchhalter (finance_ro, postgres_select) liest die Aufgaben seines Auftrags per id nach (agent.* ist ihm per D10
--   verschlossen): SELECT core.fn_handoff_tasks_read(ARRAY[12,13]). Rueckgabe jsonb-Array [{id, kind, payload, text,
--   status}] in id-Reihenfolge; unbekannte ids fehlen. Nur die angefragten ids (der Auftrag nennt sie), keine Personen-
--   oder Domain-Liste. SECURITY DEFINER, EXECUTE an <pkg>_ro/_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_tasks_read(p_ids int[])
RETURNS jsonb
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'payload', t.payload, 'text', t.text,
                                                 'status', t.status) ORDER BY t.id), '[]'::jsonb)
      FROM agent.handoff_tasks t
     WHERE t.id = ANY (COALESCE(p_ids, ARRAY[]::int[]));
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_tasks_read(int[]) FROM public;
