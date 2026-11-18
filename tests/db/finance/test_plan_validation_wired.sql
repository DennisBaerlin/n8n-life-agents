-- tests/db/finance/test_plan_validation_wired.sql
-- Die Plan-Pruefung ist im Betrieb angeschlossen: der Berater-Eintrag (core.advisors.plan_validate_fn) nennt
-- finance.fn_validate_financial_planning, und der echte Speicher-Weg fn_advisor_save_section ->
-- fn_advisor_publish_plan lehnt ungueltige Plaene ab. Bewusst ohne core.context_validators-Zeile fuer den Plan
-- (die machte ihn zum Fakten-Kontext: Reset, Lern-Vorfilter, Frische-Waechter). db_test seedet die Registries nicht ->
-- der Test legt den Berater-Eintrag selbst an, wie _seed_advisors es aus dem Manifest tut. Alle Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_status TEXT;
  v_msg    TEXT;
  -- Teilplaene je Fall (section_data = partielles facts-Objekt, Top-Block je Eintrag)
  v_bad_sum   JSONB := jsonb_build_object('target_allocation', jsonb_build_object('blocks', jsonb_build_array(
                         jsonb_build_object('key','sp500','name','S&P 500 ETF','target_pct',60),
                         jsonb_build_object('key','emerging','name','Emerging Markets ETF','target_pct',30))));
  v_bad_nokey JSONB := jsonb_build_object('target_allocation', jsonb_build_object('blocks', jsonb_build_array(
                         jsonb_build_object('name','S&P 500 ETF','target_pct',60),
                         jsonb_build_object('key','emerging','name','Emerging Markets ETF','target_pct',40))));
  v_bad_old   JSONB := jsonb_build_object('emergency_reserve', jsonb_build_object('target_months', 6));
  v_bad_goal  JSONB := jsonb_build_object('goal', jsonb_build_object('target_income_eur_month', 2000,
                         'withdrawal_rate_pct', 4, 'target_portfolio_eur', 600000));
  v_bad_risk  JSONB := jsonb_build_object('risk_profile', jsonb_build_object('risk_tolerance', 'very high'));
  v_good_goal JSONB := jsonb_build_object('goal', jsonb_build_object('target_income_eur_month', 2000, 'withdrawal_rate_pct', 4));
  v_good_full JSONB := jsonb_build_object(
    'goal', jsonb_build_object('target_income_eur_month', 2000, 'withdrawal_rate_pct', 4),
    'risk_profile', jsonb_build_object('risk_tolerance','medium','risk_capacity','high','as_of','2026-06-01'),
    'target_allocation', jsonb_build_object('blocks', jsonb_build_array(
         jsonb_build_object('key','sp500','name','S&P 500 ETF','target_pct',60),
         jsonb_build_object('key','emerging','name','Emerging Markets ETF','target_pct',30),
         jsonb_build_object('key','commodities','name','Commodities','target_pct',10))),
    'glidepath', jsonb_build_object('phases', jsonb_build_array(
         jsonb_build_object('name','accumulation','age_to',58,'equity_pct',90),
         jsonb_build_object('name','withdrawal','age_from',59,'equity_pct',60))));
  v_case   TEXT;
  v_data   JSONB;
  v_want   TEXT;
