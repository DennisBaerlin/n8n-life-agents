-- tests/db/finance/test_fn_plan_gaps.sql
-- Plan-Luecken (2026-10-27): finance.fn_plan_gaps meldet bei AKTIVEM Haushalts-Plan die nie im Interview bestaetigten
-- Katalog-Sektionen (Union ueber active + superseded), die bestaetigten Sektionen ohne verwertbaren Fakten-Block und
-- die nur im offenen Draft gespeicherten Sektionen; finance.fn_render_plan_facts zeigt daraus die Header-Zeile
-- "Plan gaps:" (auch bei leerem Sidecar). Live-Anlass: Import-Plan, nur 3 von 9 Sektionen bestaetigt, kein Notreserve-Ziel.
BEGIN;

DO $$
DECLARE
  v   jsonb;
  v_h text;
BEGIN
  -- Fixture-unabhaengig: eigener finance-Plan-Stand (das Substrat seedet einen Plan mit gold_strategy)
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', '__e2e_finance__');
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'fix', NULL, 'lazy', E'## Plan Prosa',
          jsonb_build_object('managed_by','agent','facts','{}'::jsonb))
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, metadata = EXCLUDED.metadata, load_strategy = 'lazy';

  -- ---------- (1) kein Plan -> keine Luecken, keine Header-Zeile ----------
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF (v->>'has_active_plan')::boolean IS DISTINCT FROM false OR v->'open_sections' <> '[]'::jsonb
     OR v->'missing_blocks' <> '[]'::jsonb OR v->'draft_only_sections' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [kein Plan]: %', v; END IF;
  IF finance.fn_render_plan_facts('financial_planning') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [kein Plan, Header]: %', finance.fn_render_plan_facts('financial_planning'); END IF;

  -- ---------- (2) nur Draft -> Resume-Pfad, keine Luecken-Meldung ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
  VALUES ('finance', NULL, 'Entwurf', 'draft', 1,
          '{"risk_protection":{"content":"x","saved_at":"2026-10-01T10:00:00Z"}}');
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF (v->>'has_active_plan')::boolean OR v->'open_sections' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [nur Draft]: %', v; END IF;
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';

  -- ---------- (3) Live-Form: Import v1 (leer) superseded + v2 active mit 3 Sektionen, Sidecar ohne Notreserve ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Import', 'superseded', 1, '{}', 'alt'),
         ('finance', NULL, 'Plan', 'active', 2,
          '{"goals_triggers":{"content":"x","data":{"goal":{}}},"risk_profile":{"content":"x","data":{"risk_profile":{}}},
            "wealth_building":{"content":"x","data":{"target_allocation":{},"glidepath":{}}}}', 'neu');
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('managed_by','agent','facts', jsonb_build_object(
      'goal', jsonb_build_object('target_income_eur_month',3000,'withdrawal_rate_pct',4),
      'risk_profile', jsonb_build_object('risk_tolerance','medium'),
      'target_allocation', jsonb_build_object('blocks','[]'::jsonb),
      'glidepath', jsonb_build_object('start_age',54)))
   WHERE name = 'financial_planning';
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  -- Katalog-Reihenfolge, emergency_reserve nur EINMAL (als offene Sektion, nicht zusaetzlich als fehlender Block)
  IF v->'open_sections' <> '["household_basics","risk_protection","emergency_reserve","debts_loans","retirement_pension","korea_crossborder"]'::jsonb
     OR v->'missing_blocks' <> '[]'::jsonb OR NOT (v->>'has_active_plan')::boolean THEN
    RAISE EXCEPTION 'FAIL [Live-Form]: %', v; END IF;

  -- ---------- (4) Union: eine Sektion aus einer FRUEHEREN Version zaehlt als bestaetigt ----------
  UPDATE agent.advisor_plans SET interview_state = '{"risk_protection":{"content":"x"},"household_basics":{"content":"x"}}'
   WHERE domain = 'finance' AND version = 1;
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF v->'open_sections' <> '["emergency_reserve","debts_loans","retirement_pension","korea_crossborder"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Union superseded]: %', v; END IF;
  -- Altlast: interview_state ohne Objekt-Form zaehlt als leer, nie RAISE (Render-Pfad von load_context)
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Altlast', 'superseded', 0 + 9, '"kaputt"', 'alt');
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF v->'open_sections' <> '["emergency_reserve","debts_loans","retirement_pension","korea_crossborder"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Altlast skalar]: %', v; END IF;

  -- ---------- (5) bestaetigt, aber Block fehlt; Notreserve-Sektion bestaetigt ohne angelegte Ruecklage (2026-10-30) ----------
  UPDATE agent.advisor_plans
     SET interview_state = interview_state || '{"emergency_reserve":{"content":"x"}}'
   WHERE domain = 'finance' AND status = 'active';
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF v->'missing_blocks' <> '[{"section":"emergency_reserve","block":"emergency_reserve"}]'::jsonb OR v->'open_sections' ? 'emergency_reserve' THEN
    RAISE EXCEPTION 'FAIL [Notreserve nicht angelegt]: %', v; END IF;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts}', (metadata->'facts') - 'glidepath')
   WHERE name = 'financial_planning';
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF v->'missing_blocks' <> '[{"section":"emergency_reserve","block":"emergency_reserve"},{"section":"wealth_building","block":"glidepath"}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Block fehlt]: %', v; END IF;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts}', (metadata->'facts')
         || '{"glidepath":{"start_age":54}}')
   WHERE name = 'financial_planning';
  -- Notreserve als Ruecklage angelegt -> keine Luecke mehr
  INSERT INTO finance.savings_goals (name, kind, target_months, status) VALUES ('__pg_er__', 'emergency_reserve', 6, 'active');

  -- ---------- (6) Draft-Sektion getrennt ausgewiesen (gespeichert, nur noch zu publizieren -> nicht zusaetzlich offen) ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
  VALUES ('finance', NULL, 'Entwurf', 'draft', 3, '{"debts_loans":{"content":"x"},"risk_profile":{"content":"x"}}');
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF v->'draft_only_sections' <> '["debts_loans"]'::jsonb
     OR v->'open_sections' <> '["retirement_pension","korea_crossborder"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [Draft-only]: %', v; END IF;

  -- ---------- (7) Sentinel-Domain und per_user-Zeilen zaehlen nicht ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('__e2e_finance__', NULL, 'E2E', 'active', 1, '{"retirement_pension":{"content":"x"}}', 'e2e');
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF NOT (v->'open_sections' ? 'retirement_pension') THEN
    RAISE EXCEPTION 'FAIL [Sentinel]: %', v; END IF;

  -- ---------- (8) Header-Zeile: englisch, alle drei Teile ----------
  v_h := finance.fn_render_plan_facts('financial_planning');
  IF v_h NOT LIKE '%Plan gaps: never confirmed in an interview: retirement_pension, korea_crossborder; saved in the draft, not yet published: debts_loans%' THEN
    RAISE EXCEPTION 'FAIL [Header]: %', v_h; END IF;

  -- ---------- (9) vollstaendig -> leer, keine Header-Zeile ----------
  DELETE FROM agent.advisor_plans WHERE domain = 'finance' AND status = 'draft';
  UPDATE agent.advisor_plans
     SET interview_state = interview_state || '{"debts_loans":{"content":"x"},"retirement_pension":{"content":"x"},"korea_crossborder":{"content":"x"}}'
   WHERE domain = 'finance' AND status = 'active';
  v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
  IF v->'open_sections' <> '[]'::jsonb OR v->'missing_blocks' <> '[]'::jsonb OR v->'draft_only_sections' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [vollstaendig]: %', v; END IF;
  IF finance.fn_render_plan_facts('financial_planning') LIKE '%Plan gaps%' THEN
    RAISE EXCEPTION 'FAIL [vollstaendig, Header]'; END IF;

  -- ---------- (10) leerer Sidecar + aktiver Plan -> NUR die Luecken-Zeile (keine Renten-/Fakten-Zeilen) ----------
  UPDATE agent.advisor_plans SET interview_state = '{}' WHERE domain = 'finance';
  DELETE FROM finance.savings_goals WHERE name = '__pg_er__';   -- angelegte Notreserve haette eine eigene Fakten-Zeile
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('managed_by','agent','facts','{}'::jsonb)
   WHERE name = 'financial_planning';
  v_h := finance.fn_render_plan_facts('financial_planning');
  IF v_h IS DISTINCT FROM '- Plan gaps: never confirmed in an interview: household_basics, risk_protection, emergency_reserve, debts_loans, retirement_pension, risk_profile, wealth_building, korea_crossborder, goals_triggers' THEN
    RAISE EXCEPTION 'FAIL [leerer Sidecar]: %', v_h; END IF;

  RAISE NOTICE 'PASS fn_plan_gaps (kein Plan/Draft still, Union ueber Versionen, Block ohne Zahl, Draft getrennt, Sentinel aussen, Header-Zeile)';
END $$;

ROLLBACK;
