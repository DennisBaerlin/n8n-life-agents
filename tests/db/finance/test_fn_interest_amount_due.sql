-- tests/db/finance/test_fn_interest_amount_due.sql
-- Die DB rechnet den Zins (NIE das LLM): basis x (annual_rate/100) x fn_interest_day_fraction(period_start, period_end, conv).
--   period_start ist SCHEDULE-abgeleitet (period_end - 1 Kadenz-Schritt, clamp auf den Zins-Start MIN(valid_from)) -
--     NIE aus gebuchten/uebersprungenen Tx (sonst Doppelverzinsung bei Luecke/Skip).
--   basis = Saldo zum period_end OHNE jede Zins-Tx mit interest_period_end >= period_end (eigene + spaetere
--     Gutschrift zaehlt nie in die eigene Basis -> re-eval-robust; FRUEHERE Gutschriften zaehlen -> Zinseszins).
--   Taggenaue Satz-Mischung (WS-Z3): bei unterjaehrigem Satzwechsel je Satz nur SEINE Tage (Segment-Summe),
--     EINMAL gerundet; basis konstant. Additivitaet der deutschen 30E/360 (symmetrische Februar-/31er-Klammer)
--     an inneren Grenzen geprueft. Fail-closed: Luecke in der Zinshistorie -> RAISE.
-- Signatur: fn_interest_amount_due(account_id, period_end).
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_acct   INT;
  v_acct2  INT;
  v_amt    NUMERIC;
  v_amt2   NUMERIC;
  v_raised BOOLEAN;
