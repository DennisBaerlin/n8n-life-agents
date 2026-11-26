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
  -- zweiter Teil derselben Aufgabe in derselben Runde (eine Vormerkung, mehrere Eintraege): erlaubt, Kartenzeile wieder da,
  -- die Aufgabe bleibt done
  r := finance.fn_create_recurring_payment(v_base || jsonb_build_object('name','__t_handoff_gehalt2','handoff_task_id', v_w1));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoff_task_id')::int <> v_w1 OR r->'card_lines'->-1->>'value' <> 'core.hitl.handoff_note'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w1) <> 'done' THEN RAISE EXCEPTION 'FAIL [5 zweiter Teil]: %', r; END IF;
  -- nach der Runde (Claim-Frist vorbei) -> abgelehnt (keine Doppelbuchung ueber eine alte Aufgabe)
  ALTER TABLE agent.handoff_tasks DISABLE TRIGGER trg_handoff_tasks_final;
  UPDATE agent.handoff_tasks SET claimed_at = now() - interval '5 hours', closed_at = now() - interval '4 hours' WHERE id = v_w1;
  ALTER TABLE agent.handoff_tasks ENABLE TRIGGER trg_handoff_tasks_final;
  r := finance.fn_create_recurring_payment(v_base || jsonb_build_object('name','__t_handoff_gehalt3','handoff_task_id', v_w1));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [5 alte Runde]: %', r; END IF;
  RAISE NOTICE 'PASS [5 Erfolg atomar, mehrere Teile]';

  -- 6) jede Ziel-fn kennt handoff_task_id (Pruefung vor jedem eigenen Schritt)
  FOREACH f IN ARRAY ARRAY['finance.fn_create_savings_goal', 'finance.fn_set_savings_goal', 'finance.fn_create_savings_plan',
                           'finance.fn_set_savings_plan', 'finance.fn_create_recurring_payment', 'finance.fn_create_recurring_transfer',
                           'finance.fn_set_recurring_payment', 'finance.fn_create_pension', 'finance.fn_set_pension'] LOOP
    EXECUTE format('SELECT %s($1)', f) INTO r USING jsonb_build_object('handoff_task_id', '999999', 'chat_id', '111');
    IF r->>'code' IS DISTINCT FROM 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [6 %]: %', f, r; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [6 neun Ziel-fns]';

  -- 7) Ueberspringen-Tool-fn
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_w2, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'card_lines'->0->'params'->>'text' <> 'Haftpflicht prüfen'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w2) <> 'working' THEN RAISE EXCEPTION 'FAIL [7 Probelauf]: %', r; END IF;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_w2, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'open' THEN RAISE EXCEPTION 'FAIL [7 skipped bleibt offen]: %', r; END IF;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_w3, 'chat_id', '111', 'reason', 'done_elsewhere'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w3) <> 'done' THEN RAISE EXCEPTION 'FAIL [7 done_elsewhere]: %', r; END IF;
  RAISE NOTICE 'PASS [7 cancel]';
END $$;

