-- tests/db/cross/test_recalc2_edges.sql
-- Zweitrechnung Runde 2, Randfaelle quer: Notreserve im freien Geld (Runway), beendete Ruecklagen-Rate.
-- Erwartungen von Hand hergeleitet. Werte erfunden.
-- Fachregeln:
--   * Notreserve ist im Notfall verfuegbar (Verbraucherzentrale/Finanztip: Notgroschen auf dem Tagesgeld) und zaehlt
--     deshalb zum freien Geld der Runway; gedeckt ist sie nur mit dem Saldo, der NACH den anderen Zielen auf demselben
--     Konto uebrig bleibt (kein Euro doppelt).
--     Topf 2.500, darauf Urlaubsziel 1.000 und Notreserve 2.000 -> gedeckte Notreserve min(2.000, 2.500 - 1.000) = 1.500;
--     Giro 4.000 ohne Ziel.
--     (1) freies Geld = 4.000 + 1.500 = 5.500; zurueckgelegt (nicht frei) = 2.500 - 1.500 = 1.000; Notreserve 1.500.
--     (2) Runway bei Pflicht 1.100/Monat: 5.500 / 1.100 = 5,0 -> genau 5 Monate.
--   * Ruecklagen-Rate gilt bis zum letzten Gueltigkeitstag; valid_to ist das erste NICHT mehr gueltige Datum.
--     (3) Rate 100/Monat, valid_to = morgen -> laeuft heute noch: 100; valid_to = heute -> beendet: 0, Luecke = Empfehlung.
--         Empfehlung 50 m2, Alter 10 Jahre: 50 x 11,50 / 12 = 47,92 -> 48.
BEGIN;

DO $$
DECLARE
  y int := EXTRACT(YEAR FROM core.fn_today())::int;
  v_giro int; v_pot int; v_gu int; v_ge int; v_re int; v_rp int; s jsonb; w jsonb; r record;
BEGIN
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active') ON CONFLICT (package) DO UPDATE SET status = 'active';
  UPDATE finance.recurring_payments SET status = 'paused' WHERE status = 'active';
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active' AND account_type = 'cash';
  UPDATE finance.savings_goals SET status = 'completed' WHERE status = 'active';

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2e_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2e_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__r2e_urlaub__', 3000, current_date + 300) RETURNING id INTO v_gu;
  INSERT INTO finance.savings_goals (name, kind, target_amount) VALUES ('__r2e_not__', 'emergency_reserve', 6000) RETURNING id INTO v_ge;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 4000, current_date - 3, 'other');
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_pot, 1000, current_date - 3, 'transfer', v_gu, gen_random_uuid()),
    (v_pot, 2000, current_date - 3, 'transfer', v_ge, gen_random_uuid());
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_pot, -500, current_date - 1, 'other');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2e_miete__', v_giro, -1100, 'month', current_date - 5, current_date - 5);

  s := finance.fn_liquidity_snapshot();
  IF (s->>'cash_eur')::numeric IS DISTINCT FROM 5500.00 OR (s->>'earmarked_eur')::numeric IS DISTINCT FROM 1000.00
     OR (s->>'emergency_eur')::numeric IS DISTINCT FROM 1500.00 THEN
    RAISE EXCEPTION 'FAIL [1] freies Geld mit Notreserve: erwartet 5500 / 1000 / 1500, got %', s; END IF;
  RAISE NOTICE 'PASS [1] Notreserve zaehlt nach den anderen Zielen zum freien Geld';
  w := career.fn_runway('{"transition":{"probation_months":6}}');
  IF (w->>'runway_months')::int IS DISTINCT FROM 5 OR (w->>'covers')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [2] Runway 5,0 -> 5: %', w; END IF;
  RAISE NOTICE 'PASS [2] Runway genau 5 Monate';

  -- (3) beendete Ruecklagen-Rate
  INSERT INTO finance.real_estate (name, current_value, status, living_area_m2, year_built) VALUES ('__r2e_whg__', 200000, 'active', 50, y - 10) RETURNING id INTO v_re;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__r2e_ruecklage__', v_giro, v_pot, -100, 'month', current_date - 60, current_date - 60, current_date + 1) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, recurring_payment_id) VALUES ('__r2e_mr__', 'maintenance_reserve', v_re, v_rp);
  SELECT * INTO r FROM finance.maintenance_reserve_status WHERE real_estate_id = v_re;
  IF r.recommended_monthly IS DISTINCT FROM 48 OR r.running_monthly_eur IS DISTINCT FROM 100.00 OR r.gap_monthly_eur IS DISTINCT FROM -52.00 THEN
    RAISE EXCEPTION 'FAIL [3a] Rate laeuft bis morgen: %', row_to_json(r); END IF;
  UPDATE finance.recurring_payments SET valid_to = current_date WHERE id = v_rp;
  SELECT * INTO r FROM finance.maintenance_reserve_status WHERE real_estate_id = v_re;
  IF r.running_monthly_eur IS DISTINCT FROM 0 OR r.gap_monthly_eur IS DISTINCT FROM 48 THEN
    RAISE EXCEPTION 'FAIL [3b] Rate beendet: %', row_to_json(r); END IF;
  RAISE NOTICE 'PASS [3] Ruecklagen-Rate: valid_to morgen laeuft, valid_to heute beendet -> Luecke 48';
END $$;

ROLLBACK;
