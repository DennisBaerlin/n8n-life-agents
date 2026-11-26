-- tests/db/finance/test_fn_plan_rollout.sql
-- Schritt Bank-Zettel der Abfolge: Nachrichten aus der Uebergabe, danach Wartefenster 7 Tage.
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'bt', NULL, 'lazy', 'x', jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','__rl_o__','first_name','Olli','last_name','Muster','role','owner','birth_date','1980-01-01','telegram_user_id',7701,'as_of','2026-10-23')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES ('remind_bank_todo', 'finance', 'household', TRUE)
ON CONFLICT (cron_key) DO UPDATE SET scope = excluded.scope;
INSERT INTO core.config (package, category, key, value) VALUES ('finance', 'cron_enable', 'remind_bank_todo', 'true')
ON CONFLICT (category, key) DO UPDATE SET value = 'true';

DO $$
DECLARE v_a int; v_b int; v_rp int; r jsonb; v_id int; v_stamp timestamptz := now() - interval '1 hour';
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__rl_a__','cash','EUR','active','Musterbank','__rl_o__') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rl_b__','cash','EUR','active') RETURNING id INTO v_b;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('rl1', v_a, v_b, -100, 'month', 5, core.fn_today() + 10, core.fn_today() + 10) RETURNING id INTO v_rp;
  PERFORM finance.fn_bank_note_recorded(v_rp, 'bank_setup');
  SELECT id INTO v_id FROM finance.bank_todos WHERE head_id = v_rp;

  r := finance.fn_plan_rollout('finance', NULL);
  IF (r->>'wait')::boolean OR jsonb_array_length(r->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL [Chat-Punkt nicht in der Abfolge]: %', r; END IF;

  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at)
    VALUES ('finance', 'finance', '__rl_o__', 's', 'recurring_transfer', 't', 'done', v_stamp, v_stamp);
  UPDATE finance.bank_todos SET created_at = v_stamp WHERE id = v_id;
  r := finance.fn_plan_rollout('finance', NULL);
  IF jsonb_array_length(r->'messages') <> 1 OR NOT (r->>'wait')::boolean OR jsonb_array_length(r->'messages'->0->'buttons') <> 1 THEN RAISE EXCEPTION 'FAIL [Nachricht + wait]: %', r; END IF;

  r := finance.fn_plan_rollout('finance', NULL);
  IF jsonb_array_length(r->'messages') <> 0 OR NOT (r->>'wait')::boolean THEN RAISE EXCEPTION 'FAIL [wartet]: %', r; END IF;

  UPDATE finance.bank_todos SET first_sent_at = now() - interval '8 days' WHERE id = v_id;
  r := finance.fn_plan_rollout('finance', NULL);
  IF (r->>'wait')::boolean THEN RAISE EXCEPTION 'FAIL [Wartefenster vorbei]: %', r; END IF;
  RAISE NOTICE 'PASS Abfolge';
END $$;

-- Bank-Liste nach dem Durchgehen ueber die ganze Abfolge (core.fn_plan_rollout_next): zwei Vormerkungen, eine ueber
-- fn_set_recurring_payment, eine ueber zwei fn_create_recurring_transfer-Aufrufe -> beide done, alle drei Bank-Punkte
-- in EINER Nachricht, genau einmal; nicht waehrend des Durchgehens; eine liegen gebliebene Vormerkung haelt sie nicht auf.
DO $$
DECLARE
  v_giro int; v_tages int; v_topf int; v_rp int; r jsonb; v jsonb;
  v_c int; v_a int; v_b int; v_max int; v_key text; v_items jsonb;
