-- tests/db/finance/test_fn_set_recurring_payment_day_shift.sql
-- Eigenschaft: Eine reine Verschiebung des Buchungstags (schedule_day_of_month) aendert die Anzahl der Vorkommen im
-- Geltungszeitraum nicht -- kein Termin geht verloren, keiner kommt doppelt (jeder Monat genau einmal). Gezaehlt wird je Kette
-- (alle Glieder gleichen Namens): offene Vorkommen (fn_recurring_due_open) + gebuchte (recurring_due_date) + uebersprungene.
-- Kuenftige Faelle auf festen Daten 2031/2032 (noch nichts faellig); Faelle mit gebuchten/ueberfaelligen Terminen relativ zu
-- heute (Monat m0 = laufender Monat), damit sie nicht mit dem Kalender kippen.
BEGIN;

CREATE FUNCTION pg_temp.occ_set(p_name text, p_from date, p_until date) RETURNS SETOF date LANGUAGE sql AS $$
    SELECT o.due_date FROM finance.fn_recurring_due_open(p_from, p_until) o
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id WHERE r.name = p_name
    UNION ALL
    SELECT t.recurring_due_date FROM finance.transactions t
    JOIN finance.recurring_payments r ON r.id = t.recurring_payment_id
    WHERE r.name = p_name AND t.recurring_due_date BETWEEN p_from AND p_until
    UNION ALL
    SELECT s.due_date FROM finance.recurring_payment_skips s
    JOIN finance.recurring_payments r ON r.id = s.recurring_payment_id
    WHERE r.name = p_name AND s.due_date BETWEEN p_from AND p_until;
$$;
CREATE FUNCTION pg_temp.occ(p_name text, p_from date, p_until date) RETURNS text LANGUAGE sql AS $$
    SELECT COALESCE(string_agg(d::text, ',' ORDER BY d), '') FROM pg_temp.occ_set(p_name, p_from, p_until) d;
$$;
CREATE FUNCTION pg_temp.cnt(p_name text, p_from date, p_until date) RETURNS int LANGUAGE sql AS $$
    SELECT count(*)::int FROM pg_temp.occ_set(p_name, p_from, p_until);
$$;
-- Monate mit mehr als einem Termin (Doppel) im Fenster
CREATE FUNCTION pg_temp.dup_months(p_name text, p_from date, p_until date) RETURNS int LANGUAGE sql AS $$
    SELECT count(*)::int FROM (SELECT date_trunc('month', d) FROM pg_temp.occ_set(p_name, p_from, p_until) d
                               GROUP BY 1 HAVING count(*) > 1) x;
$$;

