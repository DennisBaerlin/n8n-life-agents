-- tests/db/finance/test_recalc_maintenance_fx.sql
-- Zweitrechnung Instandhaltungsruecklage und Fremdwaehrung: Erwartungswerte schriftlich hergeleitet.
-- Instandhaltung, Fachregel § 28 Abs. 2 II. BV (https://www.gesetze-im-internet.de/bvo_2/__28.html): Satz je m2 und
--   Jahr nach dem Alter der Bezugsfertigkeit "am Ende des Kalenderjahres": weniger als 22 Jahre / mindestens 22 /
--   mindestens 32. Grundbetraege 7,10 / 9,00 / 11,50, fortgeschrieben nach § 26 Abs. 4 (Faktor ~1,62 -> 2026:
--   11,50 / 14,58 / 18,62; Gegenprobe 7,10 x 14,58/9 = 11,50). Monatsrate = Flaeche x Satz / 12, auf volle Euro auf.
--   Das Baujahr wird relativ zum laufenden Jahr gesetzt (die fn liest heute), die Erwartung ist jahresunabhaengig.
--   (1) 75 m2, 21 Jahre -> under22: 862,50 / Jahr, 71,875 -> 72 / Monat
--   (2) 75 m2, 22 Jahre -> from22: 1.093,50, 91,125 -> 92  (Grenze: genau 22 Jahre = "mindestens 22")
--   (3) 75 m2, 31 Jahre -> from22; 32 Jahre -> from32: 1.396,50, 116,375 -> 117
--   (4) 64,5 m2, Neubau (0 Jahre) -> 741,75, 61,8125 -> 62; Baujahr naechstes Jahr -> {ok:false}
-- Fremdwaehrung, Fachregel EZB-Referenzkurs = Fremdwaehrung je 1 EUR -> EUR = Betrag / Kurs, kaufmaennisch auf Cent:
--   (5) 100 USD zu 1,0825 = 92,378... -> 92,38; 15.000 JPY zu 162,35 = 92,393... -> 92,39
--   (6) Stichtag Samstag ohne eigenen Kurs -> der Freitagskurs (juengster <= Stichtag), nicht der Montagskurs
--   (7) Jahreswechsel: Stichtag 01.01. (kein Fixing) -> Kurs vom 31.12. des Vorjahres
--   (8) negativer Betrag (Abbuchung) rundet symmetrisch: -100 USD -> -92,38
--   (9) Einheitswert ungerundet: 0,20 USD zu 1,0825 = 0,184757... (nie 0,18)
BEGIN;

DO $$
DECLARE
  y int := EXTRACT(YEAR FROM core.fn_today())::int;
  v jsonb;
BEGIN
  v := finance.fn_maintenance_reserve_rate(75::numeric, y - 21);
  IF v->>'band' <> 'under22' OR (v->>'annual_eur')::numeric <> 862.50 OR (v->>'monthly_eur')::numeric <> 72 THEN
    RAISE EXCEPTION 'FAIL [1] 21 Jahre: %', v; END IF;
  v := finance.fn_maintenance_reserve_rate(75::numeric, y - 22);
  IF v->>'band' <> 'from22' OR (v->>'annual_eur')::numeric <> 1093.50 OR (v->>'monthly_eur')::numeric <> 92 THEN
    RAISE EXCEPTION 'FAIL [2] 22 Jahre: %', v; END IF;
  v := finance.fn_maintenance_reserve_rate(75::numeric, y - 31);
  IF v->>'band' <> 'from22' THEN RAISE EXCEPTION 'FAIL [3a] 31 Jahre: %', v; END IF;
  v := finance.fn_maintenance_reserve_rate(75::numeric, y - 32);
  IF v->>'band' <> 'from32' OR (v->>'annual_eur')::numeric <> 1396.50 OR (v->>'monthly_eur')::numeric <> 117 THEN
    RAISE EXCEPTION 'FAIL [3b] 32 Jahre: %', v; END IF;
  v := finance.fn_maintenance_reserve_rate(64.5::numeric, y);
  IF v->>'band' <> 'under22' OR (v->>'annual_eur')::numeric <> 741.75 OR (v->>'monthly_eur')::numeric <> 62 THEN
    RAISE EXCEPTION 'FAIL [4a] Neubau: %', v; END IF;
  v := finance.fn_maintenance_reserve_rate(64.5::numeric, y + 1);
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4b] Baujahr in der Zukunft: %', v; END IF;
  RAISE NOTICE 'PASS [1-4] Instandhaltung II. BV: Altersgrenzen 22/32, Aufrundung auf volle Euro';

  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2), ('JPY', 0) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency IN ('USD', 'JPY');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES
    ('EUR', 'USD', 1.0790, '2027-12-31'),
    ('EUR', 'USD', 1.0825, '2028-01-14'),   -- Freitag
    ('EUR', 'USD', 1.0901, '2028-01-17'),   -- Montag
    ('EUR', 'JPY', 162.35, '2028-01-14');

  IF finance.fn_to_eur(100, 'USD', '2028-01-14') IS DISTINCT FROM 92.38
     OR finance.fn_to_eur(15000, 'JPY', '2028-01-14') IS DISTINCT FROM 92.39 THEN
    RAISE EXCEPTION 'FAIL [5] Umrechnung: % / %', finance.fn_to_eur(100, 'USD', '2028-01-14'), finance.fn_to_eur(15000, 'JPY', '2028-01-14'); END IF;
  IF finance.fn_to_eur(100, 'USD', '2028-01-15') IS DISTINCT FROM 92.38 THEN
    RAISE EXCEPTION 'FAIL [6] Samstag -> Freitagskurs: %', finance.fn_to_eur(100, 'USD', '2028-01-15'); END IF;
  -- 100 / 1,0790 = 92,6784 -> 92,68
  IF finance.fn_to_eur(100, 'USD', '2028-01-01') IS DISTINCT FROM 92.68 THEN
    RAISE EXCEPTION 'FAIL [7] Jahreswechsel: %', finance.fn_to_eur(100, 'USD', '2028-01-01'); END IF;
  IF finance.fn_to_eur(-100, 'USD', '2028-01-14') IS DISTINCT FROM -92.38 THEN
    RAISE EXCEPTION 'FAIL [8] negativ: %', finance.fn_to_eur(-100, 'USD', '2028-01-14'); END IF;
  IF round(finance.fn_to_eur_unrounded(0.20, 'USD', '2028-01-14'), 6) IS DISTINCT FROM 0.184758 THEN
    RAISE EXCEPTION 'FAIL [9] Einheitswert: %', finance.fn_to_eur_unrounded(0.20, 'USD', '2028-01-14'); END IF;
  RAISE NOTICE 'PASS [5-9] Fremdwaehrung: Cent-Rundung, Wochenende, Jahreswechsel, Vorzeichen, Einheitswert';
END $$;

ROLLBACK;
