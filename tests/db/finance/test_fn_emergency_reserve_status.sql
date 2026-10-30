-- tests/db/finance/test_fn_emergency_reserve_status.sql
-- Notreserve als Ruecklage (2026-10-30): savings_goals.kind = emergency_reserve.
--   1) Gesetz: Form-CHECK (kein Datum, genau eines von Betrag/Monaten), hoechstens eine aktive, Art-Wechsel nur goal ->
--      emergency_reserve (Trigger).
--   2) fn_create_savings_goal: Monats-Ziel auf einem Geld-Konto mit Startbestand; P2P-Topf, zweite Notreserve, kein
--      Ziel -> {ok:false}; Karte nennt Ziel + gedeckt.
--   3) fn_emergency_reserve_status: Ziel = Monate x Monatsausgaben (fest + Alltag); gedeckt je Konto nach den anderen
--      Zielen (Rang), Abfluss schrumpft die Deckung; Zuordnung auf P2P abgelehnt.
--   4) fn_set_savings_goal: Umwidmung eines Sparziels (Datum entfaellt), Betrag <-> Monate; Depot-Anteil verhindert sie.
--   5) Berater: kein savings_goal_reached fuer die Notreserve; Mini-App: Abschnitt nur fuer den Haushalt.
-- Self-contained (BEGIN..ROLLBACK), Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_tg INT; v_p2p INT; v_dep INT; v_g INT; v_goal INT; v_res jsonb; v_s jsonb; v jsonb;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__ers_owner__', 'Owner Beispiel', 'owner'),
                                                                ('__ers_kid__', 'Kind Beispiel', 'child')
    ON CONFLICT (person_id) DO NOTHING;
  v_giro := (finance.fn_create_account('{"name":"__ers_giro__","account_type":"cash","currency":"EUR","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_tg   := (finance.fn_create_account('{"name":"__ers_tg__","account_type":"cash","currency":"EUR","opening_balance":8000}'::jsonb)->>'account_id')::int;
  v_p2p  := (finance.fn_create_account('{"name":"__ers_p2p__","account_type":"p2p","currency":"EUR","opening_balance":9000}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_add_recurring_payment(v_giro, -1200, '__ers_miete__', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
            t - 60, t - 60, NULL, NULL, NULL);

  -- ===== 0) Vor dem Anlegen (Onboarding, Live-Befund 2026-10-30): der Buchhalter wiederholte eine veraltete
  --      Monatsausgabe, rechnete "6 Monatsgehaelter" selbst und bot Kinderkonten an -> der Status liefert auch ohne
  --      Notreserve die frische Basis, fertige Monats-Optionen und die zulaessigen Konten mit freiem Betrag =====
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
  VALUES ('__ers_kidcash0__', 'cash', 'EUR', 'active', '__ers_kid__') RETURNING id INTO v_dep;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_dep, 700, t - 5, 'other');
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__ers_vorab__', 2000, t + 300) RETURNING id INTO v_g;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_tg, 'amount', 1500));
  v_s := finance.fn_emergency_reserve_status();
  IF (v_s->>'exists')::boolean IS DISTINCT FROM false OR (v_s->'basis'->>'monthly_eur')::numeric IS DISTINCT FROM 1200
     OR v_s->'month_options' IS DISTINCT FROM '[{"months": 3, "eur": 3600.00}, {"months": 6, "eur": 7200.00}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [0a] ohne Notreserve: frische Basis + Monats-Optionen: %', v_s; END IF;
  -- zulaessig: nur Geld-Konten der Eltern (kein P2P, kein Kinderkonto), frei = Saldo nach allen Ziel-Zuordnungen
  IF (SELECT jsonb_agg(c ORDER BY c->>'name') FROM jsonb_array_elements(v_s->'candidates') c WHERE c->>'name' LIKE '\_\_ers\_%')
     IS DISTINCT FROM '[{"name": "__ers_giro__", "free_eur": 5000.00}, {"name": "__ers_tg__", "free_eur": 6500.00}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [0b] Kandidaten-Konten: %', v_s->'candidates'; END IF;
  -- Gesetz in der fn (nicht nur im Prompt): Notreserve-Topf auf einem Kinderkonto -> {ok:false}
  v_res := finance.fn_create_savings_goal(jsonb_build_object('kind', 'emergency_reserve', 'target_months', 3,
             'reserve_account_id', v_dep));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [0c] Kinderkonto als Topf: %', v_res; END IF;
  -- Fremdwaehrung ohne Kurs: frei unbekannt (NULL), nie 0
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ers_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_g;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_g, 300, t - 5, 'other');
  IF NOT finance.fn_emergency_reserve_status()->'candidates' @? '$[*] ? (@.name == "__ers_chf__" && @.free_eur == null)' THEN
    RAISE EXCEPTION 'FAIL [0d] ohne Kurs free_eur NULL: %', finance.fn_emergency_reserve_status()->'candidates'; END IF;
  UPDATE finance.savings_goals SET status = 'cancelled' WHERE name = '__ers_vorab__';
  RAISE NOTICE 'PASS [0] Status ohne Notreserve: Basis, Monats-Optionen, zulaessige Konten, Kinderkonto abgelehnt';

  -- ===== 1) Gesetz =====
  BEGIN
    INSERT INTO finance.savings_goals (name, kind, target_amount, target_months) VALUES ('__ers_x__', 'emergency_reserve', 1000, 3);
    RAISE EXCEPTION 'FAIL [1a] Betrag UND Monate angenommen';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.savings_goals (name, kind, target_amount, target_date) VALUES ('__ers_x__', 'emergency_reserve', 1000, t + 100);
    RAISE EXCEPTION 'FAIL [1b] Notreserve mit Datum angenommen';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS [1] Form-CHECK der Notreserve';

  -- ===== 2) Anlegen =====
  v_res := finance.fn_create_savings_goal(jsonb_build_object('kind', 'emergency_reserve', 'target_months', 3,
             'reserve_account_id', v_p2p));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [2a] P2P-Topf angenommen: %', v_res; END IF;
  v_res := finance.fn_create_savings_goal(jsonb_build_object('kind', 'emergency_reserve', 'reserve_account_id', v_tg));
  IF v_res->>'code' IS DISTINCT FROM 'target_required' THEN RAISE EXCEPTION 'FAIL [2b] ohne Ziel: %', v_res; END IF;
  v_res := finance.fn_create_savings_goal(jsonb_build_object('kind', 'emergency_reserve', 'target_months', 3,
             'reserve_account_id', v_tg, 'already_saved', 3000));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'recurring_payment_id') IS NOT NULL
     OR v_res->'emergency_reserve'->>'name' <> 'Notreserve'
     OR NOT v_res->'card_lines' @? '$[*] ? (@.value == "finance.note.emergency_target_months")'
     OR NOT v_res->'card_lines' @? '$[*] ? (@.value == "finance.note.emergency_covered")'
     OR v_res->'emergency_reserve' ? 'candidates' OR v_res->'emergency_reserve' ? 'month_options' THEN
    RAISE EXCEPTION 'FAIL [2c] Notreserve angelegt (Name Default, keine Rate, Karte): %', v_res; END IF;
  v_goal := (v_res->>'goal_id')::int;
  IF (SELECT kind FROM finance.savings_goals WHERE id = v_goal) <> 'emergency_reserve'
     OR (SELECT target_months FROM finance.savings_goals WHERE id = v_goal) <> 3 THEN
    RAISE EXCEPTION 'FAIL [2d] kind/target_months gespeichert'; END IF;
  v_res := finance.fn_create_savings_goal(jsonb_build_object('kind', 'emergency_reserve', 'target_amount', 5000,
             'name', '__ers_zwei__', 'reserve_account_id', v_giro));
  IF v_res->>'code' IS DISTINCT FROM 'reserve_exists' THEN RAISE EXCEPTION 'FAIL [2e] zweite Notreserve: %', v_res; END IF;
  BEGIN
    INSERT INTO finance.savings_goals (name, kind, target_amount) VALUES ('__ers_y__', 'emergency_reserve', 1000);
    RAISE EXCEPTION 'FAIL [2f] zweite aktive Notreserve am Index vorbei';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  RAISE NOTICE 'PASS [2] Anlegen: Geld-Konto, Ziel Pflicht, hoechstens eine';

  -- ===== 3) Status: Ziel = 3 x 1200 (Alltag 0 ohne Auszug), gedeckt 3000 auf dem Tagesgeld =====
  v_s := finance.fn_emergency_reserve_status();
  IF (v_s->>'target_eur')::numeric IS DISTINCT FROM 3600.00 OR (v_s->>'covered_eur')::numeric IS DISTINCT FROM 3000.00
     OR (v_s->>'gap_eur')::numeric IS DISTINCT FROM 600.00 OR v_s->>'state' <> 'warn'
     OR (v_s->'basis'->>'fixed_eur')::numeric IS DISTINCT FROM 1200 OR jsonb_array_length(v_s->'accounts') <> 1 THEN
    RAISE EXCEPTION 'FAIL [3a] Status: %', v_s; END IF;
  -- zweites Konto zuordnen; P2P abgelehnt
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_p2p, 'amount', 500));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3b] P2P-Zuordnung angenommen: %', v_res; END IF;
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_dep, 'amount', 100));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3b2] Kinderkonto-Zuordnung angenommen: %', v_res; END IF;
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_giro, 'amount', 1000));
  IF (finance.fn_emergency_reserve_status()->>'covered_eur')::numeric IS DISTINCT FROM 4000.00
     OR finance.fn_emergency_reserve_status()->>'state' <> 'ok' THEN
    RAISE EXCEPTION 'FAIL [3c] zwei Konten gedeckt 4000, ok: %', finance.fn_emergency_reserve_status(); END IF;
  -- Rang: ein normales Ziel belegt 3500 auf dem Giro (Saldo 5000); Geld fliesst ab (-3000 -> Saldo 2000): das andere
  -- Ziel geht vor, die Notreserve auf dem Giro ist nicht mehr gedeckt (kein Saldo zaehlt doppelt)
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__ers_reise__', 5000, t + 400) RETURNING id INTO v_g;
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_giro, 'amount', 3500));
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, -3000, t, 'other');
  v_s := finance.fn_emergency_reserve_status();
  IF (v_s->>'covered_eur')::numeric IS DISTINCT FROM 3000.00 OR v_s->>'state' <> 'warn' THEN
    RAISE EXCEPTION 'FAIL [3d] Rang nach anderen Zielen + Abfluss: %', v_s; END IF;
  -- Runway: das gedeckte Notreserve-Geld zaehlt als verfuegbar
  IF (finance.fn_liquidity_snapshot()->>'emergency_eur')::numeric IS DISTINCT FROM 3000.00 THEN
    RAISE EXCEPTION 'FAIL [3e] liquidity_snapshot.emergency_eur: %', finance.fn_liquidity_snapshot(); END IF;
  RAISE NOTICE 'PASS [3] Status: Ziel aus Monatsausgaben, Deckung je Konto nach Rang, P2P raus, Runway';

  -- ===== 4) set: Betrag statt Monate; Umwidmung eines Sparziels =====
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 4000));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (SELECT target_months FROM finance.savings_goals WHERE id = v_goal) IS NOT NULL
     OR (SELECT target_amount FROM finance.savings_goals WHERE id = v_goal) <> 4000 THEN
    RAISE EXCEPTION 'FAIL [4a] Betrag ersetzt Monate: %', v_res; END IF;
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_date', (t + 30)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [4b] Datum an der Notreserve: %', v_res; END IF;
  -- Umwidmung nur ohne andere aktive Notreserve
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'kind', 'emergency_reserve'));
  IF v_res->>'code' IS DISTINCT FROM 'reserve_exists' THEN RAISE EXCEPTION 'FAIL [4c] Umwidmung trotz Notreserve: %', v_res; END IF;
  UPDATE finance.savings_goals SET status = 'cancelled' WHERE id = v_goal;
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'kind', 'emergency_reserve'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'converted_to' <> 'emergency_reserve'
     OR (SELECT kind::text || coalesce(target_date::text, '-') FROM finance.savings_goals WHERE id = v_g) <> 'emergency_reserve-'
     OR (SELECT target_amount FROM finance.savings_goals WHERE id = v_g) <> 5000 THEN
    RAISE EXCEPTION 'FAIL [4d] Umwidmung: %', v_res; END IF;
  BEGIN
    UPDATE finance.savings_goals SET kind = 'goal' WHERE id = v_g;
    RAISE EXCEPTION 'FAIL [4e] Art zurueckgewechselt';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS [4] set: Ziel-Art Betrag/Monate, kein Datum, Umwidmung nur goal -> Notreserve';

  -- ===== 5) Berater + Mini-App =====
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 9000, t, 'other');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_advisor_review('finance')->'alerts') a
              WHERE a->>'kind' = 'savings_goal_reached' AND a->>'label' = '__ers_reise__') THEN
    RAISE EXCEPTION 'FAIL [5a] savings_goal_reached fuer die Notreserve'; END IF;
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', '__ers_owner__', 'params', '{}'::jsonb));
  IF v->'sections'->0->'title' <> core.fn_ui_tpl('finance.app.goals.section_emergency')
     OR v->'sections'->0->'items'->0->>'label' <> '__ers_reise__'
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->1->'items') i WHERE i->>'label' = '__ers_reise__') THEN
    RAISE EXCEPTION 'FAIL [5b] Notreserve-Abschnitt zuerst, nicht in der Ziel-Liste: %', v->'sections'; END IF;
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', '__ers_kid__', 'params', '{}'::jsonb));
  IF v::text LIKE '%section_emergency%' OR v::text LIKE '%__ers_reise__%' THEN
    RAISE EXCEPTION 'FAIL [5c] Kind sieht die Notreserve: %', v; END IF;
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', '__ers_kid__', 'params', '{"probe":true}'::jsonb));
  IF v::text LIKE '%banner_emergency%' THEN RAISE EXCEPTION 'FAIL [5d] Kind-Banner zur Notreserve: %', v; END IF;
  RAISE NOTICE 'PASS [5] Berater ohne reached-Alert; Mini-App nur fuer den Haushalt';

  -- ===== 6) Code-Review 2026-10-30: Karte beim Aendern, Kinderkonto zaehlt nie, Umwidmung mit Rate in P2P =====
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'target_months', 6));
  IF NOT v_res->'card_lines' @? '$[*] ? (@.value == "finance.note.emergency_target_months")'
     OR NOT v_res->'card_lines' @? '$[*] ? (@.value == "finance.note.emergency_covered")'
     OR v_res->'emergency_reserve' ? 'candidates' OR v_res->'emergency_reserve' ? 'month_options' THEN
    RAISE EXCEPTION 'FAIL [6a] set-Karte nennt Ziel in EUR + gedeckt: %', v_res; END IF;
  DECLARE v_kidacc INT; v_before NUMERIC; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('__ers_kidacc__', 'cash', 'EUR', 'active', '__ers_kid__') RETURNING id INTO v_kidacc;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_kidacc, 1000, t, 'other');
    v_before := (finance.fn_emergency_reserve_status()->>'covered_eur')::numeric;
    PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g, 'account_id', v_kidacc, 'amount', 500));
    IF (finance.fn_emergency_reserve_status()->>'covered_eur')::numeric IS DISTINCT FROM v_before THEN
      RAISE EXCEPTION 'FAIL [6b] Kinderkonto zaehlt zur Haushalts-Notreserve'; END IF;
  END;
  DECLARE v_g2 INT; v_rp INT; BEGIN
    UPDATE finance.savings_goals SET status = 'cancelled' WHERE id = v_g;
    INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__ers_p2pziel__', 5000, t + 400) RETURNING id INTO v_g2;
    v_rp := finance.fn_add_recurring_payment(v_giro, -100, 'Sparrate __ers_p2pziel__', 1::smallint, 'month'::finance.schedule_unit,
              1::smallint, t + 20, t + 20, NULL, NULL, NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_p2p WHERE id = v_rp;
    UPDATE finance.savings_goals SET recurring_payment_id = v_rp WHERE id = v_g2;
    v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g2, 'kind', 'emergency_reserve'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (SELECT kind FROM finance.savings_goals WHERE id = v_g2) <> 'goal' THEN
      RAISE EXCEPTION 'FAIL [6c] Umwidmung trotz Rate in einen P2P-Topf: %', v_res; END IF;
  END;
  RAISE NOTICE 'PASS [6] set-Karte, Kinderkonto raus, Umwidmung prueft die laufende Rate';
END $$;
ROLLBACK;
