-- tests/db/finance/test_maintenance_reserve.sql
-- Instandhaltungsruecklage (Feature 2026-10-27): Immobilie mit Wohnflaeche + Baujahr, offenes Sparziel mit
-- real_estate_id (ohne Zielbetrag/-datum), Rate = genannt / fortgefuehrter Dauerauftrag / Empfehlung nach II. BV
-- (finance.fn_maintenance_reserve_rate), Sperren, Loeschen/Verkaufen, View maintenance_reserve_status, E2E-Cleanup.
-- Erfundene Musterwerte (Repo oeffentlich).
BEGIN;

INSERT INTO core.config (package, category, key, value) VALUES
    ('finance','finance','maintenance_rate_under22_eur_m2','11.50'),
    ('finance','finance','maintenance_rate_from22_eur_m2','14.58'),
    ('finance','finance','maintenance_rate_from32_eur_m2','18.62')
  ON CONFLICT (category, key) DO UPDATE SET value = excluded.value, package = 'finance';

-- ---------- (A) Immobilie: Flaeche + Baujahr, Karte mit Empfehlung ----------
DO $$
DECLARE
  y INT := EXTRACT(YEAR FROM core.fn_today())::int;
  r JSONB;
  v_id INT;
BEGIN
  r := finance.fn_create_real_estate(jsonb_build_object('name','__mr_haus__','living_area_m2','110','year_built',y - 32));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [A1 create]: %', r; END IF;
  v_id := (r->>'real_estate_id')::int;
  IF NOT EXISTS (SELECT 1 FROM finance.real_estate WHERE id = v_id AND living_area_m2 = 110 AND year_built = y - 32) THEN
    RAISE EXCEPTION 'FAIL [A1 Spalten nicht gespeichert]'; END IF;
  -- Karte: Empfehlung (171 EUR/Monat) + "noch keine Ruecklage"
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l
                 WHERE l->>'value' = 'finance.note.maintenance_recommendation'
                   AND (l->'params'->'monthly'->>'value')::numeric = 171) THEN
    RAISE EXCEPTION 'FAIL [A1 Karte Empfehlung]: %', r->'card_lines'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = 'finance.note.maintenance_reserve_missing') THEN
    RAISE EXCEPTION 'FAIL [A1 Karte keine Ruecklage]: %', r->'card_lines'; END IF;
  RAISE NOTICE 'PASS [A1 Flaeche/Baujahr gespeichert, Karte mit Empfehlung 171]';

  -- ohne Daten: keine Empfehlungszeile
  r := finance.fn_create_real_estate('{"name":"__mr_grund__"}'::jsonb);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' LIKE 'finance.note.maintenance%') THEN
    RAISE EXCEPTION 'FAIL [A2 ohne Daten keine Zeile]: %', r; END IF;
  -- Baujahr in der Zukunft / Flaeche <= 0 -> korrigierbar ohne Write
  r := finance.fn_create_real_estate(jsonb_build_object('name','__mr_zukunft__','living_area_m2','90','year_built',y + 2));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.real_estate WHERE name = '__mr_zukunft__') THEN
    RAISE EXCEPTION 'FAIL [A3 Zukunftsjahr]: %', r; END IF;
  r := finance.fn_create_real_estate(jsonb_build_object('name','__mr_null__','living_area_m2','0','year_built',y - 5));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [A3 Flaeche 0]: %', r; END IF;
  RAISE NOTICE 'PASS [A2-A3 ohne Daten keine Zeile; Zukunftsjahr/Flaeche 0 -> ok:false]';

  -- set: Daten nachtragen -> Karte mit Empfehlung (Alter 25 -> 14,58 -> 134)
  v_id := (SELECT id FROM finance.real_estate WHERE name = '__mr_grund__');
  r := finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_id, 'living_area_m2', '110', 'year_built', y - 25));
  IF (r->>'ok')::boolean IS DISTINCT FROM true
     OR NOT EXISTS (SELECT 1 FROM finance.real_estate WHERE id = v_id AND living_area_m2 = 110 AND year_built = y - 25)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l
                    WHERE l->>'value' = 'finance.note.maintenance_recommendation' AND (l->'params'->'monthly'->>'value')::numeric = 134) THEN
    RAISE EXCEPTION 'FAIL [A4 set Daten]: %', r; END IF;
  r := finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_id, 'year_built', y + 1));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [A4 set Zukunftsjahr]: %', r; END IF;
  RAISE NOTICE 'PASS [A4 set_real_estate traegt Daten nach, Karte 134]';

  -- CHECK-Backstop
  BEGIN
    UPDATE finance.real_estate SET living_area_m2 = 0 WHERE id = v_id;
    RAISE EXCEPTION 'FAIL [A5 CHECK Flaeche]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    UPDATE finance.real_estate SET year_built = 1500 WHERE id = v_id;
    RAISE EXCEPTION 'FAIL [A5 CHECK Baujahr]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS [A5 CHECK-Backstops Flaeche/Baujahr]';
