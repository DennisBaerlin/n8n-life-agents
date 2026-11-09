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
  IF jsonb_array_length(r->'messages') <> 1 OR NOT (r->>'wait')::boolean THEN RAISE EXCEPTION 'FAIL [Nachricht + wait]: %', r; END IF;

  r := finance.fn_plan_rollout('finance', NULL);
  IF jsonb_array_length(r->'messages') <> 0 OR NOT (r->>'wait')::boolean THEN RAISE EXCEPTION 'FAIL [wartet]: %', r; END IF;

  UPDATE finance.bank_todos SET first_sent_at = now() - interval '8 days' WHERE id = v_id;
  r := finance.fn_plan_rollout('finance', NULL);
  IF (r->>'wait')::boolean THEN RAISE EXCEPTION 'FAIL [Wartefenster vorbei]: %', r; END IF;
  RAISE NOTICE 'PASS Abfolge';
END $$;
ROLLBACK;