DO $$
DECLARE
  v_res JSONB; v_acct INT; v_kid INT; v_rp INT; c0 INT; c1 INT; v_txt TEXT; v_last DATE; d DATE; k INT;
  v_sum0 NUMERIC; v_sum1 NUMERIC;
  m0 DATE := date_trunc('month', core.fn_today())::date;   -- laufender Monat
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_dsh_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_dsh_kid__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_kid := (v_res->>'account_id')::int;

  -- TEST 1 (Fund): monatlich am 25., erster Termin = valid_from 2031-01-25; Tag -> 20. Der Januar-Termin wandert auf den 20.
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_a__','account_id',v_acct,
    'direction','expense','amount',50,'schedule_unit','month','schedule_day_of_month',25,'first_payment_date','2031-01-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  c0 := pg_temp.cnt('__test_dsh_a__', '2031-01-01', '2031-12-31');
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL day_shift [frueher, ok]: %', v_res; END IF;
  c1 := pg_temp.cnt('__test_dsh_a__', '2031-01-01', '2031-12-31');
  v_txt := split_part(pg_temp.occ('__test_dsh_a__', '2031-01-01', '2031-12-31'), ',', 1);
  IF c0 <> 12 OR c1 <> c0 OR v_txt IS DISTINCT FROM '2031-01-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [frueher]: vorher % nachher % Vorkommen, erstes % (erwartet 12/12, 2031-01-20)', c0, c1, v_txt; END IF;
  IF v_res->>'first_due' IS DISTINCT FROM '2031-01-20' OR (v_res->>'split')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL day_shift [first_due in place]: % (erwartet first_due 2031-01-20, split false)', v_res; END IF;
  RAISE NOTICE 'PASS day_shift [Tag nach vorn: 12 Termine, erster 2031-01-20, first_due 2031-01-20]';

  -- TEST 2: Tag nach hinten (20. -> 25.): gleiche Anzahl, erster 2031-01-25
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_b__','account_id',v_acct,
    'direction','expense','amount',50,'schedule_unit','month','schedule_day_of_month',20,'first_payment_date','2031-01-20')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  c0 := pg_temp.cnt('__test_dsh_b__', '2031-01-01', '2031-12-31');
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',25));
  c1 := pg_temp.cnt('__test_dsh_b__', '2031-01-01', '2031-12-31');
  v_txt := split_part(pg_temp.occ('__test_dsh_b__', '2031-01-01', '2031-12-31'), ',', 1);
  IF c0 <> 12 OR c1 <> c0 OR v_txt IS DISTINCT FROM '2031-01-25' THEN
    RAISE EXCEPTION 'FAIL day_shift [spaeter]: vorher % nachher %, erstes % (erwartet 12/12, 2031-01-25)', c0, c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [Tag nach hinten: gleiche Anzahl]';

  -- TEST 3: Monatsletzter -> 20.: der Januar bleibt (2031-01-20)
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_c__','account_id',v_acct,
    'direction','expense','amount',50,'schedule_unit','month','schedule_day_of_month',-1,'first_payment_date','2031-01-31')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  c0 := pg_temp.cnt('__test_dsh_c__', '2031-01-01', '2031-12-31');
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20));
  c1 := pg_temp.cnt('__test_dsh_c__', '2031-01-01', '2031-12-31');
  v_txt := split_part(pg_temp.occ('__test_dsh_c__', '2031-01-01', '2031-12-31'), ',', 1);
  IF c0 <> 12 OR c1 <> c0 OR v_txt IS DISTINCT FROM '2031-01-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [Monatsletzter]: vorher % nachher %, erstes % (erwartet 12/12, 2031-01-20)', c0, c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [Monatsletzter -> 20.: gleiche Anzahl]';

  -- TEST 4: Dauer-Uebertrag mit Ende (letzter gueltiger Tag 2031-06-25, 6 Termine), Tag -> 28.: weiter 6 Termine,
  --         letzte Ausfuehrung (standing_order_overview) 2031-06-28
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object('name','__test_dsh_d__','from_account_id',v_acct,
    'to_account_id',v_kid,'amount',100,'schedule_unit','month','schedule_day_of_month',25,
    'first_payment_date','2031-01-25','valid_to','2031-06-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  c0 := pg_temp.cnt('__test_dsh_d__', '2031-01-01', '2031-12-31');
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',28));
  c1 := pg_temp.cnt('__test_dsh_d__', '2031-01-01', '2031-12-31');
  SELECT last_execution INTO v_last FROM finance.standing_order_overview WHERE name = '__test_dsh_d__';
  IF c0 <> 6 OR c1 <> c0 OR v_last IS DISTINCT FROM DATE '2031-06-28' THEN
    RAISE EXCEPTION 'FAIL day_shift [Ende, spaeter]: vorher % nachher %, letzte Ausfuehrung % (erwartet 6/6, 2031-06-28)', c0, c1, v_last; END IF;
  RAISE NOTICE 'PASS day_shift [Ende + Tag nach hinten: 6 Termine, letzte 2031-06-28]';

  -- TEST 5: dasselbe mit Tag nach vorn (25. -> 20.): Summe 600 bleibt, erster 2031-01-20, letzte Ausfuehrung 2031-06-20
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object('name','__test_dsh_e__','from_account_id',v_acct,
    'to_account_id',v_kid,'amount',100,'schedule_unit','month','schedule_day_of_month',25,
    'first_payment_date','2031-01-25','valid_to','2031-06-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT COALESCE(sum(abs(r.amount)), 0) INTO v_sum0 FROM finance.fn_recurring_due_open('2031-01-01', '2031-12-31') o
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id WHERE r.name = '__test_dsh_e__';
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20));
  SELECT COALESCE(sum(abs(r.amount)), 0) INTO v_sum1 FROM finance.fn_recurring_due_open('2031-01-01', '2031-12-31') o
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id WHERE r.name = '__test_dsh_e__';
  SELECT last_execution INTO v_last FROM finance.standing_order_overview WHERE name = '__test_dsh_e__';
  v_txt := split_part(pg_temp.occ('__test_dsh_e__', '2031-01-01', '2031-12-31'), ',', 1);
  IF v_sum0 <> 600 OR v_sum1 <> v_sum0 OR v_txt IS DISTINCT FROM '2031-01-20' OR v_last IS DISTINCT FROM DATE '2031-06-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [Ende, frueher]: Summe vorher % nachher %, erstes %, letzte % (erwartet 600/600, 2031-01-20, 2031-06-20)',
      v_sum0, v_sum1, v_txt, v_last; END IF;
  RAISE NOTICE 'PASS day_shift [Ende + Tag nach vorn: Summe 600 bleibt]';

  -- TEST 6: gebuchte Vorkommen (m-4..m-1 am 25.), Tag -> 20.: die gebuchten Monate bleiben je einmal am 25., kein Monat doppelt,
  --         Anzahl gleich; der letzte Monat im Fenster laeuft am 20. (Split, previous_id)
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_f__','account_id',v_acct,
    'direction','expense','amount',30,'schedule_unit','month','schedule_day_of_month',25,
    'first_payment_date',(m0 - interval '4 months' + interval '24 days')::date)) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  FOR k IN REVERSE 4..1 LOOP
    d := (m0 - make_interval(months => k) + interval '24 days')::date;
    SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',d)) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL day_shift [Setup Buchung %]: %', d, v_res; END IF;
  END LOOP;
  c0 := pg_temp.cnt('__test_dsh_f__', (m0 - interval '4 months')::date, (m0 + interval '8 months' - interval '1 day')::date);
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true
     OR (v_res->>'previous_id')::int IS DISTINCT FROM v_rp OR extract(day FROM (v_res->>'first_due')::date) <> 20 THEN
    RAISE EXCEPTION 'FAIL day_shift [gebucht, Rueckgabe]: % (erwartet split, previous_id %, first_due am 20.)', v_res, v_rp; END IF;
  c1 := pg_temp.cnt('__test_dsh_f__', (m0 - interval '4 months')::date, (m0 + interval '8 months' - interval '1 day')::date);
  v_txt := pg_temp.occ('__test_dsh_f__', (m0 - interval '4 months')::date, (m0 - interval '1 day')::date);
  IF c0 <> 12 OR c1 <> c0 OR pg_temp.dup_months('__test_dsh_f__', (m0 - interval '4 months')::date, (m0 + interval '8 months')::date) <> 0
     OR v_txt IS DISTINCT FROM (SELECT string_agg((m0 - make_interval(months => g.i) + interval '24 days')::date::text, ',' ORDER BY g.i DESC)
                                FROM generate_series(1, 4) g(i))
     OR extract(day FROM (SELECT max(x) FROM pg_temp.occ_set('__test_dsh_f__', m0, (m0 + interval '8 months' - interval '1 day')::date) x)) <> 20 THEN
    RAISE EXCEPTION 'FAIL day_shift [gebucht, frueher]: vorher % nachher %, gebuchte Monate %', c0, c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [gebuchte Vorkommen + Tag nach vorn: keine Doppel-Termine]';

  -- TEST 7: m-4..m-2 gebucht am 20., m-1 uebersprungen; Tag -> 25.: kein erledigter Monat kommt am 25. wieder
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_g__','account_id',v_acct,
    'direction','expense','amount',30,'schedule_unit','month','schedule_day_of_month',20,
    'first_payment_date',(m0 - interval '4 months' + interval '19 days')::date)) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  FOR k IN REVERSE 4..2 LOOP
    PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,
      'due_date',(m0 - make_interval(months => k) + interval '19 days')::date));
  END LOOP;
  PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,
    'due_date',(m0 - interval '1 month' + interval '19 days')::date));
  c0 := pg_temp.cnt('__test_dsh_g__', (m0 - interval '4 months')::date, (m0 + interval '8 months' - interval '1 day')::date);
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',25)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL day_shift [gebucht spaeter, ok]: %', v_res; END IF;
  c1 := pg_temp.cnt('__test_dsh_g__', (m0 - interval '4 months')::date, (m0 + interval '8 months' - interval '1 day')::date);
  IF c0 <> 12 OR c1 <> c0 OR pg_temp.dup_months('__test_dsh_g__', (m0 - interval '4 months')::date, (m0 + interval '8 months')::date) <> 0 THEN
    RAISE EXCEPTION 'FAIL day_shift [gebucht + Skip, spaeter]: vorher % nachher %, Reihe %', c0, c1,
      pg_temp.occ('__test_dsh_g__', (m0 - interval '4 months')::date, (m0 + interval '8 months')::date); END IF;
  RAISE NOTICE 'PASS day_shift [gebucht + uebersprungen + Tag nach hinten: keine Doppel-Termine]';

  -- TEST 8: ueberfaellige offene Termine (m-3..m-1 am 25., nichts gebucht), Tag -> 20.: sie bleiben am 25. offen (bei der Bank
  --         schon gelaufen), erst ab heute gilt der 20.; Anzahl gleich, kein Monat doppelt
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_o__','account_id',v_acct,
    'direction','expense','amount',30,'schedule_unit','month','schedule_day_of_month',25,
    'first_payment_date',(m0 - interval '3 months' + interval '24 days')::date)) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  c0 := pg_temp.cnt('__test_dsh_o__', (m0 - interval '3 months')::date, (m0 + interval '9 months' - interval '1 day')::date);
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20)) INTO v_res;
  c1 := pg_temp.cnt('__test_dsh_o__', (m0 - interval '3 months')::date, (m0 + interval '9 months' - interval '1 day')::date);
  v_txt := pg_temp.occ('__test_dsh_o__', (m0 - interval '3 months')::date, (m0 - interval '1 day')::date);
  IF (v_res->>'split')::boolean IS DISTINCT FROM true OR c0 <> 12 OR c1 <> c0
     OR pg_temp.dup_months('__test_dsh_o__', (m0 - interval '3 months')::date, (m0 + interval '9 months')::date) <> 0
     OR v_txt IS DISTINCT FROM (SELECT string_agg((m0 - make_interval(months => g.i) + interval '24 days')::date::text, ',' ORDER BY g.i DESC)
                                FROM generate_series(1, 3) g(i)) THEN
    RAISE EXCEPTION 'FAIL day_shift [ueberfaellig]: % vorher % nachher %, Vormonate %', v_res, c0, c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [ueberfaellige Termine bleiben am alten Tag]';

  -- TEST 9: Betrag + Tag zusammen (Split) zum Stichtag des Maerz-Termins: Maerz gilt schon am neuen Tag, kein Monat faellt aus
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_h__','account_id',v_acct,
    'direction','expense','amount',40,'schedule_unit','month','schedule_day_of_month',25,'first_payment_date','2031-01-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',45,
    'valid_from','2031-03-25','schedule_day_of_month',20)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'first_due' IS DISTINCT FROM '2031-03-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [Split, ok/first_due]: % (erwartet first_due 2031-03-20)', v_res; END IF;
  c1 := pg_temp.cnt('__test_dsh_h__', '2031-01-01', '2031-12-31');
  v_txt := pg_temp.occ('__test_dsh_h__', '2031-01-01', '2031-04-30');
  IF c1 <> 12 OR v_txt IS DISTINCT FROM '2031-01-25,2031-02-25,2031-03-20,2031-04-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [Betrag+Tag]: % Termine, Reihe % (erwartet 12, Jan/Feb am 25., ab Maerz am 20.)', c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [Betrag + Tag: kein Monat faellt aus]';

  -- TEST 10: Betrag + Tag nach hinten zum Stichtag nach dem Maerz-Termin: Maerz bleibt einmal (am 25.), April am 28.
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_i__','account_id',v_acct,
    'direction','expense','amount',40,'schedule_unit','month','schedule_day_of_month',25,'first_payment_date','2031-01-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',45,
    'valid_from','2031-03-26','schedule_day_of_month',28));
  c1 := pg_temp.cnt('__test_dsh_i__', '2031-01-01', '2031-12-31');
  v_txt := pg_temp.occ('__test_dsh_i__', '2031-01-01', '2031-04-30');
  IF c1 <> 12 OR v_txt IS DISTINCT FROM '2031-01-25,2031-02-25,2031-03-25,2031-04-28' THEN
    RAISE EXCEPTION 'FAIL day_shift [Betrag+Tag spaeter]: % Termine, Reihe % (erwartet 12, Maerz am 25., April am 28.)', c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [Betrag + Tag nach hinten: kein Monat doppelt]';

  -- TEST 11: Split mit valid_from vor dem ersten Termin (2031-12-01, Anker 2032-01-25): Betrag + Tag 20 ab 2031-12-10 ->
  --          die neue Zeile ankert am 20. (sonst fiele der Januar weg)
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_n__','account_id',v_acct,
    'direction','expense','amount',40,'schedule_unit','month','schedule_day_of_month',25,
    'first_payment_date','2032-01-25','valid_from','2031-12-01')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',45,
    'valid_from','2031-12-10','schedule_day_of_month',20)) INTO v_res;
  c1 := pg_temp.cnt('__test_dsh_n__', '2032-01-01', '2032-12-31');
  v_txt := split_part(pg_temp.occ('__test_dsh_n__', '2031-12-01', '2032-12-31'), ',', 1);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR c1 <> 12 OR v_txt IS DISTINCT FROM '2032-01-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [Split-Anker]: % -> % Termine 2032, erster % (erwartet 12, 2032-01-20)', v_res, c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [Split ankert am neuen Tag]';

  -- TEST 12: neuer Tag laege vor dem Beginn der Zeile (valid_from 2031-01-22, Anker 01-25; Betrag + Tag 20 ab 01-23) ->
  --          {ok:false, code day_before_start}, nichts geschrieben
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_p__','account_id',v_acct,
    'direction','expense','amount',40,'schedule_unit','month','schedule_day_of_month',25,
    'first_payment_date','2031-01-25','valid_from','2031-01-22')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',45,
    'valid_from','2031-01-23','schedule_day_of_month',20)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'day_before_start' OR (v_res->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT count(*) FROM finance.recurring_payments WHERE name = '__test_dsh_p__') <> 1 THEN
    RAISE EXCEPTION 'FAIL day_shift [day_before_start]: %', v_res; END IF;
  RAISE NOTICE 'PASS day_shift [neuer Tag vor dem Beginn -> ok:false day_before_start]';

  -- TEST 13: gespeicherter Tag NULL (= Tag des Ankers 25) + Eingabe Tag 25 mit Betrag ab 2031-03-01: keine Verschiebung,
  --          Stichtag bleibt 2031-03-01
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_q__','account_id',v_acct,
    'direction','expense','amount',40,'schedule_unit','month','first_payment_date','2031-01-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',45,
    'valid_from','2031-03-01','schedule_day_of_month',25)) INTO v_res;
  SELECT valid_from INTO d FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF d IS DISTINCT FROM DATE '2031-03-01' THEN
    RAISE EXCEPTION 'FAIL day_shift [NULL-Tag gleich]: neuer Start % (erwartet 2031-03-01)', d; END IF;
  RAISE NOTICE 'PASS day_shift [gespeicherter Tag NULL = Ankertag: keine Verschiebung]';

  -- TEST 14: Quartal (Anker 2031-02-25), Tag -> 10.: Phase Feb/Mai/Aug/Nov bleibt, 4 Termine
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_r__','account_id',v_acct,
    'direction','expense','amount',90,'schedule_unit','month','schedule_interval',3,'schedule_day_of_month',25,
    'first_payment_date','2031-02-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',10));
  v_txt := pg_temp.occ('__test_dsh_r__', '2031-01-01', '2031-12-31');
  IF v_txt IS DISTINCT FROM '2031-02-10,2031-05-10,2031-08-10,2031-11-10' THEN
    RAISE EXCEPTION 'FAIL day_shift [Quartal]: Reihe % (erwartet Feb/Mai/Aug/Nov am 10.)', v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [Quartal: Phase bleibt]';

  -- TEST 15: vorletzter Tag (-2) -> 5.: Februar 2031 bleibt (2031-02-05), 12 Termine
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_s__','account_id',v_acct,
    'direction','expense','amount',20,'schedule_unit','month','schedule_day_of_month',-2,'first_payment_date','2031-02-27')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',5));
  c1 := pg_temp.cnt('__test_dsh_s__', '2031-02-01', '2032-01-31');
  v_txt := split_part(pg_temp.occ('__test_dsh_s__', '2031-01-01', '2032-01-31'), ',', 1);
  IF c1 <> 12 OR v_txt IS DISTINCT FROM '2031-02-05' THEN
    RAISE EXCEPTION 'FAIL day_shift [-2 -> 5]: % Termine, erster % (erwartet 12, 2031-02-05)', c1, v_txt; END IF;
  RAISE NOTICE 'PASS day_shift [vorletzter Tag -> 5.: Februar bleibt]';

  -- TEST 16: Eroeffnungssaldo-Stichtag 2031-01-22 bleibt Untergrenze: der Termin am 20.01. steckt schon im Saldo
  SELECT finance.fn_create_account('{"name":"__test_dsh_open__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  -- hand-injected: Stichtag in der Zukunft, den fn_create_account (nur Vergangenheit/heute) nicht annimmt; prueft die Schranke
  UPDATE finance.accounts SET opening_balance_date = '2031-01-22' WHERE id = (v_res->>'account_id')::int;
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_l__','account_id',(v_res->>'account_id')::int,
    'direction','expense','amount',50,'schedule_unit','month','schedule_day_of_month',25,'first_payment_date','2031-01-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20)) INTO v_res;
  SELECT valid_from INTO d FROM finance.recurring_payments WHERE id = v_rp;
  IF d IS DISTINCT FROM DATE '2031-01-22' OR v_res->>'first_due' IS DISTINCT FROM '2031-02-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [Eroeffnungssaldo]: valid_from % first_due % (erwartet 2031-01-22 / 2031-02-20)', d, v_res->>'first_due'; END IF;
  RAISE NOTICE 'PASS day_shift [Eroeffnungssaldo bleibt Untergrenze]';

  -- TEST 17: Kette (Betrag ab Maerz-Termin, gleicher Tag), danach Tag des Kopfs -> 20.: Maerz wandert, Vorgaenger-Ende folgt;
  --          der Tag am Vorgaenger (Glied mit Nachfolger) -> {ok:false, code has_successor}
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_m__','account_id',v_acct,
    'direction','expense','amount',40,'schedule_unit','month','schedule_day_of_month',25,'first_payment_date','2031-01-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',45,'valid_from','2031-03-25')) INTO v_res;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',15)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'has_successor' THEN
    RAISE EXCEPTION 'FAIL day_shift [Glied mit Nachfolger]: % (erwartet code has_successor)', v_res; END IF;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',
    (SELECT id FROM finance.recurring_payments WHERE predecessor_id = v_rp), 'schedule_day_of_month',20)) INTO v_res;
  c1 := pg_temp.cnt('__test_dsh_m__', '2031-01-01', '2031-12-31');
  v_txt := pg_temp.occ('__test_dsh_m__', '2031-01-01', '2031-04-30');
  SELECT valid_to INTO d FROM finance.recurring_payments WHERE id = v_rp;
  IF c1 <> 12 OR v_txt IS DISTINCT FROM '2031-01-25,2031-02-25,2031-03-20,2031-04-20' OR d IS DISTINCT FROM DATE '2031-03-20' THEN
    RAISE EXCEPTION 'FAIL day_shift [Kette]: % Termine, Reihe %, Vorgaenger-Ende % (erwartet 12, Maerz am 20., 2031-03-20)', c1, v_txt, d; END IF;
  RAISE NOTICE 'PASS day_shift [Kette: Kopf verschoben, Vorgaenger-Ende folgt; Glied mit Nachfolger abgelehnt]';

  -- TEST 18: pausierte Zahlung: first_due NULL (nichts faellig); nach dem Fortsetzen 12 Termine ab 2031-01-20
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_t__','account_id',v_acct,
    'direction','expense','amount',50,'schedule_unit','month','schedule_day_of_month',25,'first_payment_date','2031-01-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'status','paused'));
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20)) INTO v_res;
  IF NOT (v_res ? 'first_due') OR v_res->'first_due' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL day_shift [pausiert first_due]: % (erwartet first_due null)', v_res; END IF;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'status','active'));
  c1 := pg_temp.cnt('__test_dsh_t__', '2031-01-01', '2031-12-31');
  IF c1 <> 12 THEN RAISE EXCEPTION 'FAIL day_shift [pausiert, fortgesetzt]: % Termine (erwartet 12)', c1; END IF;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'notes','x')) INTO v_res;
  IF v_res ? 'first_due' THEN RAISE EXCEPTION 'FAIL day_shift [first_due nur bei Betrag/Tag]: %', v_res; END IF;
  RAISE NOTICE 'PASS day_shift [pausiert: first_due null, fortgesetzt 12 Termine; Notiz ohne first_due]';

  -- TEST 19: explizites Ende zusammen mit dem Tag gilt woertlich (letzter gueltiger Tag 2031-06-26 -> valid_to 2031-06-27)
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_u__','account_id',v_acct,
    'direction','expense','amount',50,'schedule_unit','month','schedule_day_of_month',25,
    'first_payment_date','2031-01-25','valid_to','2031-12-25')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',28,
    'valid_to','2031-06-26'));
  SELECT valid_to INTO d FROM finance.recurring_payments WHERE id = v_rp;
  IF d IS DISTINCT FROM DATE '2031-06-27' THEN
    RAISE EXCEPTION 'FAIL day_shift [explizites Ende]: valid_to % (erwartet 2031-06-27)', d; END IF;
  RAISE NOTICE 'PASS day_shift [explizites Ende gilt woertlich]';

  -- TEST 20: derselbe Tag noch einmal genannt (keine Verschiebung) -> kein first_due (sonst zeigte die Karte den aeltesten offenen
  --          Termin als "Gilt ab"); Betrag + Tag an einem Glied mit Nachfolger -> has_successor, kein gegabelter Split
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_dsh_v__','account_id',v_acct,
    'direction','expense','amount',50,'schedule_unit','month','schedule_day_of_month',20,'first_payment_date','2031-01-20')) INTO v_res;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',20)) INTO v_res;
  IF v_res ? 'first_due' THEN RAISE EXCEPTION 'FAIL day_shift [gleicher Tag ohne first_due]: %', v_res; END IF;
  PERFORM finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',55,'valid_from','2031-04-20'));
  SELECT finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',52,
    'valid_from','2031-02-21','schedule_day_of_month',10)) INTO v_res;
  IF v_res->>'code' IS DISTINCT FROM 'has_successor'
     OR (SELECT count(*) FROM finance.recurring_payments WHERE predecessor_id = v_rp) <> 1 THEN
    RAISE EXCEPTION 'FAIL day_shift [Betrag+Tag am Glied mit Nachfolger]: %', v_res; END IF;
  RAISE NOTICE 'PASS day_shift [gleicher Tag: kein first_due; Betrag+Tag am Glied mit Nachfolger abgelehnt]';
END $$;

ROLLBACK;
