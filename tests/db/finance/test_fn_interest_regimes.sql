-- tests/db/finance/test_fn_interest_regimes.sql
-- Audit Paket 2, Punkt 5: Zinssatzwechsel erbt den Rhythmus; Kadenzwechsel verankert das Raster neu.
--   Fehler vorher: fn_set_account_interest setzte ohne Kadenz-Angabe Default 'year'; fn_interest_due_open nahm die
--   Kadenz der OFFENEN Zeile, verankert am ersten valid_from -> ein Monatskonto (Gutschriften Feb..Jul gebucht) bekam
--   nach dem Satzwechsel am 1.7. eine Jahresperiode 1.1.-1.1. -> Februar bis Juni doppelt verzinst.
--   Jetzt: (1) Erben der Kadenz; (2) Regime = zusammenhaengender Lauf gleicher Kadenz (fn_interest_regimes), Anker =
--   Regime-Start; das alte Regime endet am Wechseltag OHNE eigene Gutschrift, der Rest seit seinem letzten Rasterpunkt
--   laeuft in die erste Periode des neuen (Live-Befund 2026-10-24); (3) Periodenstart = groesste
--   Rastergrenze < period_end (auch fuer Teilperioden); (4) offen nur nach der juengsten gebuchten/uebersprungenen
--   Periode -> Alt-Raster aus Fehler-Daten wird nie nachtraeglich angeboten.
BEGIN;

DO $$
DECLARE
  v_res  JSONB;
  v_a    INT;
  v_b    INT;
  v_c    INT;
  v_d    INT;
  v_row  RECORD;
  v_cnt  INT;
  v_prev DATE;
