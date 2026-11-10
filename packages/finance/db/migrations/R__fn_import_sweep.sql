-- ============================================================
-- fn_import_sweep (Hygiene — verfallene Staging-Zeilen loeschen)
--   Aus dem Write-Pfad von fn_import_stage herausgezogen (ein Write-Tool darf fremden Zustand nicht als Seiteneffekt
--   jedes Calls loeschen). Gerufen von fn_import_stage beim Anlegen eines NEUEN Batches, von fn_import_stage_recurring
--   vor jedem Ergaenzen und taeglich von cron_refresh_fx_rates (immer an, finance_rw).
--   (1) Import-Batches ohne Vorschlags-origin: nicht committete Zeilen nach p_days ab created_at.
--   (2) Vorschlags-Stapel (origin recurring_suggestion): der ganze Stapel (offene, abgelehnte und uebernommene Zeilen)
--   p_days nach seinem letzten Ergaenzen (max(merged_at)); Stempeln und Ablehnen verschieben die Frist nicht
--   (updated_at waere dafuer falsch, das setzt der Touch-Trigger bei jedem UPDATE).
--   RUECKGABE: Anzahl geloeschter Rows.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_sweep(p_days int DEFAULT 7)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_m INT;
BEGIN
    DELETE FROM finance.import_staging
    WHERE origin IS NULL AND status <> 'committed'
      AND created_at < NOW() - make_interval(days => p_days);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    DELETE FROM finance.import_staging s
    WHERE s.origin = 'recurring_suggestion'
      AND s.batch_id IN (SELECT x.batch_id FROM finance.import_staging x WHERE x.origin = 'recurring_suggestion'
                         GROUP BY x.batch_id HAVING max(COALESCE(x.merged_at, x.created_at)) < NOW() - make_interval(days => p_days));
    GET DIAGNOSTICS v_m = ROW_COUNT;
    RETURN v_n + v_m;
END;
$$;
