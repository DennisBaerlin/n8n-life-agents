-- ============================================================
-- fn_clear_e2e_data (GEGUARDETES TEST-CLEANUP, estate-Teil — KEIN Produktiv-Tool)
--   Paket-Hook der Konvention <pkg>.fn_clear_e2e_data(text) (Phase B, docs/package-contract.md §6): der Core-
--   Dispatcher agent.fn_clear_e2e_data ruft ihn je installiertem Paket (gleiche Transaktion).
--   Reihenfolge FK-sicher: directives VOR storage_places (FK RESTRICT auf storage_place_id). directives haben
--   keinen Namen -> Sentinel in notes/location_note ODER via referenzierte Sentinel-Fundstelle. person_records/
--   funeral_preferences keyen auf REALE Personen -> nur zeilen-genau ueber den Sentinel in notes/wishes.
--   Ereignisfall (cases/case_tasks) traegt keinen Sentinel-Namen; in der ephemeren Container-DB gibt es keinen
--   Nicht-Test-Produzenten eines Falls (nur der E2E-Tier APPROVEt create_case) -> wholesale (case_tasks vor cases).
--   Post-Assertion: keine Sentinel-Zeile darf bleiben. p_runid: NULL/'' = generischer Sweep.
--   RUECKGABE: {estate_rows} (Summe ueber alle Register)
--   Tests: tests/db/core/test_fn_clear_e2e_data.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_clear_e2e_data(p_runid text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pat_any CONSTANT text := CASE WHEN COALESCE(p_runid,'') = '' THEN '%\_\_E2E%'
                                    ELSE '%\_\_E2E\_' || p_runid || '\_\_%' END;
    v_n   int;
    v_est int := 0;
BEGIN
    IF COALESCE(p_runid,'') <> '' AND p_runid !~ '^[a-z0-9]+$' THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: ungültige run-id % (nur [a-z0-9])', p_runid;
    END IF;

    DELETE FROM estate.case_tasks;  GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.cases;       GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.directives
     WHERE COALESCE(notes, '') LIKE v_pat_any OR COALESCE(location_note, '') LIKE v_pat_any
        OR storage_place_id IN (SELECT id FROM estate.storage_places WHERE name LIKE v_pat_any);
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.provider_contracts WHERE provider LIKE v_pat_any OR COALESCE(notes, '') LIKE v_pat_any;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.digital_accounts WHERE provider LIKE v_pat_any OR COALESCE(notes, '') LIKE v_pat_any;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.contacts WHERE name LIKE v_pat_any OR COALESCE(notes, '') LIKE v_pat_any;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.special_assets WHERE description LIKE v_pat_any OR COALESCE(notes, '') LIKE v_pat_any;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.storage_places WHERE name LIKE v_pat_any OR COALESCE(notes, '') LIKE v_pat_any;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.person_records WHERE COALESCE(notes, '') LIKE v_pat_any;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;
    DELETE FROM estate.funeral_preferences WHERE COALESCE(wishes, '') LIKE v_pat_any;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_est := v_est + v_n;

    IF EXISTS (SELECT 1 FROM estate.provider_contracts WHERE provider LIKE v_pat_any)
    OR EXISTS (SELECT 1 FROM estate.digital_accounts   WHERE provider LIKE v_pat_any)
    OR EXISTS (SELECT 1 FROM estate.contacts           WHERE name LIKE v_pat_any)
    OR EXISTS (SELECT 1 FROM estate.special_assets     WHERE description LIKE v_pat_any)
    OR EXISTS (SELECT 1 FROM estate.storage_places     WHERE name LIKE v_pat_any)
    OR EXISTS (SELECT 1 FROM estate.directives         WHERE COALESCE(notes, '') LIKE v_pat_any OR COALESCE(location_note, '') LIKE v_pat_any) THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: estate Sentinel-Zeilen nach Cleanup noch vorhanden — Abbruch';
    END IF;

    RETURN jsonb_build_object('estate_rows', v_est);
END;
$$;