END $$;

-- ---------- (B) Ruecklage anlegen ----------
DO $$
DECLARE
  y      INT := EXTRACT(YEAR FROM core.fn_today())::int;
  r      JSONB;
  v_giro INT; v_pot INT; v_pot2 INT; v_depot INT;
  v_haus INT := (SELECT id FROM finance.real_estate WHERE name = '__mr_haus__');
  v_goal INT;
  v_rp   finance.recurring_payments%ROWTYPE;
BEGIN
  v_giro  := (finance.fn_create_account('{"name":"__mr_giro__","account_type":"cash","opening_balance":9000}'::jsonb)->>'account_id')::int;
  v_pot   := (finance.fn_create_account('{"name":"__mr_topf__","account_type":"cash","opening_balance":2000}'::jsonb)->>'account_id')::int;
  v_pot2  := (finance.fn_create_account('{"name":"__mr_topf2__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__mr_depot__','account_type','stocks_depot',
                'settlement_id', v_giro))->>'account_id')::int;

  -- (B1) gesperrte Eingaben
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_haus__','target_amount',5000,
         'reserve_account_id',v_pot,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [B1 Zielbetrag]: %', r; END IF;
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_haus__','target_date',(core.fn_today() + 400)::text,
         'reserve_account_id',v_pot,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [B1 Zieldatum]: %', r; END IF;
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_haus__','savings_plan','irgendein Plan',
         'reserve_account_id',v_pot,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [B1 Sparplan]: %', r; END IF;
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_haus__','reserve_account_id',v_depot,
         'already_saved',100));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [B1 Depot-Topf]: %', r; END IF;
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_gibtsnicht__','reserve_account_id',v_pot,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL [B1 unbekannte Immobilie]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM finance.savings_goals WHERE real_estate_id IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL [B1 Write trotz Ablehnung]'; END IF;
  RAISE NOTICE 'PASS [B1 Zielbetrag/Datum/Sparplan/Depot/unbekannte Immobilie -> ok:false ohne Write]';

  -- (B2) Empfehlung als Rate, Default-Name, Startbestand, Post-State; target_amount 0 = Tool-Default (nicht gesetzt)
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_haus__','target_amount',0,'reserve_account_id',v_pot,
         'account_id',v_giro,'already_saved',1500));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [B2 create]: %', r; END IF;
  v_goal := (r->>'goal_id')::int;
  IF (r->>'monthly_rate')::numeric IS DISTINCT FROM 171 OR (r->>'recommended_monthly')::numeric IS DISTINCT FROM 171
     OR r->>'band' IS DISTINCT FROM 'from32' OR (r->>'rate_eur_m2')::numeric IS DISTINCT FROM 18.62
     OR (r->>'real_estate_id')::int IS DISTINCT FROM v_haus OR r->'target_date' <> 'null'::jsonb
     OR (r->>'current_amount')::numeric IS DISTINCT FROM 1500
     OR (r->'effective'->>'monthly_savings_rate')::numeric IS DISTINCT FROM 171
     OR r->'effective'->>'name' IS DISTINCT FROM 'Instandhaltungsrücklage __mr_haus__' THEN
    RAISE EXCEPTION 'FAIL [B2 Rueckgabe]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal AND real_estate_id = v_haus
                 AND target_amount IS NULL AND target_date IS NULL AND name = 'Instandhaltungsrücklage __mr_haus__') THEN
    RAISE EXCEPTION 'FAIL [B2 Zeile]'; END IF;
  SELECT rp.* INTO v_rp FROM finance.recurring_payments rp JOIN finance.savings_goals g ON g.recurring_payment_id = rp.id WHERE g.id = v_goal;
  IF v_rp.amount IS DISTINCT FROM -171 OR v_rp.account_id IS DISTINCT FROM v_giro OR v_rp.target_account_id IS DISTINCT FROM v_pot THEN
    RAISE EXCEPTION 'FAIL [B2 Rate]: amount=% acct=% target=%', v_rp.amount, v_rp.account_id, v_rp.target_account_id; END IF;
  RAISE NOTICE 'PASS [B2 Ruecklage: Rate = Empfehlung 171, ohne Ziel/Datum, Default-Name, Startbestand 1500]';

  -- (B3) Fortschritts-View: kein Prozent/Rest, Stand ok
  IF NOT EXISTS (SELECT 1 FROM finance.savings_goal_progress WHERE id = v_goal
                 AND progress_percent IS NULL AND remaining_amount IS NULL AND current_amount = 1500 AND pace_drift_pp IS NULL) THEN
    RAISE EXCEPTION 'FAIL [B3 savings_goal_progress]: %', (SELECT row_to_json(p) FROM finance.savings_goal_progress p WHERE id = v_goal); END IF;
  RAISE NOTICE 'PASS [B3 Fortschritt ohne Ziel: Prozent/Rest NULL, Stand 1500]';

  -- (B4) zweite aktive Ruecklage derselben Immobilie -> freundlich ok:false (UNIQUE ist nur Backstop)
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_haus__','reserve_account_id',v_pot2,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'reserve_exists' THEN
    RAISE EXCEPTION 'FAIL [B4 zweite Ruecklage]: %', r; END IF;
  RAISE NOTICE 'PASS [B4 zweite aktive Ruecklage -> reserve_exists]';

  -- (B5) Immobilie ohne Daten: ohne Rate -> maintenance_data_missing; genannte Rate unter Empfehlung -> Hinweis
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_ohne__','reserve_account_id',v_pot2,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL [B5 Vorbedingung]: %', r; END IF;
  PERFORM finance.fn_create_real_estate('{"name":"__mr_ohne__"}'::jsonb);
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_ohne__','reserve_account_id',v_pot2,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'maintenance_data_missing' THEN
    RAISE EXCEPTION 'FAIL [B5 ohne Daten]: %', r; END IF;
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_ohne__','name','Ruecklage Garage',
         'reserve_account_id',v_pot2,'account_id',v_giro,'monthly_savings_rate',40));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'monthly_rate')::numeric IS DISTINCT FROM 40
     OR r->'recommended_monthly' <> 'null'::jsonb
     OR NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE name = 'Ruecklage Garage' AND real_estate_id IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL [B5 eigene Rate ohne Daten]: %', r; END IF;
  RAISE NOTICE 'PASS [B5 ohne Daten: Rate Pflicht; eigener Name + Rate ok]';
