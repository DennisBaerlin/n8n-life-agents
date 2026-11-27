-- tests/db/finance/test_fn_reopen_handoff_task.sql
-- finance.fn_reopen_handoff_task (Abbruch-Zweig der Eintrags-Karten) und mehrteilige Eintraege:
--   * Karte nicht bestaetigt -> die Vormerkung ist sofort wieder offen und bleibt in derselben Runde eintragbar;
--     ohne handoff_task_id (Karte ausserhalb des Eintragens) passiert nichts; laeuft unter finance_rw;
--   * zwei vereinbarte Aufrufe, der erste eingetragen, die Karte des zweiten nicht bestaetigt -> der fehlende Aufruf kommt
--     als neue offene Vormerkung (follows_task_id) wieder; finance.fn_handoff_diff nennt ihn (call), die Vorpruefung im
--     recheck liefert ihn als Aufruf; eine geloeschte Sache traegt keinen Aufruf;
--   * zwei Aenderungen verschiedener Sachen unter einer Vormerkung gehen beide durch, dieselbe Sache zweimal nicht;
--   * die Karten "zurueckstellen", "nicht mehr eintragen" und "abhaken" zeigen die Stelle (core.hitl.handoff_pos) zuerst.
BEGIN;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111)))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
DELETE FROM agent.handoff_tasks;

-- ---------- 1) Karte nicht bestaetigt: sofort offen, in der Runde weiter eintragbar ----------
DO $$
DECLARE
  r    jsonb;
  v_a  int; v_b int; v_rp int; v_t int; v_t2 int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_ro_giro', 'cash', 'EUR') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_ro_tages', 'cash', 'EUR') RETURNING id INTO v_b;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_ro_ueb','from_account_id',v_a,'to_account_id',v_b,'amount',100,
         'schedule_unit','month','schedule_day_of_month',20,'first_payment_date',(core.fn_today() + 40)::text));
  v_rp := (r->>'recurring_payment_id')::int;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, wanted)
  VALUES ('finance','finance','erika','s','recurring_transfer','Übertrag künftig am 1.','working', now() - interval '2 minutes',
          jsonb_build_object('tool','set_recurring_payment','input', jsonb_build_object('payment_name','__t_ro_ueb','schedule_day_of_month',1)))
  RETURNING id INTO v_t;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','unter der Paketrolle','working', now() - interval '2 minutes') RETURNING id INTO v_t2;

  r := finance.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', '', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT count(*) FROM agent.handoff_tasks WHERE status = 'working') <> 2 THEN
    RAISE EXCEPTION 'FAIL [1 ohne Vormerkung]: %', r; END IF;
  r := finance.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_t::text, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'open'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'open' THEN RAISE EXCEPTION 'FAIL [1 sofort offen]: %', r; END IF;
  SET LOCAL ROLE finance_rw;
  r := finance.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_t2, 'chat_id', '111'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t2) <> 'open' THEN
    RAISE EXCEPTION 'FAIL [1 finance_rw]: %', r; END IF;
  -- der Nutzer sagt nach dem Abbruch doch "eintragen": derselbe Aufruf geht ohne neuen Tipp auf die Liste durch
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'schedule_day_of_month', 1, 'chat_id', '111',
         'handoff_task_id', v_t::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'done'
     OR r->'handoff_diff' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [1 danach eintragen]: %', r; END IF;
  RAISE NOTICE 'PASS [1 Karte nicht bestaetigt]';
END $$;

-- ---------- 2) zwei Teile, der zweite nicht bestaetigt: der Rest kommt als neue offene Vormerkung ----------
DO $$
DECLARE
  r    jsonb;
  v_a  int; v_b int; v_t int; v_new int; v_c1 jsonb; v_c2 jsonb; v_rp1 int;
