-- tests/db/finance/test_recalc_loan.sql
-- Zweitrechnung (differential testing) Kredit: Erwartungswerte unabhaengig hergeleitet (eigene Decimal-Schleife in
-- PowerShell + geschlossene Annuitaetenformel als Gegenprobe), nicht aus fn_loan_simulate abgeschrieben.
-- Fachregel: Annuitaet A = K * i / (1 - (1 + i)^-n), i = Jahreszins / 12 (nominaler Monatszins, Banken-Standard);
--   Monatszins = Restschuld * i, kaufmaennisch auf Cent; Tilgung = A - Zins; Schlussrate = Restschuld + Zins.
--   Quelle: https://de.wikipedia.org/wiki/Annuit%C3%A4tendarlehen
--   (1) 240.000 EUR, 3,6 % p.a., 25 Jahre: A exakt 1.214,4065 -> 1.214,41 (aufgerundet, damit 300 Raten reichen).
--       Anker 31.01.2027 ohne festen Tag -> Monatsend-Clamping gegen den Anker (28.02., 31.03. ...).
--       Nach 12 Raten Rest 233.968,21 (geschlossene Formel ohne Cent-Rundung: 233.968,20), Zins 8.541,13.
--       Nach 60 Raten Rest 207.551,05 (Formel 207.551,08 -> Cent-Rundung driftet nur Cent).
--       Volltilgung: 300. Rate am 31.12.2051 (Schlussrate 1.212,63), Zins gesamt 124.321,22.
--   (2) Sondertilgung 10.000 nach der Dezember-Rate 2027: 270 weitere Raten, letzte am 30.06.2050, Zins 102.717,69.
--   (3) Rate 0 (Raten ausgesetzt, Zins laeuft auf): 10.000 zu 6 % -> 10.050,00 / 10.100,25 / 10.150,75.
--   (4) Quartalsrate 1.500 (Monatsletzter) ueber den Jahreswechsel, 8.000 zu 4,8 %: Zins 96,00 / 75,84 / 65,41 ->
--       nach 3 Raten Rest 3.737,25; 6. Rate am 31.03.2028 tilgt, Zins gesamt 319,20.
--   (5) Faelligkeitsraster Monatsende/Schaltjahr: Anker 31.01.2028 -> 29.02.2028, 31.03.; Monatsletzter (dom -1)
--       ueber den Jahreswechsel -> 30.11., 31.12., 31.01., 28.02.2027.
-- Self-contained, reine Funktionen, Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_seg jsonb := '[{"anchor":"2027-01-31","interval":1,"unit":"month","dom":null,"days":null,"valid_from":"2027-01-31","valid_to":null,"amount":1214.41}]';
  r record;