BEGIN
  -- ============ Jahres-Zins, volles Jahr (30E/360 Spalten-Default) ============
  SELECT finance.fn_create_account(
    '{"name":"__test_int_amt__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"year","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');

  -- period_end = 2027-01-01 (echtes Jahres-Schedule-Ende); period_start = 2026-01-01 (Zins-Start). 30E/360 = 1.0.
  v_amt := finance.fn_interest_amount_due(v_acct, '2027-01-01');
  IF v_amt IS DISTINCT FROM 400.00 THEN RAISE EXCEPTION 'FAIL [year 30E/360]: erwartet 400.00, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [year 30E/360 -> 400.00]';

  -- F1: Buchung NACH dem period_end aendert den Vorschlag nicht (basis = Saldo zum period_end).
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 5000, '2027-06-01', 'other');
  IF finance.fn_interest_amount_due(v_acct, '2027-01-01') IS DISTINCT FROM 400.00 THEN
    RAISE EXCEPTION 'FAIL [F1 stable]: erwartet weiterhin 400.00';
  END IF;
  RAISE NOTICE 'PASS [F1: spaetere Buchung aendert Vorschlag nicht]';

  -- ============ Day-count zaehlt: Monats-Periode 30E/360 vs ACT/365 ============
  -- 6% p.a. monatlich auf 20000, day-count explizit 30E/360 (Monat = exakt 30/360 = 1/12).
  SELECT finance.fn_create_account(
    '{"name":"__test_int_amt2__","account_type":"cash","currency":"EUR","interest_rate":6,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct2 := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct2, 20000, '2026-01-01', 'other');

  -- period_end 2026-02-01, period_start 2026-01-01. 30E/360: 20000 * 6% * 1/12 = 100.00
  v_amt := finance.fn_interest_amount_due(v_acct2, '2026-02-01');
  IF v_amt IS DISTINCT FROM 100.00 THEN RAISE EXCEPTION 'FAIL [month 30E/360]: erwartet 100.00, got %', v_amt; END IF;

  -- Dieselbe Periode unter ACT/365 (31 echte Tage): 20000 * 6% * 31/365 = 101.92
  UPDATE finance.account_interest_rates SET day_count_convention = 'ACT/365' WHERE account_id = v_acct2;
  v_amt := finance.fn_interest_amount_due(v_acct2, '2026-02-01');
  IF v_amt IS DISTINCT FROM 101.92 THEN RAISE EXCEPTION 'FAIL [month ACT/365]: erwartet 101.92 (31 Tage), got %', v_amt; END IF;
  RAISE NOTICE 'PASS [day-count zaehlt: 30E/360 100.00 vs ACT/365 101.92]';

  -- ============ 12-Monats-Drift-Beweis (day_fraction summiert exakt auf 1.0, 30E/360) ============
  -- Tiling-Beweis: 12 zusammenhaengende Monatsenden -> Summe der Anteile = 1.0 (kein Tag faellt durch/doppelt).
  SELECT SUM(finance.fn_interest_day_fraction(
            (DATE '2026-01-01' + (k || ' months')::interval)::date,
            (DATE '2026-01-01' + ((k+1) || ' months')::interval)::date,
            '30E/360'))
    INTO v_amt
    FROM generate_series(0, 11) AS k;
  -- ROUND(.,10): 1/12 ist dezimal nicht endlich (12 x 0.08333... = 0.99999...96 = reines Numeric-Rauschen);
  -- eine ECHTE Drift (ein Tag doppelt/fehlt) waere +/- 1/360 ~ 0.0028, also um Groessenordnungen groesser.
  IF ROUND(v_amt, 10) IS DISTINCT FROM 1.0 THEN RAISE EXCEPTION 'FAIL [12-month drift 30E/360]: erwartet 1.0, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [12-Monats-Drift 30E/360 -> 1.0 (kein Tag verloren/doppelt)]';

  -- ============ Taggenaue Satz-Mischung: Satzanstieg MITTEN in der Periode (WS-Z3, vorher 41.67) ============
  -- 4% ab 2026-01-01, dann 5% ab 2026-01-15. period_end 2026-02-01, 30E/360. Seg1 [01-01,01-15)=14/360 @4%,
  -- Seg2 [01-15,02-01)=16/360 @5% (14+16=30). ROUND(10000*(0.04*14 + 0.05*16)/360, 2) = 13600/360 = 37.78.
  SELECT finance.fn_create_account(
    '{"name":"__test_int_switch__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');
  SELECT finance.fn_set_account_interest(
    jsonb_build_object('account_id', v_acct, 'annual_rate', 5, 'schedule_unit', 'month', 'valid_from', '2026-01-15')
  ) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [switch setup]: %', v_res; END IF;

  v_amt := finance.fn_interest_amount_due(v_acct, '2026-02-01');
  IF v_amt IS DISTINCT FROM 37.78 THEN RAISE EXCEPTION 'FAIL [rate rise in period]: erwartet 37.78 (14d@4%% + 16d@5%%), got %', v_amt; END IF;
  RAISE NOTICE 'PASS [Satzanstieg-in-Periode taggenau gemischt -> 37.78]';

  -- ============ Taggenaue Satz-Mischung: Satzsenkung MITTEN in der Periode (WS-Z3) ============
  -- 6% ab 2026-01-01, dann 4% ab 2026-01-15. Seg1 14/360 @6%, Seg2 16/360 @4%.
  -- ROUND(10000*(0.06*14 + 0.04*16)/360, 2) = 14800/360 = 41.11.
  SELECT finance.fn_create_account(
    '{"name":"__test_int_fall__","account_type":"cash","currency":"EUR","interest_rate":6,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');
  SELECT finance.fn_set_account_interest(
    jsonb_build_object('account_id', v_acct, 'annual_rate', 4, 'schedule_unit', 'month', 'valid_from', '2026-01-15')
  ) INTO v_res;
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-02-01');
  IF v_amt IS DISTINCT FROM 41.11 THEN RAISE EXCEPTION 'FAIL [rate fall in period]: erwartet 41.11 (14d@6%% + 16d@4%%), got %', v_amt; END IF;
  RAISE NOTICE 'PASS [Satzsenkung-in-Periode taggenau gemischt -> 41.11]';

  -- ============ Zinseszins ueber 2 Perioden + Re-Eval-Robustheit (B2) ============
  -- 12% monatlich auf 10000, 30E/360 (= 1/12 je Monat).
  SELECT finance.fn_create_account(
    '{"name":"__test_int_compound__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');

  -- Periode 1 (2026-01-01..2026-02-01): 10000 * 12% * 1/12 = 100.00; buchen (interest_period_end = period_end).
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-02-01');
  IF v_amt IS DISTINCT FROM 100.00 THEN RAISE EXCEPTION 'FAIL [compound p1]: erwartet 100.00, got %', v_amt; END IF;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end, description)
  VALUES (v_acct, 100.00, '2026-02-01', 'interest', '2026-02-01', 'Zinsgutschrift 2026-02-01');

  -- Periode 2 (2026-02-01..2026-03-01): basis = 10000 + 100 (frueheres interest_period_end < period_end zaehlt)
  --   -> 10100 * 12% * 1/12 = 101.00 (Zinseszins, > 100).
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-03-01');
  IF v_amt IS DISTINCT FROM 101.00 THEN RAISE EXCEPTION 'FAIL [compound p2]: erwartet 101.00 (Zinseszins), got %', v_amt; END IF;

  -- Re-Eval-Robustheit: Periode 2 buchen, dann erneut fragen -> weiterhin 101.00 (eigene Gutschrift via
  --   interest_period_end >= period_end ausgeschlossen, nicht in die eigene Basis).
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end, description)
  VALUES (v_acct, 101.00, '2026-03-01', 'interest', '2026-03-01', 'Zinsgutschrift 2026-03-01');
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-03-01');
  IF v_amt IS DISTINCT FROM 101.00 THEN RAISE EXCEPTION 'FAIL [compound re-eval]: erwartet weiterhin 101.00, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [Zinseszins 100->101 + re-eval-robust]';

  -- generische Zins-Tx (interest_period_end NULL) zaehlt in die Basis (kein Scheduler-Credit) und wird NICHT
  -- ausgeschlossen: +50 generischer Zins -> Periode-2-Basis 10150, aber period_end 2026-03-01 ist bereits
  -- gebucht; pruefe stattdessen Periode 3 (2026-03-01..2026-04-01): basis = 10000+100+101+50 = 10251.
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_acct, 50, '2026-03-10', 'interest', 'Bonuszins vom Nachbarn');   -- interest_period_end NULL
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-04-01');
  IF v_amt IS DISTINCT FROM ROUND(10251 * 0.12 / 12.0, 2) THEN
    RAISE EXCEPTION 'FAIL [generic interest in basis]: erwartet %, got %', ROUND(10251 * 0.12 / 12.0, 2), v_amt;
  END IF;
  RAISE NOTICE 'PASS [generische Zins-Tx (period_end NULL) zaehlt in die Basis]';

  -- ============ Luecke/Skip in der Mitte: Folgeperiode verzinst NUR ihren Schritt (B1) ============
  -- 12% monatlich auf 10000; Periode 1 NICHT gebucht (Luecke). Periode 2 period_start = period_end - 1 Monat
  --   = 2026-02-01 (NICHT zurueck bis valid_from) -> 10000 * 12% * 1/12 = 100.00 (ein Monat, NICHT zwei).
  SELECT finance.fn_create_account(
    '{"name":"__test_int_gap__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');
  -- Periode 1 (period_end 2026-02-01) ueberspringen wir bewusst (kein Write, kein Skip-Eintrag noetig fuer die Mathe).
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-03-01');   -- Periode 2
  IF v_amt IS DISTINCT FROM 100.00 THEN
    RAISE EXCEPTION 'FAIL [gap B1]: erwartet 100.00 (nur eigener Monat, kein Nachholen), got %', v_amt;
  END IF;
  RAISE NOTICE 'PASS [Luecke: Folgeperiode verzinst nur ihren Schritt -> 100.00]';

  -- ============ Schaltjahr + Tages-Anteil (ACT/365) ============
  -- 3.65% taeglich auf 10000, ACT/365: 1 Tag = 1/365 -> 1.00. period_end 2024-02-29 (Schalttag).
  SELECT finance.fn_create_account(
    '{"name":"__test_int_day__","account_type":"cash","currency":"EUR","interest_rate":3.65,"interest_credit_unit":"day","interest_valid_from":"2024-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  UPDATE finance.account_interest_rates SET day_count_convention = 'ACT/365' WHERE account_id = v_acct;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2024-01-01', 'other');
  v_amt := finance.fn_interest_amount_due(v_acct, '2024-02-29');   -- period_start 2024-02-28, 1 Tag
  IF v_amt IS DISTINCT FROM 1.00 THEN RAISE EXCEPTION 'FAIL [day ACT/365 leap]: erwartet 1.00, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [Tages-Anteil ACT/365 am Schalttag -> 1.00]';

  -- ============ Habensaldo-Guard: 0-Saldo -> 0 ============
  SELECT finance.fn_create_account(
    '{"name":"__test_int_zero__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"year","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  IF finance.fn_interest_amount_due((v_res->>'account_id')::int, '2027-01-01') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [zero balance]: erwartet 0';
  END IF;
  RAISE NOTICE 'PASS [zero balance -> 0]';

  -- ============ Additivitaets-Regression (WS-Z3): Same-Rate-Split == ungeteilt ============
  -- Ein Satzwechsel auf DENSELBEN Satz mitten in der Periode darf den Betrag NICHT aendern (Segment-Summe ==
  -- ungeteilter Einzel-Satz-Betrag). Kritisch fuer die deutsche 30E/360 an inneren Grenzen 31. + 28./29. Feb
  -- (symmetrische Klammer -> Teleskop-Summe kuerzt sich; bei ISDA-30E/360 wuerde das brechen).
  -- (a) 30E/360, innere Grenze am 31. (Jan-Periode 2026-01-01..2026-02-01); ungeteilt 100.00.
  SELECT finance.fn_create_account('{"name":"__test_int_add31__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acct, 10000, '2026-01-01', 'other');
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-02-01');   -- ungeteilt
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id', v_acct, 'annual_rate', 12, 'schedule_unit', 'month', 'valid_from', '2026-01-31'));
  v_amt2 := finance.fn_interest_amount_due(v_acct, '2026-02-01');  -- gesplittet am 31.
  IF v_amt IS DISTINCT FROM 100.00 OR v_amt2 IS DISTINCT FROM v_amt THEN
    RAISE EXCEPTION 'FAIL [additivity 31]: ungeteilt % vs split %, erwartet beide 100.00', v_amt, v_amt2; END IF;
  RAISE NOTICE 'PASS [Additivitaet 30E/360 Split am 31. -> unveraendert 100.00]';

  -- (b) 30E/360, innere Grenze am 28. Feb (Nicht-Schaltjahr 2026; Feb-Periode 2026-02-01..2026-03-01).
  SELECT finance.fn_create_account('{"name":"__test_int_addfeb__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acct, 10000, '2026-01-01', 'other');
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-03-01');   -- ungeteilte Feb-Periode
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id', v_acct, 'annual_rate', 12, 'schedule_unit', 'month', 'valid_from', '2026-02-28'));
  v_amt2 := finance.fn_interest_amount_due(v_acct, '2026-03-01');  -- gesplittet am 28. Feb
  IF v_amt IS DISTINCT FROM 100.00 OR v_amt2 IS DISTINCT FROM v_amt THEN
    RAISE EXCEPTION 'FAIL [additivity 28-Feb]: ungeteilt % vs split %, erwartet beide 100.00', v_amt, v_amt2; END IF;
  RAISE NOTICE 'PASS [Additivitaet 30E/360 Split am 28. Feb -> unveraendert 100.00]';

  -- (c) 30E/360, innere Grenze am 29. Feb (Schaltjahr 2024; Feb-Periode 2024-02-01..2024-03-01).
  SELECT finance.fn_create_account('{"name":"__test_int_addleap__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2024-01-01"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acct, 10000, '2024-01-01', 'other');
  v_amt := finance.fn_interest_amount_due(v_acct, '2024-03-01');
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id', v_acct, 'annual_rate', 12, 'schedule_unit', 'month', 'valid_from', '2024-02-29'));
  v_amt2 := finance.fn_interest_amount_due(v_acct, '2024-03-01');
  IF v_amt IS DISTINCT FROM 100.00 OR v_amt2 IS DISTINCT FROM v_amt THEN
    RAISE EXCEPTION 'FAIL [additivity 29-Feb]: ungeteilt % vs split %, erwartet beide 100.00', v_amt, v_amt2; END IF;
  RAISE NOTICE 'PASS [Additivitaet 30E/360 Split am 29. Feb -> unveraendert 100.00]';

  -- (d) ACT/365 + (e) ACT/360: trivial additiv (echte Kalendertage) — Split mitten im Monat aendert nichts.
  SELECT finance.fn_create_account('{"name":"__test_int_addact5__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"ACT/365","interest_valid_from":"2026-01-01"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acct, 10000, '2026-01-01', 'other');
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-02-01');
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id', v_acct, 'annual_rate', 12, 'schedule_unit', 'month', 'valid_from', '2026-01-15'));
  v_amt2 := finance.fn_interest_amount_due(v_acct, '2026-02-01');
  IF v_amt2 IS DISTINCT FROM v_amt THEN RAISE EXCEPTION 'FAIL [additivity ACT/365]: ungeteilt % vs split %', v_amt, v_amt2; END IF;
  RAISE NOTICE 'PASS [Additivitaet ACT/365 Split mitten im Monat -> unveraendert]';

  SELECT finance.fn_create_account('{"name":"__test_int_addact60__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"ACT/360","interest_valid_from":"2026-01-01"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acct, 10000, '2026-01-01', 'other');
  v_amt := finance.fn_interest_amount_due(v_acct, '2026-02-01');
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id', v_acct, 'annual_rate', 12, 'schedule_unit', 'month', 'valid_from', '2026-01-20'));
  v_amt2 := finance.fn_interest_amount_due(v_acct, '2026-02-01');
  IF v_amt2 IS DISTINCT FROM v_amt THEN RAISE EXCEPTION 'FAIL [additivity ACT/360]: ungeteilt % vs split %', v_amt, v_amt2; END IF;
  RAISE NOTICE 'PASS [Additivitaet ACT/360 Split mitten im Monat -> unveraendert]';

  -- ============ Fail-closed: Luecke in der Zinshistorie -> RAISE (WS-Z3) ============
  -- Direkt zwei Rate-Zeilen mit einer Luecke [2026-01-10, 2026-01-20) (NICHT via fn_set, die schliesst lueckenlos).
  SELECT finance.fn_create_account('{"name":"__test_int_gap_fc__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, day_count_convention, valid_from, valid_to)
  VALUES (v_acct, 4, 1, 'month', '30E/360', '2026-01-01', '2026-01-10'),
         (v_acct, 4, 1, 'month', '30E/360', '2026-01-20', NULL);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acct, 10000, '2026-01-01', 'other');
  v_raised := false;
  BEGIN
    v_amt := finance.fn_interest_amount_due(v_acct, '2026-02-01');   -- Segment [01-10,01-20) ungedeckt -> RAISE
  EXCEPTION WHEN others THEN
    v_raised := true;
    IF SQLERRM NOT LIKE '%not fully covered%' THEN RAISE; END IF;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [fail-closed]: Luecke in der Zinshistorie haette RAISE ausloesen muessen'; END IF;
  RAISE NOTICE 'PASS [fail-closed: Luecke in der Zinshistorie -> RAISE]';

END $$;

ROLLBACK;