BEGIN
  -- ===== (3) Periodenstart fuer Teilperioden (Rastergrenze strikt < period_end) =====
  IF finance.fn_interest_period_start(DATE '2026-01-01', DATE '2026-07-15', 1, 'month', NULL) <> DATE '2026-07-01' THEN
    RAISE EXCEPTION 'FAIL period_start [Monat, Teilperiode]: erwartet 2026-07-01, got %',
      finance.fn_interest_period_start(DATE '2026-01-01', DATE '2026-07-15', 1, 'month', NULL); END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-10', DATE '2026-07-10', 1, 'month', 15) <> DATE '2026-06-15'
     OR finance.fn_interest_period_start(DATE '2026-01-10', DATE '2026-07-20', 1, 'month', 15) <> DATE '2026-07-15' THEN
    RAISE EXCEPTION 'FAIL period_start [dom=15 vor/nach Grenztag]'; END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-31', DATE '2026-03-10', 1, 'month', -1) <> DATE '2026-02-28' THEN
    RAISE EXCEPTION 'FAIL period_start [dom=-1 Februar]: got %',
      finance.fn_interest_period_start(DATE '2026-01-31', DATE '2026-03-10', 1, 'month', -1); END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-31', DATE '2026-03-15', 1, 'month', NULL) <> DATE '2026-02-28' THEN
    RAISE EXCEPTION 'FAIL period_start [dom NULL, Anker 31.]'; END IF;
  IF finance.fn_interest_period_start(DATE '2026-01-01', DATE '2026-01-10', 7, 'day', NULL) <> DATE '2026-01-08'
     OR finance.fn_interest_period_start(DATE '2026-01-01', DATE '2026-01-10', 1, 'week', NULL) <> DATE '2026-01-08'
     OR finance.fn_interest_period_start(DATE '2020-06-15', DATE '2026-01-01', 1, 'year', NULL) <> DATE '2025-06-15' THEN
    RAISE EXCEPTION 'FAIL period_start [day/week/year Teilperiode]'; END IF;
  RAISE NOTICE 'PASS period_start [Teilperioden: Monat/dom 15/dom -1/Anker 31/day/week/year]';

  -- ===== (1) Beispiel aus dem Audit: Satzwechsel ohne Kadenz erbt "monatlich" =====
  SELECT (finance.fn_create_account('{"name":"__test_irg_a__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_a;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 12000, '2025-12-31', 'other');
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id',v_a,'annual_rate',2.0,'schedule_unit','month','schedule_day_of_month',1,
    'posting_day_of_month',3,'valid_from','2026-01-01'));
  SELECT finance.fn_set_account_interest(jsonb_build_object('account_id',v_a,'annual_rate',3.0,'valid_from','2026-07-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL Satzwechsel: %', v_res; END IF;
  SELECT * INTO v_row FROM finance.account_interest_rates WHERE account_id = v_a AND valid_to IS NULL;
  IF v_row.schedule_unit::text IS DISTINCT FROM 'month' OR v_row.schedule_interval IS DISTINCT FROM 1
     OR v_row.posting_day_of_month IS DISTINCT FROM 3 OR v_row.auto_post IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL erben [Kadenz]: unit=% n=% pdom=% auto=%', v_row.schedule_unit, v_row.schedule_interval,
      v_row.posting_day_of_month, v_row.auto_post; END IF;
  -- keine Jahresperiode: die Juli-Gutschrift deckt 1.7.-1.8. zum neuen Satz (12000 x 3 % x 31/365 = 30.58)
  SELECT * INTO v_row FROM finance.fn_interest_due_open(DATE '2026-09-05') o WHERE o.account_id = v_a AND o.period_end = DATE '2026-08-01';
  IF v_row.period_start IS DISTINCT FROM DATE '2026-07-01' THEN
    RAISE EXCEPTION 'FAIL erben [Periode]: erwartet 2026-07-01..2026-08-01, got %..%', v_row.period_start, v_row.period_end; END IF;
  IF finance.fn_interest_amount_due(v_a, DATE '2026-08-01') IS DISTINCT FROM 30.58 THEN
    RAISE EXCEPTION 'FAIL erben [Betrag Juli]: erwartet 30.58, got %', finance.fn_interest_amount_due(v_a, DATE '2026-08-01'); END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open(DATE '2027-01-05') o WHERE o.account_id = v_a AND o.period_end - o.period_start > 31) THEN
    RAISE EXCEPTION 'FAIL erben [keine Jahresperiode]: %', (SELECT jsonb_agg(to_jsonb(o)) FROM finance.fn_interest_due_open(DATE '2027-01-05') o WHERE o.account_id = v_a); END IF;
  RAISE NOTICE 'PASS erben [Satzwechsel ohne Kadenz bleibt monatlich, Juli = 30.58, keine Doppelverzinsung]';

  -- ===== (2) expliziter Kadenzwechsel: keine Gutschrift am Wechseltag, danach neues Raster =====
  SELECT (finance.fn_create_account('{"name":"__test_irg_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_b;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_b, 12000, '2025-12-31', 'other');
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id',v_b,'annual_rate',2.0,'schedule_unit','month','schedule_day_of_month',1,'valid_from','2026-01-01'));
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id',v_b,'annual_rate',3.0,'schedule_unit','year','valid_from','2026-07-15'));
  SELECT count(*) INTO v_cnt FROM finance.fn_interest_regimes(v_b);
  IF v_cnt <> 2
     OR NOT EXISTS (SELECT 1 FROM finance.fn_interest_regimes(v_b) r WHERE r.regime_start = '2026-01-01' AND r.regime_end = '2026-07-15'
                    AND r.anchor = '2026-01-01' AND r.unit = 'month')
     OR NOT EXISTS (SELECT 1 FROM finance.fn_interest_regimes(v_b) r WHERE r.regime_start = '2026-07-15' AND r.regime_end IS NULL
                    AND r.anchor = '2026-07-15' AND r.unit = 'year') THEN
    RAISE EXCEPTION 'FAIL regimes: %', (SELECT jsonb_agg(to_jsonb(r)) FROM finance.fn_interest_regimes(v_b) r); END IF;
  -- Fenster bis 1.8.: Juni (1.5.-1.6.), Juli (1.6.-1.7.) im alten Raster — lueckenlos; KEINE eigene Gutschrift am
  -- Wechseltag 15.7. (Live-Befund 2026-10-24: eine Bank zahlt dort nichts, die Teilperiode 1.7.-15.7. gehoert in die
  -- naechste regulaere Gutschrift des neuen Rhythmus)
  v_prev := DATE '2026-05-01'; v_cnt := 0;
  FOR v_row IN SELECT * FROM finance.fn_interest_due_open(DATE '2026-08-01') o WHERE o.account_id = v_b ORDER BY o.period_end LOOP
    IF v_row.period_start <> v_prev THEN
      RAISE EXCEPTION 'FAIL Kacheln: Periode %..% schliesst nicht an % an', v_row.period_start, v_row.period_end, v_prev; END IF;
    v_prev := v_row.period_end; v_cnt := v_cnt + 1;
  END LOOP;
  IF v_cnt <> 2 OR v_prev <> DATE '2026-07-01' THEN
    RAISE EXCEPTION 'FAIL Wechseltag: erwartet 2 Perioden bis 2026-07-01 (keine am 15.7.), got % bis %', v_cnt, v_prev; END IF;
  -- Erste Periode des neuen Rhythmus 1.7.2026-15.7.2027: alter Satz auf 1.7.-15.7. (12000 x 2 % x 14/365 = 9.2055)
  -- + neuer Satz 15.7.-15.7. (360.00), einmal gerundet = 369.21
  SELECT * INTO v_row FROM finance.fn_interest_due_open(DATE '2027-07-20') o WHERE o.account_id = v_b;
  IF v_row.period_start IS DISTINCT FROM DATE '2026-07-01' OR v_row.period_end IS DISTINCT FROM DATE '2027-07-15'
     OR finance.fn_interest_amount_due(v_b, DATE '2027-07-15') IS DISTINCT FROM 369.21 THEN
    RAISE EXCEPTION 'FAIL neues Raster: %..% Betrag %', v_row.period_start, v_row.period_end,
      finance.fn_interest_amount_due(v_b, DATE '2027-07-15'); END IF;
  RAISE NOTICE 'PASS Kadenzwechsel [keine Gutschrift am Wechseltag, erste neue Periode 1.7.-15.7.2027 = 369.21 (Satz-Mischung)]';

  -- Live-Befund 2026-10-24 (Trade Republic): Rhythmus 'year' am 23.10. angelegt, am 24.10. auf monatlich/Monatsende/
  -- Gutschrift am 1. korrigiert -> KEINE Gutschrift 23.10.-24.10.; die erste Periode 23.10.-31.10. wird am 01.11. gutgeschrieben.
  DECLARE v_e INT; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_irg_e__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_e;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_e, 5000, '2026-10-01', 'other');
    INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, day_count_convention, valid_from, valid_to)
    VALUES (v_e, 2.5, 1, 'year', 'ACT/365', '2026-10-23', '2026-10-24');
    INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, schedule_day_of_month, posting_day_of_month, day_count_convention, valid_from)
    VALUES (v_e, 2.5, 1, 'month', -1, 1, 'ACT/365', '2026-10-24');
    IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open(DATE '2026-10-30') o WHERE o.account_id = v_e) THEN
      RAISE EXCEPTION 'FAIL Wechseltag TR: Gutschrift am 24.10. angeboten: %',
        (SELECT jsonb_agg(to_jsonb(o)) FROM finance.fn_interest_due_open(DATE '2026-10-30') o WHERE o.account_id = v_e); END IF;
    SELECT * INTO v_row FROM finance.fn_interest_due_open(DATE '2026-11-05') o WHERE o.account_id = v_e;
    IF v_row.period_start IS DISTINCT FROM DATE '2026-10-23' OR v_row.period_end IS DISTINCT FROM DATE '2026-10-31'
       OR v_row.value_date IS DISTINCT FROM DATE '2026-11-01'
       OR finance.fn_interest_amount_due(v_e, DATE '2026-10-31') IS DISTINCT FROM ROUND(5000 * 0.025 * 8 / 365.0, 2) THEN
      RAISE EXCEPTION 'FAIL Wechseltag TR: erwartet 23.10.-31.10. am 01.11., got %..% am % Betrag %', v_row.period_start,
        v_row.period_end, v_row.value_date, finance.fn_interest_amount_due(v_e, DATE '2026-10-31'); END IF;
  END;
  RAISE NOTICE 'PASS Wechseltag [korrigierter Rhythmus: keine Gutschrift am Wechseltag, Rest in der naechsten regulaeren]';

  -- Wechsel monatlich -> taeglich (auto_post true): die erste taegliche Periode traegt den Rest des alten Rhythmus
  -- (1.7.-16.7.) und kommt deshalb MIT Karte (auto_post false); ab dem Folgetag automatisch.
  DECLARE v_f INT; v_ap1 BOOLEAN; v_ap2 BOOLEAN; v_ps1 DATE; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_irg_f__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_f;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_f, 1000, '2025-12-31', 'other');
    PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id',v_f,'annual_rate',2.0,'schedule_unit','month','schedule_day_of_month',1,'valid_from','2026-01-01'));
    PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id',v_f,'annual_rate',2.0,'schedule_unit','day','valid_from','2026-07-15'));
    SELECT o.period_start, o.auto_post INTO v_ps1, v_ap1 FROM finance.fn_interest_due_open(DATE '2026-07-20') o WHERE o.account_id = v_f AND o.period_end = '2026-07-16';
    SELECT o.auto_post INTO v_ap2 FROM finance.fn_interest_due_open(DATE '2026-07-20') o WHERE o.account_id = v_f AND o.period_end = '2026-07-17';
    IF v_ps1 IS DISTINCT FROM DATE '2026-07-01' OR v_ap1 IS DISTINCT FROM false OR v_ap2 IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL Wechsel auf taeglich: erwartet 1.7.-16.7. mit Karte, danach auto; got ps=% ap1=% ap2=%', v_ps1, v_ap1, v_ap2; END IF;
  END;
  RAISE NOTICE 'PASS Wechsel auf taeglich [Rest des alten Rhythmus mit Karte, danach automatisch]';

  -- ===== (4) Bestandsdaten mit dem alten Fehler (Default year am 1.7.) — keine Doppel-Gutschrift =====
  SELECT (finance.fn_create_account('{"name":"__test_irg_c__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_c;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_c, 12000, '2025-12-31', 'other');
  INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, valid_from, valid_to)
  VALUES (v_c, 2.0, 1, 'month', '2026-01-01', '2026-07-01'), (v_c, 3.0, 1, 'year', '2026-07-01', NULL);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end)
  SELECT v_c, 20, d::date, 'interest', d::date FROM generate_series(DATE '2026-02-01', DATE '2026-07-01', interval '1 month') d;
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open(DATE '2027-01-05') o WHERE o.account_id = v_c) THEN
    RAISE EXCEPTION 'FAIL Bestand: Jahresperiode ab 1.1. (Doppelverzinsung Feb-Jun) wird angeboten: %',
      (SELECT jsonb_agg(to_jsonb(o)) FROM finance.fn_interest_due_open(DATE '2027-01-05') o WHERE o.account_id = v_c); END IF;
  SELECT * INTO v_row FROM finance.fn_interest_due_open(DATE '2027-07-05') o WHERE o.account_id = v_c;
  IF v_row.period_start IS DISTINCT FROM DATE '2026-07-01' OR v_row.period_end IS DISTINCT FROM DATE '2027-07-01' THEN
    RAISE EXCEPTION 'FAIL Bestand [neues Raster]: %..%', v_row.period_start, v_row.period_end; END IF;
  RAISE NOTICE 'PASS Bestand [Fehler-Raster: keine Periode ueber gebuchte Monate, naechste 1.7.-1.7.]';

  -- ===== (4b) offen nur NACH der juengsten gebuchten Periode =====
  SELECT (finance.fn_create_account('{"name":"__test_irg_d__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_d;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_d, 12000, '2025-12-31', 'other');
  PERFORM finance.fn_set_account_interest(jsonb_build_object('account_id',v_d,'annual_rate',2.0,'schedule_unit','month','schedule_day_of_month',1,'valid_from','2026-01-01'));
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end)
  VALUES (v_d, 20, '2026-03-01', 'interest', '2026-03-01');
  IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open(DATE '2026-03-05') o WHERE o.account_id = v_d) THEN
    RAISE EXCEPTION 'FAIL offen-nach-juengster: Periode vor der gebuchten 2026-03-01 angeboten'; END IF;
  RAISE NOTICE 'PASS offen [nur Perioden nach der juengsten gebuchten/uebersprungenen]';

  -- ===== (5) Review: rueckdatierter Satz-/Kadenzwechsel VOR die juengste verzinste Periode -> ok:false =====
  SELECT finance.fn_set_account_interest(jsonb_build_object('account_id',v_d,'annual_rate',2.5,'schedule_unit','month',
    'schedule_interval',3,'valid_from','2026-02-15')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'credited_until')::date IS DISTINCT FROM DATE '2026-03-01' THEN
    RAISE EXCEPTION 'FAIL rueckdatiert: erwartet ok:false bis 2026-03-01, got %', v_res; END IF;
  RAISE NOTICE 'PASS rueckdatiert [Wechsel vor bereits verzinster Periode -> ok:false]';

  -- ===== (6) Review: nur das Intervall genannt ("alle 3 Monate") -> Einheit Monat bleibt (nicht 'year') =====
  SELECT finance.fn_set_account_interest(jsonb_build_object('account_id',v_d,'annual_rate',2.5,'schedule_interval',3,
    'valid_from','2026-04-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL Intervall: %', v_res; END IF;
  SELECT * INTO v_row FROM finance.account_interest_rates WHERE account_id = v_d AND valid_to IS NULL;
  IF v_row.schedule_unit::text IS DISTINCT FROM 'month' OR v_row.schedule_interval IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL Intervall: erwartet alle 3 Monate, got % %', v_row.schedule_interval, v_row.schedule_unit; END IF;
  -- Vorschau = Buchung: dieselbe fn liefert die Karte
  v_res := finance.fn_interest_rate_preview(jsonb_build_object('account_id',v_d,'annual_rate',3.0,'valid_from','2026-06-01'));
  IF (v_res->>'schedule_interval')::int IS DISTINCT FROM 3 OR v_res->>'schedule_unit' IS DISTINCT FROM 'month'
     OR (v_res->>'auto_post')::boolean IS DISTINCT FROM false OR v_res->>'conv_reason' IS DISTINCT FROM 'previous' THEN
    RAISE EXCEPTION 'FAIL Vorschau: %', v_res; END IF;
  RAISE NOTICE 'PASS Intervall/Vorschau [nur Intervall -> Monat bleibt; Vorschau erbt Kadenz/auto_post]';
END $$;

ROLLBACK;
