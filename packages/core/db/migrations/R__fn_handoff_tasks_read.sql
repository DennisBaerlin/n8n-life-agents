-- ============================================================
-- core.fn_handoff_tasks_read(p_ids) — publiziertes Lesefenster der vereinbarten Plan-Aufgaben fuer den Buchhalter
--   Der Buchhalter (finance_ro, postgres_select) liest die Aufgaben seines Auftrags per id nach (agent.* ist ihm per D10
--   verschlossen): SELECT core.fn_handoff_tasks_read(ARRAY[12,13]). Rueckgabe jsonb-Array [{id, kind, payload, text,
--   status, why, wanted, rest}] in id-Reihenfolge; unbekannte ids fehlen. why = Grund der Vereinbarung, wanted = der beim
--   Vereinbaren gepruefte Aufruf (NULL ohne Vorpruefung), rest = Text des offenen Punkts, der beim Eintragen offen bleibt
--   (core.fn_handoff_rest). Nur die angefragten ids (der Auftrag nennt sie), keine Personen- oder Domain-Liste.
--   SECURITY DEFINER, EXECUTE an <pkg>_ro/_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql, tests/db/core/test_fn_defer_handoff_task.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_tasks_read(p_ids int[])
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
-- plpgsql: core.fn_handoff_rest steht in dieser Datei unten, eine sql-fn pruefte den Body schon beim CREATE.
BEGIN
    RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'payload', t.payload, 'text', t.text,
                                                         'status', t.status, 'why', t.why, 'wanted', t.wanted,
                                                         'rest', core.fn_handoff_rest(t.id)) ORDER BY t.id), '[]'::jsonb)
              FROM agent.handoff_tasks t
             WHERE t.id = ANY (COALESCE(p_ids, ARRAY[]::int[])));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_tasks_read(int[]) FROM public;

-- core.fn_handoff_rest(p_task_id) — Text des offenen Punkts (open_point_id) einer Aufgabe, solange er offen ist, sonst NULL.
--   Die Ids leben im interview_state des Plans der Domain (Haushalt person_id NULL, per_user die Person); der gueltige Plan
--   geht vor dem Entwurf (beim Veroeffentlichen wandert der Entwurf samt Ids in die gueltige Zeile).
CREATE OR REPLACE FUNCTION core.fn_handoff_rest(p_task_id int)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    -- gueltiger Plan zuerst: ein dort geschlossener Punkt ist kein Rest mehr, auch wenn ein Entwurf ihn noch offen fuehrt
    SELECT CASE WHEN o.resolved THEN NULL ELSE o.text END
      FROM agent.handoff_tasks t
      JOIN agent.advisor_plans ap ON ap.domain = t.domain AND (ap.person_id IS NULL OR ap.person_id = t.person_id)
                                 AND ap.status IN ('active', 'draft')
      JOIN LATERAL core.fn_plan_open_points(ap.interview_state) o ON o.id = t.open_point_id
     WHERE t.id = p_task_id AND t.open_point_id IS NOT NULL
     ORDER BY (ap.status = 'active') DESC
     LIMIT 1;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_rest(int) FROM public;
