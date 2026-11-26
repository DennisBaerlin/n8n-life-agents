-- tests/db/finance/test_fn_entry_effects.sql
-- finance.fn_entry_effects(p_domain): Folge-Zeile der Eintrags-Liste. Zaehlt die Konten, deren Vorschau ein offener
--   Eintrag noch verfaelscht (Hinweis-Klasse entry aus finance.fn_advisor_hints), abgeleitet bei jedem Lesen:
--   ohne offenen Eintrag 0; Eintrag nennt das Konto -> 1; dringender Hinweis zaehlt nicht (bleibt eigene Frage);
--   Eintrag erledigt -> wieder 0. Werte erfunden.
BEGIN;

DO $$
DECLARE
  t      date := core.fn_today();
  r      jsonb;
  v_fund int;
  v_low  int;
  v_t    int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM agent.handoff_tasks;

  -- ein Sparplan zehrt ein Konto in einigen Wochen auf (nicht dringend), ein zweites Konto geht in 3 Tagen ins Minus (dringend)
  v_fund := (finance.fn_create_account('{"name":"__ee_fund__","account_type":"cash","currency":"EUR","opening_balance":1000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, plan_execution_days)
    VALUES ('__ee_depot__', 'stocks_depot', 'EUR', 'active', v_fund, '{}');
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name', '__ee_plan__', 'depot_name', '__ee_depot__', 'isin', 'EEST00000001',
            'symbol', 'EEETF', 'security_name', 'Ee ETF', 'amount', 100, 'schedule_interval', 1, 'schedule_unit', 'week', 'first_payment_date', (t + 2)::text));
  v_low := (finance.fn_create_account('{"name":"__ee_low__","account_type":"cash","currency":"EUR","opening_balance":100}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_add_recurring_payment(v_low, -500, '__ee_low_miete__', 1::smallint, 'month'::finance.schedule_unit, NULL::smallint, t + 3, t + 3, NULL, NULL, NULL);

  -- 1) ohne offenen Eintrag -> 0
  r := finance.fn_entry_effects('finance');
  IF (r->>'accounts')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [1 ohne Eintrag]: %', r; END IF;

  -- 2) offener Eintrag nennt beide Konten: nur das nicht dringende zaehlt
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, payload, text)
  VALUES ('finance', 'finance', 'erika', 'wealth_building', 'savings_plan', '{"account":"__ee_fund__","other":"__ee_low__"}', 'Sparplan anpassen')
  RETURNING id INTO v_t;
  r := finance.fn_entry_effects('finance');
  IF (r->>'accounts')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [2 ein Konto]: %', r; END IF;

  -- 3) Eintrag gestrichen -> wieder 0 (nichts gespeichert)
  UPDATE agent.handoff_tasks SET status = 'cancelled', closed_at = now(), close_reason = 'dropped' WHERE id = v_t;
  r := finance.fn_entry_effects('finance');
  IF (r->>'accounts')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [3 erledigt]: %', r; END IF;
  RAISE NOTICE 'PASS [entry_effects]';
END $$;

ROLLBACK;
