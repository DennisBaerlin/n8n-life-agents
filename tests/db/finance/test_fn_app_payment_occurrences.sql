-- tests/db/finance/test_fn_app_payment_occurrences.sql
-- finance.fn_app_payment_occurrences — Vorkommen eines Kontos fuer die Mini-App (UX 2026-10-30):
--   eigener Uebertrag A -> B: bei A Abgang mit „→ B", bei B Eingang (+) — vorher fehlte der Eingang beim Ziel;
--   Sparplan-Zahlung traegt den Plan-Namen; Kind-Sicht: verborgene Quelle „vom Haushalt", verborgenes Ziel „Haushalt".
--   Erfundene Werte.
BEGIN;
DO $$
DECLARE
  t date := current_date; v_a int; v_b int; v_kid int; v_dep int; v_rp int; v jsonb;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('apo_kid', 'Kind Beispiel', 'child');
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apo_a__', 'cash', 'EUR', 'active') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__apo_b__', 'cash', 'EUR', 'active') RETURNING id INTO v_b;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Kind Konto', 'cash', 'EUR', 'active', 'apo_kid') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Kind Depot', 'stocks_depot', 'EUR', 'active', v_kid, 'apo_kid') RETURNING id INTO v_dep;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__apo_a_to_b__', v_a, v_b, -150, 'month', t + 3, t + 3),
           ('__apo_a_to_kid__', v_a, v_kid, -20, 'month', t + 4, t + 4),
           ('Spar Kind', v_kid, v_b, -5, 'month', t + 6, t + 6);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('Sparplan Welt ETF Kind', v_kid, -10, 'month', t + 2, t + 2) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id)
    VALUES ('Welt ETF Kind', v_dep, 'APO1', 'Welt ETF', v_rp, 'apo_kid');

  v := finance.fn_app_payment_occurrences(v_a, t, t + 30, true, 'owner');
  IF NOT (v->'rows' @> jsonb_build_array(jsonb_build_object('label', '__apo_a_to_b__', 'amount', -150, 'to', '__apo_b__'))) THEN
    RAISE EXCEPTION 'FAIL [1] Quelle: Abgang mit Ziel, got %', v; END IF;
  v := finance.fn_app_payment_occurrences(v_b, t, t + 30, true, 'owner');
  IF NOT (v->'rows' @> jsonb_build_array(jsonb_build_object('label', '__apo_a_to_b__', 'amount', 150, 'cur', 'EUR')))
     OR (v->>'fx_gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [2] Ziel: Eingang +150 (fehlte bisher), got %', v; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v->'rows') x WHERE x->'to' <> 'null'::jsonb) <> 0 THEN
    RAISE EXCEPTION 'FAIL [3] Eingang ohne Ziel-Angabe, got %', v; END IF;

  -- Kind-Sicht auf das eigene Konto: Sparplan mit Plan-Namen, Eingang vom verborgenen Konto neutral, Auftrag an verborgenes Konto „Haushalt"
  v := finance.fn_app_payment_occurrences(v_kid, t, t + 30, false, 'apo_kid');
  IF NOT (v->'rows' @> jsonb_build_array(jsonb_build_object('label', 'Welt ETF Kind', 'amount', -10))) THEN
    RAISE EXCEPTION 'FAIL [4] Plan-Name statt „Sparplan …", got %', v; END IF;
  IF NOT (v->'rows' @> jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.payments.from_household'), 'amount', 20))) THEN
    RAISE EXCEPTION 'FAIL [5] verborgene Quelle neutral, got %', v; END IF;
  IF NOT (v->'rows' @> jsonb_build_array(jsonb_build_object('label', 'Spar Kind', 'to', core.fn_ui_tpl('finance.app.payments.household')))) THEN
    RAISE EXCEPTION 'FAIL [6] verborgenes Ziel „Haushalt", got %', v; END IF;
  IF v::text LIKE '%__apo_%' THEN RAISE EXCEPTION 'FAIL [7] Kind sieht fremde Namen: %', v; END IF;
  RAISE NOTICE 'PASS [1-7] Quelle/Ziel eines Uebertrags, Plan-Name, Zero-Trust';
END $$;
ROLLBACK;
