-- tests/db/finance/test_fn_handoff_repair.sql
-- Nachholen einer erledigten Vormerkung ueber den ganzen Weg: finance.fn_handoff_precheck (recheck, finance.fn_handoff_repair)
-- -> core.fn_handoff_register -> core.fn_plan_rollout_next (step fix) -> Knopf core.fn_handle_handoff_cb (...:fix).
--   * wie vereinbart eingetragen, spaeter vom Nutzer geaendert: bleibt als Abweichung im Register (diff), wird nie als
--     Nachholen angeboten, der Knopf legt keine Folge-Vormerkung an;
--   * zwei vereinbarte Aufrufe, der erste eingetragen und spaeter geaendert, der zweite nie eingetragen: angeboten wird
--     genau der fehlende Aufruf, die Aenderung am ersten bleibt;
--   * erster Aufruf eingetragen und wieder geloescht, zweiter nie eingetragen: der fehlende Aufruf bleibt nachholbar.
BEGIN;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
ON CONFLICT (package) DO UPDATE SET status = 'active';
DELETE FROM core.context_scopes WHERE context_name = 'financial_planning';
DELETE FROM core.advisors;
INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, handoff_check_fn, handoff_diff_fn)
VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', TRUE,
        'finance.fn_handoff_precheck', 'finance.fn_handoff_diff');
UPDATE core.config SET value = 'false' WHERE category = 'advisor' AND key = 'plan_sync_required';
DELETE FROM agent.handoff_tasks;
DELETE FROM agent.advisor_plans WHERE domain = 'finance';
INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, synced_at, interview_state)
VALUES ('finance', NULL, 'T', 'active', 1, now(), '{"s":{"content":"x"}}');

