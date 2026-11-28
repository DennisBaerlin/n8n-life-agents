-- tests/db/finance/test_fn_set_savings_plan_end.sql
-- Kuenftiges Sparplan-Ende ueber fn_set_savings_plan(valid_to): Ende am Kopf der Kette (Status unveraendert),
--   letzte Ausfuehrung = letzter Rasterpunkt davor (fn_recurring_last_due), Karte (bank_stop_until + Erinnerungs-Zeile nur bei
--   eingeschalteter Bank-Erinnerung), Konto-Vorschau ohne Raten danach, Ablehnungen (Ende nicht in der Zukunft, keine Ausfuehrung
--   mehr davor, zusammen mit anderen Aenderungen, schon beendete Kette, ungueltiger Monat), Verlaengern, Monat mit und ohne
--   Jahr, Probelauf ohne Write, geplante Aenderung, letzte Ausfuehrung heute, Bank-Ende-Erinnerung (fn_bank_end_due) faellig
--   ab L+3, Plan-Aufgabe (handoff) wird erledigt. Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_today  date := core.fn_today();
  -- 15. des Folgemonats: liegt immer nach heute und weit weg von Monatsenden
  a        date := (date_trunc('month', core.fn_today()) + interval '1 month' + interval '14 days')::date;
  v_settle int; v_depot int; v_plan int; v_rp int; v_rp_b int; v_task int;
  r        jsonb;
  v_note   jsonb;
  v_n      int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 't', NULL, 'lazy', 'f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','__spe_owner__','first_name','Olli','last_name','Muster','role','owner',
                       'birth_date','1980-01-01','telegram_user_id',7501)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES
    ('remind_bank_end', 'finance', 'household', true)
  ON CONFLICT (cron_key) DO UPDATE SET scope = excluded.scope, default_enabled = excluded.default_enabled;
  INSERT INTO core.config (package, category, key, value) VALUES ('finance', 'cron_enable', 'remind_bank_end', 'true')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true';

  r := finance.fn_create_account('{"name":"__spe_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb);
  v_settle := (r->>'account_id')::int;
  r := finance.fn_create_account(jsonb_build_object('name','__spe_depot__','account_type','stocks_depot',
         'account_holder','Test','currency','EUR','settlement_id', v_settle));
  v_depot := (r->>'account_id')::int;
  UPDATE finance.accounts SET plan_execution_days = '{}', bank = 'Testbroker' WHERE id = v_depot;

  r := finance.fn_create_savings_plan(jsonb_build_object('name','__spe_plan__','depot_name','__spe_depot__',
         'isin','IE00B3RBWM25','symbol','VWCE','security_name','Test ETF','amount',100,
         'schedule_interval',1,'schedule_unit','month','first_payment_date', a::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP FAIL create: %', r; END IF;
  v_plan := (r->>'savings_plan_id')::int;
  v_rp   := (r->>'recurring_payment_id')::int;

  -- [1] Ende ist kein Ausfuehrungstag: letzte Ausfuehrung = letzter Rasterpunkt davor
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__',
         'valid_to', (a + interval '2 months' + interval '10 days')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'last_execution')::date IS DISTINCT FROM (a + interval '2 months')::date
     OR (r->>'split')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1 Ende gesetzt]: %', r; END IF;
  IF (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM (a + interval '2 months' + interval '11 days')::date
     OR (SELECT status FROM finance.recurring_payments WHERE id = v_rp) <> 'active'
     OR (SELECT status FROM finance.savings_plans WHERE id = v_plan) <> 'active' THEN
    RAISE EXCEPTION 'FAIL [1 Kette]: valid_to/status falsch'; END IF;
  IF (SELECT last_execution FROM finance.savings_plan_overview WHERE id = v_plan) IS DISTINCT FROM (a + interval '2 months')::date
     OR (SELECT last_valid_day FROM finance.savings_plan_overview WHERE id = v_plan) IS DISTINCT FROM (a + interval '2 months' + interval '10 days')::date THEN
    RAISE EXCEPTION 'FAIL [1 Uebersicht]: %', (SELECT to_jsonb(o) FROM finance.savings_plan_overview o WHERE id = v_plan); END IF;
  RAISE NOTICE 'PASS [1] Ende + letzte Ausfuehrung + Uebersicht';

  -- [2] Karte: Bank-Hinweis mit Datum der letzten Ausfuehrung + Erinnerungs-Zeile (Bank-Erinnerung an)
  SELECT e INTO v_note FROM jsonb_array_elements(r->'card_lines') e WHERE e->>'value' = 'finance.note.bank_stop_savings_plan_until';
  IF v_note IS NULL OR v_note->'params'->>'bank' IS DISTINCT FROM 'Testbroker'
     OR v_note->'params'->'date' IS DISTINCT FROM core.fn_ui_date((a + interval '2 months')::date) THEN
    RAISE EXCEPTION 'FAIL [2 Bank-Hinweis]: %', r->'card_lines'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') e WHERE e->>'value' = 'finance.note.savings_plan_end_reminder') THEN
    RAISE EXCEPTION 'FAIL [2 Erinnerungs-Zeile fehlt]: %', r->'card_lines'; END IF;
  RAISE NOTICE 'PASS [2] Karte';

  -- [3] Konto-Vorschau: drei Raten bis zur letzten Ausfuehrung, danach keine
  SELECT count(*) INTO v_n FROM finance.fn_account_planned_flows(v_settle, v_today, (a + interval '2 months')::date) f
   WHERE f.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
  IF v_n <> 3 THEN RAISE EXCEPTION 'FAIL [3 Raten bis zum Ende]: %', v_n; END IF;
  SELECT count(*) INTO v_n FROM finance.fn_account_planned_flows(v_settle, (a + interval '2 months' + interval '1 day')::date,
                                                                 (a + interval '12 months')::date) f
   WHERE f.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [3 Raten nach dem Ende]: %', v_n; END IF;
  RAISE NOTICE 'PASS [3] Konto-Vorschau';

  -- [4] Ende heute -> abgelehnt, kein Write
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','valid_to', v_today::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'end_not_future'
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM (a + interval '2 months' + interval '11 days')::date THEN
    RAISE EXCEPTION 'FAIL [4 Ende nicht in der Zukunft]: %', r; END IF;
  RAISE NOTICE 'PASS [4] Ende <= heute';

  -- [5] keine Ausfuehrung mehr vor dem Ende -> abgelehnt mit fruehestem moeglichem Ende
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','valid_to', (a - 1)::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'no_execution_before_end'
     OR (r->>'earliest_end')::date IS DISTINCT FROM a THEN
    RAISE EXCEPTION 'FAIL [5 keine Ausfuehrung]: %', r; END IF;
  RAISE NOTICE 'PASS [5] keine Ausfuehrung vor dem Ende';

  -- [6] Ende zusammen mit Betrag/Status -> eigener Schritt
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','new_amount',150,
         'valid_to', (a + interval '3 months')::date::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'end_separately' THEN
    RAISE EXCEPTION 'FAIL [6 Betrag + Ende]: %', r; END IF;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','status','paused',
         'valid_to', (a + interval '3 months')::date::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'end_separately' THEN
    RAISE EXCEPTION 'FAIL [6 Status + Ende]: %', r; END IF;
  -- Betrag aendern und pausieren in einem Aufruf -> eigener Schritt (die Pause fiele sonst still weg)
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','new_amount',150,'status','paused'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'status_separately' THEN
    RAISE EXCEPTION 'FAIL [6 Betrag + Status]: %', r; END IF;
  -- unbekannter Status -> Ablehnung statt Abbruch
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','status','ruhend'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6 unbekannter Status]: %', r; END IF;
  RAISE NOTICE 'PASS [6] eigener Schritt';

  -- [7] Probelauf schreibt nichts, nennt aber die letzte Ausfuehrung
  r := core.fn_dry_run('finance.fn_set_savings_plan(jsonb)'::regprocedure, jsonb_build_object('savings_plan_name','__spe_plan__',
         'valid_to', (a + interval '4 months' + interval '3 days')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'last_execution')::date IS DISTINCT FROM (a + interval '4 months')::date
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM (a + interval '2 months' + interval '11 days')::date THEN
    RAISE EXCEPTION 'FAIL [7 Probelauf]: %', r; END IF;
  RAISE NOTICE 'PASS [7] Probelauf';

  -- [8] Verlaengern: spaeteres Ende ersetzt das alte
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__',
         'valid_to', (a + interval '4 months' + interval '3 days')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR finance.fn_recurring_last_due(v_rp) IS DISTINCT FROM (a + interval '4 months')::date THEN
    RAISE EXCEPTION 'FAIL [8 Verlaengern]: %', r; END IF;
  RAISE NOTICE 'PASS [8] Verlaengern';

  -- [9] Bank-Ende-Erinnerung: faellig ab L+3, nicht an L+2
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_bank_end_due((a + interval '4 months')::date + 3)) e
                  WHERE (e->>'head')::int = v_rp AND e->>'kind' = 'savings_plan' AND e->>'name' = '__spe_plan__') THEN
    RAISE EXCEPTION 'FAIL [9 Erinnerung L+3]'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_bank_end_due((a + interval '4 months')::date + 2)) e
              WHERE (e->>'head')::int = v_rp) THEN
    RAISE EXCEPTION 'FAIL [9 Erinnerung L+2 zu frueh]'; END IF;
  RAISE NOTICE 'PASS [9] Bank-Ende-Erinnerung';

  -- [10] Bank-Erinnerung aus -> keine Erinnerungs-Zeile auf der Karte
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'remind_bank_end';
  r := core.fn_dry_run('finance.fn_set_savings_plan(jsonb)'::regprocedure, jsonb_build_object('savings_plan_name','__spe_plan__',
         'valid_to', (a + interval '5 months')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') e WHERE e->>'value' = 'finance.note.savings_plan_end_reminder') THEN
    RAISE EXCEPTION 'FAIL [10 Erinnerung aus]: %', r; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'remind_bank_end';
  RAISE NOTICE 'PASS [10] Erinnerung aus';

  -- [11] geplante Aenderung: Ende vor ihrem Start -> keine Ausfuehrung mehr am Kopf; danach -> Kopf traegt es
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__spe_plan_b__','depot_name','__spe_depot__',
         'isin','IE00B3RBWM25','symbol','VWCE','security_name','Test ETF','amount',50,
         'schedule_interval',1,'schedule_unit','month','first_payment_date', a::text));
  v_rp_b := (r->>'recurring_payment_id')::int;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_b__','new_amount',80,
         'valid_from', (a + interval '1 month')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP FAIL [11 Split]: %', r; END IF;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_b__','valid_to', (a + 10)::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'no_execution_before_end'
     OR (r->>'earliest_end')::date IS DISTINCT FROM (a + interval '1 month')::date THEN
    RAISE EXCEPTION 'FAIL [11 vor der Aenderung]: %', r; END IF;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_b__',
         'valid_to', (a + interval '1 month' + interval '5 days')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'last_execution')::date IS DISTINCT FROM (a + interval '1 month')::date
     OR (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp_b) IS DISTINCT FROM (a + interval '1 month')::date THEN
    RAISE EXCEPTION 'FAIL [11 nach der Aenderung]: % / %', r,
      (SELECT valid_to FROM finance.recurring_payments WHERE id = v_rp_b); END IF;
  RAISE NOTICE 'PASS [11] geplante Aenderung';

  -- [12] Plan-Aufgabe "Sparplan endet nach ..." wird mit dem Ende erledigt
  DELETE FROM agent.handoff_tasks;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','__spe_owner__','s','savings_plan','Sparplan endet nach dem fuenften Monat','working',now())
    RETURNING id INTO v_task;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','handoff_task_id', v_task::text,
         'chat_id','7501','valid_to', (a + interval '5 months' + interval '2 days')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_task) <> 'done'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') e WHERE e->>'value' = 'core.hitl.handoff_note') THEN
    RAISE EXCEPTION 'FAIL [12 Plan-Aufgabe]: %', r; END IF;
  RAISE NOTICE 'PASS [12] Plan-Aufgabe';

  -- [13] Monat statt Tag ("nach dem Monat X"): Ende = letzter Tag dieses Monats, die fn rechnet ihn
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__',
         'valid_to', to_char(a + interval '6 months', 'YYYY-MM')));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'last_execution')::date IS DISTINCT FROM (a + interval '6 months')::date
     OR (r->>'last_valid_day')::date IS DISTINCT FROM (date_trunc('month', a + interval '7 months') - interval '1 day')::date THEN
    RAISE EXCEPTION 'FAIL [13 Monat]: %', r; END IF;
  RAISE NOTICE 'PASS [13] Monat';

  -- [14] Monat ohne Jahr: die DB nimmt das naechste Vorkommen dieses Monats (7 Monate voraus = dieses oder naechstes Jahr)
  r := core.fn_dry_run('finance.fn_set_savings_plan(jsonb)'::regprocedure, jsonb_build_object('savings_plan_name','__spe_plan__',
         'valid_to', to_char(a + interval '6 months', 'MM')));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'last_execution')::date IS DISTINCT FROM (a + interval '6 months')::date THEN
    RAISE EXCEPTION 'FAIL [14 Monat ohne Jahr]: %', r; END IF;
  RAISE NOTICE 'PASS [14] Monat ohne Jahr';

  -- [15] ungueltiger Monat -> korrigierbare Ablehnung statt Ausnahme
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','valid_to','2030-13'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'invalid_date' THEN
    RAISE EXCEPTION 'FAIL [15 Monat 13]: %', r; END IF;
  RAISE NOTICE 'PASS [15] ungueltiger Monat';

  -- [16] Ablehnungstext nennt das frueheste Ende als Datum (das Modell sieht nur reason)
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan__','valid_to', (a - 1)::text));
  IF position(a::text IN r->>'reason') = 0 THEN RAISE EXCEPTION 'FAIL [16 Datum im Text]: %', r; END IF;
  RAISE NOTICE 'PASS [16] Datum im Ablehnungstext';

  -- [17] schon beendete Kette wird nicht still verlaengert (die Luecke wuerde faellig) -> plan_ended
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__spe_plan_c__','depot_name','__spe_depot__',
         'isin','IE00B3RBWM25','symbol','VWCE','security_name','Test ETF','amount',30,
         'schedule_interval',1,'schedule_unit','month','first_payment_date', a::text));
  UPDATE finance.recurring_payments SET valid_to = v_today WHERE id = (r->>'recurring_payment_id')::int;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_c__',
         'valid_to', (a + interval '2 months')::date::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'plan_ended' THEN
    RAISE EXCEPTION 'FAIL [17 beendet]: %', r; END IF;
  RAISE NOTICE 'PASS [17] beendete Kette';

  -- [18] letzte Ausfuehrung heute: Karte sagt "jetzt beenden" (ohne _until) und verspricht keine Erinnerung (die Karte
  --      hat sie schon gesagt, fn_bank_stop_note_told merkt das); ist die heutige schon erledigt -> keine Ausfuehrung mehr
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__spe_plan_d__','depot_name','__spe_depot__',
         'isin','IE00B3RBWM25','symbol','VWCE','security_name','Test ETF','amount',40,
         'schedule_interval',1,'schedule_unit','month','first_payment_date', v_today::text));
  v_rp_b := (r->>'recurring_payment_id')::int;
  IF finance.fn_recurring_next_due(v_rp_b, v_today) IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'SETUP FAIL [18 Termin heute]: %', finance.fn_recurring_next_due(v_rp_b, v_today); END IF;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_d__','valid_to', (v_today + 5)::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'last_execution')::date IS DISTINCT FROM v_today
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') e
                 WHERE e->>'value' IN ('finance.note.savings_plan_end_reminder', 'finance.note.bank_stop_savings_plan_until'))
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') e WHERE e->>'value' = 'finance.note.bank_stop_savings_plan') THEN
    RAISE EXCEPTION 'FAIL [18 heute]: %', r; END IF;
  INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date) VALUES (v_rp_b, v_today);
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_d__','valid_to', (v_today + 6)::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' IS DISTINCT FROM 'no_execution_before_end' THEN
    RAISE EXCEPTION 'FAIL [18 heute erledigt]: %', r; END IF;
  RAISE NOTICE 'PASS [18] letzte Ausfuehrung heute';

  -- [19] pausierter Plan bekommt das Ende, aber kein Erinnerungs-Versprechen (fn_bank_end_due meldet nur aktive Koepfe)
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__spe_plan_e__','depot_name','__spe_depot__',
         'isin','IE00B3RBWM25','symbol','VWCE','security_name','Test ETF','amount',50,
         'schedule_interval',1,'schedule_unit','month','first_payment_date', a::text));
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_e__','status','paused'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP FAIL [19 pausieren]: %', r; END IF;
  r := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__spe_plan_e__','valid_to', (a + interval '3 months')::date::text));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') e WHERE e->>'value' = 'finance.note.savings_plan_end_reminder') THEN
    RAISE EXCEPTION 'FAIL [19 pausiert mit Erinnerung]: %', r; END IF;
  RAISE NOTICE 'PASS [19] pausierter Plan ohne Erinnerung';
END $$;

ROLLBACK;
