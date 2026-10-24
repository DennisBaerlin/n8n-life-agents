-- tests/db/finance/test_fn_recurring_due_open.sql
-- Testet die Faelligkeits-/Offen-Logik: alle schedule_units, interval, dom=-1/NULL,
-- valid-Grenzen, sowie gebucht/uebersprungen -> nicht mehr offen.
-- Referenzdatum p_until = 2026-06-15; Rueck-Fenster = 90 Tage (ab 2026-03-17).
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_acct   INT;
  v_until  DATE := '2026-06-15';
  r1 INT; r2 INT; r3 INT; r4 INT; r5 INT; r6 INT; r7 INT; r8 INT; r9 INT; r10 INT; r11 INT;
  c INT;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_due_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct := (v_result->>'account_id')::int;

  -- Payments via internem Helper (volle Kontrolle ueber valid_from/valid_to/schedule).
  r1  := finance.fn_add_recurring_payment(v_acct, -100, 'M dom1',   1::smallint,'month'::finance.schedule_unit, 1::smallint,    '2026-04-01','2026-04-01', NULL, NULL, NULL);
  r2  := finance.fn_add_recurring_payment(v_acct, -100, 'M last',   1::smallint,'month'::finance.schedule_unit, -1::smallint,   '2026-04-30','2026-04-30', NULL, NULL, NULL);
  r3  := finance.fn_add_recurring_payment(v_acct, -100, 'M relDay', 1::smallint,'month'::finance.schedule_unit, NULL,           '2026-04-15','2026-04-15', NULL, NULL, NULL);
  r4  := finance.fn_add_recurring_payment(v_acct, -100, 'Quarterly',3::smallint,'month'::finance.schedule_unit, 1::smallint,    '2026-01-01','2026-01-01', NULL, NULL, NULL);
  r5  := finance.fn_add_recurring_payment(v_acct, -100, 'Weekly',   1::smallint,'week'::finance.schedule_unit,  NULL,           '2026-06-01','2026-06-01', NULL, NULL, NULL);
  r6  := finance.fn_add_recurring_payment(v_acct,  500, 'Yearly',   1::smallint,'year'::finance.schedule_unit,  NULL,           '2025-06-10','2025-06-10', NULL, NULL, NULL);
  r7  := finance.fn_add_recurring_payment(v_acct,  -10, 'Daily',    1::smallint,'day'::finance.schedule_unit,   NULL,           '2026-06-13','2026-06-13', NULL, NULL, NULL);
  r8  := finance.fn_add_recurring_payment(v_acct, -100, 'Future',   1::smallint,'month'::finance.schedule_unit, 1::smallint,    '2026-08-01','2026-08-01', NULL, NULL, NULL);
  r9  := finance.fn_add_recurring_payment(v_acct, -100, 'ValidTo',  1::smallint,'month'::finance.schedule_unit, 1::smallint,    '2026-04-01','2026-04-01','2026-04-15', NULL, NULL);
  r10 := finance.fn_add_recurring_payment(v_acct, -100, 'Booked',   1::smallint,'month'::finance.schedule_unit, 1::smallint,    '2026-04-01','2026-04-01', NULL, NULL, NULL);
  r11 := finance.fn_add_recurring_payment(v_acct, -100, 'Skipped',  1::smallint,'month'::finance.schedule_unit, 1::smallint,    '2026-04-01','2026-04-01', NULL, NULL, NULL);

  -- Helper-Makro per SELECT count(*) WHERE recurring_payment_id = X
  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r1;
  IF c <> 3 THEN RAISE EXCEPTION 'FAIL [M dom1]: erwartet 3, got %', c; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id=r1 AND due_date='2026-06-01') THEN
    RAISE EXCEPTION 'FAIL [M dom1]: 2026-06-01 fehlt'; END IF;
  RAISE NOTICE 'PASS [M dom1] = 3';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r2;
  IF c <> 2 THEN RAISE EXCEPTION 'FAIL [M last]: erwartet 2 (04-30,05-31), got %', c; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id=r2 AND due_date='2026-05-31') THEN
    RAISE EXCEPTION 'FAIL [M last]: 2026-05-31 fehlt'; END IF;
  RAISE NOTICE 'PASS [M last] = 2';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r3;
  IF c <> 3 THEN RAISE EXCEPTION 'FAIL [M relDay]: erwartet 3 (04-15,05-15,06-15), got %', c; END IF;
  RAISE NOTICE 'PASS [M relDay] = 3';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r4;
  IF c <> 1 THEN RAISE EXCEPTION 'FAIL [Quarterly]: erwartet 1 (04-01), got %', c; END IF;
  RAISE NOTICE 'PASS [Quarterly] = 1';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r5;
  IF c <> 3 THEN RAISE EXCEPTION 'FAIL [Weekly]: erwartet 3 (06-01,06-08,06-15), got %', c; END IF;
  RAISE NOTICE 'PASS [Weekly] = 3';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r6;
  IF c <> 1 THEN RAISE EXCEPTION 'FAIL [Yearly]: erwartet 1 (2026-06-10), got %', c; END IF;
  RAISE NOTICE 'PASS [Yearly] = 1';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r7;
  IF c <> 3 THEN RAISE EXCEPTION 'FAIL [Daily]: erwartet 3 (06-13..06-15), got %', c; END IF;
  RAISE NOTICE 'PASS [Daily] = 3';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r8;
  IF c <> 0 THEN RAISE EXCEPTION 'FAIL [Future]: erwartet 0, got %', c; END IF;
  RAISE NOTICE 'PASS [Future] = 0';

  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r9;
  IF c <> 1 THEN RAISE EXCEPTION 'FAIL [ValidTo]: erwartet 1 (nur 04-01), got %', c; END IF;
  RAISE NOTICE 'PASS [ValidTo] = 1';

  -- Gebucht -> nicht mehr offen: r10 hat 3 (04-01,05-01,06-01); 05-01 buchen -> 2.
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r10, 'due_date', '2026-05-01')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [book]: %', v_result; END IF;
  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r10;
  IF c <> 2 THEN RAISE EXCEPTION 'FAIL [Booked]: erwartet 2 nach Buchung 05-01, got %', c; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id=r10 AND due_date='2026-05-01') THEN
    RAISE EXCEPTION 'FAIL [Booked]: 05-01 noch offen trotz Buchung'; END IF;
  RAISE NOTICE 'PASS [Booked] = 2 (05-01 raus)';

  -- Doppelt buchen -> {ok:false}
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r10, 'due_date', '2026-05-01')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [double book]: erwartet ok=false, got %', v_result; END IF;
  RAISE NOTICE 'PASS [double book -> ok:false]';

  -- Uebersprungen -> nicht mehr offen: r11 hat 3; 06-01 skippen -> 2.
  SELECT finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', r11, 'due_date', '2026-06-01')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [skip]: %', v_result; END IF;
  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r11;
  IF c <> 2 THEN RAISE EXCEPTION 'FAIL [Skipped]: erwartet 2 nach Skip 06-01, got %', c; END IF;
  RAISE NOTICE 'PASS [Skipped] = 2 (06-01 raus)';

  -- Audit F2a: valid_to ist EXKLUSIV ([valid_from, valid_to) wie Views/close_*/Split) -> ein Vorkommen genau
  -- AM valid_to ist nicht mehr faellig (vorher inklusiv -> Doppel-Faelligkeit am Split-Stichtag).
  DECLARE r12 INT; r13 INT;
  BEGIN
    r12 := finance.fn_add_recurring_payment(v_acct, -100, 'ValidToExcl', 1::smallint,'month'::finance.schedule_unit, 1::smallint, '2026-04-01','2026-04-01','2026-06-01', NULL, NULL);
    SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r12;
    IF c <> 2 THEN RAISE EXCEPTION 'FAIL [ValidTo exklusiv]: erwartet 2 (04-01,05-01; 06-01 = valid_to raus), got %', c; END IF;
    RAISE NOTICE 'PASS [ValidTo exklusiv] = 2';

    -- Audit F2a: Vorkommen VOR valid_from sind nicht faellig (Anker first_payment_date bleibt der Rhythmus-Takt).
    r13 := finance.fn_add_recurring_payment(v_acct, -100, 'ValidFromLate', 1::smallint,'month'::finance.schedule_unit, 1::smallint, '2026-04-01','2026-05-15', NULL, NULL, NULL);
    SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id = r13;
    IF c <> 1 OR NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_until) WHERE recurring_payment_id=r13 AND due_date='2026-06-01') THEN
      RAISE EXCEPTION 'FAIL [ValidFrom]: erwartet nur 06-01, got count %', c; END IF;
    RAISE NOTICE 'PASS [ValidFrom: Vorkommen vor valid_from nicht faellig] = 1';
  END;

  -- Feste Monatstage (schedule_days_of_month, Broker-Kalender): je Monat GENAU die Tage der Liste, kein
  -- zusaetzlicher Anker-Tag aus dem Monats-Zweig (Zaehlung, nicht nur Existenz).
  DECLARE r14 INT; r15 INT; r16 INT;
  BEGIN
    r14 := finance.fn_add_recurring_payment(v_acct, -100, 'Days4', 1::smallint,'month'::finance.schedule_unit, NULL, '2026-04-02','2026-04-02', NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET schedule_days_of_month = '{2,9,16,23}' WHERE id = r14;
    -- 04: 2,9,16,23 | 05: 2,9,16,23 | 06: 2,9 (<= 06-15) -> 10
    SELECT count(*) INTO c FROM finance.fn_recurring_due_open(DATE '2026-04-01', v_until) WHERE recurring_payment_id = r14;
    IF c <> 10 THEN RAISE EXCEPTION 'FAIL [Days4]: erwartet 10 (4+4+2), got %', c; END IF;
    SELECT count(*) INTO c FROM finance.fn_recurring_due_open(DATE '2026-05-01', DATE '2026-05-31') WHERE recurring_payment_id = r14;
    IF c <> 4 THEN RAISE EXCEPTION 'FAIL [Days4 Mai]: erwartet genau 4, got %', c; END IF;
    IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(DATE '2026-04-01', v_until) o
               WHERE o.recurring_payment_id = r14 AND EXTRACT(DAY FROM o.due_date) NOT IN (2,9,16,23)) THEN
      RAISE EXCEPTION 'FAIL [Days4]: Termin ausserhalb der Liste'; END IF;
    RAISE NOTICE 'PASS [Days4: 4 Termine je Monat, nur 2/9/16/23]';

    -- Start mitten im Monat: erster Monat erst ab first_payment_date (04-16 -> 16,23), dann voll
    r15 := finance.fn_add_recurring_payment(v_acct, -100, 'Days4Mid', 1::smallint,'month'::finance.schedule_unit, NULL, '2026-04-16','2026-04-16', NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET schedule_days_of_month = '{2,9,16,23}' WHERE id = r15;
    SELECT count(*) INTO c FROM finance.fn_recurring_due_open(DATE '2026-04-01', DATE '2026-04-30') WHERE recurring_payment_id = r15;
    IF c <> 2 THEN RAISE EXCEPTION 'FAIL [Days4Mid April]: erwartet 2 (16,23), got %', c; END IF;
    RAISE NOTICE 'PASS [Days4Mid: erster Monat ab Start]';

    -- interval 2: jeden zweiten Monat zwei Tage (04: 2,16 | 05: - | 06: 2 (<= 06-15))
    r16 := finance.fn_add_recurring_payment(v_acct, -100, 'Days2Bi', 2::smallint,'month'::finance.schedule_unit, NULL, '2026-04-02','2026-04-02', NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET schedule_days_of_month = '{2,16}' WHERE id = r16;
    SELECT count(*) INTO c FROM finance.fn_recurring_due_open(DATE '2026-04-01', v_until) WHERE recurring_payment_id = r16;
    IF c <> 3 THEN RAISE EXCEPTION 'FAIL [Days2Bi]: erwartet 3 (04-02,04-16,06-02), got %', c; END IF;
    IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(DATE '2026-04-01', v_until) WHERE recurring_payment_id = r16
               AND due_date BETWEEN '2026-05-01' AND '2026-05-31') THEN
      RAISE EXCEPTION 'FAIL [Days2Bi]: Mai darf keinen Termin haben'; END IF;
    RAISE NOTICE 'PASS [Days2Bi: alle 2 Monate je 2 Tage]';
  END;

END $$;

ROLLBACK;
