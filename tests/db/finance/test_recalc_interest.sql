-- tests/db/finance/test_recalc_interest.sql
-- Zweitrechnung Zinsbuchung (Tagesgeld): Erwartungswerte schriftlich hergeleitet, nicht aus der fn abgeschrieben.
-- Fachregel: Zins = Saldo x Satz x Tage/Basis; ACT/365 = echte Kalendertage / 365 (Tagesgeld-Standard), 30E/360 =
--   jeder volle Monat 30 Tage (Tag 31 und der letzte Februartag zaehlen als 30, Variante "30E/360 ISDA",
--   https://en.wikipedia.org/wiki/Day_count_convention#30E/360_ISDA). Bei Satzwechsel je Satz seine Tage, einmal runden.
--   (1) 15.000 zu 3,1 % ACT/365, Gutschrift am Monatsersten:
--       Dezember 2027 (31 Tage, ueber den Jahreswechsel) = 15000 x 0,031 x 31/365 = 39,4931 -> 39,49
--       Februar 2028 (Schaltjahr, 29 Tage)               = 15000 x 0,031 x 29/365 = 36,9452 -> 36,95
--   (2) Satzsenkung auf 2,6 % ab 15.02.2028: 14 Tage zu 3,1 % + 15 Tage zu 2,6 %
--       = 15000 x (0,434 + 0,390) / 365 = 33,8630 -> 33,86 (je Segment gerundet waeren es 17,84 + 16,03 = 33,87)
--   (3) Negativer Saldo -> kein Habenzins (0), auch nicht negativ
--   (4) Tageszaehlung direkt: ACT/365 volles Schaltjahr 366/365; 30E/360 vom 31.01. zum 29.02.2028 = 30/360;
--       15.12.2027 -> 15.03.2028 = 90/360; ACT/360 Januar = 31/360
-- Self-contained, Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_res  jsonb;
  v_acct int;
  v_neg  int;
  v_amt  numeric;
BEGIN
  v_res := finance.fn_create_account(
    '{"name":"__recalc_tg__","account_type":"cash","currency":"EUR","interest_rate":3.1,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"ACT/365","interest_valid_from":"2027-11-01"}'::jsonb);
  v_acct := (v_res->>'account_id')::int;
  IF v_acct IS NULL THEN RAISE EXCEPTION 'FAIL [setup]: %', v_res; END IF;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acct, 15000, '2027-11-01', 'other');

  -- (1)
  v_amt := finance.fn_interest_amount_due(v_acct, '2028-01-01');
  IF v_amt IS DISTINCT FROM 39.49 THEN RAISE EXCEPTION 'FAIL [1a] Dezember ueber Jahreswechsel: erwartet 39.49, got %', v_amt; END IF;
  v_amt := finance.fn_interest_amount_due(v_acct, '2028-03-01');
  IF v_amt IS DISTINCT FROM 36.95 THEN RAISE EXCEPTION 'FAIL [1b] Februar Schaltjahr: erwartet 36.95, got %', v_amt; END IF;

  -- (2)
  v_res := finance.fn_set_account_interest(
    jsonb_build_object('account_id', v_acct, 'annual_rate', 2.6, 'schedule_unit', 'month', 'valid_from', '2028-02-15'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2 setup]: %', v_res; END IF;
  v_amt := finance.fn_interest_amount_due(v_acct, '2028-03-01');
  IF v_amt IS DISTINCT FROM 33.86 THEN RAISE EXCEPTION 'FAIL [2] Satzwechsel einmal gerundet: erwartet 33.86, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [1-2] Tagesgeld ACT/365: Jahreswechsel, Schaltjahr, Satzwechsel';

  -- (3)
  v_res := finance.fn_create_account(
    '{"name":"__recalc_neg__","account_type":"cash","currency":"EUR","interest_rate":2,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"ACT/365","interest_valid_from":"2027-11-01"}'::jsonb);
  v_neg := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_neg, -500, '2027-11-01', 'other');
  v_amt := finance.fn_interest_amount_due(v_neg, '2027-12-01');
  IF v_amt IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [3] negativer Saldo: erwartet 0, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [3] negativer Saldo -> 0';

  -- (4)
  IF finance.fn_interest_day_fraction('2027-07-01', '2028-07-01', 'ACT/365') IS DISTINCT FROM 366::numeric / 365
     OR finance.fn_interest_day_fraction('2028-01-31', '2028-02-29', '30E/360') IS DISTINCT FROM 30::numeric / 360
     OR finance.fn_interest_day_fraction('2027-12-15', '2028-03-15', '30E/360') IS DISTINCT FROM 90::numeric / 360
     OR finance.fn_interest_day_fraction('2027-01-01', '2027-02-01', 'ACT/360') IS DISTINCT FROM 31::numeric / 360 THEN
    RAISE EXCEPTION 'FAIL [4] Tageszaehlung'; END IF;
  RAISE NOTICE 'PASS [4] Tageszaehlung ACT/365, 30E/360, ACT/360';
END $$;

ROLLBACK;