BEGIN
  -- Setup: Berater-Eintrag wie der Seed ihn aus dem Manifest schreibt. Die Spalte ist die neue Schnittstelle.
  INSERT INTO core.advisors (domain, plan_context, review_fn, package)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'finance');
  EXECUTE $q$UPDATE core.advisors SET plan_validate_fn = 'finance.fn_validate_financial_planning' WHERE domain = 'finance'$q$;
  IF EXISTS (SELECT 1 FROM core.context_validators WHERE context_name = 'financial_planning') THEN
    RAISE EXCEPTION 'FAIL [setup]: financial_planning darf keine context_validators-Zeile haben';
  END IF;

  -- (1) fuenf ungueltige Plaene gehen ueber den echten Speicher-Weg nicht mehr durch
  FOR v_case, v_data, v_want IN
    SELECT * FROM (VALUES
      ('Anteile 90 %',            v_bad_sum,   '%sum to%'),
      ('Block ohne Schluessel',   v_bad_nokey, '%needs a key%'),
      ('alter Notreserve-Block',  v_bad_old,   '%emergency_reserve%'),
      ('drei Ziel-Zahlen',        v_bad_goal,  '%only two of%'),
      ('Risiko-Wert sehr hoch',   v_bad_risk,  '%risk_tolerance%')) AS t(c, d, w)
  LOOP
    v_res := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','plan_name','__test_plan__',
      'section_key','s1','topic','t1','section_content','x','section_data', v_data));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL [setup %]: save_section %', v_case, v_res; END IF;
    v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','finance','check_findings','[]','check_passes',1,'reminders',jsonb_build_array(),'plan_md','# Plan'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE 'plan facts invalid:%'
       OR v_res->>'reason' NOT LIKE v_want THEN
      RAISE EXCEPTION 'FAIL [ungueltig: %]: erwartet ok:false mit "plan facts invalid: ..." (%), got %', v_case, v_want, v_res; END IF;
    SELECT status INTO v_status FROM agent.advisor_plans WHERE domain = 'finance' AND status IN ('draft','active') ORDER BY id DESC LIMIT 1;
    IF v_status IS DISTINCT FROM 'draft' OR EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = 'financial_planning') THEN
      RAISE EXCEPTION 'FAIL [ungueltig: %]: Teil-Write (Status %)', v_case, v_status; END IF;
    RAISE NOTICE 'PASS [ungueltiger Plan abgelehnt: %]', v_case;
  END LOOP;

  -- (2) Probelauf vor der Karte prueft dieselbe Stelle und schreibt nichts
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','finance','section_key','s1','topic','t1',
    'section_content','x','section_data', v_bad_sum));
  v_res := core.fn_dry_run('agent.fn_advisor_publish_plan(jsonb)'::regprocedure,
    jsonb_build_object('domain','finance','check_findings','[]','check_passes',1,'reminders',jsonb_build_array(),'plan_md','# Plan'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [Probelauf]: ungueltiger Plan muss auch im Probelauf abgelehnt werden, got %', v_res; END IF;
  RAISE NOTICE 'PASS [Probelauf lehnt den ungueltigen Plan ebenfalls ab]';

  -- (3) Teilplan (nur Ziel) und danach der gueltige Vollplan werden veroeffentlicht
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','finance','section_key','s1','topic','t1',
    'section_content','x','section_data', v_good_goal));
  v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','finance','check_findings','[]','check_passes',1,'reminders',jsonb_build_array(),'plan_md','# Plan'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [Teilplan]: erwartet ok, got %', v_res; END IF;
  RAISE NOTICE 'PASS [gueltiger Teilplan veroeffentlicht]';

  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','finance','section_key','s1','topic','t1',
    'section_content','x','section_data', v_good_full));
  v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','finance','check_findings','[]','check_passes',1,'reminders',jsonb_build_array(),'plan_md','# Plan v2'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [Vollplan]: erwartet ok, got %', v_res; END IF;
  RAISE NOTICE 'PASS [gueltiger Vollplan veroeffentlicht]';

  -- (4) Netz: ein direkter Write mit ungueltigen Fakten scheitert am Trigger (gleiche Pruefstelle)
  BEGIN
    UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts}', metadata->'facts' || v_bad_sum)
     WHERE name = 'financial_planning';
    RAISE EXCEPTION 'FAIL [Trigger-Netz]: ungueltige Fakten per UPDATE akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg NOT LIKE 'household facts invalid:%sum to%' THEN
      RAISE EXCEPTION 'FAIL [Trigger-Netz]: falsche Meldung: %', v_msg; END IF;
    RAISE NOTICE 'PASS [Trigger lehnt ungueltige Plan-Fakten ab]';
  END;

  -- (5) Altbestand: ein schon gespeicherter ungueltiger Plan blockiert reine Prosa-Writes nicht, das naechste Publish aber
  --     nur, solange der ungueltige Block drin steht (er wird nicht neu geschrieben)
  ALTER TABLE agent.core_contexts DISABLE TRIGGER trg_validate_household_facts;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts}', metadata->'facts' || v_bad_sum)
   WHERE name = 'financial_planning';
  ALTER TABLE agent.core_contexts ENABLE TRIGGER trg_validate_household_facts;
  UPDATE agent.core_contexts SET content = content || E'\n- Notiz' WHERE name = 'financial_planning';
  RAISE NOTICE 'PASS [Prosa-Write an Alt-Plan mit ungueltigen Fakten bleibt moeglich]';
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','finance','section_key','s1','topic','t1',
    'section_content','x','section_data', v_good_goal));
  v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','finance','check_findings','[]','check_passes',1,'reminders',jsonb_build_array(),'plan_md','# Plan v3'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%sum to%' THEN
    RAISE EXCEPTION 'FAIL [Alt-Plan Publish]: alter ungueltiger Block muss das Publish stoppen, got %', v_res; END IF;
  PERFORM agent.fn_advisor_save_section(jsonb_build_object('domain','finance','section_key','s1','topic','t2',
    'section_content','x','section_data', jsonb_build_object('target_allocation', v_good_full->'target_allocation')));
  v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','finance','check_findings','[]','check_passes',1,'reminders',jsonb_build_array(),'plan_md','# Plan v3'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [Alt-Plan korrigiert]: erwartet ok nach neuem Allokations-Block, got %', v_res; END IF;
  RAISE NOTICE 'PASS [Alt-Plan: Publish verlangt den korrigierten Block, danach ok]';

  -- (6) ohne Eintrag im Berater-Feld (NULL) laeuft keine Paket-Pruefung (bisheriges Verhalten, Paket nicht installiert)
  UPDATE core.advisors SET plan_validate_fn = NULL WHERE domain = 'finance';
  IF agent.fn_validate_context_facts(v_bad_sum, 'financial_planning') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [NULL]: ohne plan_validate_fn darf keine Paket-Pruefung laufen'; END IF;
  RAISE NOTICE 'PASS [plan_validate_fn NULL -> keine Paket-Pruefung]';
END $$;

ROLLBACK;
