-- tests/db/finance/test_fn_bank_todos.sql
-- Bank-Zettel: Recorder, Sichtbarkeit, Claim, Nachholen, Rechte. Werte erfunden, db_test ohne seed_data -> Registry self-seeden.
BEGIN;

CREATE FUNCTION pg_temp.mk(p_name text, p_acct int, p_tgt int, p_first date DEFAULT core.fn_today() + 5) RETURNS int LANGUAGE sql AS $$
    INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES (p_name, p_acct, p_tgt, -100, 'month', 5, p_first, p_first) RETURNING id;
$$;
CREATE FUNCTION pg_temp.ev(p_head int) RETURNS text LANGUAGE sql AS $$
    SELECT event FROM finance.bank_todos WHERE head_id = p_head AND status = 'open';
$$;
CREATE FUNCTION pg_temp.tid(p_head int) RETURNS int LANGUAGE sql AS $$
    SELECT id FROM finance.bank_todos WHERE head_id = p_head AND status = 'open';
$$;
CREATE FUNCTION pg_temp.age_todo(p_head int, p_sent_days int, p_created_hours int DEFAULT 100) RETURNS void LANGUAGE sql AS $$
    UPDATE finance.bank_todos SET created_at = now() - make_interval(hours => p_created_hours),
           first_sent_at = CASE WHEN p_sent_days IS NULL THEN NULL ELSE now() - make_interval(days => p_sent_days) END
     WHERE head_id = p_head AND status = 'open';
$$;
CREATE FUNCTION pg_temp.claimed(r jsonb, p_recipient text, p_id int) RETURNS boolean LANGUAGE sql AS $$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(r) m, jsonb_array_elements(m->'groups') g, jsonb_array_elements(g->'items') i
                    WHERE m->>'recipient' = p_recipient AND (i->>'id')::int = p_id);
$$;
CREATE FUNCTION pg_temp.tx(p_rp int) RETURNS int LANGUAGE sql AS $$
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, recurring_due_date, group_id)
    SELECT account_id, -100, core.fn_today(), 'transfer', id, core.fn_today(), gen_random_uuid() FROM finance.recurring_payments WHERE id = p_rp
    RETURNING id;
$$;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'bt', NULL, 'lazy', 'x', jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','__bt_o__','first_name','Olli','last_name','Muster','role','owner','birth_date','1980-01-01','telegram_user_id',7501,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__bt_p__','first_name','Petra','last_name','Muster','role','partner','birth_date','1982-01-01','telegram_user_id',7502,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__bt_k__','first_name','Kim','last_name','Muster','role','child','birth_date','2012-01-01','telegram_user_id',7503,'as_of','2026-10-23')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES
  ('remind_bank_todo', 'finance', 'household', TRUE), ('remind_bank_todo_person', 'finance', 'person', TRUE)
ON CONFLICT (cron_key) DO UPDATE SET scope = excluded.scope, default_enabled = excluded.default_enabled;
INSERT INTO core.config (package, category, key, value) VALUES
  ('finance', 'cron_enable', 'remind_bank_todo', 'true'), ('finance', 'cron_enable', 'remind_bank_todo_person', 'true')
ON CONFLICT (category, key) DO UPDATE SET value = 'true';

