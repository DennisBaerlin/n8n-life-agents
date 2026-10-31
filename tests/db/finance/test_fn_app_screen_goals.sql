-- tests/db/finance/test_fn_app_screen_goals.sql
-- finance.fn_app_screen_goals(p jsonb) — Mini-App-Bildschirm „Ziele" (docs/package-contract.md §3.12, View-Modell v1).
--   1) Owner/Partner sehen den Haushalt (Mini-App UX 2026-10-30): Abschnitte Ruecklagen, Sparziele, Sparplaene, Konten;
--      Hero = Sparziele + Ruecklagen + gap bei CHF ohne Kurs (dann ohne Aufschluesselung), Sparziele hinter Plan zuerst
--      (Pille mit Rueckstand behind_amount, ohne Betrag bei fx-Luecke), erreicht zuletzt ohne Balken, Restzeit im
--      Untertitel (nicht bei erreicht), Details = Konten-Anteile (Summe = Zielstand); Ruecklagen mit Empfehlungs-Pill
--      inkl. Betrag (keine Pill ohne Empfehlung), kein Balken, Herleitung; Sparplaene aktiv vor pausiert (Soft-Close und
--      gestoppte Beitraege = pausiert), Wert = Monatsbetrag, Summe im Titel, Deckungs-Pill nur bei Abweichung; Konten
--      (Kontostand, „fuer Ziele"/„Dauerauftraege", Pille nur bei Abweichung: fehlen X / Kurswert X darunter / nicht
--      ermittelbar, Bank-To-do „→ Ziel", Zufluesse, Konto-Zeile); Ruecklage einer verkauften Immobilie ohne Pill.
--   2) Kind sieht nur Eigenes (Ziel beneficiary = ich; Sparplan beneficiary = ich UND eigenes Depot): Volltextsuche ohne
--      fremde Namen und ohne *id-Feld; eigener Sparplan auf einem Eltern-Depot bleibt unsichtbar.
--   3) unbekannte Rolle sieht nur Eigenes, unbekannte Person nichts.
--   4) probe -> {ok, empty, banners}: Banner nur fuer "hinter Plan" ohne fx-Luecke, target = goals.
--   5) Muell -> bad_request ohne RAISE; Frei-SQL-Sitzung -> forbidden, kein EXECUTE fuer *_ro.
--   6) Dauerauftraege: Zufluesse am Sparplan („Geld kommt von", extern mit Namen), Tag + „ab", Kind sieht verborgene
--      Konten neutral, alert-Banner nur fuer sichtbare Deckungs-Konten.
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
  -- Guthaben, damit die Deckungs-Pillen der Sparplaene gruen sind (Luecke -> eigener Fall in 6)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 10000, current_date - 40, 'other'),
                                                                                         (v_kid_cash, 1000, current_date - 40, 'other');

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
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, recurring_payment_id) VALUES ('__apgl_res_a__', 'maintenance_reserve', v_re1, v_rp);
  INSERT INTO finance.savings_goals (name, kind, real_estate_id) VALUES ('__apgl_res_b__', 'maintenance_reserve', v_re2);
  INSERT INTO finance.real_estate (name, current_value, living_area_m2, year_built, status) VALUES ('__apgl_re3__', 1, 100, 1990, 'sold') RETURNING id INTO v_re3;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id) VALUES ('__apgl_res_c__', 'maintenance_reserve', v_re3);   -- verkauft: Empfehlung bekannt, aber keine Pill

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
  -- Hero: 2000 + 1000 + 0 (CHF ohne Kurs) + 500 (Kind) + 3000 (Partner) + 300 (Gast) + Ruecklagen 0; gap -> keine Note
  IF v->'hero'->'value' <> core.fn_ui_money(6800, 'EUR') OR (v->'hero'->>'gap')::boolean IS NOT TRUE
     OR jsonb_typeof(v->'hero'->'note') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1c] Hero 6800 EUR + gap ohne Note erwartet, got %', v->'hero'; END IF;
  IF jsonb_array_length(v->'banners') <> 0 THEN RAISE EXCEPTION 'FAIL [1d] Banner nur in der probe-Antwort, got %', v->'banners'; END IF;
  SELECT array_agg(s->'title'->>'value' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o);
  IF v_labels IS DISTINCT FROM ARRAY['finance.app.goals.section_reserves', 'finance.app.goals.section_goals',
                                     'finance.app.goals.section_plans', 'finance.app.goals.section_accounts'] THEN
    RAISE EXCEPTION 'FAIL [1e] 4 Abschnitte erwartet, got %', v_labels; END IF;

  v_sec := v->'sections'->1;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.goals.section_goals') THEN RAISE EXCEPTION 'FAIL [1f] Abschnitt Sparziele'; END IF;
  IF jsonb_typeof(v_sec->'value') <> 'null' THEN RAISE EXCEPTION 'FAIL [1f2] Sparziel-Summe entfaellt bei fx-Luecke, got %', v_sec->'value'; END IF;
  -- hinter Plan zuerst (behind, CHF behind), dann nach Datum/Prioritaet/Name, erreicht zuletzt
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['__apgl_hh_behind__', '__apgl_hh_chf__', '__apgl_hh_goal__', '__apgl_p_goal__', '__apgl_g_goal__', 'Alpha Fahrrad'] THEN
    RAISE EXCEPTION 'FAIL [1g] Reihenfolge hinter Plan / Datum / erreicht, got %', v_labels; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_hh_goal__'
                    AND i->'value' = core.fn_ui_money(2000, 'EUR')
                    AND i->'sub'->>'value' = 'finance.app.goals.target_left'
                    AND i->'sub'->'params'->'target' = core.fn_ui_money(10000, 'EUR')
                    AND i->'sub'->'params'->'left' = core.fn_ui_tpl('finance.app.goals.left_m', jsonb_build_object(
                                     'months', core.fn_ui_num(extract(month FROM age(v_td, current_date)))))
                    AND i->'details' = jsonb_build_array(
                          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_target_date'), 'value', core.fn_ui_date(v_td)),
                          jsonb_build_object(
                                     'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object('account', '__apgl_pot__')),
                                     'value', core.fn_ui_money(2000, 'EUR')))
                    AND i->'pill' = jsonb_build_object('state', 'ok', 'icon', 'check', 'text', core.fn_ui_tpl('finance.app.goals.pace.on_track'))
                    AND i->'progress' = '{"pct":20.0,"state":"ok"}'::jsonb
                    AND (i->>'gap')::boolean IS FALSE) THEN
    RAISE EXCEPTION 'FAIL [1h] on_track-Ziel (Wert, Sub, Pill, Balken), got %', v_sec; END IF;
  -- hinter Plan: Pille nennt den Rueckstand aus savings_goal_progress.behind_amount (DB rechnet)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i, finance.savings_goal_progress p
                  WHERE i->>'label' = '__apgl_hh_behind__' AND p.name = '__apgl_hh_behind__' AND p.behind_amount > 0
                    AND i->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                                      'finance.app.goals.pace.behind_gap', jsonb_build_object('gap', core.fn_ui_money(p.behind_amount, 'EUR'))))
                    AND i->'progress'->>'state' = 'warn') THEN
    RAISE EXCEPTION 'FAIL [1i] behind-Ziel warn mit Rueckstand, got %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = 'Alpha Fahrrad'
                    AND i->'pill' = jsonb_build_object('state', 'ok', 'icon', 'check', 'text', core.fn_ui_tpl('finance.app.goals.pace.reached'))
                    AND jsonb_typeof(i->'progress') = 'null'
                    AND i->'sub'->>'value' = 'finance.app.goals.target_by') THEN
    RAISE EXCEPTION 'FAIL [1j] erreichtes Ziel (ohne Restzeit, ohne Balken)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_hh_chf__' AND (i->>'gap')::boolean
                    AND i->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.goals.pace.behind'))) THEN
    RAISE EXCEPTION 'FAIL [1k] CHF-Ziel ohne Kurs: gap + „hinter Plan" ohne Betrag (waere zu hoch)'; END IF;
  IF v::text LIKE '%__apgl_done__%' THEN RAISE EXCEPTION 'FAIL [1l] abgeschlossenes Ziel sichtbar'; END IF;

  -- Konten: Topf traegt 2000 + 1000 + 3000 + 300 bei Saldo 0 -> „fehlen 6300", Wert = Kontostand 0, kein Balken
  v_sec := v->'sections'->3;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_pot__' AND i->'value' = core.fn_ui_money(0, 'EUR')
                    AND i->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                                      'finance.app.goals.missing', jsonb_build_object('gap', core.fn_ui_money(6300, 'EUR'))))
                    AND jsonb_typeof(i->'progress') = 'null'
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.accounts_reserved', jsonb_build_object(
                                     'reserved', core.fn_ui_money(6300, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1v] Konten: Topf fehlen 6300, got %', v_sec; END IF;
  IF v_sec->'items'->0->>'label' <> '__apgl_pot__' THEN RAISE EXCEPTION 'FAIL [1v2] Abweichung zuerst, got %', v_sec; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
              WHERE s->'title'->>'value' IN ('finance.app.goals.section_plans', 'finance.app.goals.section_accounts')
                AND i->'pill'->>'state' = 'ok') THEN
    RAISE EXCEPTION 'FAIL [1v3] keine gruenen Nebenbefund-Pillen (Sparplaene/Konten), got %', v; END IF;

  v_sec := v->'sections'->0;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.goals.section_reserves') THEN RAISE EXCEPTION 'FAIL [1m] Abschnitt Ruecklagen'; END IF;
  IF v_sec->'value' <> core.fn_ui_money(0, 'EUR') THEN RAISE EXCEPTION 'FAIL [1m2] Ruecklagen-Summe 0, got %', v_sec->'value'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['__apgl_res_a__', '__apgl_res_b__', '__apgl_res_c__'] THEN RAISE EXCEPTION 'FAIL [1n] Ruecklagen, got %', v_labels; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i, finance.maintenance_reserve_status m
                  WHERE i->>'label' = '__apgl_res_a__' AND m.goal_name = '__apgl_res_a__'
                    AND m.recommended_monthly IS NOT NULL AND m.gap_monthly_eur > 0
                    AND i->'value' = core.fn_ui_money(0, 'EUR')
                    AND jsonb_typeof(i->'progress') = 'null'
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.reserve_rate_rec', jsonb_build_object(
                                     'rate', core.fn_ui_money(50, 'EUR'), 'recommended', core.fn_ui_money(m.recommended_monthly, 'EUR')))
                    AND i->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                                      'finance.app.goals.reserve_low', jsonb_build_object('gap', core.fn_ui_money(m.gap_monthly_eur, 'EUR'))))) THEN
    RAISE EXCEPTION 'FAIL [1o] Ruecklage mit Empfehlung (Rate, Empfehlung, Pill mit Betrag, kein Balken), got %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_res_b__' AND jsonb_typeof(i->'pill') = 'null'
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object('rate', core.fn_ui_money(0, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1p] Ruecklage ohne Empfehlung: keine Pill'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i, finance.maintenance_reserve_status m
                  WHERE i->>'label' = '__apgl_res_c__' AND m.goal_name = '__apgl_res_c__'
                    AND m.gap_monthly_eur > 0 AND jsonb_typeof(i->'pill') = 'null') THEN
    RAISE EXCEPTION 'FAIL [1p2] Ruecklage einer verkauften Immobilie: keine Pill (wie der Berater)'; END IF;
  -- Herleitung der Empfehlung (II. BV) zum Aufklappen, Werte aus maintenance_reserve_status
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i, finance.maintenance_reserve_status m
                  WHERE i->>'label' = '__apgl_res_a__' AND m.goal_name = '__apgl_res_a__'
                    AND i->'details' = jsonb_build_array(
                        jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_property'), 'value', '__apgl_re1__'),
                        jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_area'),
                            'value', core.fn_ui_tpl('finance.app.goals.d_area_value', jsonb_build_object('area', core.fn_ui_num(100, 0)))),
                        jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_built'),
                            'value', core.fn_ui_tpl('finance.app.goals.d_built_value', jsonb_build_object(
                                'year', '1990', 'age', core.fn_ui_num(m.age_years)))),
                        jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate_m2'),
                            'value', core.fn_ui_tpl('finance.app.goals.d_rate_m2_value', jsonb_build_object(
                                'rate', core.fn_ui_money(m.rate_eur_m2, 'EUR')))),
                        jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_recommended'),
                            'value', core.fn_ui_tpl('finance.app.goals.d_recommended_value', jsonb_build_object(
                                'annual', core.fn_ui_money(m.recommended_annual, 'EUR'),
                                'monthly', core.fn_ui_money(m.recommended_monthly, 'EUR')))),
                        jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_running'),
                            'value', core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                'rate', core.fn_ui_money(50, 'EUR')))))
                    AND m.recommended_annual = round(100 * m.rate_eur_m2, 2)) THEN
    RAISE EXCEPTION 'FAIL [1x] Ruecklage: Herleitung Flaeche/Baujahr/Satz/Empfehlung/Rate, got %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_res_b__'
                    AND i->'details' @> jsonb_build_array(jsonb_build_object(
                        'label', core.fn_ui_tpl('finance.app.goals.d_missing'), 'value', NULL))) THEN
    RAISE EXCEPTION 'FAIL [1x2] Ruecklage ohne Flaeche/Baujahr: Hinweis „fehlt"'; END IF;

  v_sec := v->'sections'->2;
  IF v_sec->'title' <> core.fn_ui_tpl('finance.app.goals.section_plans') THEN RAISE EXCEPTION 'FAIL [1q] Abschnitt Sparplaene'; END IF;
  -- Summe der aktiven Plaene im Titel: 100 + 25 (Kind) + 30 (Kind auf Eltern-Depot)
  IF v_sec->'value' <> core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object('rate', core.fn_ui_money(155, 'EUR'))) THEN
    RAISE EXCEPTION 'FAIL [1q2] Sparplan-Summe 155 im Monat, got %', v_sec->'value'; END IF;
  SELECT array_agg(i->>'label' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v_sec->'items') WITH ORDINALITY AS t(i, o);
  IF v_labels IS DISTINCT FROM ARRAY['Alpha Sparplan', '__apgl_hh_plan__', '__apgl_kid_on_hh__', '__apgl_a_paused__', '__apgl_closed__'] THEN
    RAISE EXCEPTION 'FAIL [1r] Sparplaene aktiv vor pausiert (Soft-Close = pausiert), got %', v_labels; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_hh_plan__'
                    AND i->'value' = core.fn_ui_money(100, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.plan_next', jsonb_build_object('date', core.fn_ui_date(current_date + 5)))
                    AND jsonb_typeof(i->'pill') = 'null'
                    AND i->'details'->0 = jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_security'), 'value', 'Welt ETF')
                    AND i->'details'->1 = jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_depot'), 'value', '__apgl_hh_depot__')
                    AND i->'details'->2 = jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_from'), 'value', '__apgl_giro__')
                    AND jsonb_array_length(i->'details') = 3) THEN
    RAISE EXCEPTION 'FAIL [1s] aktiver Sparplan (Monatsbetrag, je Ausfuehrung, gedeckt = keine Pill, Details ohne Konto), got %', v_sec; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_a_paused__' AND jsonb_typeof(i->'sub') = 'null'
                    AND i->'pill' = jsonb_build_object('state', 'neutral', 'icon', 'pause', 'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))) THEN
    RAISE EXCEPTION 'FAIL [1t] pausierter Sparplan'; END IF;
  -- Konten: Giro = Kontostand, Dauerauftraege im Monat (Ruecklagen-Rate Giro -> Topf, Tag frei), gedeckt = keine Pill,
  -- Details Bank-To-do + zuletzt die Konto-Zeile; Sparplan-Ausfuehrungen stehen nur unter Sparplaene
  v_sec := v->'sections'->3;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                  WHERE i->>'label' = '__apgl_giro__'
                    AND i->'value' = core.fn_ui_money(10000, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.accounts_orders', jsonb_build_object('monthly', core.fn_ui_money(50, 'EUR')))
                    AND jsonb_typeof(i->'pill') = 'null'
                    AND i->'details'->0 = jsonb_build_object(
                          'label', core.fn_ui_tpl('finance.app.goals.d_order_to', jsonb_build_object('account', '__apgl_pot__')),
                          'value', core.fn_ui_tpl('finance.app.goals.amount_rhythm', jsonb_build_object(
                                       'amount', core.fn_ui_money(50, 'EUR'),
                                       'rhythm', core.fn_ui_tpl('finance.app.goals.rhythm_month_free', jsonb_build_object(
                                                     'day', core.fn_ui_num(extract(day FROM current_date - 30)))))))
                    AND i->'details'->-1->'label' = core.fn_ui_tpl('finance.app.goals.d_fund_account', jsonb_build_object('account', '__apgl_giro__'))
                    AND i->'details'->-1->'value'->>'value' = 'finance.app.goals.d_fund_summary') THEN
    RAISE EXCEPTION 'FAIL [1y] Konten: Giro 10000, Dauerauftraege 50/Monat, Bank-To-do + Konto-Zeile, got %', v_sec; END IF;
  RAISE NOTICE 'PASS [1] Owner: 4 Abschnitte, Hero + gap, Reihenfolge, Pillen mit Betraegen, Ruecklagen + Herleitung, Sparplaene, Konten';

  IF finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_partner')) <> v THEN
    RAISE EXCEPTION 'FAIL [1u] Partner muss die Haushalts-Sicht bekommen'; END IF;
  RAISE NOTICE 'PASS [1u] Partner = Haushalts-Sicht';

  -- Depot-Reserve: Position ohne Kurs -> nicht ermittelbar + gap, nie gruen
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_hh_depot, 'APG00000009', 'APGLX', '__apgl_noprice__', 1, 100, 'EUR');
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__apgl_dep_goal__', 1000, v_td) RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_goal, v_hh_depot, 100, 'manual');
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->3->'items') i
                  WHERE i->>'label' = '__apgl_hh_depot__' AND (i->>'gap')::boolean AND jsonb_typeof(i->'progress') = 'null'
                    AND i->'pill' = jsonb_build_object('state', 'neutral', 'icon', 'info', 'text', core.fn_ui_tpl('finance.app.goals.cover_unknown'))) THEN
    RAISE EXCEPTION 'FAIL [1w] Depot-Reserve ohne Kurs: nicht ermittelbar + gap, kein Balken, got %', v->'sections'->3; END IF;
  -- Konten-Anteile eines Ziels ergeben den Zielstand
  IF (SELECT sum((d->'value'->>'value')::numeric) FROM jsonb_array_elements(v->'sections'->1->'items') i,
            jsonb_array_elements(i->'details') d
       WHERE i->>'label' = '__apgl_dep_goal__' AND d->'label'->>'value' = 'finance.app.goals.d_on_account') IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL [1w2] Konten-Anteile = Zielstand 100'; END IF;
  -- Kursdelle (Mini-App UX 2026-10-30): Kurs 99, Reserve 100 -> 1 %% < 10 %% -> grau „Kurswert 1 darunter", „fuer Ziele" ohne „frei"
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APGLX', 99, 'EUR', current_date);
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->3->'items') i
                  WHERE i->>'label' = '__apgl_hh_depot__' AND NOT (i->>'gap')::boolean
                    AND i->'value' = core.fn_ui_money(99, 'EUR')
                    AND i->'sub' = core.fn_ui_tpl('finance.app.goals.accounts_reserved', jsonb_build_object('reserved', core.fn_ui_money(100, 'EUR')))
                    AND i->'pill' = jsonb_build_object('state', 'neutral', 'icon', 'info', 'text', core.fn_ui_tpl(
                                      'finance.app.goals.cover_dip', jsonb_build_object('gap', core.fn_ui_money(1, 'EUR'))))) THEN
    RAISE EXCEPTION 'FAIL [1w3] Kursdelle grau mit Betrag, got %', v->'sections'->3; END IF;
  -- heftiger Einbruch: Kurs 80 -> 20 %% -> gelb „fehlen 20"
  UPDATE finance.market_prices SET price = 80 WHERE symbol = 'APGLX';
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->3->'items') i
                  WHERE i->>'label' = '__apgl_hh_depot__'
                    AND i->'pill' = jsonb_build_object('state', 'warn', 'icon', 'alert', 'text', core.fn_ui_tpl(
                                      'finance.app.goals.missing', jsonb_build_object('gap', core.fn_ui_money(20, 'EUR'))))) THEN
    RAISE EXCEPTION 'FAIL [1w4] Einbruch ab der Schwelle gelb „fehlen 20", got %', v->'sections'->3; END IF;
  DELETE FROM finance.market_prices WHERE symbol = 'APGLX';
  DELETE FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  DELETE FROM finance.savings_goals WHERE id = v_goal;
  DELETE FROM finance.depot_holdings WHERE symbol = 'APGLX';
  RAISE NOTICE 'PASS [1w] Depot-Reserve: nicht ermittelbar / Kursdelle grau / Einbruch gelb; Konten-Anteile = Zielstand';

  -- Sparrate im Aufklappen nur, wenn sie GERADE laeuft (Praedikat active_recurring_payments): kuenftig -> keine Zeile
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_future__', v_giro, v_pot, -20, 'month', current_date + 10, current_date + 10) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id)
    VALUES ('__apgl_rate_future__', 1000, v_td, v_rp) RETURNING id INTO v_goal;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apgl_rp_now__', v_giro, v_pot, -40, 'month', current_date - 10, current_date - 10) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id)
    VALUES ('__apgl_rate_now__', 1000, v_td, v_rp);
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->1->'items') i, jsonb_array_elements(i->'details') d
              WHERE i->>'label' = '__apgl_rate_future__' AND d->'label'->>'value' = 'finance.app.goals.d_rate') THEN
    RAISE EXCEPTION 'FAIL [1z] kuenftige Sparrate darf nicht als laufend erscheinen'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections'->1->'items') i
                  WHERE i->>'label' = '__apgl_rate_now__'
                    AND i->'details'->1 = jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
                          'value', core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object(
                              'rate', core.fn_ui_money(40, 'EUR'), 'account', '__apgl_giro__')))) THEN
    RAISE EXCEPTION 'FAIL [1z2] laufende Sparrate mit Abbuchungskonto, got %', v->'sections'->1; END IF;
  DELETE FROM finance.savings_goals WHERE name IN ('__apgl_rate_future__', '__apgl_rate_now__');
  DELETE FROM finance.recurring_payments WHERE name IN ('__apgl_rp_future__', '__apgl_rp_now__');
  RAISE NOTICE 'PASS [1z] Sparrate nur, wenn sie gerade laeuft, mit Abbuchungskonto';

  -- ===== 2) Kind: nur Eigenes =====
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_kid', 'params', '{}'::jsonb));
  IF v->'hero'->'value' <> core.fn_ui_money(500, 'EUR') OR (v->'hero'->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [2a] Kind-Hero 500 ohne gap, got %', v->'hero'; END IF;
  v_txt := v::text;
  IF v_txt LIKE '%__apgl_%' THEN RAISE EXCEPTION 'FAIL [2b] Kind-Antwort enthaelt fremde Namen: %', v_txt; END IF;
  IF v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [2c] Antwort traegt ein *id-Feld: %', v_txt; END IF;
  IF v_txt NOT LIKE '%Alpha Fahrrad%' OR v_txt NOT LIKE '%Alpha Sparplan%' THEN RAISE EXCEPTION 'FAIL [2d] eigenes Ziel/eigener Plan fehlt: %', v_txt; END IF;
  SELECT array_agg(s->'title'->>'value' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v->'sections') WITH ORDINALITY AS t(s, o);
  IF v_labels IS DISTINCT FROM ARRAY['finance.app.goals.section_goals', 'finance.app.goals.section_plans',
                                     'finance.app.goals.section_accounts'] THEN
    RAISE EXCEPTION 'FAIL [2e] Kind: Sparziele + Sparplaene + eigenes Konto, leere Abschnitte entfallen, got %', v_labels; END IF;
  IF v_txt LIKE '%finance.app.goals.d_from%' THEN RAISE EXCEPTION 'FAIL [2f] Kind sieht kein Abbuchungskonto'; END IF;
  RAISE NOTICE 'PASS [2] Kind sieht nur Eigenes, Plan auf Eltern-Depot unsichtbar, keine IDs';

  -- ===== 3) Allow-List =====
  v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_guest'));
  IF v->'hero'->'value' <> core.fn_ui_money(300, 'EUR') OR v::text LIKE '%__apgl_hh_%' OR v::text LIKE '%__apgl_res_%'
     OR v::text LIKE '%__apgl_pot__%' THEN
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

  -- ===== 6) Dauerauftraege, Zufluesse, Kind-Sicht, alert-Banner =====
  -- Zubringer Giro -> Kind-Konto am 1. ab naechstem Monat, externe Zuwendung aufs Kind-Konto, Kind -> Giro (verborgen),
  -- Haushaltskonto ohne Guthaben mit Abfluss in 3 Tagen (Ziel eines Dauerauftrags -> Deckungs-Konto -> alert)
  DECLARE
    v_next1 date := (date_trunc('month', current_date) + interval '1 month')::date;
    v_low int;
  BEGIN
    INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month,
                                            first_payment_date, valid_from) VALUES
      ('__apgl_rp_feed__', v_giro, v_kid_cash, -150, 'month', 1, v_next1, v_next1),
      ('Zuwendung Beispiel', v_kid_cash, NULL, 50, 'month', 1, v_next1, v_next1),
      ('Rueckgabe Beispiel', v_kid_cash, v_giro, -10, 'month', 15, v_next1 + 14, v_next1 + 14);
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apgl_low__', 'cash', 'EUR', 'active') RETURNING id INTO v_low;
    INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('__apgl_rp_low_in__', v_giro, v_low, -10, 'month', current_date + 20, current_date + 20);
    INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('__apgl_rp_low_out__', v_low, NULL, -100, 'month', current_date + 3, current_date + 3) RETURNING id INTO v_rp;
    -- der Abfluss ist ein Sparplan (sonst Ausgabenkonto mit unbekannten Alltagsausgaben -> neutral statt alert)
    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
      VALUES ('__apgl_low_plan__', v_hh_depot, 'APGL6', 'Welt ETF', v_rp);

    v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_owner'));
    v_sec := v->'sections'->3;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                    WHERE i->>'label' = 'Kind Konto'
                      AND i->'details' @> jsonb_build_array(
                          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_money_from', jsonb_build_object('source', '__apgl_giro__')),
                              'value', core.fn_ui_tpl('finance.app.goals.amount_rhythm_from', jsonb_build_object(
                                  'amount', core.fn_ui_money(150, 'EUR'),
                                  'rhythm', core.fn_ui_tpl('finance.app.goals.rhythm_month_day', jsonb_build_object('day', core.fn_ui_num(1))),
                                  'date', core.fn_ui_date(v_next1)))),
                          jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_money_from', jsonb_build_object('source', 'Zuwendung Beispiel')),
                              'value', core.fn_ui_tpl('finance.app.goals.amount_rhythm_from', jsonb_build_object(
                                  'amount', core.fn_ui_money(50, 'EUR'),
                                  'rhythm', core.fn_ui_tpl('finance.app.goals.rhythm_month_day', jsonb_build_object('day', core.fn_ui_num(1))),
                                  'date', core.fn_ui_date(v_next1)))))) THEN
      RAISE EXCEPTION 'FAIL [6a] Konten: Zufluesse am Kind-Konto (intern benannt, extern mit Namen), got %', v_sec; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                    WHERE i->>'label' = '__apgl_giro__' AND i->'sub' = core.fn_ui_tpl('finance.app.goals.accounts_orders', jsonb_build_object('monthly', core.fn_ui_money(210, 'EUR')))
                      AND i->'details' @> jsonb_build_array(jsonb_build_object(
                          'label', core.fn_ui_tpl('finance.app.goals.d_order_to', jsonb_build_object('account', 'Kind Konto')),
                          'value', core.fn_ui_tpl('finance.app.goals.amount_rhythm_from', jsonb_build_object(
                              'amount', core.fn_ui_money(150, 'EUR'),
                              'rhythm', core.fn_ui_tpl('finance.app.goals.rhythm_month_day', jsonb_build_object('day', core.fn_ui_num(1))),
                              'date', core.fn_ui_date(v_next1)))))) THEN
      RAISE EXCEPTION 'FAIL [6b] Giro: 50 + 150 + 10 im Monat, Auftrag ans Kind-Konto mit Tag + ab, got %', v_sec; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sec->'items') i
                    WHERE i->>'label' = 'Kind Konto'
                      AND i->'details'->0->'label' = core.fn_ui_tpl('finance.app.goals.d_order_to', jsonb_build_object('account', '__apgl_giro__'))) THEN
      RAISE EXCEPTION 'FAIL [6c] Haushalt sieht den Auftrag des Kind-Kontos mit Ziel, got %', v_sec; END IF;
    v := finance.fn_app_screen_goals('{"person_id":"apgl_owner","params":{"probe":true}}');
    IF NOT (v->'banners' @> jsonb_build_array(jsonb_build_object('state', 'alert', 'icon', 'alert',
              'text', core.fn_ui_tpl('finance.app.goals.banner_fund_gap', jsonb_build_object(
                          'account', '__apgl_low__', 'date', core.fn_ui_date(current_date + 3))),
              'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb)))) THEN
      RAISE EXCEPTION 'FAIL [6d] alert-Banner fuer das leere Haushaltskonto, got %', v; END IF;
    IF v_sec->'items'->0->>'label' <> '__apgl_low__' OR v_sec->'items'->0->'pill'->>'state' <> 'alert' THEN
      RAISE EXCEPTION 'FAIL [6d2] Konten: alert zuerst, got %', v_sec; END IF;
    RAISE NOTICE 'PASS [6a-d] Haushalt: Zufluesse am Konto, Bank-To-do mit Tag/ab, alert zuerst + Banner';

    -- Kind: verborgene Konten neutral, kein fremdes Banner, keine IDs
    v := finance.fn_app_screen_goals(jsonb_build_object('person_id', 'apgl_kid'));
    v_txt := v::text;
    IF v_txt LIKE '%__apgl_%' OR v_txt ~ '"[a-z_]*id"\s*:' THEN RAISE EXCEPTION 'FAIL [6e] Kind sieht fremde Namen/IDs: %', v_txt; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
                    WHERE i->>'label' = 'Kind Konto'
                      AND i->'details' @> jsonb_build_array(jsonb_build_object(
                          'label', core.fn_ui_tpl('finance.app.goals.d_money_from', jsonb_build_object(
                                       'source', core.fn_ui_tpl('finance.app.common.household_account'))),
                          'value', core.fn_ui_tpl('finance.app.goals.amount_rhythm_from', jsonb_build_object(
                              'amount', core.fn_ui_money(150, 'EUR'),
                              'rhythm', core.fn_ui_tpl('finance.app.goals.rhythm_month_day', jsonb_build_object('day', core.fn_ui_num(1))),
                              'date', core.fn_ui_date(v_next1)))))) THEN
      RAISE EXCEPTION 'FAIL [6f] Kind: Zubringer vom verborgenen Giro heisst Haushaltskonto, got %', v; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
                    WHERE s->'title' = core.fn_ui_tpl('finance.app.goals.section_accounts') AND i->>'label' = 'Kind Konto'
                      AND i->'details'->0->'label' = core.fn_ui_tpl('finance.app.goals.d_order_to', jsonb_build_object(
                                                         'account', core.fn_ui_tpl('finance.app.common.household_account')))) THEN
      RAISE EXCEPTION 'FAIL [6g] Kind: eigener Auftrag an verborgenes Konto -> „→ Haushaltskonto", got %', v; END IF;
    IF finance.fn_app_screen_goals('{"person_id":"apgl_kid","params":{"probe":true}}')->'banners' <> '[]'::jsonb THEN
      RAISE EXCEPTION 'FAIL [6h] Kind bekommt fremdes Deckungs-Banner'; END IF;
    RAISE NOTICE 'PASS [6e-h] Kind: verborgene Konten neutral, eigener Auftrag sichtbar, kein fremdes Banner';
  END;
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
