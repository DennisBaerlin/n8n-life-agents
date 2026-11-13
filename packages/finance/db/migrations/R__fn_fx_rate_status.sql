-- fn_fx_rate_status (READ) -- Wechselkurs-Stand je aktiver Fremdwaehrung (eine Adresse fuer "fehlt ein Kurs?")
--   Ein Eintrag je Waehrung aus fn_active_currencies, also auch fuer die erst vom Kursabruf gelernte Waehrung.
--   Eingabe: keine; Grenze aus core.config finance.fx_stale_days (Default 7).
--   Rueckgabe: code, last_as_of (juengster EUR-Kurs, NULL ohne Kurs), status missing | stale (Alter > Grenze) | ok.
--   Seiteneffekte: keine. Keine Fremdwaehrung -> keine Zeile; Aufrufer im Workflow aggregieren (0 Zeilen = kein Item).
CREATE OR REPLACE FUNCTION finance.fn_fx_rate_status()
RETURNS TABLE (code text, last_as_of date, status text) LANGUAGE sql STABLE AS $$
  WITH last_rate AS (
    SELECT ac.code, max(fxr.as_of) AS last_as_of
    FROM finance.fn_active_currencies() ac
    LEFT JOIN finance.fx_rates fxr ON fxr.base_currency = 'EUR' AND fxr.quote_currency = ac.code
    GROUP BY ac.code
  )
  SELECT l.code, l.last_as_of,
         CASE WHEN l.last_as_of IS NULL THEN 'missing'
              WHEN current_date - l.last_as_of > COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'fx_stale_days'), '')::numeric, 7) THEN 'stale'
              ELSE 'ok' END
  FROM last_rate l
$$;
