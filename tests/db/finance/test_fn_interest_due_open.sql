-- tests/db/finance/test_fn_interest_due_open.sql
-- Offene Zins-Vorkommen je aktivem cash/fixed_deposit/p2p-Konto (fn_interest_eligible_account_type): (account_id, value_date, period_start, period_end, auto_post).
-- Schedule auf MIN(valid_from) verankert; dom voll geehrt (-1/fester Tag/NULL); Arrears entkoppelt value_date
-- vom period_end; booked/skip keyen auf period_end (interest_period_end / interest_skips.period_end); ORDER BY period_end.
BEGIN;

DO $$
DECLARE
  v_res  JSONB;
  v_acct INT;
  v_cnt  INT;
  v_vd   DATE;
  v_pe   DATE;
  v_ps   DATE;
  v_ap   BOOLEAN;
BEGIN
  -- ===== Basis: monatlich, dom NULL (Anker-Tag) =====
  -- Altzeile (vor dem Pflicht-Tag 2026-10-24 geschrieben): fn_create_account lehnt monatlich ohne Tag ab -> direkt anlegen.
  SELECT finance.fn_create_account('{"name":"__test_int_due__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, day_count_convention, valid_from)
  VALUES (v_acct, 4, 1, 'month', 'ACT/365', '2026-01-01');

  -- p_until 2026-03-15 -> period_end 2026-02-01 & 2026-03-01 (k>=1; Anker 2026-01-01 ist KEIN Ende)
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_due_open('2026-03-15') WHERE account_id = v_acct;
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [monthly count]: erwartet 2, got %', v_cnt; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2026-03-15')
             WHERE account_id = v_acct AND period_end = '2026-01-01') THEN
    RAISE EXCEPTION 'FAIL [anchor]: 2026-01-01 darf KEIN period_end sein';
  END IF;
  -- value_date = period_end (kein Arrears); period_start = period_end - 1 Monat (clamp Anker)
  SELECT value_date, period_start INTO v_vd, v_ps FROM finance.fn_interest_due_open('2026-03-15')
    WHERE account_id = v_acct AND period_end = '2026-02-01';
  IF v_vd IS DISTINCT FROM DATE '2026-02-01' THEN RAISE EXCEPTION 'FAIL [vd default]: erwartet 2026-02-01, got %', v_vd; END IF;
  IF v_ps IS DISTINCT FROM DATE '2026-01-01' THEN RAISE EXCEPTION 'FAIL [period_start]: erwartet 2026-01-01, got %', v_ps; END IF;
  RAISE NOTICE 'PASS [monatlich dom NULL: 2 Enden, Anker kein Ende, vd=pe, ps=pe-1M]';

  -- gebucht (interest_period_end = period_end) -> 02-01 faellt raus
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end, description)
  VALUES (v_acct, 33, '2026-02-01', 'interest', '2026-02-01', 'Zinsgutschrift 2026-02-01');
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_due_open('2026-03-15') WHERE account_id = v_acct;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [booked on period_end]: erwartet 1, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [gebucht (interest_period_end=period_end) faellt raus -> 1]';

  -- generische Zins-Tx (interest_period_end NULL) markiert KEINE Periode als gebucht
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_acct, 9, '2026-03-01', 'interest', 'Bonuszins');   -- interest_period_end NULL
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_due_open('2026-03-15') WHERE account_id = v_acct;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [generic not booked]: 03-01 muss offen bleiben, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [generische Zins-Tx (period_end NULL) markiert nichts als gebucht]';

  -- uebersprungen via fn_skip_interest_occurrence(period_end 2026-03-01) -> 0 offen
  SELECT finance.fn_skip_interest_occurrence(
    jsonb_build_object('account_id', v_acct, 'period_end', '2026-03-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [skip fn]: %', v_res; END IF;
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_due_open('2026-03-15') WHERE account_id = v_acct;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [skip on period_end]: erwartet 0, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [uebersprungen (period_end) faellt raus -> 0]';

  -- Skip-Idempotenz: zweimal skip auf dasselbe period_end -> ON CONFLICT DO NOTHING -> genau eine Zeile
  SELECT finance.fn_skip_interest_occurrence(
    jsonb_build_object('account_id', v_acct, 'period_end', '2026-03-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [skip idem fn]: %', v_res; END IF;
  SELECT count(*) INTO v_cnt FROM finance.interest_skips
    WHERE account_id = v_acct AND period_end = '2026-03-01';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [skip idempotent]: erwartet genau 1 Zeile, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [skip-Idempotenz: zweiter skip auf dasselbe period_end -> 1 Zeile]';

  -- ===== dom = fester Tag (15.) =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_dom15__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"month","interest_credit_day_of_month":15,"interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  -- p_until 2026-02-20 -> Enden 2026-01-15, 2026-02-15
  IF NOT EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2026-02-20')
                 WHERE account_id = v_acct AND period_end = '2026-01-15')
     OR NOT EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2026-02-20')
                 WHERE account_id = v_acct AND period_end = '2026-02-15') THEN
    RAISE EXCEPTION 'FAIL [dom 15]: Enden 2026-01-15/2026-02-15 erwartet';
  END IF;
  RAISE NOTICE 'PASS [dom fester Tag 15 geehrt]';

  -- ===== dom = -1 (Monatsletzter) + Arrears (posting am 5. des Folgemonats) =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_arrears__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"month","interest_credit_day_of_month":-1,"interest_posting_day_of_month":5,"interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- period_end 2026-01-31 -> value_date 2026-02-05 (5. des Folgemonats), value_date <> period_end.
  -- p_until 2026-02-10: 01-31/02-05 sichtbar; das Ende 2026-02-28 (value_date 2026-03-05) noch NICHT faellig.
  SELECT value_date, period_end INTO v_vd, v_pe FROM finance.fn_interest_due_open('2026-02-10')
    WHERE account_id = v_acct AND period_end = '2026-01-31';
  IF v_vd IS DISTINCT FROM DATE '2026-02-05' THEN RAISE EXCEPTION 'FAIL [arrears vd]: erwartet 2026-02-05, got %', v_vd; END IF;
  IF v_vd = v_pe THEN RAISE EXCEPTION 'FAIL [arrears decoupled]: value_date darf <> period_end sein'; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2026-02-10')
             WHERE account_id = v_acct AND period_end = '2026-02-28') THEN
    RAISE EXCEPTION 'FAIL [arrears window]: 2026-02-28 (value_date 2026-03-05) noch nicht faellig';
  END IF;
  RAISE NOTICE 'PASS [dom -1 + Arrears: value_date=2026-02-05 entkoppelt, Fenster auf value_date]';

  -- ===== auto_post-Flag durchgereicht =====
  UPDATE finance.account_interest_rates SET auto_post = true WHERE account_id = v_acct;
  SELECT auto_post INTO v_ap FROM finance.fn_interest_due_open('2026-02-10')
    WHERE account_id = v_acct AND period_end = '2026-01-31';
  IF v_ap IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [auto_post true]: erwartet true, got %', v_ap; END IF;
  RAISE NOTICE 'PASS [auto_post-Flag durchgereicht]';

  -- ===== daily + ORDER BY period_end ASC =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_daily__","account_type":"cash","currency":"EUR","interest_rate":3.65,"interest_credit_unit":"day","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  -- auto_post explizit NULL -> die fn COALESCEt NULL auf false (sicherer Default: nicht auto-buchen).
  -- (fn_create_account setzt daily zwar auf true; hier pruefen wir die COALESCE-Logik der due_open-fn.)
  UPDATE finance.account_interest_rates SET auto_post = NULL WHERE account_id = v_acct;
  -- p_until 2026-01-05 -> Enden 2026-01-02,03,04,05 (4)
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_due_open('2026-01-05') WHERE account_id = v_acct;
  IF v_cnt <> 4 THEN RAISE EXCEPTION 'FAIL [daily count]: erwartet 4, got %', v_cnt; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2026-01-05') WHERE account_id = v_acct AND auto_post IS DISTINCT FROM false) THEN
    RAISE EXCEPTION 'FAIL [auto_post COALESCE]: NULL -> false erwartet';
  END IF;
  -- ORDER BY period_end ASC
  IF (SELECT array_agg(period_end ORDER BY period_end) FROM finance.fn_interest_due_open('2026-01-05') WHERE account_id = v_acct)
     IS DISTINCT FROM (SELECT array_agg(period_end) FROM finance.fn_interest_due_open('2026-01-05') WHERE account_id = v_acct) THEN
    RAISE EXCEPTION 'FAIL [order]: nicht nach period_end ASC sortiert';
  END IF;
  RAISE NOTICE 'PASS [daily: 4 Enden, auto_post default false, ORDER BY period_end ASC]';

  -- ===== p2p ist zins-faehig (WS-Z4, Bondora Go & Grow: taeglich) -> erscheint in due_open =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_p2p__","account_type":"p2p","currency":"EUR","interest_rate":6,"interest_credit_unit":"day","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  -- p_until 2026-01-04 -> Enden 2026-01-02,03,04 (3; Anker 01-01 kein Ende). Frueher war p2p ausgeschlossen.
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_due_open('2026-01-04') WHERE account_id = v_acct;
  IF v_cnt <> 3 THEN RAISE EXCEPTION 'FAIL [p2p eligible]: erwartet 3 Enden, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [p2p zins-faehig: erscheint in due_open]';

  -- ===== nur Einlagen-Konten: due_open-FILTER schliesst Depot aus (Defense-in-Depth, WS-Z4) =====
  -- Das Anlegen einer Depot-Zinszeile sperrt der Trigger trg_finance_reject_interest_rate_ineligible
  -- (geprueft in test_fn_interest_eligible_account_type). Hier wird der due_open-Filter geprueft: selbst
  -- eine (per Trigger-Disable simulierte) Alt-/Korrupt-Zeile auf einem Depot darf NIE als Stichtag erscheinen.
  SELECT finance.fn_create_account(
    jsonb_build_object('name','__test_int_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_acct)
  ) INTO v_res;
  ALTER TABLE finance.account_interest_rates DISABLE TRIGGER trg_finance_reject_interest_rate_ineligible;
  INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, valid_from)
  VALUES ((v_res->>'account_id')::int, 4, 1, 'month', '2026-01-01');
  ALTER TABLE finance.account_interest_rates ENABLE TRIGGER trg_finance_reject_interest_rate_ineligible;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2026-03-15')
             WHERE account_id = (v_res->>'account_id')::int) THEN
    RAISE EXCEPTION 'FAIL [deposit-only]: Depot-Konto darf keine Zins-Stichtage liefern';
  END IF;
  RAISE NOTICE 'PASS [Depot-Filter: Alt-Zeile bleibt aus due_open]';

  -- ===== 90-Tage-Rueckfenster (auf value_date) =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_window__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_valid_from":"2025-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2025-12-15')
             WHERE account_id = v_acct AND period_end = '2025-02-01') THEN
    RAISE EXCEPTION 'FAIL [90d window]: 2025-02-01 (>90 Tage) darf nicht erscheinen';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2025-12-15')
                 WHERE account_id = v_acct AND period_end = '2025-12-01') THEN
    RAISE EXCEPTION 'FAIL [90d window]: 2025-12-01 (im Fenster) muss erscheinen';
  END IF;
  RAISE NOTICE 'PASS [90-Tage-Fenster auf value_date]';

  -- ===== Kalender-Raster (Live-Befund 2026-10-24): vierteljaehrlich zum Quartalsende, Start 24.10. =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_quarter__","account_type":"cash","currency":"EUR","interest_rate":2,"interest_credit_unit":"month","interest_credit_interval":3,"interest_credit_day_of_month":-1,"interest_valid_from":"2026-10-24"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  SELECT period_start, period_end INTO v_ps, v_pe FROM finance.fn_interest_due_open('2027-01-15') WHERE account_id = v_acct;
  IF v_pe IS DISTINCT FROM DATE '2026-12-31' OR v_ps IS DISTINCT FROM DATE '2026-10-24' THEN
    RAISE EXCEPTION 'FAIL [Quartal Teilperiode]: erwartet 2026-10-24..2026-12-31, got %..%', v_ps, v_pe; END IF;
  SELECT period_start, period_end INTO v_ps, v_pe FROM finance.fn_interest_due_open('2027-04-05') WHERE account_id = v_acct;
  IF v_pe IS DISTINCT FROM DATE '2027-03-31' OR v_ps IS DISTINCT FROM DATE '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL [Quartal]: erwartet 2026-12-31..2027-03-31, got %..%', v_ps, v_pe; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2027-04-05') WHERE account_id = v_acct AND period_end IN ('2026-10-31', '2027-01-31')) THEN
    RAISE EXCEPTION 'FAIL [Quartal]: altes Anker-Raster (31.10./31.01.) darf nicht mehr erscheinen'; END IF;
  RAISE NOTICE 'PASS [Quartalsende = Kalender-Quartal, erste Teilperiode ab Start]';

  -- ===== jaehrlich zum Jahresende vs. am Jahrestag =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_yearend__","account_type":"cash","currency":"EUR","interest_rate":2,"interest_credit_unit":"year","interest_credit_day_of_month":-1,"interest_valid_from":"2026-10-24"}'::jsonb
  ) INTO v_res;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2027-01-10') WHERE account_id = (v_res->>'account_id')::int
                 AND period_end = '2026-12-31' AND period_start = '2026-10-24') THEN
    RAISE EXCEPTION 'FAIL [Jahresende]: erwartet Teilperiode 2026-10-24..2026-12-31'; END IF;
  SELECT finance.fn_create_account(
    '{"name":"__test_int_anniv__","account_type":"fixed_deposit","currency":"EUR","interest_rate":3,"interest_credit_unit":"year","interest_valid_from":"2026-10-24","fixed_deposit_maturity_date":"2028-10-24"}'::jsonb
  ) INTO v_res;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_interest_due_open('2027-11-01') WHERE account_id = (v_res->>'account_id')::int
                 AND period_end = '2027-10-24' AND period_start = '2026-10-24') THEN
    RAISE EXCEPTION 'FAIL [Jahrestag]: erwartet 2026-10-24..2027-10-24'; END IF;
  RAISE NOTICE 'PASS [jaehrlich: Jahresende kalendergerecht, ohne Tag am Jahrestag]';

  -- ===== Schutz vor Doppelverzinsung: Bestandsbuchung nach ALTEM Anker-Raster (31.01.) vor dem neuen Quartal =====
  -- Simuliert ein Konto, das vor der Kalender-Korrektur bis 31.01. verzinst wurde: die naechste Periode (bis 31.03.)
  -- beginnt am 31.01. (juengste erledigte Periode), NICHT am Rasterpunkt 31.12. (sonst Januar doppelt).
  SELECT finance.fn_create_account(
    '{"name":"__test_int_legacygrid__","account_type":"cash","currency":"EUR","interest_rate":2,"interest_credit_unit":"month","interest_credit_interval":3,"interest_credit_day_of_month":-1,"interest_valid_from":"2026-10-24"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end, description)
  VALUES (v_acct, 1000, '2026-10-24', 'other', NULL, 'Einzahlung'),
         (v_acct, 5, '2027-01-31', 'interest', '2027-01-31', 'Zinsgutschrift alt');
  SELECT period_start INTO v_ps FROM finance.fn_interest_due_open('2027-04-05') WHERE account_id = v_acct AND period_end = '2027-03-31';
  IF v_ps IS DISTINCT FROM DATE '2027-01-31' THEN
    RAISE EXCEPTION 'FAIL [Doppelverzinsung due_open]: period_start erwartet 2027-01-31, got %', v_ps; END IF;
  -- fn_interest_amount_due rechnet dieselbe Periode: 59 Tage (31.01.-31.03.) statt 90
  IF finance.fn_interest_amount_due(v_acct, '2027-03-31')
     IS DISTINCT FROM ROUND(1005 * 0.02 * finance.fn_interest_day_fraction('2027-01-31', '2027-03-31', 'ACT/365'), 2) THEN
    RAISE EXCEPTION 'FAIL [Doppelverzinsung amount_due]: erwartet 59-Tage-Zins, got %', finance.fn_interest_amount_due(v_acct, '2027-03-31'); END IF;
  RAISE NOTICE 'PASS [kein Doppelzins nach Raster-Wechsel: Periode beginnt an der juengsten erledigten Periode]';

END $$;

ROLLBACK;