DO $$
DECLARE
  r     jsonb;
  v     jsonb;
  v_a   int; v_b int; v_t int; v_t2 int; v_t3 int; v_rp int; v_rp1 int; v_rp3 int; v_new int;
  v_c1  jsonb; v_c2 jsonb; v_d1 jsonb; v_d2 jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hr_giro', 'cash', 'EUR') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hr_tages', 'cash', 'EUR') RETURNING id INTO v_b;

  -- ---------- 1) wie vereinbart eingetragen, spaeter selbst geaendert ----------
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, wanted)
  VALUES ('finance','finance','erika','s','recurring_transfer','Übertrag am 1.','working', now() - interval '3 minutes',
          jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','__t_hr_ueb',
            'from_account_name','__t_hr_giro','to_account_name','__t_hr_tages','amount',100,'schedule_unit','month',
            'schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text)))
  RETURNING id INTO v_t;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_hr_ueb','from_account_id',v_a,'to_account_id',v_b,'amount',100,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111',
         'handoff_task_id',v_t::text));
  v_rp := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR finance.fn_handoff_diff(v_t) <> '[]'::jsonb THEN RAISE EXCEPTION 'SETUP [1 eingetragen]: %', r; END IF;
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'schedule_day_of_month', 15, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(finance.fn_handoff_diff(v_t)) = 0 THEN RAISE EXCEPTION 'SETUP [1 geaendert]: %', r; END IF;

  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','task_id',v_t,'status','done','kind','recurring_transfer'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r ? 'call' OR r ? 'calls' THEN RAISE EXCEPTION 'FAIL [1 recheck stellt die Aenderung zurueck]: %', r; END IF;
  r := core.fn_handoff_register('finance', '111');
  IF jsonb_array_length(r) <> 1 OR r->0->>'row_kind' <> 'deviation' OR (r->0->>'possible_now')::boolean IS NOT FALSE
     OR jsonb_array_length(r->0->'diff') = 0 OR r->0->'call' <> 'null'::jsonb THEN RAISE EXCEPTION 'FAIL [1 Register]: %', r; END IF;
  v := core.fn_plan_rollout_next('finance', 'erika');
  IF v->>'step' IS NOT DISTINCT FROM 'fix' THEN RAISE EXCEPTION 'FAIL [1 eigene Aenderung als Nachholen angeboten]: %', v; END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_t || ':fix','chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'nothing_open'
     OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE follows_task_id = v_t) THEN RAISE EXCEPTION 'FAIL [1 Knopf]: %', r; END IF;
  RAISE NOTICE 'PASS [1 eigene Aenderung]';

  -- ---------- 2) erster Teil eingetragen und geaendert, zweiter nie eingetragen ----------
  v_c1 := jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','__t_hr_teil1',
            'from_account_name','__t_hr_giro','to_account_name','__t_hr_tages','amount',300,'schedule_unit','month',
            'schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text));
  v_c2 := jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','__t_hr_teil2',
            'from_account_name','__t_hr_giro','to_account_name','__t_hr_tages','amount',100,'schedule_unit','month',
            'schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 70)::text));
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, wanted)
  VALUES ('finance','finance','erika','s','recurring_transfer','Raten und Rest','working', now() - interval '3 minutes',
          jsonb_build_array(v_c1, v_c2)) RETURNING id INTO v_t2;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_hr_teil1','from_account_id',v_a,'to_account_id',v_b,'amount',300,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111',
         'handoff_task_id',v_t2::text));
  v_rp1 := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP [2 erster Teil]: %', r; END IF;
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp1, 'amount', 250,
         'valid_from', (core.fn_today() + 71)::text, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(finance.fn_handoff_diff(v_t2)) <> 2 THEN
    RAISE EXCEPTION 'SETUP [2 geaendert]: % / %', r, finance.fn_handoff_diff(v_t2); END IF;

  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','task_id',v_t2,'status','done','kind','recurring_transfer'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r ? 'calls' OR r->'call'->>'tool' IS DISTINCT FROM 'create_recurring_transfer'
     OR r->'call'->'input'->>'name' IS DISTINCT FROM '__t_hr_teil2' THEN RAISE EXCEPTION 'FAIL [2 recheck nur der fehlende Teil]: %', r; END IF;
  v := core.fn_plan_rollout_next('finance', 'erika');
  IF v->>'step' IS DISTINCT FROM 'fix' OR v->'messages'->0->'msg'->0->>'value' <> 'core.rollout.fix_offer_one'
     OR v->'messages'->0->'buttons'->0->>'data' <> 'handoff:finance:' || v_t2 || ':fix' THEN RAISE EXCEPTION 'FAIL [2 Angebot]: %', v; END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data', v->'messages'->0->'buttons'->0->>'data','chat_id','111','chat_type','private'));
  SELECT id INTO v_new FROM agent.handoff_tasks WHERE follows_task_id = v_t2;
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'task_ids') <> 1 OR v_new IS NULL
     OR (SELECT wanted->'input'->>'name' FROM agent.handoff_tasks WHERE id = v_new) IS DISTINCT FROM '__t_hr_teil2'
     OR r->'tasks'->0->'wanted'->'input'->>'name' IS DISTINCT FROM '__t_hr_teil2'
     OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE follows_task_id = v_t) THEN
    RAISE EXCEPTION 'FAIL [2 Knopf holt nur den fehlenden Teil nach]: % / %', r, (SELECT wanted FROM agent.handoff_tasks WHERE id = v_new); END IF;
  IF (SELECT abs(amount) FROM finance.recurring_payments WHERE id = finance.fn_handoff_rp_latest(v_rp1)) <> 250 THEN
    RAISE EXCEPTION 'FAIL [2 Aenderung am ersten Teil bleibt]'; END IF;
  RAISE NOTICE 'PASS [2 fehlender Teil neben eigener Aenderung]';

  -- ---------- 3) erster Teil eingetragen und geloescht, zweiter nie eingetragen ----------
  v_d1 := jsonb_set(v_c1, '{input,name}', '"__t_hr_weg"');
  v_d2 := jsonb_set(v_c2, '{input,name}', '"__t_hr_offen"');
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, wanted)
  VALUES ('finance','finance','erika','s','recurring_transfer','Zwei Überträge','working', now() - interval '3 minutes',
          jsonb_build_array(v_d1, v_d2)) RETURNING id INTO v_t3;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_hr_weg','from_account_id',v_a,'to_account_id',v_b,'amount',300,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111',
         'handoff_task_id',v_t3::text));
  v_rp3 := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP [3 erster Teil]: %', r; END IF;
  DELETE FROM finance.bank_todos WHERE head_id = v_rp3;
  DELETE FROM finance.recurring_payments WHERE id = v_rp3;
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','task_id',v_t3,'status','done','kind','recurring_transfer'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r ? 'calls' OR r->'call'->'input'->>'name' IS DISTINCT FROM '__t_hr_offen' THEN
    RAISE EXCEPTION 'FAIL [3 fehlender Teil neben geloeschter Sache]: %', r; END IF;
  RAISE NOTICE 'PASS [3 geloescht und fehlend]';
END $$;

ROLLBACK;
