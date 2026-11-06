-- ============================================================
-- fn_today (DIE EINE ADRESSE FUER "HEUTE")
--   Kalendertag des Haushalts zu einem Zeitpunkt, Standard p_at = now(). Haushalts-Zeitzone = Sitzungs-Zeitzone:
--   der Installer setzt sie je Datenbank (provisioning/lib/install_pg.sh apply_db_timezone, Standard Europe/Berlin),
--   damit CURRENT_DATE / ::date in allen uebrigen SQL-Stellen denselben Tag liefern wie diese fn.
--   Defaults "Datum leer = heute" in den Write-fns und die Monitor-Auswertung (mit ihrer injizierbaren Uhr) lesen
--   "heute" hier.
--   STABLE: innerhalb einer Transaktion konstant (now() = Transaktionsbeginn, Zeitzone = Sitzungs-Einstellung).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_today(p_at timestamptz DEFAULT pg_catalog.now())
RETURNS date
LANGUAGE sql
STABLE
AS $$
    SELECT (p_at AT TIME ZONE pg_catalog.current_setting('TimeZone'))::date;
$$;
