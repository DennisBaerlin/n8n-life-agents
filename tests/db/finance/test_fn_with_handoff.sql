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
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT x->'params'->>'text' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'core.hitl.handoff_note') <> 'Haftpflicht prüfen'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_w2) <> 'working' THEN RAISE EXCEPTION 'FAIL [7 Probelauf]: %', r; END IF;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_w2, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'open' THEN RAISE EXCEPTION 'FAIL [7 skipped bleibt offen]: %', r; END IF;
  INSERT INTO finance.insurances (name, valid_from) VALUES ('__t_handoff_hausrat', CURRENT_DATE);
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_w3, 'chat_id', '111', 'reason', 'done_elsewhere',
         'ref_type', 'insurance', 'ref_name', '__t_handoff_hausrat'));
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
  -- Karte: Stelle, Vereinbart, dann "bisher -> neu" fuer den Tag (Ist-Wert aus den Daten, nicht vom Modell)
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'card_lines'->-2->>'value' <> 'core.hitl.handoff_note'
     OR r->'card_lines'->-3->>'value' <> 'core.hitl.handoff_pos'
     OR r->'card_lines'->-1->>'value' <> 'core.hitl.value_before_after'
     OR r->'card_lines'->-1->'params'->'field'->>'value' <> 'finance.handoff.field.day'
     OR (r->'card_lines'->-1->'params'->'before'->'params'->>'day')::int <> 20
     OR (r->'card_lines'->-1->'params'->'after'->'params'->>'day')::int <> 1
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

  -- eingetragen wird, welche Sache betroffen war (entered_refs), nie ein gespeicherter Unterschied
  IF (SELECT entered_refs FROM agent.handoff_tasks WHERE id = v_t8) IS DISTINCT FROM
       jsonb_build_array(jsonb_build_object('type','recurring_payment','id',(SELECT r2.id FROM finance.recurring_payments r2
                                                                              WHERE r2.name = '__t_ho_uebertrag' ORDER BY r2.id DESC LIMIT 1)))
     OR (SELECT entered_refs->0->>'type' FROM agent.handoff_tasks WHERE id = v_t9) <> 'pension'
     OR (SELECT (entered_refs->0->>'id')::int FROM agent.handoff_tasks WHERE id = v_t10) <> v_pen THEN
    RAISE EXCEPTION 'FAIL [11 entered_refs]: % / %', (SELECT entered_refs FROM agent.handoff_tasks WHERE id = v_t8),
      (SELECT entered_refs FROM agent.handoff_tasks WHERE id = v_t9); END IF;
  RAISE NOTICE 'PASS [11 entered_refs]';
END $$;