-- Recorder-Tabelle
DO $$
DECLARE v_a int; v_b int; v_rp int; v_n jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__bt_a__','cash','EUR','active','Musterbank','__bt_o__') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status, account_number) VALUES ('__bt_b__','cash','EUR','active','DE00TEST') RETURNING id INTO v_b;

  v_rp := pg_temp.mk('r1', v_a, v_b);
  v_n := finance.fn_bank_note_recorded(v_rp, 'bank_setup');
  IF jsonb_array_length(v_n) <> 1 OR pg_temp.ev(v_rp) <> 'setup' THEN RAISE EXCEPTION 'FAIL [keiner+setup]: % %', v_n, pg_temp.ev(v_rp); END IF;
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_change');
  IF pg_temp.ev(v_rp) <> 'setup' THEN RAISE EXCEPTION 'FAIL [setup+change bleibt setup]'; END IF;
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_stop');
  IF pg_temp.ev(v_rp) <> 'setup' THEN RAISE EXCEPTION 'FAIL [setup+stop bleibt setup]'; END IF;
  PERFORM pg_temp.tx(v_rp);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_stop');
  IF pg_temp.ev(v_rp) <> 'stop' THEN RAISE EXCEPTION 'FAIL [setup+stop gelaufen -> stop]'; END IF;
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_change');
  IF pg_temp.ev(v_rp) <> 'change' THEN RAISE EXCEPTION 'FAIL [stop+change gelaufen -> change]'; END IF;
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_stop');
  IF pg_temp.ev(v_rp) <> 'stop' THEN RAISE EXCEPTION 'FAIL [change+stop -> stop]'; END IF;

  v_rp := pg_temp.mk('r2', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_change');
  IF pg_temp.ev(v_rp) <> 'setup' THEN RAISE EXCEPTION 'FAIL [keiner+change nie gelaufen -> setup]'; END IF;

  v_rp := pg_temp.mk('r3', v_a, v_b);
  PERFORM pg_temp.tx(v_rp);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_change');
  IF pg_temp.ev(v_rp) <> 'change' THEN RAISE EXCEPTION 'FAIL [keiner+change gelaufen]'; END IF;

  v_rp := pg_temp.mk('r4', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_stop');
  IF pg_temp.ev(v_rp) <> 'stop' THEN RAISE EXCEPTION 'FAIL [keiner+stop]'; END IF;
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_setup');
  IF pg_temp.ev(v_rp) <> 'setup' THEN RAISE EXCEPTION 'FAIL [stop+setup nie gelaufen -> setup]'; END IF;

  -- schon gesendeter Punkt, Art wechselt -> neue Zeile
  v_rp := pg_temp.mk('r5', v_a, v_b);
  PERFORM pg_temp.tx(v_rp);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_change');
  UPDATE finance.bank_todos SET first_sent_at = now() WHERE head_id = v_rp;
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_stop');
  IF (SELECT count(*) FROM finance.bank_todos WHERE head_id = v_rp) <> 2 OR pg_temp.ev(v_rp) <> 'stop'
     OR (SELECT first_sent_at FROM finance.bank_todos WHERE head_id = v_rp AND status = 'open') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [gesendet + neue Art = neue Zeile]'; END IF;

  -- leere Notiz legt nichts an; Partial-UNIQUE
  v_rp := (SELECT finance.fn_recurring_lineage_head(id) FROM finance.recurring_payments WHERE name = 'r1');
  DECLARE v_man int; BEGIN
    v_man := pg_temp.mk('r6', v_a, v_b); UPDATE finance.recurring_payments SET executed_by = 'manual' WHERE id = v_man;
    PERFORM finance.fn_bank_note_recorded(v_man, 'bank_setup');
    IF EXISTS (SELECT 1 FROM finance.bank_todos WHERE head_id = v_man) THEN RAISE EXCEPTION 'FAIL [leere Notiz]'; END IF;
  END;
  BEGIN
    INSERT INTO finance.bank_todos (head_id, event) SELECT head_id, 'setup' FROM finance.bank_todos WHERE status = 'open' LIMIT 1;
    RAISE EXCEPTION 'FAIL [Partial-UNIQUE]';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS Recorder';
END $$;

-- Aufrufer + Probelauf + Split/Reopen
DO $$
DECLARE v_a int; v_b int; v_rp int; v_r jsonb; v_new int; v_src int; v_g int; v_pot int; v_t int; v_e jsonb;
BEGIN
  SELECT id INTO v_a FROM finance.accounts WHERE name = '__bt_a__';
  SELECT id INTO v_b FROM finance.accounts WHERE name = '__bt_b__';

  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','w1','from_account_id',v_a,'to_account_id',v_b,'amount',50,'schedule_unit','month','first_payment_date',(core.fn_today() + 30)::text));
  v_rp := (v_r->>'recurring_payment_id')::int;
  IF pg_temp.ev(v_rp) <> 'setup' THEN RAISE EXCEPTION 'FAIL [create transfer -> Punkt]'; END IF;

  -- Probelauf hinterlaesst nichts
  v_t := (SELECT count(*) FROM finance.bank_todos);
  BEGIN
    PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name','w1dry','from_account_id',v_a,'to_account_id',v_b,'amount',50,'schedule_unit','month','first_payment_date',(core.fn_today() + 30)::text));
    RAISE EXCEPTION 'rollback_dry';
  EXCEPTION WHEN raise_exception THEN NULL; END;
  IF (SELECT count(*) FROM finance.bank_todos) <> v_t THEN RAISE EXCEPTION 'FAIL [Probelauf]'; END IF;

  -- Split und Reopen: ein Punkt auf dem neuen Kopf
  v_e := finance.fn_split_recurring_payment(v_rp, core.fn_today() + 60, -70, NULL, NULL, NULL, NULL, NULL, NULL);
  v_new := (v_e->>'recurring_payment_id')::int;
  IF (SELECT count(*) FROM finance.bank_todos WHERE head_id = v_new AND status = 'open') <> 1
     OR EXISTS (SELECT 1 FROM finance.bank_todos WHERE head_id = v_rp) THEN RAISE EXCEPTION 'FAIL [Split folgt]'; END IF;

  -- until_free_money anlegen + aendern, jeweils ohne Kartenzeile
  v_src := (finance.fn_create_account('{"name":"__bt_src__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_pot := (finance.fn_create_account('{"name":"__bt_pot__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_src, 20000, current_date - 5, 'other');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__bt_free__', 8000, (current_date + interval '1 year')::date, 'active') RETURNING id INTO v_g;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_src, 'amount', 8000));
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','free1','from_account_id',v_src,'to_account_id',v_pot,'amount',5000,
           'schedule_unit','month','schedule_day_of_month',25,'first_payment_date',(date_trunc('month', current_date) + interval '1 month')::date,'until_free_money',true));
  v_rp := (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS NOT TRUE OR pg_temp.ev(v_rp) <> 'setup' THEN RAISE EXCEPTION 'FAIL [free anlegen]: %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') c WHERE c->>'value' LIKE 'finance.note.bank%') THEN RAISE EXCEPTION 'FAIL [free ohne Karte]'; END IF;
  v_r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'until_free_money', true));
  IF pg_temp.ev(finance.fn_recurring_lineage_head(v_rp)) <> 'setup' THEN RAISE EXCEPTION 'FAIL [free aendern bleibt setup]'; END IF;

  RAISE NOTICE 'PASS Aufrufer';