BEGIN
  DELETE FROM finance.bank_todos;
  DELETE FROM agent.handoff_tasks WHERE domain = 'finance';
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  DELETE FROM core.advisors WHERE domain = 'finance';
  INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step, rollout_fn)
  VALUES ('finance', 'finance', 'financial_planning', 'finance.fn_advisor_review', TRUE, 'finance.fn_plan_rollout');
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, synced_at) VALUES ('finance', 'p', 'active', 1, now());
  INSERT INTO finance.accounts (name, account_type, currency, status, bank, owner_person_id) VALUES ('__rl_giro__','cash','EUR','active','Musterbank','__rl_o__') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES ('__rl_tages__','cash','EUR','active','__rl_o__') RETURNING id INTO v_tages;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES ('__rl_topf__','cash','EUR','active','__rl_o__') RETURNING id INTO v_topf;
  -- bestehender Uebertrag (vor dem Plan im Chat angelegt): sein Bank-Punkt ist ein Chat-Punkt
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__rl_uebertrag__','from_account_id',v_giro,'to_account_id',v_tages,'amount',200,
         'schedule_unit','month','schedule_day_of_month',20,'first_payment_date',(core.fn_today() + 40)::text));
  v_rp := (r->>'recurring_payment_id')::int;
  -- C zuerst: bleibt liegen (der Nutzer verschiebt sie), A und B werden eingetragen
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES
    ('finance','finance','__rl_o__','s','other','Versicherung prüfen') RETURNING id INTO v_c;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES
    ('finance','finance','__rl_o__','s','recurring_transfer','Übertrag künftig am 1.') RETURNING id INTO v_a;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES
    ('finance','finance','__rl_o__','s','recurring_transfer','Zwei Uebertraege im Jahr in den Topf') RETURNING id INTO v_b;
  v_max := v_b;

  -- nach dem Veroeffentlichen: die Liste
  v := core.fn_plan_rollout_next('finance', '__rl_o__');
  IF (v->>'step')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [Bank-Liste: Liste zuerst]: %', v; END IF;
  PERFORM core.fn_notify_commit('plan_rollout', v->'messages'->0->'latch'->>'key');
  -- [Durchgehen]: alle drei beansprucht (Claim wie core.fn_handle_handoff_cb, dessen Gates deckt test_fn_handoff_tasks)
  UPDATE agent.handoff_tasks SET status = 'working', claimed_at = now() WHERE domain = 'finance' AND id <= v_max AND status = 'open';

  -- A: Tag des bestehenden Uebertrags auf den 1. (set_recurring_payment)
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'schedule_day_of_month', 1, 'chat_id', '7701', 'handoff_task_id', v_a::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [Bank-Liste: A]: %', r; END IF;
  -- waehrend des Durchgehens: keine Bank-Liste
  v := core.fn_plan_rollout_next('finance', '__rl_o__');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL [Bank-Liste: mitten im Durchgehen]: %', v; END IF;
  -- B: zwei jaehrliche Uebertraege fuer eine Vormerkung
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__rl_rate_a__','from_account_id',v_giro,'to_account_id',v_topf,'amount',900,
         'schedule_unit','year','first_payment_date',(core.fn_today() + 60)::text,'chat_id','7701','handoff_task_id',v_b::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [Bank-Liste: B1]: %', r; END IF;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__rl_rate_b__','from_account_id',v_giro,'to_account_id',v_topf,'amount',800,
         'schedule_unit','year','first_payment_date',(core.fn_today() + 120)::text,'chat_id','7701','handoff_task_id',v_b::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [Bank-Liste: B2 zweiter Teil]: %', r; END IF;
  IF (SELECT count(*) FROM agent.handoff_tasks WHERE id IN (v_a, v_b) AND status = 'done') <> 2 THEN RAISE EXCEPTION 'FAIL [Bank-Liste: A und B done]'; END IF;
  -- C auf spaeter gelegt (zurueck auf open)
  PERFORM core.fn_release_handoff_tasks(jsonb_build_object('task_ids', jsonb_build_array(v_c)));
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_c) <> 'open' THEN RAISE EXCEPTION 'FAIL [Bank-Liste: C open]'; END IF;

  -- Ende des Durchgehens: die Bank-Liste, eine Nachricht, alle drei Punkte
  v := core.fn_plan_rollout_next('finance', '__rl_o__');
  IF (v->>'step')::int IS DISTINCT FROM 3 OR jsonb_array_length(v->'messages') <> 1 THEN RAISE EXCEPTION 'FAIL [Bank-Liste kommt]: %', v; END IF;
  -- Form der Abfolge: Einleitung, Leerzeile, drei Punkte, Leerzeile, Anleitung; ein Knopf btodo; je Punkt ein Merker
  v_items := v->'messages'->0;
  IF jsonb_array_length(v_items->'lines') <> 7 OR v_items->'lines'->0->0->>'value' <> 'finance.bank_todo.intro'
     OR v_items->'lines'->0->0->'params'->>'bank' <> 'Musterbank' OR v_items->'lines'->2->>0 <> '1.' OR v_items->'lines'->4->>0 <> '3.'
     OR v_items->'lines'->6->0->>'value' <> 'finance.bank_todo.howto'
     OR jsonb_array_length(v_items->'buttons') <> 1 OR v_items->'buttons'->0->>'data' NOT LIKE 'btodo:%'
     OR v_items->'buttons'->0->>'text_key' <> 'finance.bank_todo.btn_done' OR v_items->'buttons'->0->'params'->>'bank' <> 'Musterbank'
     OR jsonb_array_length(v_items->'latches') <> 3 THEN RAISE EXCEPTION 'FAIL [Bank-Liste: drei Punkte gebuendelt]: %', v; END IF;
  -- alle drei Punkte tragen ihre Vormerkung
  IF (SELECT count(*) FROM finance.bank_todos WHERE status = 'open' AND handoff_task_id IN (v_a, v_b)) <> 3 THEN RAISE EXCEPTION 'FAIL [Bank-Liste: Verweis]'; END IF;
  FOR v_key IN SELECT x->>'key' FROM jsonb_array_elements(v_items->'latches') x LOOP PERFORM core.fn_notify_commit('finance:bank_todo', v_key); END LOOP;
  -- genau einmal
  v := core.fn_plan_rollout_next('finance', '__rl_o__');
  IF (v->>'step')::int = 3 AND jsonb_array_length(v->'messages') > 0 THEN RAISE EXCEPTION 'FAIL [Bank-Liste: zweimal]: %', v; END IF;
  RAISE NOTICE 'PASS Bank-Liste nach dem Durchgehen';
END $$;
ROLLBACK;
