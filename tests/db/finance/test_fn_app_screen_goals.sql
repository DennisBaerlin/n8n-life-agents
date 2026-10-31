-- tests/db/finance/test_fn_app_screen_goals.sql
-- finance.fn_app_screen_goals(p jsonb) — Mini-App-Bildschirm „Ziele" (docs/package-contract.md §3.12, View-Modell v1;
-- UX-Gesamtkonzept 2026-10-31 §5.3: Ruecklagen, Sparziele, Sparplaene; kein Abschnitt Konten).
--   1) Owner: drei Abschnitte ohne Summe ausser Sparplaene; nirgends eine ok-Pille oder ein ok-Balken; Hero + gap.
--      Sparziele: Untertitel „von x · bis Monat" / „x erreicht · geplant fuer", hinter Plan mit Betrag, fx-Luecke nur gap,
--      Quelle der Rate (Sparplaene / Dauerauftrag / beides / keine), Depot-Deckung (ohne Kurs gap, Delle still, Einbruch
--      alert mit Depot-Name an jedem Ziel des Depots). Ruecklagen: Notreserve warn/voll, Instandhaltung warn mit
--      Richtwert-Zeile und Rate ohne Betrag, Reihenfolge. Sparplaene: Untertitel aus dem heutigen Glied (feste Tage,
--      einmal monatlich, woechentlich, geplante Aenderung), Spiegel-Pille des Abbuchungskontos (warn Monat / alert Datum),
--      Reihenfolge, Summe; Details ohne ISIN und ohne „Position heute".
--   2) Kind sieht nur Eigenes: Rate nennt nur eigene Plaene, Eltern-Depot gibt keine Pille her, keine Namen/IDs.
--   3) unbekannte Rolle sieht nur Eigenes (Haushaltskonto), unbekannte Person nichts.
--   4) probe -> {ok, empty, banners}: „hinter Plan" ohne fx-Luecke; kein Notreserve-Banner; Konto-Banner (alert) nur fuer
--      Abbuchungskonten, die der Konten-Tab nicht zeigt (Kinder-Konto in der Haushalts-Sicht). 4b: Spiegel-Pille
--      „x unter dem Puffer" (verdict buffer, short_by) = Pille der Konten-Zeile (fn_app_low_state_pill).
--   5) Muell -> bad_request ohne RAISE; Frei-SQL-Sitzung -> forbidden, kein EXECUTE fuer *_ro.
--   6) Fixture-Haushalt tests/util/util_app_household.sql: core.fn_app_view_lint = 0 fuer Owner, Partnerin, beide
--      Kinder, Gast; Konzept-Faelle (Rate aus zwei Sparplaenen, Depot-Delle still, Einbruch alert, Notreserve, Kind).
--   1)–5) laufen auf eigenen Mini-Daten (Randfaelle, die der Haushalt nicht hat).
-- Self-contained (zwei Transaktionen, je BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_pot INT; v_chf INT; v_broker INT; v_low INT; v_hh_depot INT; v_kid_cash INT; v_kid_depot INT;
  v_re1 INT; v_re2 INT; v_re3 INT; v_rp INT; v_rp2 INT; v_goal INT; v_mix INT; v_kgoal INT; v_emerg INT;
  v_old timestamptz := now() - interval '100 days';
  v_td  date := current_date + 265;
  v jsonb; v_sec jsonb; v_it jsonb; v_txt text; v_labels text[]; v_n numeric;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  DELETE FROM core.config WHERE package = 'core' AND category = 'advisor' AND key = 'drift_pace_pp';
  DELETE FROM core.config WHERE package = 'finance' AND category = 'finance' AND key = 'depot_cover_warn_pct';

  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('apgl_owner',   'Owner Beispiel',   'owner'),
    ('apgl_partner', 'Partner Beispiel', 'partner'),
    ('apgl_kid',     'Kind Beispiel',    'child'),
    ('apgl_guest',   'Gast Beispiel',    'grandparent');

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_broker__', 'cash', 'EUR', 'active') RETURNING id INTO v_broker;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_low__', 'cash', 'EUR', 'active') RETURNING id INTO v_low;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__apgl_hh_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_hh_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Alpha Konto', 'cash', 'EUR', 'active', 'apgl_kid') RETURNING id INTO v_kid_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Alpha Depot', 'stocks_depot', 'EUR', 'active', v_kid_cash, 'apgl_kid') RETURNING id INTO v_kid_depot;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 50000, current_date - 40, 'other'), (v_kid_cash, 1000, current_date - 40, 'other'),
    (v_broker, 1000, current_date - 40, 'other');
  -- Depot-Positionen: Haushalts-Depot erst ohne Kurs (unknown), Kind-Depot gedeckt
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency) VALUES
    (v_hh_depot, 'APG00000009', 'APGLX', '__apgl_pos__', 2, 100, 'EUR'),
    (v_kid_depot, 'APG00000010', 'APGLK', 'Alpha Position', 1, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APGLK', 100, 'EUR', current_date);

  -- ===== Sparziele (365 Tage Laufzeit, 100 vergangen -> erwartet 27.40 %) =====
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month,
                                          first_payment_date, valid_from)
    VALUES ('__apgl_rp_goal__', v_giro, v_pot, -100, 'month', 1, current_date - 10, current_date - 10) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, priority, recurring_payment_id)
    VALUES ('__apgl_hh_goal__', 10000, v_td, v_old, 2, v_rp) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_pot, 2000, 'manual');   -- on_track
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, priority)
    VALUES ('__apgl_hh_behind__', 10000, v_td, v_old, 1) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_pot, 1000, 'manual');   -- behind -> Pille + Banner
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at)
    VALUES ('__apgl_hh_chf__', 10000, v_td, v_old) RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_chf, 500, current_date - 5, 'transfer', v_goal, gen_random_uuid());                                    -- behind, aber fx-Luecke -> nur gap
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
  -- zwei Ziele auf dem Haushalts-Depot + ein Kind-Ziel mit Anteil darauf (Depot fuer das Kind verborgen)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at) VALUES ('__apgl_dep_a__', 150, v_td, v_old) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_hh_depot, 100, 'manual');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at) VALUES ('__apgl_dep_b__', 150, v_td + 1, v_old) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_hh_depot, 100, 'manual');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id)
    VALUES ('Alpha Roller', 100, current_date + 200, 'apgl_kid') RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_hh_depot, 50, 'manual');
  -- Kind-Ziel aus zwei Sparplaenen (einer auf dem Eltern-Depot, fuer das Kind verborgen)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id)
    VALUES ('Alpha Ziel', 1000, current_date + 365, 'apgl_kid') RETURNING id INTO v_kgoal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_kgoal, v_kid_depot, 100, 'manual');
  -- Ziel mit Sparplan UND Dauerauftrag
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month,
                                          first_payment_date, valid_from)
    VALUES ('__apgl_rp_mix__', v_giro, v_pot, -20, 'month', 15, current_date - 10, current_date - 10) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id)
    VALUES ('__apgl_mix__', 5000, current_date + 700, v_rp) RETURNING id INTO v_mix;

  -- ===== Ruecklagen: Notreserve (fehlen 600) + Instandhaltung mit/ohne Richtwert + verkauft =====
  INSERT INTO finance.savings_goals (name, kind, target_amount) VALUES ('__apgl_emergency__', 'emergency_reserve', 1000) RETURNING id INTO v_emerg;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_emerg, v_giro, 400, 'manual');
  INSERT INTO finance.real_estate (name, current_value, living_area_m2, year_built) VALUES ('__apgl_re1__', 300000, 100, 1990) RETURNING id INTO v_re1;
  INSERT INTO finance.real_estate (name, current_value) VALUES ('__apgl_re2__', 200000) RETURNING id INTO v_re2;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_res__', v_giro, v_pot, -50, 'month', current_date - 30, current_date - 30) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, recurring_payment_id) VALUES ('__apgl_res_a__', 'maintenance_reserve', v_re1, v_rp);
  INSERT INTO finance.savings_goals (name, kind, real_estate_id) VALUES ('__apgl_res_b__', 'maintenance_reserve', v_re2);
  INSERT INTO finance.real_estate (name, current_value, living_area_m2, year_built, status) VALUES ('__apgl_re3__', 1, 100, 1990, 'sold') RETURNING id INTO v_re3;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id) VALUES ('__apgl_res_c__', 'maintenance_reserve', v_re3);

  -- ===== Sparplaene =====
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_plan__', v_giro, -100, 'month', current_date + 5, current_date + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, isin, security_name, recurring_payment_id, savings_goal_id)
    VALUES ('__apgl_hh_plan__', v_hh_depot, 'APGL1', 'APG00000001', 'Welt ETF', v_rp, v_mix);
  -- feste Tage, Konto ohne Alltag mit 1000 -> reicht ~10 Monate -> warn (Monat)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
    VALUES ('__apgl_rp_days__', v_broker, -25, 'month', ARRAY[2, 9, 16, 23]::smallint[], current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__apgl_days_plan__', v_hh_depot, 'APGL7', 'Tage ETF', v_rp);
  -- leeres Konto, Abbuchung in 3 Tagen -> alert (Datum)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_low__', v_low, -100, 'month', current_date + 3, current_date + 3) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__apgl_low_plan__', v_hh_depot, 'APGL6', 'Leer ETF', v_rp);
  -- woechentlich
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_week__', v_giro, -10, 'week', current_date + 2, current_date + 2) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__apgl_week_plan__', v_hh_depot, 'APGL8', 'Woche ETF', v_rp);
  -- geplante Aenderung: heute 40, ab +20 Tagen 60 (Kopf = kuenftiges Glied)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__apgl_rp_chg_old__', v_giro, -40, 'month', current_date - 25, current_date - 25, current_date + 20) RETURNING id INTO v_rp;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('__apgl_rp_chg_new__', v_giro, -60, 'month', current_date + 20, current_date + 20, v_rp) RETURNING id INTO v_rp2;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__apgl_change_plan__', v_hh_depot, 'APGL9', 'Wechsel ETF', v_rp2);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__apgl_rp_paused__', v_giro, -40, 'month', current_date - 30, current_date - 30, 'paused') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, status)
    VALUES ('__apgl_a_paused__', v_hh_depot, 'APGL2', 'Anleihen ETF', v_rp, 'paused');
  -- Kind: eigener Plan + Plan auf dem Eltern-Depot, beide fuer „Alpha Ziel"
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_kid__', v_kid_cash, -25, 'month', current_date + 5, current_date + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id, savings_goal_id)
    VALUES ('Alpha Sparplan', v_kid_depot, 'APGL4', 'Kinder ETF', v_rp, 'apgl_kid', v_kgoal);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_kid_hh__', v_giro, -30, 'month', current_date + 5, current_date + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id, savings_goal_id)
    VALUES ('__apgl_kid_on_hh__', v_hh_depot, 'APGL5', 'Eltern ETF', v_rp, 'apgl_kid', v_kgoal);

  -- ===== 1) Owner: Haushalt =====
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner', 'params', '{}'::jsonb));
  IF (v->>'ok')::boolean IS NOT TRUE OR NOT (v ? 'title' AND v ? 'hero' AND v ? 'banners' AND v ? 'sections') THEN
    RAISE EXCEPTION 'FAIL [1a] View-Modell v1 erwartet, got %', v; END IF;
  IF v->'title' <> core.fn_ui_tpl('finance.app.goals.title') OR v->'hero'->'label' <> core.fn_ui_tpl('finance.app.goals.hero') THEN
    RAISE EXCEPTION 'FAIL [1b] title/hero.label %', v; END IF;
  -- Hero = alle sichtbaren Ziele + Instandhaltung + Notreserve gedeckt (400); CHF ohne Kurs -> gap, keine Note
  SELECT sum(p.current_amount) INTO v_n FROM finance.savings_goal_progress p
   WHERE p.status = 'active' AND p.target_amount IS NOT NULL AND p.id <> v_emerg;
  IF v->'hero'->'value' <> core.fn_ui_money(v_n + 400, 'EUR') OR (v->'hero'->>'gap')::boolean IS NOT TRUE
     OR jsonb_typeof(v->'hero'->'note') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1c] Hero % + gap ohne Note erwartet, got %', v_n + 400, v->'hero'; END IF;
  IF jsonb_array_length(v->'banners') <> 0 THEN RAISE EXCEPTION 'FAIL [1d] Banner nur in der probe-Antwort, got %', v->'banners'; END IF;
  SELECT array_agg(s->'title'->>'value' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o);
  IF v_labels IS DISTINCT FROM ARRAY['finance.app.goals.section_reserves', 'finance.app.goals.section_goals',
                                     'finance.app.goals.section_plans'] THEN
    RAISE EXCEPTION 'FAIL [1e] genau Ruecklagen, Sparziele, Sparplaene (kein Konten-Abschnitt), got %', v_labels; END IF;
  IF jsonb_typeof(v->'sections'->0->'value') <> 'null' OR jsonb_typeof(v->'sections'->1->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1f] keine Summe neben Ruecklagen/Sparziele (steht in der Hero-Note), got %', v->'sections'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
              WHERE i->'pill'->>'state' = 'ok' OR i->'progress'->>'state' = 'ok') THEN
    RAISE EXCEPTION 'FAIL [1g] keine gruene Pille, kein gruener Balken, got %', v; END IF;
  v_txt := v::text;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [1h] Owner-Antwort traegt ein *id-Feld: %', v_txt; END IF;
  IF v_txt LIKE '%APG0000000%' OR v_txt LIKE '%finance.app.goals.d_position%' THEN
    RAISE EXCEPTION 'FAIL [1i] keine ISIN, kein „Position heute"'; END IF;
  IF v_txt LIKE '%__apgl_done__%' THEN RAISE EXCEPTION 'FAIL [1j] abgeschlossenes Ziel sichtbar'; END IF;
  SELECT string_agg(l.rule || ' ' || l.path, '; ') INTO v_txt
    FROM core.fn_app_view_lint(v, ARRAY['finance.app.goals.pace.paused', 'finance.app.goals.pace.unmeasurable'], '{}') l;
  IF v_txt IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1j2] fn_app_view_lint Owner: %', v_txt; END IF;

  -- --- Sparziele ---
  v_sec := v->'sections'->1;
  -- Reihenfolge: hinter Plan (warn) zuerst, dann nach Datum/Prioritaet/Name; erreicht zuletzt
  IF v_sec->'items'->0->>'label' <> '__apgl_hh_behind__' OR v_sec->'items'->-1->>'label' <> 'Alpha Fahrrad' THEN
    RAISE EXCEPTION 'FAIL [1k] warn zuerst, erreicht zuletzt, got %', v_sec->'items'; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_hh_goal__';
  IF v_it->'value' <> core.fn_ui_money(2000, 'EUR')
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.goals.goal_sub', jsonb_build_object(
                         'target', core.fn_ui_money(10000, 'EUR'), 'date', core.fn_ui_month(v_td)))
     OR jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'progress' <> '{"pct":20.0,"state":"neutral"}'::jsonb
     OR (v_it->>'gap')::boolean IS NOT FALSE
     OR v_it->'details' <> jsonb_build_array(
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object('account', '__apgl_giro__')),
                             'value', finance.fn_app_order_line((SELECT id FROM finance.recurring_payments WHERE name = '__apgl_rp_goal__'))),
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object('account', '__apgl_pot__')),
                             'value', core.fn_ui_money(2000, 'EUR')),
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_target_date'), 'value', core.fn_ui_date(v_td))) THEN
    RAISE EXCEPTION 'FAIL [1l] Ziel im Plan: Untertitel Monat, keine Pille, neutraler Balken, Rate vom Dauerauftrag, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_hh_behind__';
  IF NOT EXISTS (SELECT 1 FROM finance.savings_goal_progress p
                  WHERE p.name = '__apgl_hh_behind__' AND p.behind_amount > 0
                    AND v_it->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                                         'finance.app.goals.pace.behind_gap', jsonb_build_object('gap', core.fn_ui_money(p.behind_amount, 'EUR')))))
     OR v_it->'progress'->>'state' <> 'warn'
     OR v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
                                                 'value', core.fn_ui_tpl('finance.app.goals.d_rate_none')) THEN
    RAISE EXCEPTION 'FAIL [1m] hinter Plan: warn mit Rueckstand, Balken warn, „keine laufende Rate", got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_hh_chf__';
  IF (v_it->>'gap')::boolean IS NOT TRUE OR jsonb_typeof(v_it->'pill') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1n] CHF-Ziel ohne Kurs: nur gap, keine (zu hohe) Hinter-Plan-Pille, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = 'Alpha Fahrrad';
  IF jsonb_typeof(v_it->'pill') <> 'null' OR jsonb_typeof(v_it->'progress') <> 'null'
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.goals.goal_sub_reached', jsonb_build_object(
                         'target', core.fn_ui_money(500, 'EUR'), 'date', core.fn_ui_date(current_date + 30)))
     OR v_it->'details' <> jsonb_build_array(jsonb_build_object(
          'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object('account', 'Alpha Konto')),
          'value', core.fn_ui_money(500, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [1o] erreicht: keine Pille, kein Balken, „x erreicht · geplant fuer", nur „liegt auf" (ohne „keine laufende Rate", ohne Zieldatum), got %', v_it; END IF;
  -- Sparplan-Ziel: Betrag aller Plaene, Namen nach Monatsbetrag; Ziel mit Plan UND Dauerauftrag: zwei Rate-Zeilen
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = 'Alpha Ziel';
  IF v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
        'value', core.fn_ui_tpl('finance.app.goals.d_rate_plans', jsonb_build_object(
                     'rate', core.fn_ui_money(55, 'EUR'), 'plans', '__apgl_kid_on_hh__, Alpha Sparplan'))) THEN
    RAISE EXCEPTION 'FAIL [1p] Rate aus zwei Sparplaenen (Haushalt sieht beide Namen), got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_mix__';
  IF v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
        'value', core.fn_ui_tpl('finance.app.goals.d_rate_plan', jsonb_build_object(
                     'rate', core.fn_ui_money(100, 'EUR'), 'plans', '__apgl_hh_plan__')))
     OR v_it->'details'->1 <> jsonb_build_object(
        'label', core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object('account', '__apgl_giro__')),
        'value', finance.fn_app_order_line((SELECT id FROM finance.recurring_payments WHERE name = '__apgl_rp_mix__'))) THEN
    RAISE EXCEPTION 'FAIL [1q] Sparplan (Einzahl) + Dauerauftrag = zwei Rate-Zeilen, got %', v_it; END IF;
  -- Depot ohne Kurs: gap an den Zielen des Depots, keine Pille
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_dep_a__' AND (i->>'gap')::boolean AND jsonb_typeof(i->'pill') = 'null') THEN
    RAISE EXCEPTION 'FAIL [1r] Depot ohne Kurs: gap, keine Pille, got %', v_sec; END IF;
  RAISE NOTICE 'PASS [1a-r] Owner: drei Abschnitte, keine gruenen Signale, Sparziele mit Quelle der Rate';

  -- --- Ruecklagen: Notreserve warn zuerst, dann Instandhaltung ---
  v_sec := v->'sections'->0;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['__apgl_emergency__', '__apgl_res_a__', '__apgl_res_b__', '__apgl_res_c__'] THEN
    RAISE EXCEPTION 'FAIL [1s] Ruecklagen: gelb zuerst, got %', v_labels; END IF;
  v_it := v_sec->'items'->0;
  IF v_it->'value' <> core.fn_ui_money(400, 'EUR')
     OR v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                          'finance.app.goals.missing', jsonb_build_object('gap', core.fn_ui_money(600, 'EUR'))))
     OR v_it->'progress' <> '{"pct":40.0,"state":"warn"}'::jsonb
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.goals.emergency_sub_amount', jsonb_build_object('target', core.fn_ui_money(1000, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [1t] Notreserve unvollstaendig: warn fehlen 600, Balken, Ziel 1000, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_res_a__';
  IF NOT EXISTS (SELECT 1 FROM finance.maintenance_reserve_status m
                  WHERE m.goal_name = '__apgl_res_a__' AND m.recommended_monthly IS NOT NULL AND m.gap_monthly_eur > 0
                    AND v_it->'value' = core.fn_ui_money(0, 'EUR')
                    AND jsonb_typeof(v_it->'progress') = 'null'
                    AND v_it->'sub' = core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object('rate', core.fn_ui_money(50, 'EUR')))
                    AND v_it->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                                         'finance.app.goals.reserve_low', jsonb_build_object('gap', core.fn_ui_money(m.gap_monthly_eur, 'EUR'))))
                    AND v_it->'details' = jsonb_build_array(
                          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object('account', '__apgl_giro__')),
                                             'value', finance.fn_app_order_line((SELECT id FROM finance.recurring_payments WHERE name = '__apgl_rp_res__'))),
                          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_guide'),
                                             'value', core.fn_ui_tpl('finance.app.goals.d_guide_value', jsonb_build_object(
                                                 'monthly', core.fn_ui_money(m.recommended_monthly, 'EUR'),
                                                 'area', core.fn_ui_num(100, 0),
                                                 'rate', core.fn_ui_money(m.rate_eur_m2, 'EUR')))),
                          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_property'), 'value', '__apgl_re1__'))) THEN
    RAISE EXCEPTION 'FAIL [1u] Instandhaltung: „x im Monat", warn unter Richtwert, Rate von Konto, Richtwert-Zeile, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_res_b__';
  IF jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'details' <> jsonb_build_array(
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'), 'value', core.fn_ui_tpl('finance.app.goals.d_rate_none')),
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_missing'), 'value', NULL),
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_property'), 'value', '__apgl_re2__')) THEN
    RAISE EXCEPTION 'FAIL [1v] Instandhaltung ohne Flaeche/Baujahr: keine Pille, „fehlen", got %', v_it; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i, finance.maintenance_reserve_status m
                  WHERE i->>'label' = '__apgl_res_c__' AND m.goal_name = '__apgl_res_c__'
                    AND m.gap_monthly_eur > 0 AND jsonb_typeof(i->'pill') = 'null') THEN
    RAISE EXCEPTION 'FAIL [1w] Ruecklage einer verkauften Immobilie: keine Pille'; END IF;
  RAISE NOTICE 'PASS [1s-w] Ruecklagen: Notreserve warn, Instandhaltung mit Richtwert, Reihenfolge';

  -- --- Sparplaene ---
  v_sec := v->'sections'->2;
  SELECT sum(finance.fn_to_eur(o.monthly_amount, o.currency)) INTO v_n FROM finance.savings_plan_overview o WHERE o.status = 'active';
  IF v_sec->'value' <> core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object('rate', core.fn_ui_money(v_n, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [1x] Sparplan-Summe % im Monat, got %', v_n, v_sec->'value'; END IF;
  -- warn: das Tage-Konto UND seit Paket B (Ziel-Geld ist nicht frei) das Kinderkonto (500 von 1000 fuer „Alpha Fahrrad“)
  IF v_sec->'items'->0->>'label' <> '__apgl_low_plan__'
     OR NOT (jsonb_build_array(v_sec->'items'->1->>'label', v_sec->'items'->2->>'label') @> '["__apgl_days_plan__", "Alpha Sparplan"]'::jsonb)
     OR v_sec->'items'->-1->>'label' <> '__apgl_a_paused__' THEN
    RAISE EXCEPTION 'FAIL [1y] Sparplaene: alert, warn, aktiv, pausiert zuletzt, got %', v_sec->'items'; END IF;
  v_it := v_sec->'items'->0;
  -- Spiegel-Pille = dasselbe Urteil + dieselbe Pille wie die Konten-Zeile (fn_account_low_state + fn_app_low_state_pill)
  IF v_it->'pill' <> jsonb_build_object('state', 'alert', 'icon', 'alert', 'text', core.fn_ui_tpl(
                       'finance.app.accounts.pill_gap', jsonb_build_object('date', core.fn_ui_date(current_date + 3))))
     OR v_it->'pill' <> finance.fn_app_low_state_pill(finance.fn_account_low_state(v_low)) THEN
    RAISE EXCEPTION 'FAIL [1z] leeres Abbuchungskonto: alert „Luecke ab" mit Datum = Konten-Pille, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_days_plan__';
  IF v_it->'pill'->>'state' <> 'warn' OR v_it->'pill'->'text'->>'value' <> 'finance.app.accounts.pill_until'
     OR v_it->'pill'->'text'->'params'->'month'->>'kind' <> 'month'
     OR v_it->'pill' <> finance.fn_app_low_state_pill(finance.fn_account_low_state(v_broker))
     OR v_it->'value' <> core.fn_ui_money(100, 'EUR')
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.goals.plan_days_next', jsonb_build_object(
                         'n', core.fn_ui_num(4), 'amount', core.fn_ui_money(25, 'EUR'),
                         'date', core.fn_ui_date((SELECT o.next_execution FROM finance.savings_plan_overview o WHERE o.name = '__apgl_days_plan__')))) THEN
    RAISE EXCEPTION 'FAIL [1z2] feste Tage: „4x monatlich je 25", warn „reicht bis" als Monat, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_hh_plan__';
  IF v_it->'value' <> core.fn_ui_money(100, 'EUR')
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.goals.plan_next', jsonb_build_object('date', core.fn_ui_date(current_date + 5)))
     OR jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'details' <> jsonb_build_array(
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_security'), 'value', 'Welt ETF'),
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_depot'), 'value', '__apgl_hh_depot__'),
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_from'), 'value', '__apgl_giro__'),
          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_goal'), 'value', '__apgl_mix__')) THEN
    RAISE EXCEPTION 'FAIL [1z3] Plan einmal monatlich: „naechste", gedeckt ohne Pille, Details ohne ISIN, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_week_plan__';
  IF v_it->'sub' <> finance.fn_app_order_line((SELECT id FROM finance.recurring_payments WHERE name = '__apgl_rp_week__')) THEN
    RAISE EXCEPTION 'FAIL [1z4] woechentlich: Rhythmus-Zeile, got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v_sec->'items') i WHERE i->>'label' = '__apgl_change_plan__';
  IF v_it->'value' <> core.fn_ui_money(40, 'EUR')
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.goals.plan_next', jsonb_build_object('date',
                         core.fn_ui_date((SELECT o.next_execution FROM finance.savings_plan_overview o WHERE o.name = '__apgl_change_plan__'))))
     OR NOT (v_it->'details' @> jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_change'),
                'value', finance.fn_app_order_line((SELECT id FROM finance.recurring_payments WHERE name = '__apgl_rp_chg_new__'))))) THEN
    RAISE EXCEPTION 'FAIL [1z5] geplante Aenderung: Wert/Untertitel aus dem heutigen Glied, Aenderung im Aufklappen, got %', v_it; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_a_paused__' AND jsonb_typeof(i->'sub') = 'null'
                    AND i->'pill' = jsonb_build_object('state', 'neutral', 'icon', 'pause', 'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))) THEN
    RAISE EXCEPTION 'FAIL [1z6] pausierter Sparplan'; END IF;
  RAISE NOTICE 'PASS [1x-z] Sparplaene: Summe, Reihenfolge, Spiegel-Pillen, Untertitel aus dem heutigen Glied';

  IF finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_partner')) <> v THEN
    RAISE EXCEPTION 'FAIL [1u2] Partner muss die Haushalts-Sicht bekommen'; END IF;
  RAISE NOTICE 'PASS [1u2] Partner = Haushalts-Sicht';

  -- --- Depot-Deckung: Delle still, Einbruch alert mit Depot-Name an jedem Ziel des Depots ---
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APGLX', 122, 'EUR', current_date);   -- 244 von 250: Delle
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->1->'items') i
              WHERE i->>'label' IN ('__apgl_dep_a__', '__apgl_dep_b__', 'Alpha Roller') AND (jsonb_typeof(i->'pill') <> 'null' OR (i->>'gap')::boolean)) THEN
    RAISE EXCEPTION 'FAIL [1da] Kursdelle unter der Schwelle: keine Pille, kein gap, got %', v->'sections'->1; END IF;
  UPDATE finance.market_prices SET price = 90 WHERE symbol = 'APGLX';                                                -- 180 von 250: Einbruch
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  IF (SELECT count(*) FROM jsonb_array_elements(v->'sections'->1->'items') i
       WHERE i->>'label' IN ('__apgl_dep_a__', '__apgl_dep_b__', 'Alpha Roller')
         AND i->'pill' = jsonb_build_object('state', 'alert', 'icon', 'alert', 'text', core.fn_ui_tpl(
                           'finance.app.goals.cover_short', jsonb_build_object('depot', '__apgl_hh_depot__', 'gap', core.fn_ui_money(70, 'EUR'))))
         AND i->'progress'->>'state' = 'alert') <> 3
     OR v->'sections'->1->'items'->0->'pill'->>'state' <> 'alert' THEN
    RAISE EXCEPTION 'FAIL [1db] Einbruch ab Schwelle: alert „<Depot>: Kurswert 70 unter dem Zurueckgelegten" an allen drei Zielen, zuerst, got %', v->'sections'->1; END IF;
  RAISE NOTICE 'PASS [1d] Depot-Deckung: Delle still, Einbruch alert mit Depot-Name';

  -- --- Kind: nur Eigenes; Eltern-Depot gibt keine Pille her; Rate nennt nur eigene Plaene ---
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_kid', 'params', '{}'::jsonb));
  v_txt := v::text;
  IF v_txt LIKE '%__apgl_%' THEN RAISE EXCEPTION 'FAIL [2a] Kind-Antwort enthaelt fremde Namen: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [2b] Antwort traegt ein *id-Feld: %', v_txt; END IF;
  IF v_txt NOT LIKE '%Alpha Fahrrad%' OR v_txt NOT LIKE '%Alpha Sparplan%' THEN RAISE EXCEPTION 'FAIL [2c] eigenes Ziel/eigener Plan fehlt: %', v_txt; END IF;
  SELECT array_agg(s->'title'->>'value' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o);
  IF v_labels IS DISTINCT FROM ARRAY['finance.app.goals.section_goals', 'finance.app.goals.section_plans'] THEN
    RAISE EXCEPTION 'FAIL [2d] Kind: Sparziele + Sparplaene, got %', v_labels; END IF;
  IF jsonb_typeof(v->'sections'->1->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2e] eine Plan-Zeile -> keine Summe, got %', v->'sections'->1; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = 'Alpha Roller';
  IF jsonb_typeof(v_it->'pill') <> 'null' OR (v_it->>'gap')::boolean
     OR NOT (v_it->'details' @> jsonb_build_array(jsonb_build_object(
               'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object(
                            'account', core.fn_ui_tpl('finance.app.common.household_account'))),
               'value', core.fn_ui_money(50, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [2f] Kind-Ziel auf Eltern-Depot: keine Pille, „Haushaltskonto", got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = 'Alpha Ziel';
  IF v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
        'value', core.fn_ui_tpl('finance.app.goals.d_rate_plans', jsonb_build_object(
                     'rate', core.fn_ui_money(55, 'EUR'), 'plans', 'Alpha Sparplan'))) THEN
    RAISE EXCEPTION 'FAIL [2g] Kind: Rate zaehlt alle Plaene, nennt nur den eigenen (Mehrzahl nach Gesamtzahl), got %', v_it; END IF;
  IF v_txt LIKE '%finance.app.goals.d_from%' THEN RAISE EXCEPTION 'FAIL [2h] Kind sieht kein Abbuchungskonto'; END IF;
  SELECT string_agg(l.rule || ' ' || l.path, '; ') INTO v_txt
    FROM core.fn_app_view_lint(v, ARRAY['finance.app.goals.pace.paused', 'finance.app.goals.pace.unmeasurable'], '{}') l;
  IF v_txt IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2h2] fn_app_view_lint Kind: %', v_txt; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur Eigenes, Eltern-Depot still, Rate ohne fremde Namen, keine IDs';

  -- ===== 2b) Review: Ziel ohne Geld mehr im Depot bekommt keine Depot-Pille; fremder Plan ohne Kurs fuer das Kind =====
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__apgl_dep_zero__', 150, v_td) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES
    (v_goal, v_hh_depot, 100, 'manual'), (v_goal, v_hh_depot, -100, 'manual');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id)
    VALUES ('Alpha Franken', 100, current_date + 300, 'apgl_kid') RETURNING id INTO v_goal;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_chf_plan__', v_chf, -10, 'month', current_date + 5, current_date + 5) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id, savings_goal_id)
    VALUES ('__apgl_chf_plan__', v_hh_depot, 'APGLF', 'Franken ETF', v_rp, 'apgl_kid', v_goal);
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->1->'items') i WHERE i->>'label' = '__apgl_dep_zero__';
  IF jsonb_typeof(v_it->'pill') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2i] Ziel ohne Anteil am eingebrochenen Depot: keine Pille, got %', v_it; END IF;
  IF jsonb_typeof(v->'sections'->2->'value') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2j] Plan ohne Wechselkurs: keine Sparplan-Summe, got %', v->'sections'->2->'value'; END IF;
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_kid'));
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = 'Alpha Franken';
  IF (v_it->>'gap')::boolean IS NOT TRUE
     OR v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
                                                 'value', core.fn_ui_tpl('finance.app.goals.d_rate_plans_anon_nofx')) THEN
    RAISE EXCEPTION 'FAIL [2k] Kind: fremder Plan ohne Kurs -> „aus Sparplaenen" ohne Namen/Betrag + gap, got %', v_it; END IF;
  DELETE FROM finance.savings_plans WHERE name = '__apgl_chf_plan__';
  DELETE FROM finance.savings_goals WHERE name IN ('__apgl_dep_zero__', 'Alpha Franken');
  RAISE NOTICE 'PASS [2b] Depot-Pille nur mit Anteil; fremder Plan ohne Kurs anonym mit gap';

  -- ===== 3) Allow-List =====
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_guest'));
  IF v->'hero'->'value' <> core.fn_ui_money(300, 'EUR') OR v::text LIKE '%__apgl_hh_%' OR v::text LIKE '%__apgl_res_%'
     OR v::text LIKE '%__apgl_pot__%' OR v::text LIKE '%__apgl_emergency__%' THEN
    RAISE EXCEPTION 'FAIL [3a] unbekannte Rolle nur Eigenes (300), fremder Topf ohne Namen, got %', v; END IF;
  IF NOT (v->'sections'->0->'items'->0->'details' @> jsonb_build_array(jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object(
                         'account', core.fn_ui_tpl('finance.app.common.household_account'))),
            'value', core.fn_ui_money(300, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [3a2] fremdes Konto heisst „Haushaltskonto", got %', v->'sections'->0; END IF;
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_nobody'));
  IF (v->>'ok')::boolean IS NOT TRUE OR v->'hero'->'value' <> core.fn_ui_money(0, 'EUR')
     OR jsonb_array_length(v->'sections') <> 1 OR jsonb_array_length(v->'sections'->0->'items') <> 0
     OR v->'sections'->0->'empty' <> core.fn_ui_tpl('finance.app.goals.empty') THEN
    RAISE EXCEPTION 'FAIL [3b] unbekannte Person: leerer Bildschirm, got %', v; END IF;
  RAISE NOTICE 'PASS [3] Allow-List';

  -- ===== 4) probe: nur „hinter Plan" (kein Notreserve-, kein Konto-Banner) =====
  v := finance.fn_app_screen_goals('{"person_id":"apgl_owner","params":{"probe":true}}');
  IF v <> jsonb_build_object('ok', true, 'empty', false, 'banners', jsonb_build_array(jsonb_build_object(
            'state', 'warn', 'icon', 'alert',
            'text', core.fn_ui_tpl('finance.app.goals.banner_behind', jsonb_build_object('name', '__apgl_hh_behind__')),
            'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb)))) THEN
    RAISE EXCEPTION 'FAIL [4a] probe Owner: genau ein Banner (behind ohne fx-Luecke), got %', v; END IF;
  IF finance.fn_app_screen_goals('{"person_id":"apgl_kid","params":{"probe":true}}') <> '{"ok":true,"empty":false,"banners":[]}'::jsonb
     OR finance.fn_app_screen_goals('{"person_id":"apgl_nobody","params":{"probe":true}}') <> '{"ok":true,"empty":true,"banners":[]}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4b] probe Kind/unbekannt'; END IF;
  RAISE NOTICE 'PASS [4] probe {ok, empty, banners}';

  -- ===== 4b) Spiegel-Pille verdict buffer + Startseiten-Hinweis fuer ein Kinder-Konto (nicht auf dem Konten-Tab) =====
  DECLARE v_stmt int; v_kleer int; BEGIN
    -- Konto MIT Kontoauszug, 300 Stand, Sparplan 400 in 4 Tagen -> tiefster Stand -100 < Puffer -> „x unter dem Puffer"
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_stmt__', 'cash', 'EUR', 'active') RETURNING id INTO v_stmt;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_stmt, 300, current_date - 40, 'other');
    UPDATE finance.accounts SET last_reconciled_at = current_date - 5 WHERE id = v_stmt;
    INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
        line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at, oneoff_out, oneoff_threshold)
      VALUES (v_stmt, current_date - 34, current_date - 5, 300, 300, 'EUR', 0, 0, 0, 0, NULL, 0, NULL);
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('__apgl_rp_stmt__', v_stmt, -400, 'month', current_date + 4, current_date + 4) RETURNING id INTO v_rp;
    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
      VALUES ('__apgl_stmt_plan__', v_hh_depot, 'APGLS', 'Auszug ETF', v_rp);
    -- Kinder-Konto ohne Guthaben, eigener Sparplan in 3 Tagen -> alert; steht in der Haushalts-Sicht NICHT auf Konten
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('Alpha Leer', 'cash', 'EUR', 'active', 'apgl_kid') RETURNING id INTO v_kleer;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('Alpha Leer Rate', v_kleer, -20, 'month', current_date + 3, current_date + 3) RETURNING id INTO v_rp;
    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id)
      VALUES ('Alpha Leerplan', v_kid_depot, 'APGLL', 'Leer Kinder ETF', v_rp, 'apgl_kid');
    -- Kinder-Konto, das nur per Dauerauftrag etwas fuellt (fn_funding_accounts kind order_source), ohne Guthaben
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('Alpha Quelle', 'cash', 'EUR', 'active', 'apgl_kid') RETURNING id INTO v_rp;
    INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('Alpha Quelle Uebertrag', v_rp, v_kid_cash, -15, 'month', current_date + 3, current_date + 3);

    v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
    SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->2->'items') i WHERE i->>'label' = '__apgl_stmt_plan__';
    IF v_it->'pill'->>'state' <> 'alert' OR v_it->'pill'->'text'->>'value' <> 'finance.app.accounts.pill_short'
       OR (v_it->'pill'->'text'->'params'->'amount'->>'value')::numeric
          IS DISTINCT FROM (finance.fn_account_low_state(v_stmt)->>'short_by')::numeric
       OR (finance.fn_account_low_state(v_stmt)->>'short_by')::numeric <= 0 THEN
      RAISE EXCEPTION 'FAIL [4c] Konto mit Auszug: alert „x unter dem Puffer" mit short_by, got % / %', v_it, finance.fn_account_low_state(v_stmt); END IF;

    v := finance.fn_app_screen_goals('{"person_id":"apgl_owner","params":{"probe":true}}');
    IF NOT (v->'banners' @> jsonb_build_array(jsonb_build_object(
              'state', 'alert', 'icon', 'alert',
              'text', core.fn_ui_tpl('finance.app.accounts.banner_gap', jsonb_build_object(
                          'account', 'Alpha Leer', 'date', core.fn_ui_date(current_date + 3))),
              'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb))))
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'banners') b
                       WHERE b->>'state' = 'alert' AND b->'text'->'params'->>'account' = 'Alpha Quelle')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v->'banners') b
                   WHERE b->'text'->'params'->>'account' IN ('__apgl_stmt__', '__apgl_low__')) THEN
      RAISE EXCEPTION 'FAIL [4d] Haushalt: alert-Banner nur fuer Kinder-Konten (Sparplan und Dauerauftrag; gelistete Konten meldet Konten), got %', v; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_app_screen_goals(
                 '{"person_id":"apgl_kid","params":{"probe":true}}')->'banners') b
                WHERE b->'text'->>'value' LIKE 'finance.app.accounts.%') THEN
      RAISE EXCEPTION 'FAIL [4e] Kind: eigenes Konto steht auf seinem Konten-Tab -> kein Konto-Banner von Ziele'; END IF;
    RAISE NOTICE 'PASS [4b] Spiegel-Pille „unter dem Puffer" aus short_by; Kinder-Konto-Banner nur in der Haushalts-Sicht';
  END;

  -- ===== Notreserve voll: keine Pille, kein Balken, „Ziel x erreicht", zuletzt =====
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_emerg, v_giro, 600, 'manual');
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  v_it := v->'sections'->0->'items'->-1;
  IF v_it->>'label' <> '__apgl_emergency__' OR jsonb_typeof(v_it->'pill') <> 'null' OR jsonb_typeof(v_it->'progress') <> 'null'
     OR v_it->'sub' <> core.fn_ui_tpl('finance.app.goals.emergency_sub_reached', jsonb_build_object('target', core.fn_ui_money(1000, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [1ea] volle Notreserve: still, „Ziel 1000 erreicht", zuletzt, got %', v->'sections'->0; END IF;
  RAISE NOTICE 'PASS [1e] Notreserve voll';

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

-- ===== 6) Fixture-Haushalt (tests/util/util_app_household.sql): Regeln §3.12 fuer alle Personen + Konzept §5.3 =====
BEGIN;
\ir ../../util/util_app_household.sql
DO $$
DECLARE
  v jsonb; v_it jsonb; v_pid text; v_lint text;
  v_neutral text[] := ARRAY['finance.app.goals.pace.paused', 'finance.app.goals.pace.unmeasurable'];
BEGIN
  -- core.fn_app_view_lint = 0 Zeilen fuer Owner, Partnerin, beide Kinder, Gast
  FOR v_pid IN SELECT id FROM pg_temp.app_fx WHERE key IN ('p_owner', 'p_partner', 'p_lea', 'p_tom', 'p_guest') LOOP
    v := finance.fn_app_screen_goals(jsonb_build_object('person_id', v_pid));
    IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [6a] % ok erwartet, got %', v_pid, v; END IF;
    SELECT string_agg(l.rule || ' ' || l.path, '; ') INTO v_lint FROM core.fn_app_view_lint(v, v_neutral, '{}') l;
    IF v_lint IS NOT NULL THEN RAISE EXCEPTION 'FAIL [6b] fn_app_view_lint fuer %: %', v_pid, v_lint; END IF;
  END LOOP;

  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'fxh_jonas'));
  -- Kind-Depots: Lea knapp unter dem Ziel-Geld (Delle) -> keine Pille; Tom deutlich darunter -> alert mit Depot-Name
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->1->'items') i WHERE i->>'label' = 'Depot Lea';
  IF jsonb_typeof(v_it->'pill') <> 'null'
     OR v_it->'details'->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
          'value', core.fn_ui_tpl('finance.app.goals.d_rate_plans', jsonb_build_object(
                       'rate', core.fn_ui_money(200, 'EUR'), 'plans', 'ETF World Lea, Einzelaktie Lea'))) THEN
    RAISE EXCEPTION 'FAIL [6c] Depot Lea: Delle ohne Pille, „Rate: 200 im Monat aus Sparplaenen ETF World Lea, Einzelaktie Lea", got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->1->'items') i WHERE i->>'label' = 'Depot Tom';
  IF v_it->'pill'->>'state' <> 'alert' OR v_it->'pill'->'text'->>'value' <> 'finance.app.goals.cover_short'
     OR v_it->'pill'->'text'->'params'->>'depot' <> 'Depot Tom' OR v->'sections'->1->'items'->0->>'label' <> 'Depot Tom' THEN
    RAISE EXCEPTION 'FAIL [6d] Depot Tom: Einbruch ab Schwelle alert mit Depot-Name, zuerst, got %', v->'sections'->1; END IF;
  -- Dauerauftrags-Ziel nennt Konto + Rhythmus; Notreserve fehlen 5.000; kein Notreserve-/Konto-Banner im probe
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->1->'items') i WHERE i->>'label' = 'Fahrrad Mira';
  IF v_it->'details'->0->'label' <> core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object('account', 'Girokonto Jonas')) THEN
    RAISE EXCEPTION 'FAIL [6e] Fahrrad Mira: „Rate von Girokonto Jonas", got %', v_it; END IF;
  SELECT i INTO v_it FROM jsonb_array_elements(v->'sections'->0->'items') i WHERE i->>'label' = 'Notreserve';
  IF v_it->'pill' <> jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                       'finance.app.goals.missing', jsonb_build_object('gap', core.fn_ui_money(5000, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [6f] Notreserve warn fehlen 5000, got %', v_it; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_app_screen_goals(jsonb_build_object(
               'person_id', 'fxh_jonas', 'params', jsonb_build_object('probe', true)))->'banners') b
              WHERE b->'text'->>'value' <> 'finance.app.goals.banner_behind') THEN
    RAISE EXCEPTION 'FAIL [6g] probe: nur „hinter Plan"-Banner'; END IF;
  -- Kinder: Lea sieht ihr Ziel und ihre Plaene, keine Eltern-Namen
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'fxh_lea'));
  IF v::text LIKE '%Jonas%' OR v::text LIKE '%Mira%' OR v::text LIKE '%Tom%' OR v::text NOT LIKE '%ETF World Lea%' THEN
    RAISE EXCEPTION 'FAIL [6h] Lea sieht nur Eigenes, got %', v; END IF;
  RAISE NOTICE 'PASS [6] Fixture-Haushalt: Lint = 0 fuer alle Personen, Rate-Quellen, Depot-Delle/-Einbruch, Notreserve, Kind-Sicht';
END $$;
ROLLBACK;