BEGIN
  SELECT id INTO v_a FROM finance.accounts WHERE name = '__t_ro_giro';
  SELECT id INTO v_b FROM finance.accounts WHERE name = '__t_ro_tages';
  v_c1 := jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','__t_ro_teil1',
            'from_account_name','__t_ro_giro','to_account_name','__t_ro_tages','amount',300,'schedule_unit','month',
            'schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text));
  v_c2 := jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','__t_ro_teil2',
            'from_account_name','__t_ro_giro','to_account_name','__t_ro_tages','amount',100,'schedule_unit','month',
            'schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 70)::text));
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, wanted)
  VALUES ('finance','finance','erika','s','recurring_transfer','Raten und Rest zur Rücklage','working', now() - interval '3 minutes',
          jsonb_build_array(v_c1, v_c2)) RETURNING id INTO v_t;

  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_ro_teil1','from_account_id',v_a,'to_account_id',v_b,'amount',300,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111',
         'handoff_task_id',v_t::text));
  v_rp1 := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'done' THEN RAISE EXCEPTION 'FAIL [2 erster Teil]: %', r; END IF;

  -- der fehlende Teil steht im Unterschied mit seinem Aufruf; der recheck liefert ihn als Aufruf
  r := finance.fn_handoff_diff(v_t);
  IF jsonb_array_length(r) <> 1 OR r->0->>'field' <> 'exists' OR r->0->'call' IS DISTINCT FROM v_c2 OR r->0 ? 'ref' THEN
    RAISE EXCEPTION 'FAIL [2 Unterschied nennt den Aufruf]: %', r; END IF;
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','task_id',v_t,'status','done','kind','recurring_transfer'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'call'->'input'->>'name' IS DISTINCT FROM '__t_ro_teil2'
     OR (r->'call'->'input'->>'amount')::numeric <> 100 THEN RAISE EXCEPTION 'FAIL [2 recheck liefert den fehlenden Teil]: %', r; END IF;

  -- Karte des zweiten Teils nicht bestaetigt
  r := finance.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111'));
  v_new := (r->>'follow_task_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_new IS NULL
     OR (SELECT status || '|' || text FROM agent.handoff_tasks WHERE id = v_new) <> 'open|Raten und Rest zur Rücklage'
     OR (SELECT wanted FROM agent.handoff_tasks WHERE id = v_new) IS DISTINCT FROM v_c2 THEN
    RAISE EXCEPTION 'FAIL [2 Rest als neue Vormerkung]: % / %', r, (SELECT to_jsonb(t) FROM agent.handoff_tasks t WHERE id = v_new); END IF;

  -- die neue Vormerkung wird wie jede andere eingetragen
  UPDATE agent.handoff_tasks SET status = 'working', claimed_at = now() WHERE id = v_new;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_ro_teil2','from_account_id',v_a,'to_account_id',v_b,'amount',100,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 70)::text,'chat_id','111',
         'handoff_task_id',v_new::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_new) <> 'done'
     OR finance.fn_handoff_diff(v_new) IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [2 Rest eingetragen]: %', r; END IF;

  -- geloeschte Sache: Abweichung ohne Aufruf (wer sie loescht, will sie nicht nachgeholt haben), nicht nachholbar
  DELETE FROM finance.bank_todos WHERE head_id = v_rp1;
  DELETE FROM finance.recurring_payments WHERE id = v_rp1;
  r := finance.fn_handoff_diff(v_t);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r) d WHERE d->>'field' = 'exists' AND d ? 'ref' AND NOT d ? 'call') THEN
    RAISE EXCEPTION 'FAIL [2 geloescht ohne Aufruf]: %', r; END IF;
  RAISE NOTICE 'PASS [2 fehlender Teil]';
END $$;

-- ---------- 3) zwei Aenderungen verschiedener Sachen unter einer Vormerkung ----------
DO $$
DECLARE
  r    jsonb;
  v_a  int; v_b int; v_x int; v_y int; v_t int;
