-- tests/db/finance/test_fn_pension_outlook.sql
-- Testet finance.fn_pension_outlook (Berater-Fenster, Renteninformation-Plan 2026-10-26, Werte erfunden) und
-- finance.fn_pension_statements_due (Erinnerung): juengste Renteninformation je Rente, Alter/stale/never,
-- Szenarien in Kaufkraft zum Stand (nominal / (1+i)^n, n = Regelaltersrente - Stand), ohne Inflation keine Realwerte.
BEGIN;

DO $$
DECLARE
  v JSONB; v_drv INT; v_bav INT; v_r JSONB; v_due JSONB;
BEGIN
  INSERT INTO finance.pension (name, pension_type) VALUES ('__t_po DRV', 'statutory') RETURNING id INTO v_drv;
  INSERT INTO finance.pension (name, pension_type, provider) VALUES ('__t_po bAV', 'occupational', 'Allianz') RETURNING id INTO v_bav;
  -- zwei Jahre Historie; die juengste zaehlt. 34 Jahre bis zur Regelaltersrente.
  INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim, projection, scenario_1pct, scenario_2pct,
      em_monthly, earning_points, regular_retirement_date)
  VALUES (v_drv, core.fn_today() - 400, 250, 2000, 2700, 3800, 780, 7.5, (core.fn_today() - 400) + 12418),
         (v_drv, core.fn_today() - 30,  300, 2100, 2800, 3900, 800, 8.0, (core.fn_today() - 30) + 12418);

  -- TEST 1: mit Inflation 2 % -> Realwerte; 2-%-Szenario in Kaufkraft ~ Hochrechnung (Renten steigen wie Inflation)
  v := finance.fn_pension_outlook('{"inflation_pct":2}'::jsonb);
  SELECT e INTO v_r FROM jsonb_array_elements(v->'pensions') e WHERE e->>'name' = '__t_po DRV';
  IF (v->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->>'statement_date')::date IS DISTINCT FROM core.fn_today() - 30
     OR (v_r->>'projection')::numeric IS DISTINCT FROM 2100
     OR (v_r->>'stale')::boolean IS DISTINCT FROM false OR (v_r->>'never')::boolean IS DISTINCT FROM false
     OR NOT ((v_r->>'scenario_2pct_real')::numeric BETWEEN 1950 AND 2050)
     OR NOT ((v_r->>'scenario_1pct_real')::numeric BETWEEN 1400 AND 1500)
     OR (v_r->>'basis') NOT LIKE '%gross%' THEN
    RAISE EXCEPTION 'FAIL pension_outlook [Realwerte]: %', v_r; END IF;
  RAISE NOTICE 'PASS pension_outlook [juengste Info, Realwerte zum Stand, brutto-Hinweis]';

  -- TEST 2: ohne Inflation -> keine Realwerte, Hinweis
  v := finance.fn_pension_outlook('{}'::jsonb);
  SELECT e INTO v_r FROM jsonb_array_elements(v->'pensions') e WHERE e->>'name' = '__t_po DRV';
  IF v_r ? 'scenario_1pct_real' OR v_r->>'real_note' IS NULL THEN
    RAISE EXCEPTION 'FAIL pension_outlook [ohne Inflation]: %', v_r; END IF;
  RAISE NOTICE 'PASS pension_outlook [ohne Inflation keine Realwerte]';

  -- TEST 3: bAV ohne Information -> never im Fenster, aber KEINE Erinnerung (viele Arbeitgeber schicken keine);
  --         die frische DRV ist nicht faellig
  SELECT e INTO v_r FROM jsonb_array_elements(v->'pensions') e WHERE e->>'name' = '__t_po bAV';
  IF (v_r->>'never')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL pension_outlook [never]: %', v_r; END IF;
  v_due := finance.fn_pension_statements_due();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_due) e WHERE e->>'name' IN ('__t_po bAV', '__t_po DRV')) THEN
    RAISE EXCEPTION 'FAIL pension_due [bAV never / DRV frisch nicht faellig]: %', v_due; END IF;
  -- gesetzliche Rente ohne Information -> faellig (never)
  DELETE FROM finance.pension_statements WHERE pension_id = v_drv;
  v_due := finance.fn_pension_statements_due();
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_due) e WHERE e->>'name' = '__t_po DRV' AND (e->>'never')::boolean) THEN
    RAISE EXCEPTION 'FAIL pension_due [DRV never]: %', v_due; END IF;
  INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim, regular_retirement_date)
  VALUES (v_drv, core.fn_today() - 400, 250, (core.fn_today() - 400) + 12418),
         (v_drv, core.fn_today() - 30, 300, (core.fn_today() - 30) + 12418);

  -- TEST 4: Info aelter als 13 Monate -> stale + faellig; pausierte Rente nie faellig
  DELETE FROM finance.pension_statements WHERE pension_id = v_drv AND statement_date = core.fn_today() - 30;
  v_due := finance.fn_pension_statements_due();
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_due) e WHERE e->>'name' = '__t_po DRV'
                 AND (e->>'last_statement_date')::date = core.fn_today() - 400) THEN
    RAISE EXCEPTION 'FAIL pension_due [stale]: %', v_due; END IF;
  UPDATE finance.pension SET status = 'paused' WHERE id = v_bav;
  v_due := finance.fn_pension_statements_due();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_due) e WHERE e->>'name' = '__t_po bAV') THEN
    RAISE EXCEPTION 'FAIL pension_due [pausiert]: %', v_due; END IF;
  RAISE NOTICE 'PASS pension_due [never + stale faellig, frisch/pausiert nicht]';
END $$;

ROLLBACK;