END $$;

-- (B6) Empfehlung unterschritten -> Karten-Hinweis; Dauerauftrag in den Topf -> existing_transfer / fortfuehren
DO $$
DECLARE
  y      INT := EXTRACT(YEAR FROM core.fn_today())::int;
  r      JSONB;
  v_giro INT := (SELECT id FROM finance.accounts WHERE name = '__mr_giro__');
  v_pot3 INT; v_old INT;
  v_next DATE := (date_trunc('month', core.fn_today()) + interval '1 month')::date;
BEGIN
  v_pot3 := (finance.fn_create_account('{"name":"__mr_topf3__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_real_estate(jsonb_build_object('name','__mr_wohnung__','living_area_m2','70','year_built',y - 10));
  -- Empfehlung: 70 x 11,50 / 12 = 67,08 -> 68
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_wohnung__','reserve_account_id',v_pot3,
         'account_id',v_giro,'monthly_savings_rate',50));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'recommended_monthly')::numeric IS DISTINCT FROM 68
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'card_lines') l WHERE l->>'value' = 'finance.note.maintenance_rate_below') THEN
    RAISE EXCEPTION 'FAIL [B6 unter Empfehlung]: %', r; END IF;
  RAISE NOTICE 'PASS [B6 Rate unter Empfehlung -> Karten-Hinweis]';
  PERFORM finance.fn_close_savings_goal(jsonb_build_object('savings_goal_name', 'Instandhaltungsrücklage __mr_wohnung__', 'outcome', 'cancelled'));

  -- bestehender Dauerauftrag vom Giro in den Topf
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__mr_uebertrag__','from_account_id',v_giro,
         'to_account_id',v_pot3,'amount',90,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',v_next));
  v_old := (r->>'recurring_payment_id')::int;
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_wohnung__','reserve_account_id',v_pot3,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'existing_transfer' THEN
    RAISE EXCEPTION 'FAIL [B7 existing_transfer]: %', r; END IF;
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_wohnung__','reserve_account_id',v_pot3,
         'account_id',v_giro,'replace_transfer','true'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'monthly_rate')::numeric IS DISTINCT FROM 90
     OR (r->>'replaced_transfer_id')::int IS DISTINCT FROM v_old THEN
    RAISE EXCEPTION 'FAIL [B7 fortfuehren]: %', r; END IF;
  RAISE NOTICE 'PASS [B7 bestehender Dauerauftrag: existing_transfer, dann fortgefuehrt mit 90]';
