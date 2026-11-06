-- ============================================================
-- fn_clear_e2e_data (GEGUARDETES TEST-CLEANUP, career-Teil — KEIN Produktiv-Tool)
--   Paket-Hook der Konvention <pkg>.fn_clear_e2e_data(text) (Phase B, docs/package-contract.md §6): der Core-
--   Dispatcher agent.fn_clear_e2e_data ruft ihn je installiertem Paket (gleiche Transaktion).
--   Loescht die Sentinel-Job-Treffer (title traegt '__E2E__') + Post-Assertion (keiner darf bleiben).
--   p_runid: NULL/'' = generischer Sweep, sonst nur '__E2E_<runid>__'.
--   RUECKGABE: {job_matches}
--   Tests: tests/db/core/test_fn_clear_e2e_data.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_clear_e2e_data(p_runid text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pat_any CONSTANT text := CASE WHEN COALESCE(p_runid,'') = '' THEN '%\_\_E2E%'
                                    ELSE '%\_\_E2E\_' || p_runid || '\_\_%' END;
    v_jm int;
BEGIN
    IF COALESCE(p_runid,'') <> '' AND p_runid !~ '^[a-z0-9]+$' THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: ungültige run-id % (nur [a-z0-9])', p_runid;
    END IF;

    DELETE FROM career.job_matches WHERE title LIKE v_pat_any;
    GET DIAGNOSTICS v_jm = ROW_COUNT;

    IF EXISTS (SELECT 1 FROM career.job_matches WHERE title LIKE v_pat_any) THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: career.job_matches Sentinel-Zeilen nach Cleanup noch vorhanden — Abbruch';
    END IF;

    RETURN jsonb_build_object('job_matches', v_jm);
END;
$$;