BEGIN
  -- (1) Annuitaet
  r := finance.fn_loan_simulate(240000, 3.6, v_seg, NULL, '2027-12-31', '2027-01-15');
  IF r.balance IS DISTINCT FROM 233968.21 OR r.interest_total IS DISTINCT FROM 8541.13 OR r.payoff_date IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1a] nach 12 Raten: erwartet 233968.21 / Zins 8541.13, got %', r; END IF;
  r := finance.fn_loan_simulate(240000, 3.6, v_seg, NULL, '2031-12-31', '2027-01-15');
  IF r.balance IS DISTINCT FROM 207551.05 OR r.interest_total IS DISTINCT FROM 40415.65 THEN
    RAISE EXCEPTION 'FAIL [1b] nach 60 Raten: erwartet 207551.05 / 40415.65, got %', r; END IF;
  r := finance.fn_loan_simulate(240000, 3.6, v_seg, NULL, '2060-01-01', '2027-01-15');
  IF r.balance IS DISTINCT FROM 0 OR r.payoff_date IS DISTINCT FROM DATE '2051-12-31'
     OR r.interest_total IS DISTINCT FROM 124321.22 THEN
    RAISE EXCEPTION 'FAIL [1c] Volltilgung: erwartet 31.12.2051 / Zins 124321.22, got %', r; END IF;
  -- eine Rate vor dem Ende: Rest = Schlussrate - Monatszins der letzten Rate (1.212,63 = Rest + Rest*0,003)
  r := finance.fn_loan_simulate(240000, 3.6, v_seg, NULL, '2051-11-30', '2027-01-15');
  IF r.balance IS DISTINCT FROM 1209.00 THEN
    RAISE EXCEPTION 'FAIL [1d] Rest vor der Schlussrate: erwartet 1209.00, got %', r; END IF;
  RAISE NOTICE 'PASS [1] Annuitaet 240.000 / 3,6 %% / 25 J.: 12, 60, Volltilgung, Schlussrate';

  -- (2) Sondertilgung 10.000 nach der Dezember-Rate 2027 (Restschuld 233.968,21 - 10.000)
  r := finance.fn_loan_simulate(223968.21, 3.6, v_seg, '2027-12-31', '2060-01-01', '2028-01-05');
  IF r.payoff_date IS DISTINCT FROM DATE '2050-06-30' OR r.interest_total IS DISTINCT FROM 102717.69 THEN
    RAISE EXCEPTION 'FAIL [2] Sondertilgung: erwartet 30.06.2050 / Zins 102717.69, got %', r; END IF;
  RAISE NOTICE 'PASS [2] Sondertilgung verkuerzt um 18 Raten';

  -- (3) Rate 0
  r := finance.fn_loan_simulate(10000, 6,
    '[{"anchor":"2026-02-01","interval":1,"unit":"month","dom":1,"days":null,"valid_from":"2026-02-01","valid_to":null,"amount":0}]',
    NULL, '2026-04-01', '2026-01-15');
  IF r.balance IS DISTINCT FROM 10150.75 OR r.interest_total IS DISTINCT FROM 150.75 THEN
    RAISE EXCEPTION 'FAIL [3] Rate 0: erwartet 10150.75 / 150.75, got %', r; END IF;
  RAISE NOTICE 'PASS [3] Rate 0 -> Zins laeuft auf';

  -- (4) Quartal ueber den Jahreswechsel
  r := finance.fn_loan_simulate(8000, 4.8,
    '[{"anchor":"2026-12-31","interval":3,"unit":"month","dom":-1,"days":null,"valid_from":"2026-12-01","valid_to":null,"amount":1500}]',
    NULL, '2027-06-30', '2026-12-01');
  IF r.balance IS DISTINCT FROM 3737.25 OR r.interest_total IS DISTINCT FROM 237.25 THEN
    RAISE EXCEPTION 'FAIL [4a] Quartal 3 Raten: erwartet 3737.25 / 237.25, got %', r; END IF;
  r := finance.fn_loan_simulate(8000, 4.8,
    '[{"anchor":"2026-12-31","interval":3,"unit":"month","dom":-1,"days":null,"valid_from":"2026-12-01","valid_to":null,"amount":1500}]',
    NULL, '2030-01-01', '2026-12-01');
  IF r.payoff_date IS DISTINCT FROM DATE '2028-03-31' OR r.interest_total IS DISTINCT FROM 319.20 THEN
    RAISE EXCEPTION 'FAIL [4b] Quartal Volltilgung: erwartet 31.03.2028 / 319.20, got %', r; END IF;
  RAISE NOTICE 'PASS [4] Quartalsrate ueber den Jahreswechsel';

  -- (5) Raster
  IF ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2028-01-31', 1, 'month', NULL, NULL, '2028-01-01', '2028-04-30') d ORDER BY d)
     IS DISTINCT FROM ARRAY['2028-01-31','2028-02-29','2028-03-31','2028-04-30']::date[] THEN
    RAISE EXCEPTION 'FAIL [5a] Schaltjahr-Clamping: %',
      ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2028-01-31', 1, 'month', NULL, NULL, '2028-01-01', '2028-04-30') d ORDER BY d); END IF;
  IF ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-11-30', 1, 'month', -1::smallint, NULL, '2026-11-01', '2027-02-28') d ORDER BY d)
     IS DISTINCT FROM ARRAY['2026-11-30','2026-12-31','2027-01-31','2027-02-28']::date[] THEN
    RAISE EXCEPTION 'FAIL [5b] Monatsletzter ueber Jahreswechsel'; END IF;
  RAISE NOTICE 'PASS [5] Raster Monatsende/Schaltjahr/Jahreswechsel';
END $$;

ROLLBACK;
