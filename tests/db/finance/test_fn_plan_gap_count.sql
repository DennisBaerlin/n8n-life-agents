-- tests/db/finance/test_fn_plan_gap_count.sql
-- finance.fn_plan_gap_count(domain, person_id) = Anzahl offener Punkte am aktiven Haushalts-Finanzplan, gerechnet aus
-- der einen Adresse finance.fn_plan_gaps (nie bestaetigte Sektionen + fehlende Bloecke + nur im Draft) ueber die
-- Fakten des Sidecars financial_planning. Ohne aktiven Plan 0 (dann ist der Zustand "kein Plan"/"Entwurf").
-- Registry-Feld core.advisors.gaps_fn (Onboarding-Plan-Schritt "Finanzplan vervollstaendigen (n offen)").
BEGIN;

DO $$
DECLARE n int;
BEGIN
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'fix', NULL, 'lazy', E'## Plan', jsonb_build_object('managed_by','agent','facts','{}'::jsonb))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- (1) kein Plan -> 0
  n := finance.fn_plan_gap_count('finance', NULL);
  IF n IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [kein Plan]: %', n; END IF;

  -- (2) aktiver Plan mit 3 bestaetigten Sektionen, Sidecar mit allen drei Bloecken dieser Sektionen
  --     -> 6 nie bestaetigte Sektionen (Katalog 9 - 3), keine fehlenden Bloecke
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Plan', 'active', 1,
          '{"goals_triggers":{"content":"x"},"risk_profile":{"content":"x"},"wealth_building":{"content":"x"}}', 'p');
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('managed_by','agent','facts', jsonb_build_object(
      'goal', '{}'::jsonb, 'risk_profile', '{}'::jsonb, 'target_allocation', '{}'::jsonb, 'glidepath', '{}'::jsonb))
   WHERE name = 'financial_planning';
  n := finance.fn_plan_gap_count('finance', NULL);
  IF n IS DISTINCT FROM 6 THEN RAISE EXCEPTION 'FAIL [6 offen]: %', n; END IF;

  -- (3) fehlender Block zaehlt mit: glidepath raus -> 7
  UPDATE agent.core_contexts SET metadata = metadata #- '{facts,glidepath}' WHERE name = 'financial_planning';
  n := finance.fn_plan_gap_count('finance', NULL);
  IF n IS DISTINCT FROM 7 THEN RAISE EXCEPTION 'FAIL [+ fehlender Block]: %', n; END IF;

  -- (4) eine Sektion nur im Draft bleibt ein offener Punkt (muss noch veroeffentlicht werden) -> weiter 7
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
  VALUES ('finance', NULL, 'Entwurf', 'draft', 2, '{"household_basics":{"content":"x"}}');
  n := finance.fn_plan_gap_count('finance', NULL);
  IF n IS DISTINCT FROM 7 THEN RAISE EXCEPTION 'FAIL [Draft-only zaehlt]: %', n; END IF;

  RAISE NOTICE 'PASS test_fn_plan_gap_count (kein Plan 0, offene Sektionen + fehlende Bloecke + Draft-only)';
END $$;

ROLLBACK;
