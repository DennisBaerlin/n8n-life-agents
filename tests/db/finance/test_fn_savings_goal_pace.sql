-- tests/db/finance/test_fn_savings_goal_pace.sql
-- finance.fn_savings_goal_pace(goal_id) — die EINE Ampel-Regel eines Sparziels (Mini-App „Ziele" + Berater-Pace-Alert).
--   1) je ein Zustand: on_track / behind / reached / paused (Rate bzw. Sparplan) / unmeasurable; Ruecklage -> NULL,
--      nicht messbare Ruecklage -> unmeasurable, abgeschlossenes und unbekanntes Ziel -> NULL.
--   2) Grenzfaelle: Zieldatum nicht nach created_at (drift NULL), pausierter Kopf mit laufendem Vorgaenger und Rate mit
--      kuenftigem Start sind NICHT paused.
--   3) Aequivalenz zur bisherigen Berater-Bedingung ueber alle aktiven Ziele: behind <=> pace_drift_pp > Toleranz,
--      unmeasurable <=> NOT progress_measurable — mit Default-Toleranz UND mit negativer Toleranz (behind vor reached).
--   4) has_fx_gap in savings_goal_account_share + savings_goal_progress: CHF-Topf ohne Kurs.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_pot INT; v_pot2 INT; v_chf INT; v_depot INT; v_re1 INT; v_re2 INT;
  v_rp_open INT; v_rp_paused INT; v_rp_old INT; v_rp_new INT; v_rp_future INT; v_rp_plan INT; v_rp_res INT;
  g_on INT; g_behind INT; g_reached INT; g_unmeas INT; g_paused_rp INT; g_paused_plan INT; g_chain INT; g_future INT;
  g_res INT; g_res_unmeas INT; g_done INT; g_nodate INT; g_late INT; g_chf INT;
  v_old timestamptz := now() - interval '100 days';
  v_td  date := current_date + 265;
  v_n int;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  DELETE FROM core.config WHERE package = 'core' AND category = 'advisor' AND key = 'drift_pace_pp';

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__pace_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__pace_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__pace_pot2__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot2;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__pace_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__pace_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_depot;
  INSERT INTO finance.real_estate (name, current_value) VALUES ('__pace_re1__', 300000) RETURNING id INTO v_re1;
  INSERT INTO finance.real_estate (name, current_value) VALUES ('__pace_re2__', 300000) RETURNING id INTO v_re2;

  -- Ziele mit 365 Tagen Laufzeit, 100 vergangen -> erwartet 27.40 %
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at) VALUES ('__pace_on__', 10000, v_td, v_old) RETURNING id INTO g_on;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at) VALUES ('__pace_behind__', 10000, v_td, v_old) RETURNING id INTO g_behind;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at) VALUES ('__pace_reached__', 10000, v_td, v_old) RETURNING id INTO g_reached;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES
    (g_on, v_pot, 2000, 'manual'),        -- 20.00 % -> drift 7.40 <= 10
    (g_behind, v_pot, 1000, 'manual'),    -- 10.00 % -> drift 17.40 > 10
    (g_reached, v_pot, 10000, 'manual');

  -- nicht messbar: laufende Rate OHNE Topf
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__pace_rp_open__', v_giro, -100, 'month', current_date - 30, current_date - 30) RETURNING id INTO v_rp_open;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, recurring_payment_id)
    VALUES ('__pace_unmeas__', 10000, v_td, v_old, v_rp_open) RETURNING id INTO g_unmeas;

  -- pausiert ueber die Rate (Topf gesetzt -> messbar) und ueber den verknuepften Sparplan
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pace_rp_paused__', v_giro, v_pot2, -100, 'month', current_date - 30, current_date - 30, 'paused') RETURNING id INTO v_rp_paused;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, recurring_payment_id)
    VALUES ('__pace_paused_rp__', 10000, v_td, v_old, v_rp_paused) RETURNING id INTO g_paused_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at)
    VALUES ('__pace_paused_plan__', 10000, v_td, v_old) RETURNING id INTO g_paused_plan;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__pace_rp_plan__', v_giro, -50, 'month', current_date - 30, current_date - 30, 'paused') RETURNING id INTO v_rp_plan;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, savings_goal_id, status)
    VALUES ('__pace_plan__', v_depot, 'PACE', 'Pace ETF', v_rp_plan, g_paused_plan, 'paused');
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES
    (g_paused_rp, v_pot2, 2000, 'manual'), (g_paused_plan, v_pot, 2000, 'manual');

  -- Kette: alter Glied laeuft noch 30 Tage, der Kopf (ab dann) ist pausiert -> NICHT paused
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__pace_rp_old__', v_giro, v_pot, -100, 'month', current_date - 60, current_date - 60, current_date + 30) RETURNING id INTO v_rp_old;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, status, predecessor_id)
    VALUES ('__pace_rp_new__', v_giro, v_pot, -200, 'month', current_date + 30, current_date + 30, 'paused', v_rp_old) RETURNING id INTO v_rp_new;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, recurring_payment_id)
    VALUES ('__pace_chain__', 10000, v_td, v_old, v_rp_new) RETURNING id INTO g_chain;
  -- Rate startet erst kuenftig (aktiv) -> NICHT paused
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__pace_rp_future__', v_giro, v_pot, -100, 'month', current_date + 10, current_date + 10) RETURNING id INTO v_rp_future;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, recurring_payment_id)
    VALUES ('__pace_future__', 10000, v_td, v_old, v_rp_future) RETURNING id INTO g_future;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES
    (g_chain, v_pot, 2000, 'manual'), (g_future, v_pot, 2000, 'manual');

  -- Ruecklagen: ohne Ziel/Datum -> NULL; mit laufender Rate ohne Topf -> unmeasurable (Regel 1 vor Regel 2)
  INSERT INTO finance.savings_goals (name, kind, real_estate_id) VALUES ('__pace_res__', 'maintenance_reserve', v_re1) RETURNING id INTO g_res;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__pace_rp_res__', v_giro, -80, 'month', current_date - 30, current_date - 30) RETURNING id INTO v_rp_res;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, recurring_payment_id) VALUES ('__pace_res_unmeas__', 'maintenance_reserve', v_re2, v_rp_res) RETURNING id INTO g_res_unmeas;

  -- abgeschlossen -> NULL
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at, status)
    VALUES ('__pace_done__', 1000, v_td, v_old, 'completed') RETURNING id INTO g_done;

  -- Zieldatum nicht nach created_at -> drift NULL: halb gespart = on_track, voll = reached (siehe g_late unten)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at)
    VALUES ('__pace_nodate__', 1000, current_date - 20, now() - interval '10 days') RETURNING id INTO g_nodate;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (g_nodate, v_pot, 500, 'manual');
  -- Zieldatum heute, voll gespart -> erwartet 100 %, drift 0: reached bei Toleranz 10, behind bei Toleranz -5
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at)
    VALUES ('__pace_late__', 1000, current_date, v_old) RETURNING id INTO g_late;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (g_late, v_pot, 1000, 'manual');

  -- CHF-Topf ohne Kurs
  INSERT INTO finance.savings_goals (name, target_amount, target_date, created_at)
    VALUES ('__pace_chf__', 10000, v_td, v_old) RETURNING id INTO g_chf;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_chf, 500, current_date - 5, 'transfer', g_chf, gen_random_uuid());

  -- ===== 1) Zustaende =====
  IF finance.fn_savings_goal_pace(g_on)          IS DISTINCT FROM 'on_track'     THEN RAISE EXCEPTION 'FAIL [1a] on_track, got %', finance.fn_savings_goal_pace(g_on); END IF;
  IF finance.fn_savings_goal_pace(g_behind)      IS DISTINCT FROM 'behind'       THEN RAISE EXCEPTION 'FAIL [1b] behind, got %', finance.fn_savings_goal_pace(g_behind); END IF;
  IF finance.fn_savings_goal_pace(g_reached)     IS DISTINCT FROM 'reached'      THEN RAISE EXCEPTION 'FAIL [1c] reached, got %', finance.fn_savings_goal_pace(g_reached); END IF;
  IF finance.fn_savings_goal_pace(g_unmeas)      IS DISTINCT FROM 'unmeasurable' THEN RAISE EXCEPTION 'FAIL [1d] unmeasurable, got %', finance.fn_savings_goal_pace(g_unmeas); END IF;
  IF finance.fn_savings_goal_pace(g_paused_rp)   IS DISTINCT FROM 'paused'       THEN RAISE EXCEPTION 'FAIL [1e] paused (Rate), got %', finance.fn_savings_goal_pace(g_paused_rp); END IF;
  IF finance.fn_savings_goal_pace(g_paused_plan) IS DISTINCT FROM 'paused'       THEN RAISE EXCEPTION 'FAIL [1f] paused (Sparplan), got %', finance.fn_savings_goal_pace(g_paused_plan); END IF;
  IF finance.fn_savings_goal_pace(g_res)         IS NOT NULL                     THEN RAISE EXCEPTION 'FAIL [1g] Ruecklage -> NULL, got %', finance.fn_savings_goal_pace(g_res); END IF;
  IF finance.fn_savings_goal_pace(g_res_unmeas)  IS DISTINCT FROM 'unmeasurable' THEN RAISE EXCEPTION 'FAIL [1h] nicht messbare Ruecklage, got %', finance.fn_savings_goal_pace(g_res_unmeas); END IF;
  IF finance.fn_savings_goal_pace(g_done) IS NOT NULL OR finance.fn_savings_goal_pace(-1) IS NOT NULL OR finance.fn_savings_goal_pace(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1i] abgeschlossenes/unbekanntes Ziel -> NULL'; END IF;
  RAISE NOTICE 'PASS [1] Zustaende on_track/behind/reached/unmeasurable/paused, Ruecklage NULL, abgeschlossen NULL';

  -- ===== 2) Grenzfaelle =====
  IF finance.fn_savings_goal_pace(g_chain)  IS DISTINCT FROM 'on_track' THEN RAISE EXCEPTION 'FAIL [2a] laufender Vorgaenger -> nicht paused, got %', finance.fn_savings_goal_pace(g_chain); END IF;
  IF finance.fn_savings_goal_pace(g_future) IS DISTINCT FROM 'on_track' THEN RAISE EXCEPTION 'FAIL [2b] kuenftige Rate -> nicht paused, got %', finance.fn_savings_goal_pace(g_future); END IF;
  IF finance.fn_savings_goal_pace(g_nodate) IS DISTINCT FROM 'on_track' THEN RAISE EXCEPTION 'FAIL [2c] drift NULL halb gespart -> on_track, got %', finance.fn_savings_goal_pace(g_nodate); END IF;
  IF finance.fn_savings_goal_pace(g_late)   IS DISTINCT FROM 'reached'  THEN RAISE EXCEPTION 'FAIL [2d] Zieldatum heute voll -> reached, got %', finance.fn_savings_goal_pace(g_late); END IF;
  RAISE NOTICE 'PASS [2] Grenzfaelle Kette/kuenftige Rate/drift NULL/Zieldatum heute';

  -- ===== 3) Aequivalenz zur Berater-Bedingung (Default 10 und -5) =====
  SELECT count(*) INTO v_n FROM finance.savings_goal_progress p
   WHERE p.status = 'active'
     AND (COALESCE(finance.fn_savings_goal_pace(p.id) = 'behind', false) IS DISTINCT FROM COALESCE(p.pace_drift_pp > 10, false)
       OR COALESCE(finance.fn_savings_goal_pace(p.id) = 'unmeasurable', false) IS DISTINCT FROM (NOT p.progress_measurable));
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [3a] % Ziele weichen bei Toleranz 10 von der Berater-Bedingung ab', v_n; END IF;
  INSERT INTO core.config (category, key, value, package) VALUES ('advisor', 'drift_pace_pp', '-5', 'core');
  IF finance.fn_savings_goal_pace(g_late) IS DISTINCT FROM 'behind' THEN
    RAISE EXCEPTION 'FAIL [3b] Toleranz -5: drift 0 > -5 -> behind vor reached, got %', finance.fn_savings_goal_pace(g_late); END IF;
  SELECT count(*) INTO v_n FROM finance.savings_goal_progress p
   WHERE p.status = 'active'
     AND (COALESCE(finance.fn_savings_goal_pace(p.id) = 'behind', false) IS DISTINCT FROM COALESCE(p.pace_drift_pp > -5, false)
       OR COALESCE(finance.fn_savings_goal_pace(p.id) = 'unmeasurable', false) IS DISTINCT FROM (NOT p.progress_measurable));
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [3c] % Ziele weichen bei Toleranz -5 von der Berater-Bedingung ab', v_n; END IF;
  DELETE FROM core.config WHERE package = 'core' AND category = 'advisor' AND key = 'drift_pace_pp';
  RAISE NOTICE 'PASS [3] behind <=> drift > Toleranz, unmeasurable <=> NOT measurable (10 und -5)';

  -- ===== 4) has_fx_gap =====
  IF NOT (SELECT has_fx_gap FROM finance.savings_goal_account_share WHERE goal_id = g_chf AND account_id = v_chf)
     OR NOT (SELECT has_fx_gap FROM finance.savings_goal_progress WHERE id = g_chf) THEN
    RAISE EXCEPTION 'FAIL [4a] CHF-Anteil ohne Kurs muss has_fx_gap tragen'; END IF;
  IF (SELECT has_fx_gap FROM finance.savings_goal_progress WHERE id = g_on)
     OR (SELECT has_fx_gap FROM finance.savings_goal_progress WHERE id = g_res) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [4b] EUR-Ziel bzw. Ziel ohne Anteile: has_fx_gap false erwartet'; END IF;
  RAISE NOTICE 'PASS [4] has_fx_gap in savings_goal_account_share + savings_goal_progress';
END $$;
ROLLBACK;
