-- tests/db/finance/test_fn_handle_bank_todo_cb.sql
-- Knopf "bei dieser Bank erledigt": Rechte, Doppeltipp, bis max-id, erster Punkt geloescht; Ausgangs-Zeile (edit).
BEGIN;
-- Katalog-Fixture: Text = Sprach-Marker + Key (+ {bank}), damit die Ausgangs-Zeile pruefbar ist.
INSERT INTO core.ui_texts (key, lang, text, package)
SELECT k, l, upper(l) || ':' || k || CASE WHEN k LIKE '%_generic' THEN '' ELSE ':{bank}' END, 'finance'
  FROM unnest(ARRAY['finance.bank_todo.done_line', 'finance.bank_todo.done_line_generic']) k
 CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;
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
DECLARE v_o int; v_p int; v_o2 int; v_t int; v_nb int; a int; b int; c int; d int; e int; n int; r jsonb;
  v_ol text := upper(agent.fn_person_lang('__cb_o__')->>'lang');
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_o__','cash','EUR','active','Musterbank','__cb_o__') RETURNING id INTO v_o;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_p__','cash','EUR','active','Musterbank','__cb_p__') RETURNING id INTO v_p;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_o2__','cash','EUR','active','Andere','__cb_o__') RETURNING id INTO v_o2;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cb_t__','cash','EUR','active') RETURNING id INTO v_t;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES ('__cb_nb__','cash','EUR','active','__cb_o__') RETURNING id INTO v_nb;
  a := pg_temp.mk('a', v_o, v_t); b := pg_temp.mk('b', v_o, v_t); c := pg_temp.mk('c', v_o, v_t);
  d := pg_temp.mk('d', v_o2, v_t); e := pg_temp.mk('e', v_p, v_t);

  r := pg_temp.cb(a, a, '7603');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'not_allowed' THEN RAISE EXCEPTION 'FAIL [Kind]: %', r; END IF;
  IF r ? 'edit' THEN RAISE EXCEPTION 'FAIL [Kind: Nachricht bleibt unveraendert]: %', r; END IF;
  r := pg_temp.cb(a, b, '7602');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'not_allowed' THEN RAISE EXCEPTION 'FAIL [Partner fremd]: %', r; END IF;
  r := pg_temp.cb(e, e, '7602');
  IF NOT (r->>'ok')::boolean OR (r->>'closed')::int <> 1 THEN RAISE EXCEPTION 'FAIL [Partner eigen]: %', r; END IF;

  -- bis max-id, nur gleiche Bank und Inhaber
  r := pg_temp.cb(a, b, '7601');
  IF NOT (r->>'ok')::boolean OR (r->>'closed')::int <> 2 THEN RAISE EXCEPTION 'FAIL [bis max-id]: %', r; END IF;
  -- Ausgangs-Zeile: alter Text bleibt, darunter die Zeile mit der Bank in der Sprache des Tippenden
  IF NOT COALESCE((r->'edit'->>'keep_text')::boolean, false) OR r->'edit'->>'append' IS DISTINCT FROM v_ol || ':finance.bank_todo.done_line:Musterbank' THEN
    RAISE EXCEPTION 'FAIL [Ausgangs-Zeile]: %', r; END IF;
  IF (SELECT status FROM finance.bank_todos WHERE id = c) <> 'open' OR (SELECT status FROM finance.bank_todos WHERE id = d) <> 'open' THEN RAISE EXCEPTION 'FAIL [c und d bleiben offen]'; END IF;

  -- Doppeltipp
  r := pg_temp.cb(a, b, '7601');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'nothing_open' THEN RAISE EXCEPTION 'FAIL [Doppeltipp]: %', r; END IF;
  -- schon erledigt (Doppeltipp, alte Nachricht): Knopf weg, dieselbe Ausgangs-Zeile
  IF NOT COALESCE((r->'edit'->>'keep_text')::boolean, false) OR r->'edit'->>'append' IS DISTINCT FROM v_ol || ':finance.bank_todo.done_line:Musterbank' THEN
    RAISE EXCEPTION 'FAIL [Doppeltipp: Ausgangs-Zeile]: %', r; END IF;

  -- System hat den Punkt ersetzt (fn_bank_note_recorded: alter Punkt done, neuer offen fuer denselben Kopf):
  -- der Nutzer hat nichts erledigt -> Knopf weg, keine Erledigt-Zeile; der neue Punkt bleibt offen.
  DECLARE v_old int; v_new int; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_x__','cash','EUR','active','Drittbank','__cb_o__') RETURNING id INTO v_new;
    v_old := pg_temp.mk('x', v_new, v_t);
    UPDATE finance.bank_todos SET status = 'done', closed_at = now() WHERE id = v_old;
    INSERT INTO finance.bank_todos (head_id, event) SELECT head_id, 'stop' FROM finance.bank_todos WHERE id = v_old RETURNING id INTO v_new;
    r := pg_temp.cb(v_old, v_old, '7601');
    IF (r->>'ok')::boolean OR r->>'reason' <> 'nothing_open' THEN RAISE EXCEPTION 'FAIL [ersetzt]: %', r; END IF;
    IF NOT COALESCE((r->'edit'->>'keep_text')::boolean, false) OR r->'edit' ? 'append' THEN RAISE EXCEPTION 'FAIL [ersetzt: nur Knopf weg]: %', r; END IF;
    IF (SELECT status FROM finance.bank_todos WHERE id = v_new) <> 'open' THEN RAISE EXCEPTION 'FAIL [ersetzt: neuer Punkt bleibt offen]'; END IF;
    -- Nutzer hat erledigt, spaeter kommt fuer denselben Dauerauftrag ein neuer Punkt: alte Nachricht zeigt weiter die Zeile.
    INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__cb_y__','cash','EUR','active','Viertbank','__cb_o__') RETURNING id INTO v_new;
    v_old := pg_temp.mk('y', v_new, v_t);
    r := pg_temp.cb(v_old, v_old, '7601');
    INSERT INTO finance.bank_todos (head_id, event, created_at) SELECT head_id, 'change', now() + interval '1 day' FROM finance.bank_todos WHERE id = v_old;
    r := pg_temp.cb(v_old, v_old, '7601');
    IF r->'edit'->>'append' IS DISTINCT FROM v_ol || ':finance.bank_todo.done_line:Viertbank' THEN RAISE EXCEPTION 'FAIL [spaeterer Punkt: Zeile bleibt]: %', r; END IF;
  END;

  -- erster Punkt geloescht
  DELETE FROM finance.bank_todos WHERE id = c;
  r := pg_temp.cb(c, c, '7601');
  IF (r->>'ok')::boolean OR r->>'reason' <> 'nothing_open' THEN RAISE EXCEPTION 'FAIL [geloescht]: %', r; END IF;
  -- Punkt weg: Knopf weg (wirkt nie mehr), aber keine Erledigt-Zeile
  IF NOT COALESCE((r->'edit'->>'keep_text')::boolean, false) OR r->'edit' ? 'append' THEN RAISE EXCEPTION 'FAIL [geloescht: nur Knopf weg]: %', r; END IF;

  -- Konto ohne Bank: allgemeine Zeile
  n := pg_temp.mk('n', v_nb, v_t);
  r := pg_temp.cb(n, n, '7601');
  IF NOT (r->>'ok')::boolean OR r->'edit'->>'append' IS DISTINCT FROM v_ol || ':finance.bank_todo.done_line_generic' THEN
    RAISE EXCEPTION 'FAIL [ohne Bank]: %', r; END IF;

  -- erster Punkt schon gebucht (unsichtbar), zweiter derselben Bank wird trotzdem erledigt
  DECLARE v_f int; v_s int; BEGIN
    v_f := pg_temp.mk('f', v_o, v_t); v_s := pg_temp.mk('s', v_o, v_t);
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, recurring_due_date, group_id)
      SELECT r.account_id, -100, core.fn_today(), 'transfer', r.id, core.fn_today(), gen_random_uuid()
        FROM finance.recurring_payments r JOIN finance.bank_todos t ON t.head_id = r.id WHERE t.id = v_f;
    r := pg_temp.cb(v_f, v_s, '7601');
    IF NOT (r->>'ok')::boolean OR (r->>'closed')::int <> 1 OR (SELECT status FROM finance.bank_todos WHERE id = v_s) <> 'done' THEN
      RAISE EXCEPTION 'FAIL [erster schon gebucht]: %', r; END IF;
  END;

  -- kaputte Daten
  r := finance.fn_handle_bank_todo_cb('{"data":"btodo:x","chat_id":"7601"}'::jsonb);
  IF (r->>'ok')::boolean OR r ? 'edit' THEN RAISE EXCEPTION 'FAIL [kaputt]: %', r; END IF;
  RAISE NOTICE 'PASS Bank-Knopf';
END $$;
ROLLBACK;
