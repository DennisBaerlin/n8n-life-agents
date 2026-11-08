-- tests/db/finance/test_fn_recurring_next_due.sql
-- finance.fn_recurring_next_due(rp, on): naechster Termin ab einem Tag, nie ein schon gebuchter; das Suchfenster reicht
-- fuer jeden Rhythmus (woechentlich bis jaehrlich). Erfundene Werte, self-contained.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_acc INT; v_m INT; v_w INT; v_y INT; v_res JSONB;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__t_nd_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

  -- (1) monatlich ab t + 5, das Vorkommen t + 5 schon frueh gebucht -> naechster Termin ist der im Folgemonat
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_nd_monat__', v_acc, -30, 'month', t + 5, t) RETURNING id INTO v_m;
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_m, 'due_date', (t + 5)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP Buchung: %', v_res; END IF;
  IF finance.fn_recurring_next_due(v_m, t) IS DISTINCT FROM (t + 5 + interval '1 month')::date THEN
    RAISE EXCEPTION 'FAIL [1] frueh gebuchtes Vorkommen ist nicht der naechste Termin, got %', finance.fn_recurring_next_due(v_m, t); END IF;

  -- (2) woechentlich und (3) jaehrlich in 300 Tagen: das Fenster findet beide
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_nd_woche__', v_acc, -5, 'week', t + 3, t) RETURNING id INTO v_w;
  IF finance.fn_recurring_next_due(v_w, t) IS DISTINCT FROM t + 3 THEN
    RAISE EXCEPTION 'FAIL [2] woechentlich, got %', finance.fn_recurring_next_due(v_w, t); END IF;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_nd_jahr__', v_acc, -90, 'year', t + 300, t) RETURNING id INTO v_y;
  IF finance.fn_recurring_next_due(v_y, t) IS DISTINCT FROM t + 300 THEN
    RAISE EXCEPTION 'FAIL [3] jaehrlich in 300 Tagen, got %', finance.fn_recurring_next_due(v_y, t); END IF;
  -- (4) valid_to ist exklusiv: ein Termin genau am Endtag faellt weg
  UPDATE finance.recurring_payments SET valid_to = t + 3 WHERE id = v_w;
  IF finance.fn_recurring_next_due(v_w, t) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [4] Termin am exklusiven Endtag, got %', finance.fn_recurring_next_due(v_w, t); END IF;
  RAISE NOTICE 'PASS fn_recurring_next_due [frueh gebucht, woechentlich, jaehrlich, Endtag exklusiv]';
END $$;
ROLLBACK;