END $$;

-- Sichtbarkeit
DO $$
DECLARE v_a int; v_b int; v_rp int; v_rp2 int; v_tx int; v_id int;
BEGIN
  SELECT id INTO v_a FROM finance.accounts WHERE name = '__bt_a__';
  SELECT id INTO v_b FROM finance.accounts WHERE name = '__bt_b__';
  v_rp := pg_temp.mk('v1', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_setup'); v_id := pg_temp.tid(v_rp);
  IF NOT finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [sichtbar]'; END IF;
  -- zweiter Dauerauftrag gleicher Strecke bleibt sichtbar
  v_rp2 := pg_temp.mk('v2', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp2, 'bank_setup');
  v_tx := pg_temp.tx(v_rp);
  IF finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [Buchung versteckt setup]'; END IF;
  IF NOT finance.fn_bank_todo_visible(pg_temp.tid(v_rp2)) THEN RAISE EXCEPTION 'FAIL [zweite Strecke bleibt]'; END IF;
  DELETE FROM finance.transactions WHERE id = v_tx;
  IF NOT finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [Void zeigt wieder]'; END IF;
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_rp;
  IF finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [Pause versteckt]'; END IF;
  UPDATE finance.recurring_payments SET status = 'active' WHERE id = v_rp;
  IF NOT finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [Fortsetzen zeigt]'; END IF;
  UPDATE finance.recurring_payments SET executed_by = 'manual' WHERE id = v_rp;
  IF finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [executed_by versteckt]'; END IF;
  UPDATE finance.recurring_payments SET executed_by = NULL WHERE id = v_rp;

  -- stop: pausiert sichtbar, abgedeckt durch Bank-Ende nicht, nach 60 Tagen weg
  v_rp := pg_temp.mk('v3', v_a, v_b);
  PERFORM pg_temp.tx(v_rp);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_stop'); v_id := pg_temp.tid(v_rp);
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_rp;
  IF NOT finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [stop pausiert sichtbar]'; END IF;
  UPDATE finance.bank_todos SET event_at = now() - interval '61 days' WHERE id = v_id;
  IF finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [stop nach 60 Tagen weg]'; END IF;
  UPDATE finance.bank_todos SET event_at = now() WHERE id = v_id;
  UPDATE finance.recurring_payments SET status = 'active', valid_to = core.fn_today() + 100 WHERE id = v_rp;
  IF finance.fn_bank_todo_visible(v_id) THEN RAISE EXCEPTION 'FAIL [stop abgedeckt durch Bank-Ende]'; END IF;
  RAISE NOTICE 'PASS Sichtbarkeit';
END $$;

-- Claim, Gruppierung, Rechte
DO $$
DECLARE v_a int; v_b int; v_p int; v_kid int; v_rp int; v_rp2 int; v_rp3 int; r jsonb; v_id int; g jsonb;
BEGIN
  DELETE FROM finance.bank_todos;
  SELECT id INTO v_a FROM finance.accounts WHERE name = '__bt_a__';
  SELECT id INTO v_b FROM finance.accounts WHERE name = '__bt_b__';
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__bt_p__','cash','EUR','active','Musterbank','__bt_p__') RETURNING id INTO v_p;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES ('__bt_kid__','cash','EUR','active','__bt_k__') RETURNING id INTO v_kid;

  v_rp := pg_temp.mk('c1', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_setup'); v_id := pg_temp.tid(v_rp);
  -- juenger als 20 Stunden
  r := finance.fn_bank_todo_claim();
  IF pg_temp.claimed(r, 'owner', v_id) THEN RAISE EXCEPTION 'FAIL [Runde 0 erst ab 20h]'; END IF;
  PERFORM pg_temp.age_todo(v_rp, NULL, 21);
  r := finance.fn_bank_todo_claim();
  IF NOT pg_temp.claimed(r, 'owner', v_id) THEN RAISE EXCEPTION 'FAIL [Runde 0]: %', r; END IF;
  IF (SELECT first_sent_at FROM finance.bank_todos WHERE id = v_id) IS NULL THEN RAISE EXCEPTION 'FAIL [first_sent]'; END IF;
  r := finance.fn_bank_todo_claim();
  IF pg_temp.claimed(r, 'owner', v_id) THEN RAISE EXCEPTION 'FAIL [genau einmal]'; END IF;

  -- Runden 7 und 21, beide faellig -> nur die spaetere
  PERFORM pg_temp.age_todo(v_rp, 8);
  r := finance.fn_bank_todo_claim();
  IF NOT pg_temp.claimed(r, 'owner', v_id) OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->0->'groups') x WHERE (x->>'nudge')::boolean) THEN RAISE EXCEPTION 'FAIL [Runde 1]: %', r; END IF;
  PERFORM pg_temp.age_todo(v_rp, 22);
  r := finance.fn_bank_todo_claim();
  IF NOT pg_temp.claimed(r, 'owner', v_id) THEN RAISE EXCEPTION 'FAIL [Runde 2]'; END IF;
  r := finance.fn_bank_todo_claim();
  IF pg_temp.claimed(r, 'owner', v_id) THEN RAISE EXCEPTION 'FAIL [danach nicht mehr]'; END IF;

  v_rp2 := pg_temp.mk('c2', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp2, 'bank_setup'); PERFORM pg_temp.age_todo(v_rp2, 30);
  r := finance.fn_bank_todo_claim();
  IF (SELECT count(*) FROM core.notification_state WHERE source = 'finance:bank_todo' AND key LIKE pg_temp.tid(v_rp2) || ':r%') <> 1
     OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance:bank_todo' AND key = pg_temp.tid(v_rp2) || ':r2:owner') THEN
    RAISE EXCEPTION 'FAIL [beide faellig -> nur spaetere]'; END IF;

  -- frueher als 7 Tage vor dem ersten Termin nie
  v_rp3 := pg_temp.mk('c3', v_a, v_b, core.fn_today() + 60);
  PERFORM finance.fn_bank_note_recorded(v_rp3, 'bank_setup'); PERFORM pg_temp.age_todo(v_rp3, 9);
  r := finance.fn_bank_todo_claim();
  IF pg_temp.claimed(r, 'owner', pg_temp.tid(v_rp3)) THEN RAISE EXCEPTION 'FAIL [Sperre 7 Tage vor Termin]'; END IF;

  -- Mitglied bekommt eigene, Kind nie, abgeschaltet behaelt die Nachricht
  DELETE FROM finance.bank_todos; DELETE FROM core.notification_state WHERE source = 'finance:bank_todo';
  v_rp := pg_temp.mk('p1', v_p, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_setup'); PERFORM pg_temp.age_todo(v_rp, NULL); v_id := pg_temp.tid(v_rp);
  v_rp2 := pg_temp.mk('k1', v_kid, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp2, 'bank_setup'); PERFORM pg_temp.age_todo(v_rp2, NULL);
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'remind_bank_todo';
  r := finance.fn_bank_todo_claim();
  IF pg_temp.claimed(r, 'owner', v_id) OR NOT pg_temp.claimed(r, '__bt_p__', v_id) THEN RAISE EXCEPTION 'FAIL [Owner aus, Mitglied kommt]: %', r; END IF;
  IF jsonb_path_exists(r, '$[*] ? (@.recipient == "__bt_k__")') THEN RAISE EXCEPTION 'FAIL [Kind nie Empfaenger]'; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'remind_bank_todo';
  r := finance.fn_bank_todo_claim();
  IF NOT pg_temp.claimed(r, 'owner', v_id) THEN RAISE EXCEPTION 'FAIL [abgeschalteter Empfaenger behaelt]: %', r; END IF;

  -- Gruppierung ohne Banknamen getrennt; Rechte in groups
  g := finance.fn_bank_todo_groups('7501');
  IF jsonb_array_length(g) < 2 THEN RAISE EXCEPTION 'FAIL [Owner alles, je Bank/Inhaber]: %', g; END IF;
  g := finance.fn_bank_todo_groups('7502');
  IF jsonb_array_length(g) <> 1 OR g->0->'items'->0->>'name' <> 'p1' THEN RAISE EXCEPTION 'FAIL [Partner eigene]: %', g; END IF;
  IF jsonb_array_length(finance.fn_bank_todo_groups('7503')) <> 0 OR jsonb_array_length(finance.fn_bank_todo_groups('x')) <> 0 THEN RAISE EXCEPTION 'FAIL [Kind/unbekannt nichts]'; END IF;
  RAISE NOTICE 'PASS Claim';
END $$;

-- handoff-Modus + Backfill
DO $$
DECLARE v_a int; v_b int; v_rp int; v_rp2 int; v_rp3 int; r jsonb; v_id int; v_stamp timestamptz := now() - interval '1 day'; v_new int; v_n int;
BEGIN
  DELETE FROM finance.bank_todos; DELETE FROM core.notification_state WHERE source = 'finance:bank_todo';
  SELECT id INTO v_a FROM finance.accounts WHERE name = '__bt_a__';
  SELECT id INTO v_b FROM finance.accounts WHERE name = '__bt_b__';

  -- Chat-Punkt nicht in handoff
  v_rp := pg_temp.mk('h1', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_setup'); PERFORM pg_temp.age_todo(v_rp, NULL); v_id := pg_temp.tid(v_rp);
  r := finance.fn_bank_todo_claim(core.fn_today(), 'handoff');
  IF pg_temp.claimed(r, 'owner', v_id) THEN RAISE EXCEPTION 'FAIL [handoff ohne Chat-Punkte]'; END IF;

  -- Punkt mit gleichem Stempel wie die Aufgabe: Merker mit Frist und latches
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at)
    VALUES ('finance', 'finance', '__bt_o__', 's', 'recurring_transfer', 't', 'done', v_stamp, v_stamp);
  UPDATE finance.bank_todos SET created_at = v_stamp WHERE id = v_id;
  r := finance.fn_bank_todo_claim(core.fn_today(), 'handoff');
  IF NOT pg_temp.claimed(r, 'owner', v_id) OR jsonb_array_length(r->0->'latches') <> 1 THEN RAISE EXCEPTION 'FAIL [handoff latches]: %', r; END IF;
  IF (SELECT expires_at FROM core.notification_state WHERE source = 'finance:bank_todo' AND key = v_id || ':r0:owner') IS NULL THEN RAISE EXCEPTION 'FAIL [handoff Frist]'; END IF;

  -- cron ohne Frist
  v_rp2 := pg_temp.mk('h2', v_a, v_b);
  PERFORM finance.fn_bank_note_recorded(v_rp2, 'bank_setup'); PERFORM pg_temp.age_todo(v_rp2, NULL);
  PERFORM finance.fn_bank_todo_claim();
  IF (SELECT expires_at FROM core.notification_state WHERE source = 'finance:bank_todo' AND key = pg_temp.tid(v_rp2) || ':r0:owner') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [cron ohne Frist]'; END IF;

  -- Backfill
  DELETE FROM finance.bank_todos; DELETE FROM core.notification_state WHERE source = 'finance:bank_todo';
  v_rp := pg_temp.mk('b1', v_a, v_b); UPDATE finance.recurring_payments SET created_at = v_stamp WHERE id = v_rp;
  v_new := (finance.fn_split_recurring_payment(v_rp, core.fn_today() + 90, -70, NULL, NULL, NULL, NULL, NULL, NULL)->>'recurring_payment_id')::int;
  v_rp3 := pg_temp.mk('b2', v_a, v_b);
  PERFORM finance.fn_bank_todo_backfill();
  IF pg_temp.ev(v_new) <> 'setup' OR (SELECT source FROM finance.bank_todos WHERE head_id = v_new) <> 'backfill' THEN RAISE EXCEPTION 'FAIL [Backfill nach Split]'; END IF;
  IF EXISTS (SELECT 1 FROM finance.bank_todos WHERE head_id = v_rp3) THEN RAISE EXCEPTION 'FAIL [Backfill ohne Uebergabe]'; END IF;
  v_n := (SELECT count(*) FROM finance.bank_todos);
  PERFORM finance.fn_bank_todo_backfill();
  IF (SELECT count(*) FROM finance.bank_todos) <> v_n THEN RAISE EXCEPTION 'FAIL [zweiter Lauf]'; END IF;
  RAISE NOTICE 'PASS handoff + Backfill';
END $$;
ROLLBACK;
