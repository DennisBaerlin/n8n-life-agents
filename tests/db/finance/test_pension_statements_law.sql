-- tests/db/finance/test_pension_statements_law.sql
-- DB-Gesetz der Renteninformation (Plan "Renteninformation einlesen", 2026-10-26): neue Rohwert-Spalten
-- (Entgeltpunkte, DRV-Szenarien 1 %/2 %, Regelaltersrenten-Beginn), Plausibilitaet (>= 0, Szenarien steigend),
-- gesetzliche Rente ohne eigene Monatsrente/Wert (die Werte stehen in der Renteninformation) und hoechstens EINE
-- aktive gesetzliche Rente je Person (bzw. je Haushalt bei leerer Person).
BEGIN;

DO $$
DECLARE
  v_p INT;
BEGIN
  INSERT INTO finance.pension (name, pension_type) VALUES ('__t_psl_drv__', 'statutory') RETURNING id INTO v_p;

  -- TEST 1: alle neuen Spalten speicherbar
  INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim, projection, scenario_1pct,
      scenario_2pct, em_monthly, earning_points, regular_retirement_date)
  VALUES (v_p, '2023-04-01', 300.00, 2000.00, 2800.00, 3900.00, 800.00, 8.1234, '2057-05-01');
  RAISE NOTICE 'PASS pension_law [neue Spalten]';

  -- TEST 2: negative Werte / fallende Szenarien -> CHECK
  BEGIN
    INSERT INTO finance.pension_statements (pension_id, statement_date, earning_points) VALUES (v_p, '2024-04-01', -1);
    RAISE EXCEPTION 'FAIL pension_law [Entgeltpunkte negativ angenommen]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim) VALUES (v_p, '2024-04-01', -5);
    RAISE EXCEPTION 'FAIL pension_law [negativer Anspruch angenommen]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.pension_statements (pension_id, statement_date, projection, scenario_1pct) VALUES (v_p, '2024-04-01', 2000, 1500);
    RAISE EXCEPTION 'FAIL pension_law [Szenario 1 %% unter Hochrechnung angenommen]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.pension_statements (pension_id, statement_date, scenario_1pct, scenario_2pct) VALUES (v_p, '2024-04-01', 3000, 2900);
    RAISE EXCEPTION 'FAIL pension_law [Szenario 2 %% unter 1 %% angenommen]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  -- NULL-tolerant: nur ein Szenario gedruckt
  INSERT INTO finance.pension_statements (pension_id, statement_date, projection, scenario_2pct) VALUES (v_p, '2024-04-01', 2000, 4000);
  RAISE NOTICE 'PASS pension_law [>= 0 und Szenarien steigend, NULL-tolerant]';

  -- TEST 3: gesetzliche Rente traegt keine eigene Monatsrente / keinen Wert
  BEGIN
    UPDATE finance.pension SET guaranteed_monthly_pension = 2000 WHERE id = v_p;
    RAISE EXCEPTION 'FAIL pension_law [statutory mit Monatsrente angenommen]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    UPDATE finance.pension SET current_value = 1000 WHERE id = v_p;
    RAISE EXCEPTION 'FAIL pension_law [statutory mit Wert angenommen]';
  EXCEPTION WHEN check_violation THEN NULL; END;
  INSERT INTO finance.pension (name, pension_type, guaranteed_monthly_pension, current_value)
  VALUES ('__t_psl_bav__', 'occupational', 150, 12000);   -- andere Arten weiter erlaubt
  RAISE NOTICE 'PASS pension_law [statutory ohne Monatsrente/Wert, andere Arten unberuehrt]';

  -- TEST 4: hoechstens eine AKTIVE gesetzliche Rente je Person (NULL = Haushalt zaehlt als eine)
  BEGIN
    INSERT INTO finance.pension (name, pension_type) VALUES ('__t_psl_drv2__', 'statutory');
    RAISE EXCEPTION 'FAIL pension_law [zweite gesetzliche Rente (Haushalt) angenommen]';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  UPDATE finance.pension SET status = 'paid_out' WHERE id = v_p;
  INSERT INTO finance.pension (name, pension_type) VALUES ('__t_psl_drv3__', 'statutory');   -- nach Auszahlung wieder frei
  RAISE NOTICE 'PASS pension_law [eine aktive gesetzliche Rente je Person]';
END $$;

ROLLBACK;
