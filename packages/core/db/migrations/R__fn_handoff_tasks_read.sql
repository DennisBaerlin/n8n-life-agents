-- ============================================================
-- core.fn_handoff_tasks_read(p_ids) — publiziertes Lesefenster der vereinbarten Plan-Aufgaben fuer den Buchhalter
--   Der Buchhalter (finance_ro, postgres_select) liest die Aufgaben seines Auftrags per id nach (agent.* ist ihm per D10
--   verschlossen): SELECT core.fn_handoff_tasks_read(ARRAY[12,13]). Rueckgabe jsonb-Array [{id, kind, payload, text,
--   status, why, wanted, rest, entered_refs, close_reason, open_point_id}] in id-Reihenfolge; unbekannte ids fehlen. why = Grund
--   der Vereinbarung, wanted = der beim Vereinbaren gepruefte Aufruf (NULL ohne Vorpruefung), rest = Text des offenen Punkts,
--   der beim Eintragen offen bleibt (core.fn_handoff_rest); entered_refs/close_reason = Provenienz des Abschlusses (Paket-fns
--   fuer den Unterschied Soll gegen Ist und die Kartenzeilen, die agent.* nicht sehen). Nur die angefragten ids (der Auftrag nennt sie), keine Personen- oder Domain-Liste.
--   Paket-Grenze (core.fn_session_package): eine Paket-Rolle liest nur Aufgaben ihres Pakets, fremde ids fehlen wie unbekannte.
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
                                                         'rest', core.fn_handoff_rest(t.id), 'entered_refs', t.entered_refs,
                                                         'close_reason', t.close_reason, 'open_point_id', t.open_point_id) ORDER BY t.id), '[]'::jsonb)
              FROM agent.handoff_tasks t
             WHERE t.id = ANY (COALESCE(p_ids, ARRAY[]::int[]))
               AND (core.fn_session_package() IS NULL OR t.package = core.fn_session_package()));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_tasks_read(int[]) FROM public;

-- core.fn_handoff_rest(p_task_id) — Text des offenen Punkts (open_point_id) einer Aufgabe, solange er offen ist, sonst NULL.
--   Die Ids leben im interview_state der Plan-Zeile, in der die Aufgabe vereinbart wurde, und beginnen je Entwurf neu (ein
--   Ueberarbeitungs-Entwurf und der gueltige Plan fuehren dieselbe Id fuer verschiedene Punkte). Darum zaehlt die juengste
--   Plan-Zeile der Domain (Haushalt person_id NULL, per_user die Person), die vor der Aufgabe angelegt wurde; beim
--   Veroeffentlichen wird die Entwurfs-Zeile selbst zur gueltigen (gleiche id, gleiche Punkte).
CREATE OR REPLACE FUNCTION core.fn_handoff_rest(p_task_id int)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE WHEN o.resolved THEN NULL ELSE o.text END
      FROM agent.handoff_tasks t
      JOIN LATERAL (SELECT ap.interview_state FROM agent.advisor_plans ap
                     WHERE ap.domain = t.domain AND (ap.person_id IS NULL OR ap.person_id = t.person_id)
                       AND ap.created_at <= t.created_at
                     ORDER BY ap.created_at DESC, ap.id DESC LIMIT 1) pl ON true
      JOIN LATERAL core.fn_plan_open_points(pl.interview_state) o ON o.id = t.open_point_id
     WHERE t.id = p_task_id AND t.open_point_id IS NOT NULL
     LIMIT 1;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_rest(int) FROM public;
