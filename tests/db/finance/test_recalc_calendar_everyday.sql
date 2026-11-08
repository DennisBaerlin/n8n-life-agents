-- tests/db/finance/test_recalc_calendar_everyday.sql
-- Zweitrechnung Sparplan-Broker-Kalender und Alltagswert: Erwartungswerte schriftlich hergeleitet.
-- Broker-Kalender, Fachregel: ein Broker mit festen Ausfuehrungstagen 2./9./16./23. fuehrt "woechentlich" genau
--   4-mal je Kalendermonat aus (nicht 52/12-mal), "zweimal im Monat" jeden zweiten dieser Tage ab dem Starttag
--   (https://www.finanzfluss.de/broker/trade-republic/). Monatswert = Betrag x Termine je Monat; echte
--   7-Tage-Woche = Betrag x 365,25 / 12 / 7.
--   (1) Termine 12/2027 bis 01/2028 (Jahreswechsel): 02., 09., 16., 23. je Monat -> 8 Termine
--   (2) 25 EUR an 4 festen Tagen = 100,00 / Monat, 1.200,00 / Jahr; echte Woche 25 EUR = 108,71 / Monat
--       (25 x 30,4375 / 7 = 108,705), 1.304,46 / Jahr (25 x 365,25 / 7 = 1.304,464)
--   (3) Depot bei diesem Broker: "woechentlich" -> monatlich an {2,9,16,23}; "zweimal im Monat" ab dem 09. -> {9,23}
-- Alltagswert, Fachregel: Alltag je Tag = nicht zugeordnete Abgaenge ohne einmalige Grossausgaben / neu abgeglichene
--   Tage der juengsten 3 Auszuege (der frueheste Auszug zaehlt nicht, sobald ein spaeterer existiert);
--   je Monat = je Tag x 30,4375.
--   (4) Auszuege 31 + 30 + 31 = 92 Tage, Abgaenge -400 (davon einmalig -300) / -310 / -510 -> (-1.220 + 300) / 92
--       = -10,00 je Tag -> -304,375 -> -304,38 je Monat. Der frueheste Auszug (-5.000) zaehlt nicht.
-- Self-contained, Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_dep int; v jsonb;
BEGIN
  -- (1)
  IF ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2027-12-02', 1, 'month', NULL, '{2,9,16,23}'::smallint[],
                                                          '2027-12-01', '2028-01-31') d ORDER BY d)
     IS DISTINCT FROM ARRAY['2027-12-02','2027-12-09','2027-12-16','2027-12-23',
                            '2028-01-02','2028-01-09','2028-01-16','2028-01-23']::date[] THEN
    RAISE EXCEPTION 'FAIL [1] feste Tage ueber den Jahreswechsel'; END IF;

  -- (2)
  IF finance.fn_monthly_equivalent(25, 1, 'month', 4) IS DISTINCT FROM 100.00
     OR finance.fn_annual_equivalent(25, 1, 'month', 4) IS DISTINCT FROM 1200.00
     OR finance.fn_monthly_equivalent(25, 1, 'week') IS DISTINCT FROM 108.71
     OR finance.fn_annual_equivalent(25, 1, 'week', 1) IS DISTINCT FROM 1304.46 THEN
    RAISE EXCEPTION 'FAIL [2] Monats-/Jahreswert: % / % / % / %', finance.fn_monthly_equivalent(25, 1, 'month', 4),
      finance.fn_annual_equivalent(25, 1, 'month', 4), finance.fn_monthly_equivalent(25, 1, 'week'),
      finance.fn_annual_equivalent(25, 1, 'week', 1); END IF;

  -- (3)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__recalc_verr__', 'cash', 'EUR', 'active')
    RETURNING id INTO v_dep;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, settlement_account_id)
  VALUES ('__recalc_depot__', 'stocks_depot', 'EUR', 'active', 'Trade Republic', v_dep) RETURNING id INTO v_dep;
  v := finance.fn_resolve_plan_schedule(v_dep, 'week', 1::smallint, NULL, '2028-01-02', NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR v->>'schedule_unit' <> 'month'
     OR v->'schedule_days_of_month' IS DISTINCT FROM '[2, 9, 16, 23]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3a] woechentlich: %', v; END IF;
  v := finance.fn_resolve_plan_schedule(v_dep, 'week', 2::smallint, NULL, '2028-01-09', NULL);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR v->'schedule_days_of_month' IS DISTINCT FROM '[9, 23]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3b] zweimal im Monat: %', v; END IF;
  RAISE NOTICE 'PASS [1-3] Broker-Kalender: Termine, Monats-/Jahreswert, Rhythmus-Ableitung';
END $$;

DO $$
DECLARE
  t date := current_date;
  v_a int; r record;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__recalc_alltag__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, oneoff_out, oneoff_threshold)
  VALUES (v_a, t - 130, t - 100, 9000, 4000, 'EUR', 9, 0, -5000, 0, 0, NULL),
         (v_a, t - 96,  t - 66,  4000, 3600, 'EUR', 9, 0, -400,  0, -300, 250),
         (v_a, t - 65,  t - 36,  3600, 3290, 'EUR', 9, 0, -310,  0, 0, 250),
         (v_a, t - 35,  t - 5,   3290, 2780, 'EUR', 9, 0, -510,  0, 0, 250);
  SELECT * INTO r FROM finance.fn_account_everyday_per_day(v_a);
  IF r.per_day IS DISTINCT FROM -10.00 OR r.provisional THEN RAISE EXCEPTION 'FAIL [4a] je Tag: %', r; END IF;
  SELECT * INTO r FROM finance.fn_household_everyday_month();
  IF r.monthly_everyday IS DISTINCT FROM -304.38 OR r.accounts <> 1 THEN RAISE EXCEPTION 'FAIL [4b] je Monat: %', r; END IF;
  RAISE NOTICE 'PASS [4] Alltagswert: 3 juengste Auszuege, frueheste ausgenommen, Einmal-Ausgabe ausgenommen';
END $$;

ROLLBACK;