-- 12) Eintrag mit Grund, Rest und vereinbartem Soll: Kartenzeilen in der Reihenfolge Stelle, Vereinbart, Warum, Rest;
--     der Rest bleibt nach dem Abschluss offen; Abweichung vom Soll steht im Ergebnis (handoff_diff), gespeichert wird sie nicht;
--     ein weiterer Teil derselben Runde haengt seine Sache an.
DO $$
DECLARE
  r     jsonb;
  v_a   int; v_b int;
  v_t   int; v_t2 int;
  v_l   jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_h12_giro', 'cash', 'EUR') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_h12_tages', 'cash', 'EUR') RETURNING id INTO v_b;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
  VALUES ('finance', NULL, 'T', 'active', 1, jsonb_build_object('goals_triggers', jsonb_build_object('topics', jsonb_build_array(
    jsonb_build_object('topic', 'Ruecklage', 'content', 'c', 'open_points', jsonb_build_array(
      jsonb_build_object('id', 7, 'text', 'Rest einmal ueberweisen')))))));
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, why, open_point_id, wanted, status, claimed_at)
  VALUES ('finance','finance','erika','goals_triggers','Ruecklage','recurring_transfer','Monatlich 300 € zur Rücklage',
          'So ist das Geld bis zum Termin da.', 7,
          jsonb_build_array(
            jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('amount',300,'schedule_day_of_month',1)),
            jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('amount',100,'schedule_day_of_month',1))),
          'working', now() - interval '3 minutes') RETURNING id INTO v_t;  -- eigene Runde: alle Aufgaben dieser Transaktion teilen sonst now()
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','goals_triggers','other','Zweiter Eintrag derselben Runde','working',
          (SELECT claimed_at FROM agent.handoff_tasks WHERE id = v_t)) RETURNING id INTO v_t2;

  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_h12_a','from_account_id',v_a,'to_account_id',v_b,'amount',300,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111',
         'handoff_task_id',v_t::text));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [12 Write]: %', r; END IF;
  SELECT jsonb_agg(x->>'value' ORDER BY n) INTO v_l
    FROM jsonb_array_elements(r->'card_lines') WITH ORDINALITY t(x, n) WHERE x->>'value' LIKE 'core.hitl.%';
  IF v_l IS DISTINCT FROM '["core.hitl.handoff_pos","core.hitl.handoff_note","core.hitl.handoff_why","core.hitl.handoff_rest"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [12 Reihenfolge]: %', v_l; END IF;
  IF (SELECT x->'params' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'core.hitl.handoff_pos')
       IS DISTINCT FROM '{"k": 1, "n": 2}'::jsonb
     OR (SELECT x->'params'->>'why' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'core.hitl.handoff_why') <> 'So ist das Geld bis zum Termin da.'
     OR (SELECT x->'params'->>'text' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'core.hitl.handoff_rest') <> 'Rest einmal ueberweisen' THEN
    RAISE EXCEPTION 'FAIL [12 Werte]: %', r->'card_lines'; END IF;
  -- erster von zwei vereinbarten Aufrufen: der zweite steht noch aus, das ist keine Abweichung
  IF r->'handoff_diff' IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [12 diff erster Teil]: %', r->'handoff_diff'; END IF;
  -- zweiter Teil mit anderem Betrag als vereinbart: angehaengt, Abweichung sichtbar
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_h12_b','from_account_id',v_a,'to_account_id',v_b,'amount',80,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111',
         'handoff_task_id',v_t::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length((SELECT entered_refs FROM agent.handoff_tasks WHERE id = v_t)) <> 2
     OR jsonb_array_length(r->'handoff_diff') <> 1 OR r->'handoff_diff'->0->>'field' <> 'amount'
     OR (r->'handoff_diff'->0->>'wanted')::numeric <> 100 OR (r->'handoff_diff'->0->>'current')::numeric <> 80 THEN
    RAISE EXCEPTION 'FAIL [12 zweiter Teil]: % / %', r->'handoff_diff', (SELECT entered_refs FROM agent.handoff_tasks WHERE id = v_t); END IF;
  -- abgeleitet ueber die Registry-fn, nicht gespeichert
  IF jsonb_array_length(finance.fn_handoff_diff(v_t)) <> 1 THEN RAISE EXCEPTION 'FAIL [12 fn_handoff_diff]: %', finance.fn_handoff_diff(v_t); END IF;
  IF finance.fn_handoff_diff(v_t2) IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [12 offen -> []]'; END IF;
  -- Rest bleibt offen
  IF core.fn_handoff_rest(v_t) IS DISTINCT FROM 'Rest einmal ueberweisen' THEN RAISE EXCEPTION 'FAIL [12 Rest geschlossen]'; END IF;
  RAISE NOTICE 'PASS [12 Grund, Rest, Soll]';
END $$;