BEGIN
  SELECT id INTO v_a FROM finance.accounts WHERE name = '__t_ro_giro';
  SELECT id INTO v_b FROM finance.accounts WHERE name = '__t_ro_tages';
  v_x := (finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_ro_x','from_account_id',v_a,'to_account_id',v_b,'amount',50,
            'schedule_unit','month','schedule_day_of_month',20,'first_payment_date',(core.fn_today() + 40)::text))->>'recurring_payment_id')::int;
  v_y := (finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_ro_y','from_account_id',v_a,'to_account_id',v_b,'amount',60,
            'schedule_unit','month','schedule_day_of_month',20,'first_payment_date',(core.fn_today() + 40)::text))->>'recurring_payment_id')::int;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, wanted)
  VALUES ('finance','finance','erika','s','recurring_transfer','Beide Überträge künftig am 1.','working', now() - interval '4 minutes',
          jsonb_build_array(
            jsonb_build_object('tool','set_recurring_payment','input', jsonb_build_object('payment_name','__t_ro_x','schedule_day_of_month',1)),
            jsonb_build_object('tool','set_recurring_payment','input', jsonb_build_object('payment_name','__t_ro_y','schedule_day_of_month',1))))
  RETURNING id INTO v_t;
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_x, 'schedule_day_of_month', 1, 'chat_id', '111', 'handoff_task_id', v_t::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 erste Aenderung]: %', r; END IF;
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_y, 'schedule_day_of_month', 1, 'chat_id', '111', 'handoff_task_id', v_t::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length((SELECT entered_refs FROM agent.handoff_tasks WHERE id = v_t)) <> 2
     OR r->'handoff_diff' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [3 zweite Aenderung einer anderen Sache]: %', r; END IF;
  -- dieselbe Sache noch einmal: Wiederholung
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_y, 'schedule_day_of_month', 2, 'chat_id', '111', 'handoff_task_id', v_t::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [3 dieselbe Sache zweimal]: %', r; END IF;
  RAISE NOTICE 'PASS [3 zwei Aenderungen]';
END $$;

-- ---------- 4) Stelle auf den Karten ohne Buchung ----------
DO $$
DECLARE
  r    jsonb;
  v_t1 int; v_t2 int; v_t3 int;
  v_at timestamptz := now() - interval '6 minutes';
BEGIN
  INSERT INTO core.ui_texts (key, lang, text, package)
  VALUES ('finance.handoff.blocked.goal_irregular_payments', 'de', 'Geht noch nicht.', 'finance')
  ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;
  INSERT INTO finance.insurances (name, valid_from) VALUES ('__t_ro_hausrat', CURRENT_DATE);
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','savings_goal','Ziel aus Sonderzahlungen','working', v_at) RETURNING id INTO v_t1;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','Sparbuch auflösen','working', v_at) RETURNING id INTO v_t2;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','Hausrat prüfen','working', v_at) RETURNING id INTO v_t3;

  r := core.fn_dry_run('finance.fn_defer_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_t1, 'chat_id', '111', 'blocked_code', 'goal_irregular_payments'));
  IF r->'card_lines'->0->>'value' IS DISTINCT FROM 'core.hitl.handoff_pos' OR r->'card_lines'->0->'params' IS DISTINCT FROM '{"k": 1, "n": 3}'::jsonb
     OR r->'card_lines'->1->>'value' IS DISTINCT FROM 'core.hitl.handoff_note' THEN RAISE EXCEPTION 'FAIL [4 zurueckstellen]: %', r->'card_lines'; END IF;
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_t2, 'chat_id', '111', 'reason', 'dropped'));
  IF r->'card_lines'->0->>'value' IS DISTINCT FROM 'core.hitl.handoff_pos' OR r->'card_lines'->0->'params' IS DISTINCT FROM '{"k": 2, "n": 3}'::jsonb
     OR r->'card_lines'->1->>'value' IS DISTINCT FROM 'core.hitl.handoff_note' THEN RAISE EXCEPTION 'FAIL [4 nicht mehr eintragen]: %', r->'card_lines'; END IF;
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure, jsonb_build_object('handoff_task_id', v_t3, 'chat_id', '111',
         'reason', 'done_elsewhere', 'ref_type', 'insurance', 'ref_name', '__t_ro_hausrat'));
  IF r->'card_lines'->0->>'value' IS DISTINCT FROM 'core.hitl.handoff_pos' OR r->'card_lines'->0->'params' IS DISTINCT FROM '{"k": 3, "n": 3}'::jsonb
     OR r->'card_lines'->1->>'value' IS DISTINCT FROM 'core.hitl.handoff_note' THEN RAISE EXCEPTION 'FAIL [4 abhaken]: %', r->'card_lines'; END IF;
  -- nie beansprucht (Aufruf ausserhalb einer Runde): keine Stelle, die Karte beginnt mit dem vereinbarten Satz
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES ('finance','finance','erika','s','other','ohne Runde') RETURNING id INTO v_t1;
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_t1, 'chat_id', '111', 'reason', 'dropped'));
  IF r->'card_lines'->0->>'value' IS DISTINCT FROM 'core.hitl.handoff_note' THEN RAISE EXCEPTION 'FAIL [4 ohne Runde]: %', r->'card_lines'; END IF;
  RAISE NOTICE 'PASS [4 Stelle auf den Karten]';
END $$;

ROLLBACK;
