-- tests/db/finance/test_fn_maintenance_reserve_rate.sql
-- Testet finance.fn_maintenance_reserve_rate: Monatsrate der Instandhaltungsruecklage nach II. BV § 28 Abs. 2
-- (Flaeche x Satz der Altersstufe / 12, auf ganze Euro aufgerundet). Alter = Kalenderjahr - Baujahr; Stufen
-- unter 22 / ab 22 / ab 32 Jahre; Saetze aus core.config (finance.maintenance_rate_*_eur_m2).
BEGIN;

DO $$
DECLARE
  y INT := EXTRACT(YEAR FROM core.fn_today())::int;
  r JSONB;
BEGIN
  -- Saetze fest auf die Werte ab 1.1.2026 (der Test haengt nicht vom geseedeten Stand ab)
  INSERT INTO core.config (package, category, key, value) VALUES
      ('finance','finance','maintenance_rate_under22_eur_m2','11.50'),
      ('finance','finance','maintenance_rate_from22_eur_m2','14.58'),
      ('finance','finance','maintenance_rate_from32_eur_m2','18.62')
    ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value, package = 'finance';

  -- (1) Alter 32 -> Stufe ab 32: 110 x 18,62 / 12 = 170,68 -> 171
  r := finance.fn_maintenance_reserve_rate(110, y - 32);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'monthly_eur')::numeric IS DISTINCT FROM 171
     OR r->>'band' IS DISTINCT FROM 'from32' OR (r->>'rate_eur_m2')::numeric IS DISTINCT FROM 18.62
     OR (r->>'age_years')::int IS DISTINCT FROM 32 OR (r->>'annual_eur')::numeric IS DISTINCT FROM 2048.20 THEN
    RAISE EXCEPTION 'FAIL [1 Alter 32]: %', r; END IF;
  RAISE NOTICE 'PASS [1 Alter 32 -> 171 EUR/Monat]';

  -- (2) Alter 31 -> Stufe ab 22: 110 x 14,58 / 12 = 133,65 -> 134
  r := finance.fn_maintenance_reserve_rate(110, y - 31);
  IF r->>'band' IS DISTINCT FROM 'from22' OR (r->>'monthly_eur')::numeric IS DISTINCT FROM 134 THEN
    RAISE EXCEPTION 'FAIL [2 Alter 31]: %', r; END IF;
  -- (3) Alter 22 -> Stufe ab 22
  r := finance.fn_maintenance_reserve_rate(110, y - 22);
  IF r->>'band' IS DISTINCT FROM 'from22' OR (r->>'rate_eur_m2')::numeric IS DISTINCT FROM 14.58 THEN
    RAISE EXCEPTION 'FAIL [3 Alter 22]: %', r; END IF;
  -- (4) Alter 21 -> unter 22: 110 x 11,50 / 12 = 105,42 -> 106
  r := finance.fn_maintenance_reserve_rate(110, y - 21);
  IF r->>'band' IS DISTINCT FROM 'under22' OR (r->>'monthly_eur')::numeric IS DISTINCT FROM 106 THEN
    RAISE EXCEPTION 'FAIL [4 Alter 21]: %', r; END IF;
  -- (5) Baujahr = dieses Jahr -> Alter 0, unter 22
  r := finance.fn_maintenance_reserve_rate(80.5, y);
  IF r->>'band' IS DISTINCT FROM 'under22' OR (r->>'age_years')::int IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [5 Alter 0]: %', r; END IF;
  RAISE NOTICE 'PASS [2-5 Stufengrenzen 31/22/21/0]';

  -- (6) Fehlende Daten -> korrigierbar, kein RAISE
  r := finance.fn_maintenance_reserve_rate(NULL, y - 40);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'maintenance_data_missing' THEN
    RAISE EXCEPTION 'FAIL [6 Flaeche fehlt]: %', r; END IF;
  r := finance.fn_maintenance_reserve_rate(110, NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'maintenance_data_missing' THEN
    RAISE EXCEPTION 'FAIL [6 Baujahr fehlt]: %', r; END IF;
  -- (7) Baujahr in der Zukunft / Flaeche <= 0 -> korrigierbar
  r := finance.fn_maintenance_reserve_rate(110, y + 1);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS NOT NULL AND r->>'code' = 'maintenance_data_missing' THEN
    RAISE EXCEPTION 'FAIL [7 Zukunftsjahr]: %', r; END IF;
  r := finance.fn_maintenance_reserve_rate(0, y - 10);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [7 Flaeche 0]: %', r; END IF;
  RAISE NOTICE 'PASS [6-7 fehlende/ungueltige Daten -> ok:false]';

  -- (8) Satz per Config (Anpassung alle 3 Jahre ohne Code-Aenderung)
  INSERT INTO core.config (package, category, key, value) VALUES ('finance','finance','maintenance_rate_from32_eur_m2','20')
    ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value, package = 'finance';
  r := finance.fn_maintenance_reserve_rate(120, y - 50);
  IF (r->>'rate_eur_m2')::numeric IS DISTINCT FROM 20 OR (r->>'monthly_eur')::numeric IS DISTINCT FROM 200 THEN
    RAISE EXCEPTION 'FAIL [8 Config-Satz]: %', r; END IF;
  RAISE NOTICE 'PASS [8 Satz aus core.config]';
END $$;

ROLLBACK;
