-- tests/db/finance/test_fn_handoff_precheck.sql
-- finance.fn_handoff_precheck: Vorpruefung eines vereinbarten Eintrags beim Vereinbaren (mode agree) und beim Nachholen
--   (mode recheck). Fertiger Aufruf in Werkzeug-Form mit eindeutigen Namen; mehrdeutiger Name -> Kandidaten (Geld der Kinder
--   nie als Kandidat ohne genauen Namen); fehlende Sache, fehlende Faehigkeit -> "geht noch nicht" mit festem Grund-Schluessel;
--   fehlende Pflichtfelder und fremde Felder -> korrigierbare Ablehnung; "bis Betrag X" -> genau eine empfohlene Aufteilung,
--   Summe der Raten plus Rest = X; Wahl per option; Abweichung einer erledigten Aufgabe -> Reparatur-Aufruf.
BEGIN;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
  jsonb_build_object('person_id','mia','first_name','Mia','last_name','M','role','child','birth_date','2015-03-02')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

DO $$
DECLARE
  r      jsonb;
  c      jsonb;
  v_giro int; v_c1 int; v_c2 int; v_ck int; v_tg int;
  v_codes text[] := ARRAY['end_date_future','pay_until_amount','goal_irregular_payments','target_missing','tool_missing'];
  v_n    int;
  v_sum  numeric;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hp_giro', 'cash', 'EUR') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hp_cash Erika', 'cash', 'EUR') RETURNING id INTO v_c1;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hp_cash Gemeinsam', 'cash', 'EUR') RETURNING id INTO v_c2;
  INSERT INTO finance.accounts (name, account_type, currency, owner_person_id) VALUES ('__t_hp_cash Mia', 'cash', 'EUR', 'mia') RETURNING id INTO v_ck;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hp_tagesgeld', 'cash', 'EUR') RETURNING id INTO v_tg;

  -- 1) Art other ohne Werkzeug-Felder -> ok ohne Aufruf
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','domain','finance','chat_id','111','kind','other',
         'payload','{}'::jsonb,'text','Haftpflicht pruefen'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r ? 'call' OR r ? 'calls' OR r ? 'unsupported' THEN RAISE EXCEPTION 'FAIL [1 other]: %', r; END IF;
  RAISE NOTICE 'PASS [1 other ohne Werkzeug]';

  -- 2) fertiger Aufruf: Namen ohne Gross-/Kleinschreibung -> gespeicherter Name, Werkzeug aus der Art
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Sparen','from_account_name','__T_HP_GIRO','to_account_name','__t_hp_tagesgeld','amount',100,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2027-01-01')));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'call'->>'tool' <> 'create_recurring_transfer'
     OR r->'call'->'input'->>'from_account_name' <> '__t_hp_giro' OR (r->'call'->'input'->>'amount')::numeric <> 100
     OR r->'call'->'input' ? 'tool' THEN RAISE EXCEPTION 'FAIL [2 Aufruf]: %', r; END IF;
  -- Teil eines Namens, genau ein Treffer -> eindeutig
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Sparen','from_account_name','__t_hp_giro','to_account_name','tagesgeld','amount',100,
         'schedule_unit','month','first_payment_date','2027-01-01')));
  IF r->'call'->'input'->>'to_account_name' IS DISTINCT FROM '__t_hp_tagesgeld' THEN RAISE EXCEPTION 'FAIL [2 Teilname]: %', r; END IF;
  RAISE NOTICE 'PASS [2 fertiger Aufruf]';

  -- 3) mehrdeutig -> Kandidaten; das Konto des Kindes ist kein Kandidat
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Sparen','from_account_name','__t_hp_cash','to_account_name','__t_hp_tagesgeld','amount',100,
         'schedule_unit','month','first_payment_date','2027-01-01')));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_ref_ambiguous' OR jsonb_array_length(r->'candidates') <> 2
     OR r->>'field' <> 'from_account_name' OR NULLIF(r->>'reason','') IS NULL
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'candidates') x WHERE (x->>'id')::int = v_ck)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'candidates') x WHERE (x->>'id')::int = v_c1 AND x ? 'label') THEN
    RAISE EXCEPTION 'FAIL [3 mehrdeutig]: %', r; END IF;
  -- genau genannt, auch das Konto des Kindes -> eindeutig
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Taschengeld','from_account_name','__t_hp_giro','to_account_name','__t_hp_cash mia','amount',20,
         'schedule_unit','month','first_payment_date','2027-01-01')));
  IF r->'call'->'input'->>'to_account_name' IS DISTINCT FROM '__t_hp_cash Mia' THEN RAISE EXCEPTION 'FAIL [3 Kind genau]: %', r; END IF;
  RAISE NOTICE 'PASS [3 mehrdeutig, Kind]';

  -- 4) Sache fehlt -> geht noch nicht (target_missing), Aufruf mit dem genannten Namen als Soll
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Sparen','from_account_name','__t_hp_giro','to_account_name','__t_hp_zweitdepot','amount',100,
         'schedule_unit','month','first_payment_date','2027-01-01')));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'unsupported')::boolean IS NOT TRUE OR r->>'blocked_code' <> 'target_missing'
     OR r->'call'->'input'->>'to_account_name' <> '__t_hp_zweitdepot' THEN RAISE EXCEPTION 'FAIL [4 Sache fehlt]: %', r; END IF;
  RAISE NOTICE 'PASS [4 Sache fehlt]';

  -- 5) Pflichtfelder fehlen / fremdes Feld -> korrigierbar
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Sparen','from_account_name','__t_hp_giro','to_account_name','__t_hp_tagesgeld','first_payment_date','2027-01-01')));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_not_enterable'
     OR NOT (r->'missing' @> '["amount","schedule_unit"]'::jsonb) OR jsonb_array_length(r->'missing') <> 2 THEN
    RAISE EXCEPTION 'FAIL [5 Pflicht]: %', r; END IF;
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Sparen','from_account_name','__t_hp_giro','to_account_name','__t_hp_tagesgeld','amount',100,
         'schedule_unit','month','first_payment_date','2027-01-01','from_account_id',v_giro)));
  IF r->>'code' IS DISTINCT FROM 'handoff_not_enterable' OR NOT (r->'unknown' @> '["from_account_id"]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [5 fremdes Feld]: %', r; END IF;
  -- Aenderung ohne geaendertes Feld
  PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name','__t_hp_dauer','from_account_id',v_giro,'to_account_id',v_tg,
         'amount',50,'schedule_unit','month','schedule_day_of_month',20,'first_payment_date',(CURRENT_DATE + 30)::text));
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'payment_name','__t_hp_dauer')));
  IF r->>'code' IS DISTINCT FROM 'handoff_not_enterable' OR NOT (r->'missing' @> '["change"]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [5 ohne Aenderung]: %', r; END IF;
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'payment_name','__t_hp_dauer','schedule_day_of_month',1)));
  IF r->'call'->>'tool' IS DISTINCT FROM 'set_recurring_payment' THEN RAISE EXCEPTION 'FAIL [5 set]: %', r; END IF;
  RAISE NOTICE 'PASS [5 korrigierbar, set erkannt]';

  -- 6) "bis Betrag X": genau eine empfohlene Aufteilung, Summe = X
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Ruecklage','from_account_name','__t_hp_giro','to_account_name','__t_hp_tagesgeld','amount',500,'until_amount',2200,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2027-04-01')));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_choice_needed' OR jsonb_array_length(r->'options') <> 2
     OR (SELECT count(*) FROM jsonb_array_elements(r->'options') o WHERE (o->>'recommended')::boolean) <> 1 THEN
    RAISE EXCEPTION 'FAIL [6 options]: %', r; END IF;
  c := (SELECT o FROM jsonb_array_elements(r->'options') o WHERE (o->>'recommended')::boolean);
  IF c->>'key' <> 'rest_once' OR jsonb_array_length(c->'calls') <> 2 OR NULLIF(c->>'label_key','') IS NULL OR NULLIF(c->>'reason_key','') IS NULL
     OR (c->'calls'->0->'input'->>'valid_to')::date <> DATE '2027-07-01'
     OR (c->'calls'->1->'input'->>'amount')::numeric <> 200
     OR (c->'calls'->1->'input'->>'first_payment_date')::date <> DATE '2027-08-01'
     OR (c->'calls'->1->'input'->>'valid_to')::date <> DATE '2027-08-01'
     OR (c->'params'->>'n')::int <> 4 OR (c->'params'->'rest'->>'value')::numeric <> 200 OR c->'params'->'rest'->>'currency' <> 'EUR' THEN RAISE EXCEPTION 'FAIL [6 empfohlen]: %', c; END IF;
  v_sum := 4 * (c->'calls'->0->'input'->>'amount')::numeric + (c->'calls'->1->'input'->>'amount')::numeric;
  IF v_sum <> 2200 THEN RAISE EXCEPTION 'FAIL [6 Summe]: %', v_sum; END IF;
  c := (SELECT o FROM jsonb_array_elements(r->'options') o WHERE o->>'key' = 'full_rates');
  IF (c->'calls'->0->'input'->>'valid_to')::date <> DATE '2027-08-01' OR jsonb_array_length(c->'calls') <> 1
     OR (c->'params'->'over'->>'value')::numeric <> 300 THEN RAISE EXCEPTION 'FAIL [6 volle Raten]: %', c; END IF;
  -- Wahl -> Aufrufe
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','option','rest_once','payload', jsonb_build_object(
         'name','Ruecklage','from_account_name','__t_hp_giro','to_account_name','__t_hp_tagesgeld','amount',500,'until_amount',2200,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2027-04-01')));
  IF (r->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(r->'calls') <> 2 OR r ? 'call' THEN RAISE EXCEPTION 'FAIL [6 Wahl]: %', r; END IF;
  -- glattes Vielfaches -> keine Wahl, ein Aufruf mit Ende
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Ruecklage','from_account_name','__t_hp_giro','to_account_name','__t_hp_tagesgeld','amount',500,'until_amount',2000,
         'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2027-04-01')));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->'call'->'input'->>'valid_to')::date <> DATE '2027-07-01' OR r->'call'->'input' ? 'until_amount' THEN
    RAISE EXCEPTION 'FAIL [6 glatt]: %', r; END IF;
  -- nicht monatlich -> geht noch nicht
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Ruecklage','from_account_name','__t_hp_giro','to_account_name','__t_hp_tagesgeld','amount',500,'until_amount',2200,
         'schedule_unit','year','first_payment_date','2027-04-01')));
  IF (r->>'unsupported')::boolean IS NOT TRUE OR r->>'blocked_code' <> 'pay_until_amount' THEN RAISE EXCEPTION 'FAIL [6 jaehrlich]: %', r; END IF;
  RAISE NOTICE 'PASS [6 bis Betrag]';

  -- 7) weitere "geht noch nicht": Sparziel mit unregelmaessiger Quelle, Sparplan mit Ende beim Anlegen, falsches Werkzeug
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','savings_goal','payload', jsonb_build_object(
         'goal_name','Ablösung','target_amount',9000,'target_date','2030-12-31','reserve_account_name','__t_hp_tagesgeld',
         'schedule_unit','year')));
  IF (r->>'unsupported')::boolean IS NOT TRUE OR r->>'blocked_code' <> 'goal_irregular_payments'
     OR r->'call'->>'tool' <> 'create_savings_goal' THEN RAISE EXCEPTION 'FAIL [7 Sparziel]: %', r; END IF;
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','savings_plan','payload', jsonb_build_object(
         'plan_name','ETF','depot_name','x','security_name','Welt','amount',50,'schedule_unit','month','first_payment_date','2027-01-02',
         'valid_to','2028-12-31')));
  IF (r->>'unsupported')::boolean IS NOT TRUE OR r->>'blocked_code' <> 'end_date_future' THEN RAISE EXCEPTION 'FAIL [7 Sparplan-Ende]: %', r; END IF;
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_payment','payload', jsonb_build_object(
         'tool','create_savings_plan','plan_name','ETF')));
  IF (r->>'unsupported')::boolean IS NOT TRUE OR r->>'blocked_code' <> 'tool_missing' THEN RAISE EXCEPTION 'FAIL [7 Werkzeug]: %', r; END IF;
  RAISE NOTICE 'PASS [7 geht noch nicht]';

  -- 8) recheck einer zurueckgestellten Aufgabe: geht, sobald die Sache existiert
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','kind','recurring_transfer','status','deferred','task_id',1,
         'wanted', jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','Sparen',
           'from_account_name','__t_hp_giro','to_account_name','__t_hp_zweitdepot','amount',100,'schedule_unit','month',
           'first_payment_date','2027-01-01'))));
  IF r->>'blocked_code' IS DISTINCT FROM 'target_missing' THEN RAISE EXCEPTION 'FAIL [8 noch nicht]: %', r; END IF;
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__t_hp_zweitdepot', 'cash', 'EUR');
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','kind','recurring_transfer','status','deferred','task_id',1,
         'wanted', jsonb_build_object('tool','create_recurring_transfer','input', jsonb_build_object('name','Sparen',
           'from_account_name','__t_hp_giro','to_account_name','__t_hp_zweitdepot','amount',100,'schedule_unit','month',
           'first_payment_date','2027-01-01'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR r ? 'unsupported' OR r->'call'->>'tool' <> 'create_recurring_transfer' THEN
    RAISE EXCEPTION 'FAIL [8 jetzt]: %', r; END IF;
  -- ohne wanted: aus payload
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','kind','recurring_transfer','status','cancelled',
         'payload', jsonb_build_object('name','Sparen','from_account_name','__t_hp_giro','to_account_name','__t_hp_zweitdepot',
           'amount',100,'schedule_unit','month','first_payment_date','2027-01-01')));
  IF r->'call'->>'tool' IS DISTINCT FROM 'create_recurring_transfer' THEN RAISE EXCEPTION 'FAIL [8 aus payload]: %', r; END IF;
  RAISE NOTICE 'PASS [8 recheck]';

  -- 10) relative Daten werden beim Vereinbaren fest (das Soll wandert nicht mit dem Tag)
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','recurring_transfer','payload', jsonb_build_object(
         'name','Sparen','from_account_name','__t_hp_giro','to_account_name','__t_hp_tagesgeld','amount',100,
         'schedule_unit','month','first_payment_date','in 1 month','valid_to','2028-12-31')));
  IF (r->'call'->'input'->>'first_payment_date')::date IS DISTINCT FROM (core.fn_today() + interval '1 month')::date
     OR r->'call'->'input'->>'valid_to' <> '2028-12-31' THEN RAISE EXCEPTION 'FAIL [10 Datum fest]: %', r; END IF;
  -- 11) zurueckgestelltes Sparziel behaelt seinen Rhythmus im Soll; der recheck laesst es nicht als monatliches durch
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','savings_goal','payload', jsonb_build_object(
         'goal_name','Ruecklage Q','target_amount',9000,'target_date','2030-12-31','reserve_account_name','__t_hp_tagesgeld',
         'monthly_savings_rate',300,'account_name','__t_hp_giro','schedule_unit','quarter')));
  IF r->'call'->'input'->>'schedule_unit' IS DISTINCT FROM 'quarter' THEN RAISE EXCEPTION 'FAIL [11 Rhythmus im Soll]: %', r; END IF;
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','recheck','kind','savings_goal','status','deferred','wanted', r->'call'));
  IF r->>'blocked_code' IS DISTINCT FROM 'goal_irregular_payments' THEN RAISE EXCEPTION 'FAIL [11 recheck]: %', r; END IF;
  -- 12) neues Ziel, dessen Name in einem bestehenden steckt: angelegt, nie das andere Ziel geaendert
  INSERT INTO finance.savings_goals (name, goal_type, target_amount, target_date) VALUES ('Urlaub Italien', 'other', 3000, DATE '2028-06-30');
  r := finance.fn_handoff_precheck(jsonb_build_object('mode','agree','kind','savings_goal','payload', jsonb_build_object(
         'goal_name','Urlaub','target_amount',2000,'target_date','2028-06-30','reserve_account_name','__t_hp_tagesgeld')));
  IF r->'call'->>'tool' IS DISTINCT FROM 'create_savings_goal' OR r->'call'->'input'->>'goal_name' <> 'Urlaub' THEN
    RAISE EXCEPTION 'FAIL [12 anlegen statt aendern]: %', r; END IF;
  RAISE NOTICE 'PASS [10-12 Datum, Rhythmus, genauer Name]';

  -- 9) jeder Grund-Schluessel stammt aus der festen Liste (Katalog finance.handoff.blocked.<code>)
  IF EXISTS (SELECT 1 FROM regexp_matches(pg_get_functiondef('finance.fn_handoff_precheck(jsonb)'::regprocedure)
                || pg_get_functiondef('finance.fn_handoff_check_call(text,jsonb,text)'::regprocedure),
                '''blocked_code'', ''([a-z_]+)''', 'g') m WHERE NOT (m[1] = ANY (v_codes))) THEN
    RAISE EXCEPTION 'FAIL [9 Grund-Schluessel ausserhalb der Liste]'; END IF;
  RAISE NOTICE 'PASS [9 Schluessel-Liste]';
END $$;

ROLLBACK;