END $$;

-- ---------- (C) Form-CHECK + UNIQUE ----------
DO $$
DECLARE
  v_haus INT := (SELECT id FROM finance.real_estate WHERE name = '__mr_haus__');
BEGIN
  BEGIN
    INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__mr_x1__', NULL, NULL);
    RAISE EXCEPTION 'FAIL [C1 Ziel ohne Betrag/Datum/Immobilie]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.savings_goals (name, target_amount, target_date, real_estate_id) VALUES ('__mr_x2__', 1000, NULL, v_haus);
    RAISE EXCEPTION 'FAIL [C2 Ruecklage mit Zielbetrag]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.savings_goals (name, real_estate_id) VALUES ('__mr_x3__', v_haus);
    RAISE EXCEPTION 'FAIL [C3 zweite aktive Ruecklage]';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  RAISE NOTICE 'PASS [C1-C3 Form-CHECK + UNIQUE aktive Ruecklage je Immobilie]';
END $$;

-- ---------- (D) set_savings_goal / Zuordnung bei einer Ruecklage ----------
DO $$
DECLARE
  r      JSONB;
  v_goal INT := (SELECT id FROM finance.savings_goals WHERE name = 'Instandhaltungsrücklage __mr_haus__');
  v_rp   INT;
  v_depot INT := (SELECT id FROM finance.accounts WHERE name = '__mr_depot__');
  v_giro INT := (SELECT id FROM finance.accounts WHERE name = '__mr_giro__');
  v_dated INT;
BEGIN
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 8000));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [D1 Zielbetrag]: %', r; END IF;
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_date', (core.fn_today() + 500)::text));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [D1 Zieldatum]: %', r; END IF;
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'link_savings_plan_name', 'irgendein Plan'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [D1 Sparplan]: %', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal AND target_amount IS NULL AND target_date IS NULL) THEN
    RAISE EXCEPTION 'FAIL [D1 Write trotz Ablehnung]'; END IF;
  RAISE NOTICE 'PASS [D1 Zielbetrag/Datum/Sparplan an einer Ruecklage -> ok:false]';

  -- (D2) Rate aendern
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'monthly_savings_rate', '180'));
  SELECT recurring_payment_id INTO v_rp FROM finance.savings_goals WHERE id = v_goal;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'new_monthly_rate')::numeric IS DISTINCT FROM 180
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -180 THEN
    RAISE EXCEPTION 'FAIL [D2 Rate 180]: %', r; END IF;
  RAISE NOTICE 'PASS [D2 Rate einer Ruecklage aendern -> 180]';

  -- (D3) Rate an einem Ziel mit Datum -> ok:false (dort folgt sie aus Betrag und Datum)
  v_dated := (finance.fn_create_savings_goal(jsonb_build_object('name','__mr_urlaub__','target_amount',1200,
               'target_date',(core.fn_today() + 400)::text,'reserve_account_id',(SELECT id FROM finance.accounts WHERE name = '__mr_topf2__'),
               'account_id',v_giro))->>'goal_id')::int;
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_dated, 'monthly_savings_rate', '50'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [D3 Rate an Ziel mit Datum]: %', r; END IF;
  RAISE NOTICE 'PASS [D3 monthly_savings_rate nur fuer Ruecklagen]';

  -- (D4) Depot-Zuordnung -> ok:false
  r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_depot, 'amount', 100));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [D4 Depot-Zuordnung]: %', r; END IF;
  RAISE NOTICE 'PASS [D4 Ruecklage nicht im Depot]';
END $$;

-- (D5) Ruecklage ohne laufende Rate: mit Abbuchungskonto -> Rate = Empfehlung; ohne -> no_rate_running + Empfehlung
DO $$
DECLARE
  y      INT := EXTRACT(YEAR FROM core.fn_today())::int;
  r      JSONB;
  v_giro INT := (SELECT id FROM finance.accounts WHERE name = '__mr_giro__');
  v_pot4 INT;
  v_goal INT;
