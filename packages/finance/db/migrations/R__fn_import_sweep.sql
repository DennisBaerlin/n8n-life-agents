-- ============================================================
-- fn_import_sweep (Hygiene — verfallene nicht-committete Staging-Batches loeschen)
--   Aus dem Write-Pfad von fn_import_stage HERAUSgezogen (Review A1: ein Write-Tool darf
--   fremden Zustand nicht als Seiteneffekt jedes Calls loeschen — Separation of Concerns +
--   Testbarkeit). Wird (a) von fn_import_stage NUR beim Anlegen eines NEUEN Batches gerufen
--   (natuerlicher, seltener GC-Zeitpunkt) und (b) ist als standalone fn fuer einen kuenftigen
--   Cron aufrufbar (BACKLOG: an cron_reconcile_accounts o. ae. haengen).
--   RUECKGABE: Anzahl geloeschter Rows.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_sweep(p_days int DEFAULT 7)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n INT;
BEGIN
    DELETE FROM finance.import_staging
    WHERE status <> 'committed'
      AND created_at < NOW() - make_interval(days => p_days);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;
