-- ============================================================
-- fn_clear_e2e_data (TEST-CLEANUP, paperless-Teil — bewusster No-op)
--   Paket-Hook der Konvention <pkg>.fn_clear_e2e_data(text) (Phase B, docs/package-contract.md §6). paperless hat
--   KEINE eigenen Tabellen (seit v0.3.0 reiner Lese-Zugang auf Paperless-NGX, packages/paperless/CLAUDE.md)
--   -> es entstehen keine Sentinel-Zeilen. Der No-op ist explizit, damit der Dispatcher ein Paket mit Schema aber
--   ohne Hook als Vertragsbruch erkennen kann (RAISE) statt still zu ueberspringen.
--   RUECKGABE: {} (keine Zaehler)
--   Tests: tests/db/core/test_fn_clear_e2e_data.sql
-- ============================================================
CREATE OR REPLACE FUNCTION paperless.fn_clear_e2e_data(p_runid text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF COALESCE(p_runid,'') <> '' AND p_runid !~ '^[a-z0-9]+$' THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: ungültige run-id % (nur [a-z0-9])', p_runid;
    END IF;
    RETURN '{}'::jsonb;
END;
$$;
