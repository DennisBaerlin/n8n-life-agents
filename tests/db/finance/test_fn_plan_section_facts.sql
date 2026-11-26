-- tests/db/finance/test_fn_plan_section_facts.sql
-- "Stand heute" je Teil des Finanzplans: finance.fn_plan_section_facts.
--   * je Teil hoechstens sechs Zeilen {label, value, kind}, Werte frisch aus den Views (Aenderung der Daten -> neue Zeile);
--   * Geld der Kinder in keiner Haushalts-Zeile (Vermoegen);
--   * unaufgeloester Absender und Kind -> []; Teile ohne Fakten -> [];
--   * core.fn_render_prompt zeigt die Zeilen als Zitat unter der Kopfzeile core.prompt.facts_head.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  t      date := core.fn_today();
  r      jsonb;
  v_giro int;
  v_kid  int;
  v_id   bigint;
  i      int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','kim','first_name','Kim','last_name','Beispiel','role','child','birth_date','2015-03-02','telegram_user_id',333,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('kim', 'Kim Beispiel', 'child') ON CONFLICT (person_id) DO UPDATE SET role = 'child';
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, 'de', 'DE:' || k, 'finance' FROM unnest(ARRAY['finance.facts.wealth_cash','finance.facts.loan_value','finance.facts.goal_value']) k
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  UPDATE finance.loans SET status = 'paid_off';
  UPDATE finance.savings_goals SET status = 'cancelled';

  v_giro := (finance.fn_create_account('{"name":"__facts_giro__","account_type":"cash","currency":"EUR","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_kid  := (finance.fn_create_account('{"name":"__facts_kind__","account_type":"cash","currency":"EUR","opening_balance":700}'::jsonb)->>'account_id')::int;
  UPDATE finance.accounts SET owner_person_id = 'kim' WHERE id = v_kid;
  PERFORM finance.fn_add_recurring_payment(v_giro, 3000, '__facts_gehalt__', 1::smallint, 'month'::finance.schedule_unit, 1::smallint, t - 60, t - 60, NULL, NULL, NULL);
  PERFORM finance.fn_create_loan(jsonb_build_object('name', '__facts_kredit__', 'lender', 'Bank', 'current_balance', 8000,
            'interest_rate', 3.5, 'monthly_annuity', 300, 'first_payment_date', (t + 5)::text, 'debit_account_id', v_giro));
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__facts_ziel__', 2000, t + 300);
  FOR i IN 1..7 LOOP
    INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__facts_ziel_' || i, 100, t + 300);
  END LOOP;

  -- ---------- 1) Absender ----------
  IF finance.fn_plan_section_facts('household_basics', '999') <> '[]'::jsonb OR finance.fn_plan_section_facts('household_basics', '333') <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [1 unbekannt/Kind]'; END IF;
  IF finance.fn_plan_section_facts('risk_profile', '111') <> '[]'::jsonb OR finance.fn_plan_section_facts('gibt_es_nicht', '111') <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [1 Teil ohne Fakten]'; END IF;
  RAISE NOTICE 'PASS [1 Absender + leere Teile]';

  -- ---------- 2) Zeilen je Teil ----------
  r := finance.fn_plan_section_facts('household_basics', '111');
  IF jsonb_array_length(r) <> 4 OR r->0->>'kind' <> 'count' OR r->1->>'kind' <> 'money' THEN RAISE EXCEPTION 'FAIL [2 Haushalt]: %', r; END IF;
  r := finance.fn_plan_section_facts('debts_loans', '111');
  IF jsonb_array_length(r) <> 1 OR r->0->>'label' <> '__facts_kredit__' OR r->0->>'value' <> 'DE:finance.facts.loan_value' THEN
    RAISE EXCEPTION 'FAIL [2 Kredite]: %', r; END IF;
  r := finance.fn_plan_section_facts('goals_triggers', '111');
  IF jsonb_array_length(r) <> 6 OR r->0->>'label' <> '__facts_ziel__' THEN RAISE EXCEPTION 'FAIL [2 hoechstens sechs]: %', r; END IF;
  r := finance.fn_plan_section_facts('wealth_building', '111');
  IF NOT (r @> '[{"label":"DE:finance.facts.wealth_cash"}]')
     OR (SELECT count(*) FROM jsonb_array_elements(r) e WHERE e->>'label' = 'DE:finance.facts.wealth_cash') <> 1 THEN
    RAISE EXCEPTION 'FAIL [2 Vermoegen]: %', r; END IF;
  RAISE NOTICE 'PASS [2 Zeilen je Teil]';

  -- ---------- 3) Kindergeld nicht in der Haushalts-Summe, frisch nach Aenderung ----------
  r := finance.fn_plan_section_facts('wealth_building', '111');
  IF (SELECT e->>'value' FROM jsonb_array_elements(r) e WHERE e->>'label' = 'DE:finance.facts.wealth_cash')
     <> core.fn_fmt_money((SELECT sum(value_eur) FROM finance.networth_by_asset_class WHERE bucket = 'cash' AND owner_person_id IS DISTINCT FROM 'kim'), 'EUR', 'de') THEN
    RAISE EXCEPTION 'FAIL [3 ohne Kind]: %', r; END IF;
  UPDATE finance.loans SET status = 'paid_off' WHERE name = '__facts_kredit__';
  IF finance.fn_plan_section_facts('debts_loans', '111') <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [3 frisch]'; END IF;
  RAISE NOTICE 'PASS [3 Kinder + frisch]';

  -- ---------- 4) Anzeige im Karten-Renderer ----------
  DELETE FROM core.advisors WHERE domain = 'finance';
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, section_facts_fn)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', 'finance.fn_plan_section_facts');
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, status, card, options)
  VALUES ('111', 'erika', 'agent.finance_advisor', 'hint', 'queued',
          '{"lines":[{"kind":"head","text":"Kopf"},{"kind":"facts","domain":"finance","section_key":"goals_triggers"},{"kind":"text","text":"x"}]}', '[]')
  RETURNING id INTO v_id;
  r := core.fn_render_prompt(v_id);
  IF r->'card'->'lines'->1->>'kind' <> 'quote' OR r->'card'->'lines'->2->>'text' NOT LIKE '__facts_ziel__: %'
     OR jsonb_array_length(r->'card'->'lines') <> 2 + 1 + 6 THEN
    RAISE EXCEPTION 'FAIL [4 Renderer]: %', r; END IF;
  RAISE NOTICE 'PASS [4 Renderer]';
END $$;

ROLLBACK;