-- 13) Rollen-Perspektive: der Write laeuft unter finance_rw (agent.* nur ueber die core-Fenster)
DO $$
DECLARE
  r   jsonb;
  v_a int; v_b int; v_t int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_h13_giro', 'cash', 'EUR') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_h13_tages', 'cash', 'EUR') RETURNING id INTO v_b;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, why, wanted, status, claimed_at)
  VALUES ('finance','finance','erika','s','recurring_transfer','Übertrag 40 €','Grund.',
          jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('amount',40)),'working', now())
  RETURNING id INTO v_t;
  SET LOCAL ROLE finance_rw;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_h13','from_account_id',v_a,'to_account_id',v_b,'amount',40,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',(core.fn_today() + 40)::text,'chat_id','111',
         'handoff_task_id',v_t::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'handoff_diff' IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [13 finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS [13 finance_rw]';
END $$;

-- 14) Abhaken "schon im System": nur mit gefundener Sache (sonst nothing_to_tick, keine Karte); die Karte zeigt, was im
--     System steht und was offen bleibt; die Sache wird als entered_refs vermerkt. Streichen zeigt den vereinbarten Satz.
DO $$
DECLARE
  r     jsonb;
  v_acc int; v_ins int; v_t int; v_t2 int; v_t3 int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_h14_giro', 'cash', 'EUR') RETURNING id INTO v_acc;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
  VALUES ('finance', NULL, 'T14', 'draft', 2, jsonb_build_object('s', jsonb_build_object('topics', jsonb_build_array(
    jsonb_build_object('topic', 'Vorsorge', 'content', 'c', 'open_points', jsonb_build_array(
      jsonb_build_object('id', 9, 'text', 'Betrag, sobald der Anbieter sich meldet')))))));
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, open_point_id, status, claimed_at)
  VALUES ('finance','finance','erika','s','Vorsorge','other','Betriebsrente eintragen',9,'working',now()) RETURNING id INTO v_t;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','Hausrat prüfen','working',now()) RETURNING id INTO v_t2;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','Sparbuch auflösen','working',now()) RETURNING id INTO v_t3;
  PERFORM finance.fn_create_pension(jsonb_build_object('name','__t_h14_brente','pension_type','occupational'));

  -- ohne genannte Sache / Sache nicht gefunden -> nothing_to_tick, Aufgabe bleibt working
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'reason', 'done_elsewhere'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'nothing_to_tick' THEN RAISE EXCEPTION 'FAIL [14 ohne Sache]: %', r; END IF;
  -- Grund mit Leerzeichen umgeht die Pruefung nicht (core trimmt ebenso)
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'reason', ' Done_Elsewhere '));
  IF r->>'code' IS DISTINCT FROM 'nothing_to_tick' OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'working' THEN
    RAISE EXCEPTION 'FAIL [14 Grund ungetrimmt]: %', r; END IF;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'reason', 'done_elsewhere',
         'ref_type', 'pension', 'ref_name', '__t_h14_gibtsnicht'));
  IF r->>'code' IS DISTINCT FROM 'nothing_to_tick' OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'working' THEN
    RAISE EXCEPTION 'FAIL [14 nicht gefunden]: %', r; END IF;
  -- zwei Sachen gleichen Namens -> Rueckfrage mit Kandidaten, Aufgabe bleibt working
  INSERT INTO finance.pension (name, pension_type) VALUES ('__t_h14_doppelt', 'occupational'), ('__t_h14_doppelt', 'private');
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'reason', 'done_elsewhere',
         'ref_type', 'pension', 'ref_name', '__t_h14_doppelt'));
  IF r->>'code' IS DISTINCT FROM 'handoff_ref_ambiguous' OR jsonb_array_length(r->'candidates') <> 2
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'working' THEN
    RAISE EXCEPTION 'FAIL [14 mehrdeutig]: %', r; END IF;
  -- gefunden: Karte im Probelauf mit "Steht im System" (Name aus den Daten) und "Bleibt offen" (Rest)
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure, jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111',
         'reason', 'done_elsewhere', 'ref_type', 'pension', 'ref_name', '__T_H14_BRENTE'));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT x->>'value' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'label' = 'finance.label.handoff_in_system') <> '__t_h14_brente'
     OR (SELECT x->>'value' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'label' = 'finance.label.handoff_stays_open')
          <> 'Betrag, sobald der Anbieter sich meldet'
     OR r->>'card_title_key' <> 'finance.hitl.cancel_handoff_task_done_elsewhere'
     OR (SELECT x->'params'->>'text' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'core.hitl.handoff_note') <> 'Betriebsrente eintragen' THEN RAISE EXCEPTION 'FAIL [14 Karte]: %', r; END IF;
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'reason', 'done_elsewhere',
         'ref_type', 'pension', 'ref_name', '__t_h14_brente'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status || '/' || close_reason FROM agent.handoff_tasks WHERE id = v_t) <> 'done/done_elsewhere'
     OR (SELECT entered_refs->0->>'type' FROM agent.handoff_tasks WHERE id = v_t) <> 'pension' THEN RAISE EXCEPTION 'FAIL [14 abhaken]: %', r; END IF;
  -- ohne Rest: "Bleibt offen" leer
  INSERT INTO finance.insurances (name, valid_from) VALUES ('__t_h14_hausrat', CURRENT_DATE) RETURNING id INTO v_ins;
  r := core.fn_dry_run('finance.fn_cancel_handoff_task(jsonb)'::regprocedure, jsonb_build_object('handoff_task_id', v_t2, 'chat_id', '111',
         'reason', 'done_elsewhere', 'ref_type', 'insurance', 'ref_name', '__t_h14_hausrat'));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT x->'value' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'label' = 'finance.label.handoff_stays_open') <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [14 ohne Rest]: %', r; END IF;
  -- streichen: vereinbarter Satz auf der Karte
  r := finance.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_t3, 'chat_id', '111', 'reason', 'dropped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT x->'params'->>'text' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'core.hitl.handoff_note') <> 'Sparbuch auflösen'
     OR r->>'card_title_key' <> 'finance.hitl.cancel_handoff_task_dropped'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t3) <> 'cancelled' THEN RAISE EXCEPTION 'FAIL [14 dropped]: %', r; END IF;
  RAISE NOTICE 'PASS [14 abhaken]';
