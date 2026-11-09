-- tests/db/finance/test_fn_handle_bank_todo_cb.sql
-- Knopf "bei dieser Bank erledigt": Rechte, Doppeltipp, bis max-id, erster Punkt geloescht.
BEGIN;
CREATE FUNCTION pg_temp.mk(p_name text, p_acct int, p_tgt int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v int; BEGIN
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES (p_name, p_acct, p_tgt, -100, 'month', 5, core.fn_today() + 10, core.fn_today() + 10) RETURNING id INTO v;
  PERFORM finance.fn_bank_note_recorded(v, 'bank_setup');
  RETURN (SELECT id FROM finance.bank_todos WHERE head_id = v AND status = 'open');
END $$;
CREATE FUNCTION pg_temp.cb(a int, b int, chat text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT finance.fn_handle_bank_todo_cb(jsonb_build_object('data', 'btodo:' || a || ':' || b, 'chat_id', chat, 'chat_type', 'private'));
$$;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'bt', NULL, 'lazy', 'x', jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','__cb_o__','first_name','Olli','last_name','Muster','role','owner','birth_date','1980-01-01','telegram_user_id',7601,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__cb_p__','first_name','Petra','last_name','Muster','role','partner','birth_date','1982-01-01','telegram_user_id',7602,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__cb_k__','first_name','Kim','last_name','Muster','role','child','birth_date','2012-01-01','telegram_user_id',7603,'as_of','2026-10-23')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

DO $$
DECLARE v_o int; v_p int; v_o2 int; v_t int; a int; b int; c int; d int; e int; r jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_o__','cash','EUR','active','Musterbank','__cb_o__') RETURNING id INTO v_o;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_p__','cash','EUR','active','Musterbank','__cb_p__') RETURNING id INTO v_p;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_o2__','cash','EUR','active','Andere','__cb_o__') RETURNING id INTO v_o2;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cb_t__','cash','EUR','active') RETURNING id INTO v_t;
  a := pg_temp.mk('a', v_o, v_t); b := pg_temp.mk('b', v_o, v_t); c := pg_temp.mk('c', v_o, v_t);
  d := pg_temp.mk('d', v_o2, v_t); e := pg_temp.mk('e', v_p, v_t);

  r := pg_temp.cb(a, a, '7603');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'not_allowed' THEN RAISE EXCEPTION 'FAIL [Kind]: %', r; END IF;
  r := pg_temp.cb(a, b, '7602');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'not_allowed' THEN RAISE EXCEPTION 'FAIL [Partner fremd]: %', r; END IF;
  r := pg_temp.cb(e, e, '7602');
  IF NOT (r->>'ok')::boolean OR (r->>'closed')::int <> 1 THEN RAISE EXCEPTION 'FAIL [Partner eigen]: %', r; END IF;

  -- bis max-id, nur gleiche Bank und Inhaber
  r := pg_temp.cb(a, b, '7601');
  IF NOT (r->>'ok')::boolean OR (r->>'closed')::int <> 2 THEN RAISE EXCEPTION 'FAIL [bis max-id]: %', r; END IF;
  IF (SELECT status FROM finance.bank_todos WHERE id = c) <> 'open' OR (SELECT status FROM finance.bank_todos WHERE id = d) <> 'open' THEN RAISE EXCEPTION 'FAIL [c und d bleiben offen]'; END IF;

  -- Doppeltipp
  r := pg_temp.cb(a, b, '7601');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'nothing_open' THEN RAISE EXCEPTION 'FAIL [Doppeltipp]: %', r; END IF;

  -- erster Punkt geloescht
  DELETE FROM finance.bank_todos WHERE id = c;
  r := pg_temp.cb(c, c, '7601');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'nothing_open' THEN RAISE EXCEPTION 'FAIL [geloescht]: %', r; END IF;

  -- kaputte Daten
  r := finance.fn_handle_bank_todo_cb('{"data":"btodo:x","chat_id":"7601"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [kaputt]: %', r; END IF;
  RAISE NOTICE 'PASS Bank-Knopf';
END $$;
ROLLBACK;
