-- ============================================================
-- fn_monitor_due (READ-ONLY — Due-Selection des Heartbeat-Crons)
--   Liefert alle SCHARFEN, FAELLIGEN Trigger: status='armed' AND next_check_at <= p_now.
--   fired (One-Shot-Latch) und disabled erscheinen nie. run_ts = p_now wird je Zeile
--   mitgegeben, damit der Workflow dieselbe Uhr an fn_monitor_evaluate weiterreicht
--   (deterministisches Due-Set ueber die Minuten, die die Web-Beschaffung dauert).
--   Die per-Trigger-Frequenz lebt in next_check_at/check_interval — der n8n-Heartbeat
--   ist nur der Aufloesungsboden. 0 Zeilen -> 0 Items -> die Cron-Pipeline endet gratis.
--   Positional (Read-Konvention wie fn_recurring_due_open).
--   PARKEN (Phase B): Trigger einer gerade nicht verfuegbaren Paket-Methode (agent.fn_monitor_method_status —
--   Paket deinstalliert/inaktiv) erscheinen nicht (Spiegel des Filters in fn_monitor_evaluate).
--   plpgsql (nicht sql): Aufrufe werden erst zur Laufzeit gebunden — eine sql-fn validiert ihren Body beim
--   CREATE, und R__fn_monitor_method_status wird alphabetisch NACH dieser Datei angewendet.
-- ============================================================
DROP FUNCTION IF EXISTS agent.fn_monitor_due(timestamptz);   -- Sprachwechsel sql -> plpgsql
CREATE OR REPLACE FUNCTION agent.fn_monitor_due(p_now timestamptz DEFAULT now())
RETURNS TABLE (
    run_ts             timestamptz,
    id                 int,
    domain             text,
    label              text,
    trigger_type       text,
    acquisition_method text,
    acquisition_spec   jsonb
) LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT p_now, t.id, t.domain, t.label, t.trigger_type, t.acquisition_method, t.acquisition_spec
    FROM agent.monitor_triggers t
    WHERE t.status = 'armed' AND t.next_check_at <= p_now
      AND COALESCE((agent.fn_monitor_method_status(t.acquisition_method)->>'available')::boolean, false)
      -- Roter Faden: Spiegel des Erinnerungs-Fensters in agent.fn_monitor_evaluate (Datums-/Info-Trigger nur im Fenster).
      AND (t.trigger_type NOT IN ('date', 'recurring_info') OR core.fn_in_reminder_window(p_now))
    ORDER BY t.id;
END;
$$;
