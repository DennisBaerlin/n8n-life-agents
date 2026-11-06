-- tests/db/finance/test_v028_plan_goal_two_of_three.sql
-- finance:V028 (WP2): ein Finanzplan-Ziel mit Einkommen + Entnahmerate + Zielportfolio verliert das ableitbare
-- Zielportfolio (Owner-Entscheid: Einkommen + Rate bleiben); fehlt einer der beiden, bleibt alles stehen. Der Test
-- fuehrt die ECHTE Migrationsdatei zweimal aus. Der neue Validator wuerde den Altbestand ablehnen -> der Test schaltet
-- den Fakten-Trigger fuer den Aufbau ab (der Altbestand entstand vor der Regel).
BEGIN;

ALTER TABLE agent.core_contexts DISABLE TRIGGER USER;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('financial_planning', 'test', NULL, 'lazy', 'x', 'agent', 'finance',
        jsonb_build_object('facts', jsonb_build_object('goal', jsonb_build_object(
            'target_income_eur_month', 2500, 'withdrawal_rate_pct', 4, 'target_portfolio_eur', jsonb_build_array(750000, 850000),
            'target_portfolio_basis', 'investment', 'terms', 'real'))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
ALTER TABLE agent.core_contexts ENABLE TRIGGER USER;

\ir ../../../packages/finance/db/migrations/V028__plan_goal_two_of_three.sql
\ir ../../../packages/finance/db/migrations/V028__plan_goal_two_of_three.sql

DO $$
DECLARE v_goal jsonb;
BEGIN
  SELECT metadata->'facts'->'goal' INTO v_goal FROM agent.core_contexts WHERE name = 'financial_planning';
  IF v_goal ? 'target_portfolio_eur' OR (v_goal->>'target_income_eur_month')::numeric <> 2500
     OR (v_goal->>'withdrawal_rate_pct')::numeric <> 4 OR v_goal->>'target_portfolio_basis' IS DISTINCT FROM 'investment' THEN
    RAISE EXCEPTION 'FAIL [V028]: got %', v_goal; END IF;
  -- abgeleitet: 2.500 x 12 / 4 % = 750.000
  IF (finance.fn_plan_goal_resolved(v_goal)->>'target_portfolio_eur')::numeric IS DISTINCT FROM 750000 THEN
    RAISE EXCEPTION 'FAIL [V028 abgeleitet]: %', finance.fn_plan_goal_resolved(v_goal); END IF;
  RAISE NOTICE 'PASS finance:V028 (Zielportfolio entfernt, Einkommen + Rate bleiben, abgeleitet 750.000, 2 Laeufe)';
END $$;

ROLLBACK;