-- 8-10) Werkzeuge, die eine Vormerkung bisher still offen liessen: Dauerauftrag aendern, Rente anlegen und aendern.
--       Dazu der Bank-Punkt aus dem Eintragen: traegt seine Vormerkung, die Karte nur die Kurz-Zeile.
INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES ('remind_bank_todo', 'finance', 'household', TRUE), ('plan_rollout', 'core', 'household', TRUE)
ON CONFLICT (cron_key) DO UPDATE SET scope = excluded.scope;
INSERT INTO core.config (package, category, key, value) VALUES ('finance', 'cron_enable', 'remind_bank_todo', 'true'), ('core', 'cron_enable', 'plan_rollout', 'true')
ON CONFLICT (category, key) DO UPDATE SET value = 'true';
DO $$
DECLARE
  r      jsonb;
  v_a    int; v_b int; v_rp int; v_pen int;
  v_t8 int; v_t9 int; v_t10 int; v_t11 int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, bank) VALUES ('__t_ho_giro', 'cash', 'EUR', 'Musterbank') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, bank) VALUES ('__t_ho_tages', 'cash', 'EUR', 'Musterbank') RETURNING id INTO v_b;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','erika','s','recurring_transfer','Übertrag künftig am 1.','working',now()) RETURNING id INTO v_t8;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','erika','s','other','Betriebsrente ohne Betrag erfassen','working',now()) RETURNING id INTO v_t9;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','erika','s','other','Betriebsrente: Anbieter nachtragen','working',now()) RETURNING id INTO v_t10;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES
    ('finance','finance','erika','s','recurring_transfer','Übertrag 50 € aufs Tagesgeld','working',now()) RETURNING id INTO v_t11;

  -- ausserhalb des Eintragens: ganzer Bank-Absatz, Bank-Punkt ohne Vormerkung
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_ho_uebertrag','from_account_id',v_a,'to_account_id',v_b,'amount',100,
         'schedule_unit','month','schedule_day_of_month',20,'first_payment_date',(core.fn_today() + 40)::text));
  v_rp := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' LIKE 'finance.note.bank_setup_standing_order%')
     OR (SELECT handoff_task_id FROM finance.bank_todos WHERE head_id = v_rp AND status = 'open') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [8 ohne Vormerkung]: %', r; END IF;

  -- 8) Dauerauftrag aendern mit Vormerkung: done im selben Write, Kurz-Zeile statt Absatz, Bank-Punkt traegt die Vormerkung
  r := core.fn_dry_run('finance.fn_set_recurring_payment(jsonb)'::regprocedure,
         jsonb_build_object('recurring_payment_id', v_rp, 'schedule_day_of_month', 1, 'chat_id', '111', 'handoff_task_id', v_t8::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'card_lines'->-1->>'value' <> 'core.hitl.handoff_note'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t8) <> 'working' THEN RAISE EXCEPTION 'FAIL [8 Probelauf]: %', r; END IF;
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'schedule_day_of_month', 1, 'chat_id', '111', 'handoff_task_id', v_t8::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoff_task_id')::int <> v_t8
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t8) <> 'done' THEN RAISE EXCEPTION 'FAIL [8 set_recurring_payment]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'finance.bank_note.on_list')
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' LIKE 'finance.note.bank_%') THEN
    RAISE EXCEPTION 'FAIL [8 Kurz-Zeile statt Absatz]: %', r->'card_lines'; END IF;
  IF (SELECT handoff_task_id FROM finance.bank_todos WHERE head_id = finance.fn_recurring_lineage_head(v_rp) AND status = 'open') IS DISTINCT FROM v_t8 THEN
    RAISE EXCEPTION 'FAIL [8 Bank-Punkt ohne Vormerkung]'; END IF;
  -- dieselbe Aenderung noch einmal mit derselben Vormerkung: Wiederholung, abgelehnt (ein weiterer Teil legt nur Neues an)
  r := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_rp, 'schedule_day_of_month', 2, 'chat_id', '111', 'handoff_task_id', v_t8::text));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [8 set zweimal]: %', r; END IF;
  -- der Verweis reicht nicht ueber den Write hinaus
  IF NULLIF(current_setting('finance.handoff_task_id', true), '') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [8 Verweis bleibt stehen]'; END IF;
  RAISE NOTICE 'PASS [8 set_recurring_payment]';

  -- 9) Rente anlegen mit Vormerkung
  r := finance.fn_create_pension(jsonb_build_object('name','__t_ho_brente','pension_type','occupational','chat_id','111','handoff_task_id', v_t9::text));
  v_pen := (r->>'pension_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_pen IS NULL OR (r->>'handoff_task_id')::int <> v_t9
     OR r->'card_lines'->-1->>'value' <> 'core.hitl.handoff_note'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t9) <> 'done' THEN RAISE EXCEPTION 'FAIL [9 create_pension]: %', r; END IF;
  -- 10) Rente aendern mit Vormerkung
  r := finance.fn_set_pension(jsonb_build_object('pension_id', v_pen, 'provider', 'Muster-Versorgungskasse', 'chat_id', '111', 'handoff_task_id', v_t10::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoff_task_id')::int <> v_t10
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t10) <> 'done' THEN RAISE EXCEPTION 'FAIL [10 set_pension]: %', r; END IF;
  RAISE NOTICE 'PASS [9-10 Renten]';

  -- 11) neuer Dauerauftrag im Eintragen: Bank-Punkt mit Vormerkung, Kurz-Zeile
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_ho_uebertrag2','from_account_id',v_a,'to_account_id',v_b,'amount',50,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111','handoff_task_id',v_t11::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t11) <> 'done'
     OR (SELECT handoff_task_id FROM finance.bank_todos WHERE head_id = (r->>'recurring_payment_id')::int) IS DISTINCT FROM v_t11
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'finance.bank_note.on_list') THEN
    RAISE EXCEPTION 'FAIL [11 create_recurring_transfer]: %', r; END IF;
  -- Bank-Liste abgeschaltet: dann kaeme keine Liste, die Karte behaelt den ganzen Absatz
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'remind_bank_todo';
  r := core.fn_dry_run('finance.fn_create_recurring_transfer(jsonb)'::regprocedure, jsonb_build_object('name','__t_ho_uebertrag3','from_account_id',v_a,'to_account_id',v_b,
         'amount',30,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111','handoff_task_id',v_t11::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' LIKE 'finance.note.bank_setup_standing_order%') THEN
    RAISE EXCEPTION 'FAIL [11 Schalter aus -> Absatz]: %', r; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'remind_bank_todo';
  RAISE NOTICE 'PASS [11 Bank-Punkt im Eintragen]';
END $$;

ROLLBACK;
