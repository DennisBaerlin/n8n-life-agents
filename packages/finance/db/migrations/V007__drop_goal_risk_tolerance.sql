-- ============================================================
-- V007 (finance) — Phase A: das Alt-Feld goal.risk_tolerance aus dem financial_planning-Fakten-Sidecar
--   entfernen (Owner-Direktive 2026-06-24).
--
--   risk_tolerance ist in den eigenen risk_profile-Block UMGEZOGEN (one-fact-one-home; datiert, MiFID-
--   Dimensionen Bereitschaft+Tragfaehigkeit). Niemand konsumiert goal.risk_tolerance mehr; fn_render_plan_
--   facts rendert es nicht mehr. Owner-Wunsch: NICHT inert liegen lassen ("bringt sonst nur Verwirrung")
--   -> hier einmalig aus bestehenden Plaenen strippen.
--
--   WARUM eine V (nicht der Seed-Util): der Seed-Util-Merge (util_seed_financial_planning_facts.sql) ist
--   ADDITIV (jsonb ||) -> er entfernt nie einen Key. Diese V ist der deterministische, deploy-automatische
--   Loeschpfad (Substrat -Reset + Prod provision.sh/update), genau einmal gegated ueber
--   core.migration_should_apply.
--
--   IDEMPOTENT/SICHER: nur wenn die financial_planning-Zeile den Key traegt (WHERE ... ? 'risk_tolerance').
--   Fresh-DB = keine financial_planning-Zeile -> no-op. Kein BEGIN/COMMIT (der db_apply/apply_schema-Treiber
--   wrapt). Der BEFORE-UPDATE-Faktenvalidator laeuft mit: goal-minus-risk_tolerance bleibt gueltig (der
--   Validator prueft risk_tolerance ohnehin nicht; das Entfernen eines Keys trippt keine Denylist).
-- ============================================================

UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,goal}', (metadata->'facts'->'goal') - 'risk_tolerance')
WHERE name = 'financial_planning'
  AND jsonb_typeof(metadata->'facts'->'goal') = 'object'
  AND (metadata->'facts'->'goal') ? 'risk_tolerance';
