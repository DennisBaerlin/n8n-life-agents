-- ============================================================
-- fn_recurring_suggestion_expired (STABLE) -- ist ein Dauerauftrags-Vorschlags-Stapel abgelaufen?
--   Die eine Adresse der Frist O6: ein Stapel gilt 7 Tage nach seinem letzten Ergaenzen (max(merged_at)) als abgelaufen,
--   auch wenn ihn noch niemand geloescht hat (fn_import_sweep im Kurs-Cron ist nur Datenschutz und kann abgeschaltet
--   sein). Versandliste (fn_get_recurring_suggestion_queue) und Knopf (fn_handle_recurring_suggestion_cb) fragen hier.
--   RUECKGABE: boolean (unbekannter Stapel = true).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_suggestion_expired(p_batch uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE(max(COALESCE(s.merged_at, s.created_at)) < now() - interval '7 days', true)
    FROM finance.import_staging s
    WHERE s.batch_id = p_batch AND s.origin = 'recurring_suggestion';
$$;