END $$;

-- 15) Zurueckstellen statt Notiz: Karte mit dem vereinbarten Satz, unbekannter Code korrigierbar mit der gueltigen Liste
DO $$
DECLARE
  r   jsonb;
  v_t int;
BEGIN
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','savings_goal','Ziel aus zwei Sonderzahlungen','working',now()) RETURNING id INTO v_t;
  -- die gueltigen Codes sind die Katalog-Keys finance.handoff.blocked.<code>; die Test-DB laedt den Paket-Katalog nicht
  INSERT INTO core.ui_texts (key, lang, text, package)
  VALUES ('finance.handoff.blocked.goal_irregular_payments', 'de', 'Geht noch nicht.', 'finance')
  ON CONFLICT (key, lang) DO UPDATE SET text = excluded.text;
  r := finance.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'blocked_code', 'kein_code'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'unknown_blocked_code' OR NOT (r->'valid_codes' ? 'goal_irregular_payments') THEN
    RAISE EXCEPTION 'FAIL [15 unbekannt]: %', r; END IF;
  r := core.fn_dry_run('finance.fn_defer_handoff_task(jsonb)'::regprocedure,
         jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'blocked_code', 'goal_irregular_payments'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT x->'params'->>'text' FROM jsonb_array_elements(r->'card_lines') x WHERE x->>'value' = 'core.hitl.handoff_note') <> 'Ziel aus zwei Sonderzahlungen'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_t) <> 'working' THEN RAISE EXCEPTION 'FAIL [15 Probelauf]: %', r; END IF;
  r := finance.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_t, 'chat_id', '111', 'blocked_code', 'goal_irregular_payments'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status || '/' || blocked_code FROM agent.handoff_tasks WHERE id = v_t)
       <> 'deferred/goal_irregular_payments' THEN RAISE EXCEPTION 'FAIL [15 deferred]: %', r; END IF;
  RAISE NOTICE 'PASS [15 zurueckstellen]';
END $$;

ROLLBACK;
