-- ============================================================
-- fn_monitor_ro_eval (HELPER — fuehrt EINE gespeicherte Monitor-sql-Spec strukturell read-only aus)
--   Einziger Aufrufer: agent.fn_monitor_acquire (sql-Zweig; Cron fn_monitor_evaluate + Test-Abruf fn_monitor_probe).
--   SECURITY DEFINER mit EIGENTUEMER core_ro_eval (NOLOGIN, erbt nur core_ro; ALTER OWNER am Rollen-Ort
--   util_create_core_ro.sql): die Abfrage laeuft mit genau den Leserechten von core_ro, und in einer DEFINER-fn lehnt PostgreSQL jedes Setzen von role/
--   session_authorization ab -> eine eingebettete set_config('role', ...) kann die Leserolle nicht mehr ablegen
--   (frueher: SET LOCAL ROLE core_ro als Session-Owner -> 'none' setzte auf die App-Rolle zurueck; Security-Audit 2026-10).
--   search_path: gepinnt (DEFINER-Checkliste), im Body auf den Pfad des AUFRUFERS gesetzt (p_search_path) — gespeicherte
--   Specs loesen unqualifizierte Paket-Namen weiter auf. Kein Kapern-Risiko: der Eigentuemer (core_ro_eval) darf weniger
--   als jeder Aufrufer.
--   FAIL-CLOSED: current_user <> 'core_ro_eval' -> RAISE (Erst-Apply vor dem Eigentuemerwechsel, oder eine auf
--   SECURITY INVOKER umgestellte fn). Shape-Guard + Fehler-Abbildung bleiben beim Aufrufer. Eigener NOLOGIN-Eigentuemer:
--   eine Frei-SQL-Sitzung unter core_ro kann die fn weder aendern noch droppen.
--   RUECKGABE: numeric (Scalar-Subquery-Wrap 'SELECT (<q>)::numeric'; >1 Zeile/Spalte bricht kontrolliert).
--   Tests: tests/db/core/test_fn_monitor_evaluate.sql, test_fn_monitor_probe.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_ro_eval(p_query text, p_search_path text)
RETURNS numeric LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agent, core, pg_temp
AS $$
DECLARE
    v_value NUMERIC;
BEGIN
    IF current_user <> 'core_ro_eval' THEN
        RAISE EXCEPTION 'fn_monitor_ro_eval must run as core_ro_eval (got %)', current_user;
    END IF;
    PERFORM set_config('search_path', COALESCE(p_search_path, 'pg_catalog'), true);
    EXECUTE 'SELECT (' || p_query || ')::numeric' INTO STRICT v_value;
    RETURN v_value;
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_monitor_ro_eval(text, text) FROM public;
-- OWNER TO core_ro_eval: util_create_core_ro.sql (die Rolle existiert erst dort); EXECUTE hat nur die App-Rolle
-- (Sammel-Grant in apply_schema.sh), nicht core_ro und keine Paket-Rolle.
