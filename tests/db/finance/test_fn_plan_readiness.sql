-- tests/db/finance/test_fn_plan_readiness.sql
-- Daten-Reife des Finanzplans (Onboarding-Plan-Schritt, 2026-10-28): finance.fn_plan_readiness(domain, person_id)
-- meldet, ob die harten Mindestdaten fuer einen sinnvollen Plan erfasst sind — ein aktives Geld-Konto, eine laufende
-- Einnahme und eine laufende Ausgabe (Klassen aus finance.recurring_cashflow_classified) — und sonst je fehlendem Punkt
-- den Onboarding-Abschnitt, in dem er erfasst wird. Versicherungen/Rente/Depots/Ziele sind bewusst keine Pflicht.
BEGIN;

DO $$
DECLARE
  v      jsonb;
  v_acct int;
  v_save int;
BEGIN
  -- Fixture-unabhaengig: alle bestehenden Geld-Konten schliessen, alle Zahlungen pausieren
  UPDATE finance.recurring_payments SET status = 'paused';
  UPDATE finance.accounts SET status = 'closed' WHERE account_type = 'cash';

  -- (1) leer -> nicht reif, alle drei Punkte in fester Reihenfolge, mit Abschnitt
  v := finance.fn_plan_readiness('finance', NULL);
  IF (v->>'ready')::boolean IS DISTINCT FROM false
     OR v->'missing' <> '[{"key":"accounts","section":"accounts"},{"key":"income","section":"liabilities"},{"key":"expenses","section":"liabilities"}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [leer]: %', v; END IF;

  -- (2) ein Depot allein ist kein Geld-Konto
  INSERT INTO finance.accounts (name, account_type) VALUES ('__t_ready_giro', 'cash') RETURNING id INTO v_acct;
  UPDATE finance.accounts SET status = 'closed' WHERE id = v_acct;
  v := finance.fn_plan_readiness('finance', NULL);
  IF v->'missing'->0->>'key' IS DISTINCT FROM 'accounts' THEN RAISE EXCEPTION 'FAIL [geschlossenes Konto zaehlt]: %', v; END IF;
  UPDATE finance.accounts SET status = 'active' WHERE id = v_acct;

  -- (3) Konto da, Transfer zaehlt weder als Einnahme noch als Ausgabe, pausierte Zahlung zaehlt nicht
  INSERT INTO finance.accounts (name, account_type) VALUES ('__t_ready_tagesgeld', 'cash') RETURNING id INTO v_save;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('__t_ready_umbuchung', v_acct, v_save, -100, 'month', 1, current_date - 40, current_date - 40);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from, status)
  VALUES ('__t_ready_gehalt_alt', v_acct, 2500, 'month', 1, current_date - 40, current_date - 40, 'paused');
  v := finance.fn_plan_readiness('finance', NULL);
  IF (v->>'ready')::boolean IS DISTINCT FROM false
     OR v->'missing' <> '[{"key":"income","section":"liabilities"},{"key":"expenses","section":"liabilities"}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Transfer/pausiert]: %', v; END IF;

  -- (4) Einnahme da, Ausgabe fehlt
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('__t_ready_gehalt', v_acct, 2500, 'month', 1, current_date - 40, current_date - 40);
  v := finance.fn_plan_readiness('finance', NULL);
  IF v->'missing' <> '[{"key":"expenses","section":"liabilities"}]'::jsonb THEN RAISE EXCEPTION 'FAIL [nur Einnahme]: %', v; END IF;

  -- (5) Ausgabe da -> reif, missing leer
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('__t_ready_miete', v_acct, -900, 'month', 3, current_date - 40, current_date - 40);
  v := finance.fn_plan_readiness('finance', NULL);
  IF (v->>'ready')::boolean IS DISTINCT FROM true OR v->'missing' <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [reif]: %', v; END IF;

  -- (6) eine beendete Zahlung (valid_to in der Vergangenheit) zaehlt nicht mehr
  UPDATE finance.recurring_payments SET valid_to = current_date - 1 WHERE name = '__t_ready_miete';
  v := finance.fn_plan_readiness('finance', NULL);
  IF v->'missing' <> '[{"key":"expenses","section":"liabilities"}]'::jsonb THEN RAISE EXCEPTION 'FAIL [beendet]: %', v; END IF;

  RAISE NOTICE 'PASS test_fn_plan_readiness (Konto/Einnahme/Ausgabe, Transfer + pausiert + beendet zaehlen nicht)';
END $$;

ROLLBACK;