BEGIN
  v_pot4 := (finance.fn_create_account('{"name":"__mr_topf4__","account_type":"cash","opening_balance":500}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_real_estate(jsonb_build_object('name','__mr_ferienhaus__','living_area_m2','60','year_built',y - 40));
  -- nur Startbestand, keine Rate: Rate 0 (kein Abbuchungskonto)
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_ferienhaus__','reserve_account_id',v_pot4,
         'already_saved',500,'monthly_savings_rate','0'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'recurring_payment_id') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [D5 ohne Rate anlegen]: %', r; END IF;
  v_goal := (r->>'goal_id')::int;
  -- ohne Abbuchungskonto: keine Rate, Hinweis mit der Empfehlung (60 x 18,62 / 12 = 93,10 -> 94)
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'monthly_savings_rate', '94'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'code' IS DISTINCT FROM 'no_rate_running'
     OR (r->>'required_monthly_rate')::numeric IS DISTINCT FROM 94 THEN
    RAISE EXCEPTION 'FAIL [D5 no_rate_running]: %', r; END IF;
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'account_id', v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'new_monthly_rate')::numeric IS DISTINCT FROM 94
     OR (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal) IS NULL THEN
    RAISE EXCEPTION 'FAIL [D5 Rate aus Empfehlung anlegen]: %', r; END IF;
  RAISE NOTICE 'PASS [D5 Ruecklage ohne Rate: Startbestand ok, Rate spaeter = Empfehlung 94]';

  -- (D6, Review) gestoppte Rate (stop_funders) mit monthly_savings_rate wieder starten -> Folge-Zeile ab heute, aktiv
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'stop_funders', 'true'));
  IF (r->>'paused_cash_rate')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [D6 Vorbedingung stop]: %', r; END IF;
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'monthly_savings_rate', '120'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'new_monthly_rate')::numeric IS DISTINCT FROM 120
     OR NOT EXISTS (SELECT 1 FROM finance.savings_goals g JOIN finance.recurring_payments rp ON rp.id = g.recurring_payment_id
                    WHERE g.id = v_goal AND rp.status = 'active' AND rp.valid_to IS NULL AND rp.amount = -120)
     OR (SELECT running_monthly_eur FROM finance.maintenance_reserve_status WHERE goal_id = v_goal) IS DISTINCT FROM 120 THEN
    RAISE EXCEPTION 'FAIL [D6 Neustart nach stop_funders]: %', r; END IF;
  RAISE NOTICE 'PASS [D6 gestoppte Ruecklagen-Rate wieder gestartet (aktiv, 120, Status-View 120)]';

  -- (D7, Review) Default-Name kollidiert mit einem bestehenden Ziel -> name_exists statt Dublette
  PERFORM finance.fn_create_real_estate(jsonb_build_object('name','__mr_laube__','living_area_m2','40','year_built',y - 12));
  v_pot4 := (finance.fn_create_account('{"name":"__mr_topf5__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_savings_goal(jsonb_build_object('name','Instandhaltungsrücklage __mr_laube__','target_amount',500,
            'target_date',(core.fn_today() + 300)::text,'reserve_account_id',v_pot4,'already_saved',0,'account_id',v_giro));
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__mr_laube__','reserve_account_id',v_pot4,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'code' IS DISTINCT FROM 'name_exists' THEN
    RAISE EXCEPTION 'FAIL [D7 name_exists]: %', r; END IF;
  RAISE NOTICE 'PASS [D7 Default-Name einer Ruecklage kollidiert -> name_exists]';

  -- (D8, Review) Freitext statt Zahl -> korrigierbar (kein Cast-RAISE)
  r := finance.fn_create_real_estate(jsonb_build_object('name','__mr_text__','living_area_m2','ca. 100','year_built','1990er'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [D8 Freitext]: %', r; END IF;
  r := finance.fn_create_real_estate(jsonb_build_object('name','__mr_text__','living_area_m2','100','year_built','1990er'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [D8 Freitext Jahr]: %', r; END IF;
  RAISE NOTICE 'PASS [D8 Freitext bei Flaeche/Baujahr -> ok:false]';
END $$;

-- ---------- (E) Status-View ----------
DO $$
DECLARE
  v_row RECORD;
BEGIN
  SELECT * INTO v_row FROM finance.maintenance_reserve_status WHERE real_estate_name = '__mr_haus__';
  IF v_row.recommended_monthly IS DISTINCT FROM 171 OR v_row.running_monthly_eur IS DISTINCT FROM 180
     OR v_row.gap_monthly_eur IS DISTINCT FROM -9 OR v_row.saved_eur IS DISTINCT FROM 1500 OR v_row.goal_id IS NULL
     OR v_row.band IS DISTINCT FROM 'from32' THEN
    RAISE EXCEPTION 'FAIL [E1 Status Haus]: %', row_to_json(v_row); END IF;
  SELECT * INTO v_row FROM finance.maintenance_reserve_status WHERE real_estate_name = '__mr_grund__';
  IF v_row.goal_id IS NOT NULL OR v_row.recommended_monthly IS DISTINCT FROM 134 OR v_row.running_monthly_eur IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [E2 ohne Ruecklage]: %', row_to_json(v_row); END IF;
  RAISE NOTICE 'PASS [E1-E2 maintenance_reserve_status: Empfehlung, laufende Rate, Luecke, Stand]';
END $$;

-- ---------- (F) Loeschen / Verkaufen ----------
DO $$
DECLARE
  r JSONB;
  v_giro INT := (SELECT id FROM finance.accounts WHERE name = '__mr_giro__');
BEGIN
  -- verknuepfte Ruecklage blockiert das Loeschen (FK RESTRICT; die in B6 abgebrochene Ruecklage ohne Buchung hat
  -- close_savings_goal ganz geloescht, es bleibt die fortgefuehrte aus B7)
  r := finance.fn_delete_real_estate('{"real_estate_name":"__mr_wohnung__"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'reserve_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL [F1 Loeschen blockiert]: %', r; END IF;
  -- auch eine GESCHLOSSENE Ruecklage (Soft-Close, Status cancelled) haelt den Link -> weiter blockiert
  UPDATE finance.savings_goals SET status = 'cancelled' WHERE name = 'Instandhaltungsrücklage __mr_wohnung__';
  r := finance.fn_delete_real_estate('{"real_estate_name":"__mr_wohnung__"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'reserve_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL [F1 geschlossen blockiert]: %', r; END IF;
  -- Verkauf: Hinweis auf die laufende Ruecklage
  r := finance.fn_sell_real_estate(jsonb_build_object('real_estate_name','__mr_haus__','proceeds_account_id',v_giro,
         'sale_date',core.fn_today()::text,'sale_price',300000));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'linked_reserve'->>'name' IS DISTINCT FROM 'Instandhaltungsrücklage __mr_haus__' THEN
    RAISE EXCEPTION 'FAIL [F2 Verkauf Hinweis]: %', r; END IF;
  -- (Review) verkauftes Haus mit weiterlaufender Ruecklage bleibt in der Status-View (Digest zeigt die echte Rate)
  IF NOT EXISTS (SELECT 1 FROM finance.maintenance_reserve_status
                 WHERE real_estate_name = '__mr_haus__' AND property_status = 'sold' AND running_monthly_eur = 180) THEN
    RAISE EXCEPTION 'FAIL [F2 verkauft in Status-View]'; END IF;
  -- ohne Ruecklage: Loeschen geht wie bisher
  r := finance.fn_delete_real_estate('{"real_estate_name":"__mr_grund__"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [F3 Loeschen ohne Ruecklage]: %', r; END IF;
  RAISE NOTICE 'PASS [F1-F3 Loeschen blockiert (auch geschlossen), Verkauf meldet Ruecklage, ohne Ruecklage loeschbar]';
END $$;

-- ---------- (G) E2E-Cleanup: Ruecklage ohne Sentinel im Namen an einer E2E-Immobilie ----------
DO $$
DECLARE
  y INT := EXTRACT(YEAR FROM core.fn_today())::int;
  r JSONB;
  v_giro INT; v_pot INT;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__E2E__ mr giro","account_type":"cash","opening_balance":1000}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__E2E__ mr topf","account_type":"cash"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_real_estate(jsonb_build_object('name','__E2E__ mr haus','living_area_m2','100','year_built',y - 30));
  r := finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__E2E__ mr haus','name','Haus-Ruecklage',
         'reserve_account_id',v_pot,'account_id',v_giro));
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [G Vorbedingung]: %', r; END IF;
  PERFORM finance.fn_clear_e2e_data();
  IF EXISTS (SELECT 1 FROM finance.real_estate WHERE name = '__E2E__ mr haus')
     OR EXISTS (SELECT 1 FROM finance.savings_goals WHERE name = 'Haus-Ruecklage') THEN
    RAISE EXCEPTION 'FAIL [G E2E-Cleanup]'; END IF;
  RAISE NOTICE 'PASS [G E2E-Cleanup loescht die Ruecklage einer E2E-Immobilie]';
END $$;

ROLLBACK;
