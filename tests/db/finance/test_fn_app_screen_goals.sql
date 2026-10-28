-- tests/db/finance/test_fn_app_screen_goals.sql
-- finance.fn_app_screen_goals(p jsonb) — Mini-App-Bildschirm „Ziele" (docs/package-contract.md §3.12, View-Modell v1).
--   1) Owner/Partner sehen den Haushalt: Hero = Summe der Ziele mit Zielbetrag (ohne Ruecklagen) + gap bei CHF ohne Kurs,
--      Reihenfolge target_date -> priority NULLS LAST -> name, Pill/Balken je fn_savings_goal_pace, Ruecklagen mit
--      Empfehlungs-Pill (keine Pill ohne Empfehlung), Sparplaene aktiv vor pausiert (Soft-Close und gestoppte Beitraege = pausiert), Ruecklage einer verkauften Immobilie ohne Pill.
--   2) Kind sieht nur Eigenes (Ziel beneficiary = ich; Sparplan beneficiary = ich UND eigenes Depot): Volltextsuche ohne
--      fremde Namen und ohne *id-Feld; eigener Sparplan auf einem Eltern-Depot bleibt unsichtbar.
--   3) unbekannte Rolle sieht nur Eigenes, unbekannte Person nichts.
--   4) probe -> {ok, empty, banners}: Banner nur fuer "hinter Plan" ohne fx-Luecke, target = goals.
--   5) Muell -> bad_request ohne RAISE; Frei-SQL-Sitzung -> forbidden, kein EXECUTE fuer *_ro.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_pot INT; v_chf INT; v_hh_depot INT; v_kid_cash INT; v_kid_depot INT; v_re1 INT; v_re2 INT; v_re3 INT;
  v_rp INT; v_goal INT;
  v_old timestamptz := now() - interval '100 days';
  v_td  date := current_date + 265;
  v jsonb; v_sec jsonb; v_txt text; v_labels text[];
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  DELETE FROM core.config WHERE package = 'core' AND category = 'advisor' AND key = 'drift_pace_pp';

  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('apgl_owner',   'Owner Beispiel',   'owner'),
    ('apgl_partner', 'Partner Beispiel', 'partner'),
    ('apgl_kid',     'Kind Beispiel',    'child'),
    ('apgl_guest',   'Gast Beispiel',    'grandparent');

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__apgl_hh_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_hh_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Kind Konto', 'cash', 'EUR', 'active', 'apgl_kid') RETURNING id INTO v_kid_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Kind Depot', 'stocks_depot', 'EUR', 'active', v_kid_cash, 'apgl_kid') RETURNING id INTO v_kid_depot;

  -- ===== Ziele (365 Tage Laufzeit, 100 vergangen -> erwartet 27.40 %) =====
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, priority)
    VALUES ('__apgl_hh_goal__', 10000, v_td, v_old, 2) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_pot, 2000, 'manual');   -- on_track
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, priority)
    VALUES ('__apgl_hh_behind__', 10000, v_td, v_old, 1) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_pot, 1000, 'manual');   -- behind -> Banner
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at)
    VALUES ('__apgl_hh_chf__', 10000, v_td, v_old) RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_chf, 500, current_date - 5, 'transfer', v_goal, gen_random_uuid());                                                       -- behind, aber fx-Luecke -> kein Banner
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, beneficiary_person_id)
    VALUES ('Alpha Fahrrad', 500, current_date + 30, v_old, 'apgl_kid') RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_kid_cash, 500, 'manual'); -- reached
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, beneficiary_person_id)
    VALUES ('__apgl_p_goal__', 10000, v_td + 10, v_old, 'apgl_partner') RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_pot, 3000, 'manual');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, beneficiary_person_id)
    VALUES ('__apgl_g_goal__', 1000, v_td + 20, v_old, 'apgl_guest') RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_pot, 300, 'manual');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, status)
    VALUES ('__apgl_done__', 1000, v_td, v_old, 'completed');

  -- ===== Ruecklagen: mit Empfehlung (Flaeche/Baujahr) und ohne =====
  INSERT INTO finance.real_estate (name, current_value, living_area_m2, year_built) VALUES ('__apgl_re1__', 300000, 100, 1990) RETURNING id INTO v_re1;
  INSERT INTO finance.real_estate (name, current_value) VALUES ('__apgl_re2__', 200000) RETURNING id INTO v_re2;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_res__', v_giro, v_pot, -50, 'month', current_date - 30, current_date - 30) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, real_estate_id, recurring_payment_id) VALUES ('__apgl_res_a__', v_re1, v_rp);
  INSERT INTO finance.savings_goals (name, real_estate_id) VALUES ('__apgl_res_b__', v_re2);
  INSERT INTO finance.real_estate (name, current_value, living_area_m2, year_built, status) VALUES ('__apgl_re3__', 1, 100, 1990, 'sold') RETURNING id INTO v_re3;
  INSERT INTO finance.savings_goals (name, real_estate_id) VALUES ('__apgl_res_c__', v_re3);   -- verkauft: Empfehlung bekannt, aber keine Pill

  -- ===== Sparplaene =====
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_plan__', v_giro, -100, 'month', current_date + 5, current_date + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__apgl_hh_plan__', v_hh_depot, 'APGL1', 'Welt ETF', v_rp);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__apgl_rp_paused__', v_giro, -40, 'month', current_date - 30, current_date - 30, 'paused') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, status)
    VALUES ('__apgl_a_paused__', v_hh_depot, 'APGL2', 'Anleihen ETF', v_rp, 'paused');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, status)
    VALUES ('__apgl_rp_closed__', v_giro, -40, 'month', current_date - 90, current_date - 90, current_date - 10, 'paused') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, status)
    VALUES ('__apgl_closed__', v_hh_depot, 'APGL3', 'Alt ETF', v_rp, 'paused');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_kid__', v_kid_cash, -25, 'month', current_date + 5, current_date + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id)
    VALUES ('Alpha Sparplan', v_kid_depot, 'APGL4', 'Kinder ETF', v_rp, 'apgl_kid');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_kid_hh__', v_giro, -30, 'month', current_date + 5, current_date + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id)
    VALUES ('__apgl_kid_on_hh__', v_hh_depot, 'APGL5', 'Eltern ETF', v_rp, 'apgl_kid');

  -- ===== 1) Owner: Haushalt =====
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR NOT (v ? 'title' AND v ? 'hero' AND v ? 'banners' AND v ? 'sections') THEN
    RAISE EXCEPTION 'FAIL [1a] View-Modell v1 erwartet, got %', v; END IF;
  IF v->'title' <> core.fn_ui_tpl('finance.app.goals.title') OR v->'hero'->'label' <> core.fn_ui_tpl('finance.app.goals.hero') THEN
    RAISE EXCEPTION 'FAIL [1b] title/hero.label %', v; END IF;
  -- Hero: 2000 + 1000 + 0 (CHF ohne Kurs) + 500 (Kind) + 3000 (Partner) + 300 (Gast); Ruecklagen nicht
  IF v->'hero'->'value' <> core.fn_ui_money(6800, 'EUR') OR (v->'hero'->>'gap')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1c] Hero 6800 EUR + gap erwartet, got %', v->'hero'; END IF;
  IF jsonb_array_length(v->'banners') <> 0 THEN RAISE EXCEPTION 'FAIL [1d] Banner nur in der probe-Antwort, got %', v->'banners'; END IF;
  IF jsonb_array_length(v->'sections') <> 3 THEN RAISE EXCEPTION 'FAIL [1e] 3 Abschnitte erwartet, got %', v->'sections'; END IF;

  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.goals.section_goals') THEN RAISE EXCEPTION 'FAIL [1f] Abschnitt Sparziele'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['Alpha Fahrrad', '__apgl_hh_behind__', '__apgl_hh_goal__', '__apgl_hh_chf__', '__apgl_p_goal__', '__apgl_g_goal__'] THEN
    RAISE EXCEPTION 'FAIL [1g] Reihenfolge target_date/priority/name, got %', v_labels; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_hh_goal__'
                    AND i->'value' = core.fn_ui_money(2000, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.target_by',
                                     jsonb_build_object('target', core.fn_ui_money(10000, 'EUR'), 'date', core.fn_ui_date(v_td)))
                    AND i->'pill' = jsonb_build_object('state', 'ok', 'icon', 'check', 'text', core.fn_ui_tpl('finance.app.goals.pace.on_track'))
                    AND i->'progress' = '{"pct":20.0,"state":"ok"}'::jsonb
                    AND (i->>'gap')::boolean IS FALSE) THEN
    RAISE EXCEPTION 'FAIL [1h] on_track-Ziel (Wert, Sub, Pill, Balken), got %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_hh_behind__'
                    AND i->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.goals.pace.behind'))
                    AND i->'progress'->>'state' = 'warn') THEN
    RAISE EXCEPTION 'FAIL [1i] behind-Ziel warn'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = 'Alpha Fahrrad'
                    AND i->'pill' = jsonb_build_object('state', 'ok', 'icon', 'check', 'text', core.fn_ui_tpl('finance.app.goals.pace.reached'))
                    AND i->'progress' = '{"pct":100.0,"state":"ok"}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [1j] erreichtes Ziel'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_hh_chf__' AND (i->>'gap')::boolean) THEN
    RAISE EXCEPTION 'FAIL [1k] CHF-Ziel ohne Kurs traegt gap'; END IF;
  IF v::text LIKE '%__apgl_done__%' THEN RAISE EXCEPTION 'FAIL [1l] abgeschlossenes Ziel sichtbar'; END IF;

  v_sec := v->'sections'->1;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.goals.section_reserves') THEN RAISE EXCEPTION 'FAIL [1m] Abschnitt Ruecklagen'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['__apgl_res_a__', '__apgl_res_b__', '__apgl_res_c__'] THEN RAISE EXCEPTION 'FAIL [1n] Ruecklagen, got %', v_labels; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i, finance.maintenance_reserve_status m
                  WHERE i->>'label' = '__apgl_res_a__' AND m.goal_name = '__apgl_res_a__'
                    AND m.recommended_monthly IS NOT NULL
                    AND i->'value' = core.fn_ui_money(0, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.reserve_rate_rec', jsonb_build_object(
                                     'rate', core.fn_ui_money(50, 'EUR'), 'recommended', core.fn_ui_money(m.recommended_monthly, 'EUR')))
                    AND i->'pill' = CASE WHEN m.gap_monthly_eur > 0
                                         THEN jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.goals.reserve_low'))
                                         ELSE jsonb_build_object('state', 'ok', 'icon', 'check', 'text', core.fn_ui_tpl('finance.app.goals.reserve_ok')) END) THEN
    RAISE EXCEPTION 'FAIL [1o] Ruecklage mit Empfehlung (Rate, Empfehlung, Pill), got %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_res_b__' AND jsonb_typeof(i->'pill') = 'null'
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object('rate', core.fn_ui_money(0, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1p] Ruecklage ohne Empfehlung: keine Pill'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i, finance.maintenance_reserve_status m
                  WHERE i->>'label' = '__apgl_res_c__' AND m.goal_name = '__apgl_res_c__'
                    AND m.gap_monthly_eur > 0 AND jsonb_typeof(i->'pill') = 'null') THEN
    RAISE EXCEPTION 'FAIL [1p2] Ruecklage einer verkauften Immobilie: keine Pill (wie der Berater)'; END IF;

  v_sec := v->'sections'->2;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.goals.section_plans') THEN RAISE EXCEPTION 'FAIL [1q] Abschnitt Sparplaene'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['Alpha Sparplan', '__apgl_hh_plan__', '__apgl_kid_on_hh__', '__apgl_a_paused__', '__apgl_closed__'] THEN
    RAISE EXCEPTION 'FAIL [1r] Sparplaene aktiv vor pausiert (Soft-Close = pausiert), got %', v_labels; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_hh_plan__'
                    AND i->'value' = core.fn_ui_money(100, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.plan_next', jsonb_build_object(
                                     'monthly', core.fn_ui_money(100, 'EUR'), 'date', core.fn_ui_date(current_date + 5)))
                    AND jsonb_typeof(i->'pill') = 'null') THEN
    RAISE EXCEPTION 'FAIL [1s] aktiver Sparplan, got %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_a_paused__' AND jsonb_typeof(i->'sub') = 'null'
                    AND i->'pill' = jsonb_build_object('state', 'neutral', 'icon', 'pause', 'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))) THEN
    RAISE EXCEPTION 'FAIL [1t] pausierter Sparplan'; END IF;
  RAISE NOTICE 'PASS [1] Owner: Hero 6800 + gap, Reihenfolge, Pills/Balken, Ruecklagen, Sparplaene';

  IF finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_partner')) <> v THEN
    RAISE EXCEPTION 'FAIL [1u] Partner muss die Haushalts-Sicht bekommen'; END IF;
  RAISE NOTICE 'PASS [1u] Partner = Haushalts-Sicht';

  -- ===== 2) Kind: nur Eigenes =====
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_kid', 'params', '{}'::jsonb));
  IF v->'hero'->'value' <> core.fn_ui_money(500, 'EUR') OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [2a] Kind-Hero 500 ohne gap, got %', v->'hero'; END IF;
  v_txt := v::text;
  IF v_txt LIKE '%__apgl_%' THEN RAISE EXCEPTION 'FAIL [2b] Kind-Antwort enthaelt fremde Namen: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [2c] Antwort traegt ein *id-Feld: %', v_txt; END IF;
  IF v_txt NOT LIKE '%Alpha Fahrrad%' OR v_txt NOT LIKE '%Alpha Sparplan%' THEN RAISE EXCEPTION 'FAIL [2d] eigenes Ziel/eigener Plan fehlt: %', v_txt; END IF;
  IF jsonb_array_length(v->'sections') <> 2 THEN
    RAISE EXCEPTION 'FAIL [2e] Kind: Sparziele + Sparplaene, leerer Ruecklagen-Abschnitt entfaellt, got %', v->'sections'; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur Eigenes, Plan auf Eltern-Depot unsichtbar, keine IDs';

  -- ===== 3) Allow-List =====
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_guest'));
  IF v->'hero'->'value' <> core.fn_ui_money(300, 'EUR') OR v::text LIKE '%__apgl_hh_%' OR v::text LIKE '%__apgl_res_%' THEN
    RAISE EXCEPTION 'FAIL [3a] unbekannte Rolle nur Eigenes (300), got %', v; END IF;
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_nobody'));
  IF (v->>'ok')::boolean IS NOT TRUE OR v->'hero'->'value' <> core.fn_ui_money(0, 'EUR')
     OR jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 0
     OR v->'sections'->0->'empty' <> core.fn_ui_tpl('finance.app.goals.empty') THEN
    RAISE EXCEPTION 'FAIL [3b] unbekannte Person: leerer Bildschirm, got %', v; END IF;
  RAISE NOTICE 'PASS [3] Allow-List';

  -- ===== 4) probe + Banner =====
  v := finance.fn_app_screen_goals('{"person_id":"apgl_owner","params":{"probe":true}}');
  IF v <> jsonb_build_object('ok', true, 'empty', false, 'banners', jsonb_build_array(jsonb_build_object(
            'state', 'warn', 'icon', 'alert',
            'text', core.fn_ui_tpl('finance.app.goals.banner_behind', jsonb_build_object('name', '__apgl_hh_behind__')),
            'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb)))) THEN
    RAISE EXCEPTION 'FAIL [4a] probe Owner: ein Banner (behind ohne fx-Luecke), got %', v; END IF;
  IF finance.fn_app_screen_goals('{"person_id":"apgl_kid","params":{"probe":true}}') <> '{"ok":true,"empty":false,"banners":[]}'::jsonb
     OR finance.fn_app_screen_goals('{"person_id":"apgl_nobody","params":{"probe":true}}') <> '{"ok":true,"empty":true,"banners":[]}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4b] probe Kind/unbekannt'; END IF;
  RAISE NOTICE 'PASS [4] probe {ok, empty, banners}';

  -- ===== 5) Eingabe-Fehler ohne RAISE =====
  IF finance.fn_app_screen_goals('{}') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_goals('[1]') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_goals(NULL) <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_app_screen_goals('{"person_id":42}') <> '{"ok":false,"code":"bad_request"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5a] Muell -> bad_request'; END IF;
  RAISE NOTICE 'PASS [5a] Muell -> bad_request ohne RAISE';
END $$;

DO $$
BEGIN
  IF has_function_privilege('finance_ro', 'finance.fn_app_screen_goals(jsonb)', 'EXECUTE')
     OR has_function_privilege('core_ro', 'finance.fn_app_screen_goals(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [5b] Frei-SQL-Rolle hat EXECUTE auf den Bildschirm-Handler';
  END IF;
  GRANT EXECUTE ON FUNCTION finance.fn_app_screen_goals(jsonb) TO finance_ro;
END $$;
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
BEGIN
  IF finance.fn_app_screen_goals('{"person_id":"apgl_owner","params":{}}') <> '{"ok":false,"code":"forbidden"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5c] Frei-SQL-Sitzung muss forbidden bekommen'; END IF;
  RAISE NOTICE 'PASS [5] kein EXECUTE fuer *_ro; Frei-SQL-Sitzung -> forbidden';
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;
