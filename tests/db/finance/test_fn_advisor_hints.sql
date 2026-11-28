-- tests/db/finance/test_fn_advisor_hints.sql
-- Hinweise nur, wenn es brennt:
--   * finance.fn_advisor_hints: je Hinweis key + class: urgent (Problem in <= 30 Tagen), entry (eine offene Vormerkung
--     nennt das Konto), after_plan (spaeter), monthly_check (veralteter Kontoauszug, holt der Monats-Check ab);
--   * finance.fn_advisor_snapshot: ohne Entwurf alle ausser monthly_check, mit offenem Entwurf nur urgent + hints_held;
--     stillgelegte fehlen;
--   * agent.fn_advisor_defer_hint (Merker "spaeter", Latch advisor_hint) und die DB-eigene Frage der Art hint ueber
--     core.fn_next_chat_prompt: einmal je Gespraech, Spaeter -> Merker, Jetzt klaeren -> Auftrag an den Berater.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  t       date := core.fn_today();
  v       jsonb;
  r       jsonb;
  v_low   int;
  v_fund  int;
  v_hist  int;
  v_klow  text;
  v_kfund text;
  v_id    bigint;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.advisors WHERE domain = 'finance';
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, hints_fn)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', 'finance.fn_advisor_hints');
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('q', 'core.fn_answer_chat_prompt', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;
  INSERT INTO core.config (category, key, value, package, value_type, minimum, maximum)
  VALUES ('advisor', 'handoff_urgent_days', '30', 'finance', 'integer', 1, 365)
  ON CONFLICT (category, key) DO UPDATE SET value = '30';
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  DELETE FROM agent.handoff_tasks;
  DELETE FROM agent.chat_prompts;
  DELETE FROM core.notification_state WHERE source = 'advisor_hint';

  -- Konto ins Minus in 3 Tagen (urgent), Sparplan zehrt ein Konto in einigen Wochen auf (after_plan), veralteter Auszug
  v_low := (finance.fn_create_account('{"name":"__hint_low__","account_type":"cash","currency":"EUR","opening_balance":100}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_add_recurring_payment(v_low, -500, '__hint_low_miete__', 1::smallint, 'month'::finance.schedule_unit, NULL::smallint, t + 3, t + 3, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_low, 2000, '__hint_low_gehalt__', 1::smallint, 'month'::finance.schedule_unit, NULL::smallint, t + 20, t + 20, NULL, NULL, NULL);
  v_fund := (finance.fn_create_account('{"name":"__hint_fund__","account_type":"cash","currency":"EUR","opening_balance":1000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, plan_execution_days)
    VALUES ('__hint_fund_depot__', 'stocks_depot', 'EUR', 'active', v_fund, '{}');
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name', '__hint_fund_plan__', 'depot_name', '__hint_fund_depot__', 'isin', 'HINT00000001',
            'symbol', 'HINTETF', 'security_name', 'Hint ETF', 'amount', 100, 'schedule_interval', 1, 'schedule_unit', 'week', 'first_payment_date', (t + 2)::text));
  v_hist := (finance.fn_create_account('{"name":"__hint_hist__","account_type":"cash","currency":"EUR","opening_balance":300}'::jsonb)->>'account_id')::int;
  UPDATE finance.accounts SET opening_balance_date = t - 160, min_balance = 1000, last_reconciled_at = t - 100 WHERE id = v_hist;
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_hist, t - 130, t - 100, 600, 300, 'EUR', 5, 0, -300, 0, NULL);

  -- ---------- 1) Klassen ----------
  v := finance.fn_advisor_hints('finance');
  SELECT e->>'key' INTO v_klow FROM jsonb_array_elements(v) e WHERE e->>'account' = '__hint_low__';
  SELECT e->>'key' INTO v_kfund FROM jsonb_array_elements(v) e WHERE e->>'account' = '__hint_fund__';
  IF v_klow IS DISTINCT FROM 'account_coverage:' || v_low OR v_kfund IS DISTINCT FROM 'savings_funding:' || v_fund THEN
    RAISE EXCEPTION 'FAIL [1 keys]: %', v; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object('key', v_klow, 'class', 'urgent')))
     OR NOT (v @> jsonb_build_array(jsonb_build_object('key', v_kfund, 'class', 'after_plan')))
     OR NOT (v @> jsonb_build_array(jsonb_build_object('key', 'statement_stale:' || v_hist, 'class', 'monthly_check'))) THEN
    RAISE EXCEPTION 'FAIL [1 Klassen]: %', v; END IF;
  -- eine offene Vormerkung nennt das Konto -> der Hinweis gehoert zum Eintragen
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, payload, text)
  VALUES ('finance', 'finance', 'erika', 'wealth_building', 'savings_plan', '{"plan":"__hint_fund_plan__","account":"__hint_fund__"}', 'Sparplan anpassen');
  IF NOT (finance.fn_advisor_hints('finance') @> jsonb_build_array(jsonb_build_object('key', v_kfund, 'class', 'entry'))) THEN
    RAISE EXCEPTION 'FAIL [1 entry]: %', finance.fn_advisor_hints('finance'); END IF;
  RAISE NOTICE 'PASS [1 Klassen]';

  -- ---------- 2) Snapshot ohne und mit Entwurf ----------
  v := finance.fn_advisor_snapshot();
  IF NOT (v->'warnings' @> jsonb_build_array(jsonb_build_object('key', v_klow, 'class', 'urgent', 'kind', 'account_coverage')))
     OR NOT (v->'warnings' @> jsonb_build_array(jsonb_build_object('key', v_kfund, 'class', 'entry')))
     OR v->'warnings' @? '$[*] ? (@.class == "monthly_check")' OR v ? 'hints_held' THEN
    RAISE EXCEPTION 'FAIL [2 ohne Entwurf]: %', v->'warnings'; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','household_basics',
         'topic','Haushalt','section_content','Haushalt laut Daten bestätigt.'));
  v := finance.fn_advisor_snapshot();
  IF jsonb_array_length(v->'warnings') <> 1 OR v->'warnings'->0->>'key' <> v_klow
     OR (v->'hints_held'->>'entry')::int <> 1 OR (v->'hints_held'->>'monthly_check')::int <> 1 OR (v->'hints_held'->>'after_plan')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [2 mit Entwurf]: %', v; END IF;
  RAISE NOTICE 'PASS [2 Snapshot]';

  -- ---------- 3) DB-eigene Frage der Art hint ----------
  -- pausierter Entwurf (aelter als 2 Stunden): kein Plan-Gespraech -> keine Hinweis-Karte in fremden Gespraechen
  ALTER TABLE agent.advisor_plans DISABLE TRIGGER trg_advisor_plans_touch;
  UPDATE agent.advisor_plans SET updated_at = now() - interval '3 hours' WHERE domain = 'finance' AND status = 'draft';
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',true));
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 pausierter Entwurf]: %', r; END IF;
  -- dieselbe Regel im Snapshot: ein pausierter Entwurf haelt die nicht dringenden Hinweise nicht mehr zurueck
  IF (core.fn_advisor_hint_state('finance')->>'draft_open')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [3 pausierter Entwurf gilt im Snapshot als offen]: %', core.fn_advisor_hint_state('finance'); END IF;
  UPDATE agent.advisor_plans SET updated_at = now() WHERE domain = 'finance' AND status = 'draft';
  ALTER TABLE agent.advisor_plans ENABLE TRIGGER trg_advisor_plans_touch;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',true));
  IF (r->>'send')::boolean IS NOT TRUE OR r->>'kind' <> 'hint' OR r->'card'->'lines'->0->>'kind' <> 'warning' THEN
    RAISE EXCEPTION 'FAIL [3 Hinweis-Karte]: %', r; END IF;
  v_id := (r->>'prompt_id')::bigint;
  IF (SELECT payload->>'key' FROM agent.chat_prompts WHERE id = v_id) <> v_klow THEN RAISE EXCEPTION 'FAIL [3 key]'; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:later', v_id), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'none' THEN RAISE EXCEPTION 'FAIL [3 spaeter]: %', r; END IF;
  IF finance.fn_advisor_snapshot()->'warnings' @? '$[*] ? (@.class == "urgent")' THEN
    RAISE EXCEPTION 'FAIL [3 stillgelegt fehlt im Snapshot]: %', finance.fn_advisor_snapshot()->'warnings'; END IF;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',true));
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 kommt nicht wieder]: %', r; END IF;
  -- Jetzt klaeren: Auftrag an den Berater (Merker zurueck, neue Zeile fuer denselben Hinweis gibt es in diesem Gespraech nicht)
  DELETE FROM core.notification_state WHERE source = 'advisor_hint';
  DELETE FROM agent.chat_prompts WHERE kind = 'hint';
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',true));
  v_id := (r->>'prompt_id')::bigint;
  r := core.fn_dispatch_callback(jsonb_build_object('data', format('q:%s:now', v_id), 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'continue' OR r->'continue'->>'agent' <> 'agent.finance_advisor'
     OR r->'continue'->>'as' <> 'task' THEN
    RAISE EXCEPTION 'FAIL [3 jetzt klaeren]: %', r; END IF;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',true));
  IF (r->>'send')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 einmal je Gespraech]: %', r; END IF;
  RAISE NOTICE 'PASS [3 Frage der Art hint]';

  -- ---------- 4) defer per Werkzeug ----------
  r := agent.fn_advisor_defer_hint(jsonb_build_object('domain','finance','chat_id','111','key','account_coverage:999999'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'unknown_hint' THEN RAISE EXCEPTION 'FAIL [4 unknown_hint]: %', r; END IF;
  r := agent.fn_advisor_defer_hint(jsonb_build_object('domain','finance','chat_id','111','key', v_klow));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'key' <> v_klow THEN RAISE EXCEPTION 'FAIL [4 defer]: %', r; END IF;
  IF finance.fn_advisor_snapshot()->'warnings' @? '$[*] ? (@.class == "urgent")' THEN
    RAISE EXCEPTION 'FAIL [4 stillgelegt]'; END IF;
  RAISE NOTICE 'PASS [4 defer]';

  -- ---------- 5) brennt UND eine Vormerkung nennt das Konto -> urgent mit [Jetzt eintragen] ----------
  DELETE FROM core.notification_state WHERE source = 'advisor_hint';
  DELETE FROM agent.chat_prompts WHERE kind = 'hint';
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, payload, text)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'recurring_transfer', '{"account":"__hint_low__"}', 'Dauerauftrag einrichten');
  v := finance.fn_advisor_hints('finance');
  IF NOT (v @> jsonb_build_array(jsonb_build_object('key', v_klow, 'class', 'urgent', 'pending_entry', true))) THEN
    RAISE EXCEPTION 'FAIL [5 bald + Vormerkung bleibt urgent]: %', v; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object('key', v_kfund, 'class', 'entry'))) THEN
    RAISE EXCEPTION 'FAIL [5 nicht bald + Vormerkung bleibt still]: %', v; END IF;
  IF NOT (finance.fn_advisor_snapshot()->'warnings' @> jsonb_build_array(jsonb_build_object('key', v_klow, 'class', 'urgent'))) THEN
    RAISE EXCEPTION 'FAIL [5 Snapshot zeigt die Warnung]'; END IF;
  r := core.fn_next_chat_prompt(jsonb_build_object('chat_id','111','replied',true));
  IF (r->>'send')::boolean IS NOT TRUE OR r->'buttons'->0->0->>'data' NOT LIKE 'q:%:enter' THEN
    RAISE EXCEPTION 'FAIL [5 Karte mit Jetzt eintragen]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data', r->'buttons'->0->0->>'data', 'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'then' <> 'continue' OR position('enter' IN r->'continue'->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL [5 Tipp Jetzt eintragen]: %', r; END IF;
  RAISE NOTICE 'PASS [5 brennt trotz Vormerkung]';
END $$;

ROLLBACK;
