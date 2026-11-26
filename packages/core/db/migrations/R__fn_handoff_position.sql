-- ============================================================
-- core.fn_handoff_position(p_task_id) — Stelle einer vereinbarten Plan-Aufgabe in ihrer Eintrage-Runde ("Eintrag k von n")
--   Runde = alle Aufgaben derselben Person und Domain mit demselben claimed_at (ein Claim von core.fn_handle_handoff_cb
--   setzt es fuer alle in einem UPDATE). k = Rang nach id, n = Groesse der Runde; erledigte, uebersprungene (zurueck auf
--   open, claimed_at bleibt) und zurueckgestellte bleiben mitgezaehlt, damit die Zahl auf der naechsten Karte nicht springt.
--   Rueckgabe {k, n} oder NULL (nie beansprucht, unbekannte id). Nur lesend; der Zaehler kommt nie vom Modell.
--   Konsument: finance.fn_with_handoff (Kartenzeile core.hitl.handoff_pos {k, n}).
--   SECURITY DEFINER (die Paket-Schreibrolle sieht agent.* nicht), EXECUTE an <pkg>_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_position.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_position(p_task_id int)
RETURNS jsonb
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object('k', x.k, 'n', x.n)
      FROM agent.handoff_tasks t
      CROSS JOIN LATERAL (
          SELECT count(*) FILTER (WHERE r.id <= t.id) AS k, count(*) AS n
            FROM agent.handoff_tasks r
           WHERE r.domain = t.domain AND r.person_id = t.person_id AND r.claimed_at = t.claimed_at) x
     WHERE t.id = p_task_id AND t.claimed_at IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_position(int) FROM public;
