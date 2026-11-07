-- tests/db/finance/test_fn_with_handoff.sql
-- finance.fn_with_handoff + handoff_task_id an den sechs Ziel-fns (Uebergabe Berater -> Buchhalter):
--   Aufgabe nicht working / fremde Person -> {ok:false, code:'handoff_task_invalid'} ohne Write; Ablehnung der Ziel-fn ->
--   Aufgabe bleibt working; Erfolg -> Write + done in derselben Transaktion + Kartenzeile core.hitl.handoff_note;
--   Probelauf (core.fn_dry_run) laesst die Aufgabe working; finance.fn_cancel_handoff_task.
BEGIN;

DO $$
DECLARE
  r      jsonb;
  v_acc  int;
  v_open int; v_w1 int; v_w2 int; v_w3 int;
  v_base jsonb;
  f      text;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM agent.handoff_tasks;
  INSERT INTO finance.accounts (name, account_type) VALUES ('__t_handoff_giro', 'cash') RETURNING id INTO v_acc;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES
    ('finance','finance','erika','s','recurring_payment','Miete 900 € monatlich') RETURNING id INTO v_open;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','erika','s','recurring_payment','Gehalt 2.500 € monatlich','working',now()) RETURNING id INTO v_w1;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','erika','s','other','Haftpflicht prüfen','working',now()) RETURNING id INTO v_w2;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','erika','s','other','Hausrat prüfen','working',now()) RETURNING id INTO v_w3;
  v_base := jsonb_build_object('name','__t_handoff_gehalt','account_id',v_acc,'direction','income','amount',2500,
                               'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',current_date::text,'chat_id','111');

  -- 1) offene (nicht beanspruchte) Aufgabe -> keine Buchung
  r := finance.fn_create_recurring_payment(v_base || jsonb_build_object('handoff_task_id', v_open));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid'
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__t_handoff_gehalt') THEN RAISE EXCEPTION 'FAIL [1 open]: %', r; END IF;
  -- 2) fremde Person
  r := finance.fn_create_recurring_payment(v_base || jsonb_build_object('handoff_task_id', v_w1, 'chat_id', '222'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [2 Person]: %', r; END IF;
  -- 3) Ablehnung der Ziel-fn -> Aufgabe bleibt working
  r := finance.fn_create_recurring_payment(v_base || jsonb_build_object('handoff_task_id', v_w1, 'direction', 'sideways'));
  IF (r->>'ok')::boolean IS NOT FALSE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w1) <> 'working' THEN
    RAISE EXCEPTION 'FAIL [3 Ziel-fn lehnt ab]: %', r; END IF;
  RAISE NOTICE 'PASS [1-3 Ablehnungen ohne Write]';

  -- 4) Probelauf: Karte mit Notiz, Aufgabe bleibt working, nichts geschrieben
  r := core.fn_dry_run('finance.fn_create_recurring_payment(jsonb)'::regprocedure, v_base || jsonb_build_object('handoff_task_id', v_w1::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'card_lines'->-1->>'value' <> 'core.hitl.handoff_note'
     OR r->'card_lines'->-1->'params'->>'text' <> 'Gehalt 2.500 € monatlich' THEN RAISE EXCEPTION 'FAIL [4 Probelauf]: %', r; END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_w1) <> 'working'
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__t_handoff_gehalt') THEN RAISE EXCEPTION 'FAIL [4 Probelauf schrieb]'; END IF;
  RAISE NOTICE 'PASS [4 Probelauf]';

  -- 5) Erfolg: Write + done atomar
  r := finance.fn_create_recurring_payment(v_base || jsonb_build_object('handoff_task_id', v_w1::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoff_task_id')::int <> v_w1
     OR (r->>'recurring_payment_id')::int IS DISTINCT FROM (SELECT id FROM finance.recurring_payments WHERE name = '__t_handoff_gehalt')
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w1) <> 'done' THEN RAISE EXCEPTION 'FAIL [5 Erfolg]: %', r; END IF;
  -- zweiter Eintrag auf dieselbe Aufgabe -> abgelehnt (keine Doppelbuchung ueber die Aufgabe)
  r := finance.fn_create_recurring_payment(v_base || jsonb_build_object('name','__t_handoff_gehalt2','handoff_task_id', v_w1));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 zweimal]: %', r; END IF;
  RAISE NOTICE 'PASS [5 Erfolg atomar]';

  -- 6) jede Ziel-fn kennt handoff_task_id (Pruefung vor jedem eigenen Schritt)
  FOREACH f IN ARRAY ARRAY['finance.fn_create_savings_goal', 'finance.fn_set_savings_goal', 'finance.fn_create_savings_plan',
                           'finance.fn_set_savings_plan', 'finance.fn_create_recurring_payment', 'finance.fn_create_recurring_transfer'] LOOP
    EXECUTE format('SELECT %s($1)', f) INTO r USING jsonb_build_object('handoff_task_id', '999999', 'chat_id', '111');
    IF r->>'code' IS DISTINCT FROM 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [6 %]: %', f, r; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [6 sechs Ziel-fns]';

  -- 7) Ueberspringen-Tool-fn
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_w2, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'card_lines'->0->'params'->>'text' <> 'Haftpflicht prüfen'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w2) <> 'working' THEN RAISE EXCEPTION 'FAIL [7 Probelauf]: %', r; END IF;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_w2, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'cancelled' THEN RAISE EXCEPTION 'FAIL [7 skipped]: %', r; END IF;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_w3, 'chat_id', '111', 'reason', 'done_elsewhere'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w3) <> 'done' THEN RAISE EXCEPTION 'FAIL [7 done_elsewhere]: %', r; END IF;
  RAISE NOTICE 'PASS [7 cancel]';
END $$;

ROLLBACK;
