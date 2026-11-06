-- tests/db/finance/test_v039_plan_section_key_rename.sql
-- finance:V039: gespeicherte Plan-Abschnitte wandern auf den Schluessel 'crossborder'. Der Test baut den Altzustand in
-- der Test-Tx nach (Schluessel mit Suffix '_crossborder') und fuehrt die ECHTE Migration zweimal aus (zweiter Lauf =
-- No-op). Geprueft: draft, active und superseded; Inhalt, status und version bleiben; der neue Schluessel gewinnt, wenn
-- beide im selben Plan stehen; andere Domains und andere Schluessel bleiben unberuehrt.
BEGIN;

DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');
INSERT INTO agent.advisor_plans (domain, plan_name, status, version, interview_state) VALUES
    ('finance', 'alt', 'superseded', 1,
     '{"altland_crossborder":{"content":"v1","data":{},"saved_at":"2026-01-01"},"debts_loans":{"content":"d1"}}'),
    ('finance', 'aktiv', 'active', 2,
     '{"altland_crossborder":{"content":"v2","data":{"x":1},"saved_at":"2026-02-02"},"goals_triggers":{"content":"g2"}}'),
    ('finance', 'entwurf', 'draft', 3,
     '{"altland_crossborder":{"content":"alt"},"crossborder":{"content":"neu"},"risk_profile":{"content":"r3"}}'),
    ('career', 'andere Domain', 'draft', 1,
     '{"altland_crossborder":{"content":"bleibt"}}');

\ir ../../../packages/finance/db/migrations/V039__plan_section_key_rename.sql

CREATE TEMP TABLE t_v039_first ON COMMIT DROP AS
SELECT id, interview_state::text AS st FROM agent.advisor_plans;

\ir ../../../packages/finance/db/migrations/V039__plan_section_key_rename.sql

DO $$
DECLARE
  v_st jsonb;
BEGIN
  -- (1) superseded: Schluessel neu, Inhalt komplett erhalten, status + version unveraendert
  SELECT interview_state INTO v_st FROM agent.advisor_plans
   WHERE domain = 'finance' AND status = 'superseded' AND version = 1;
  IF v_st IS DISTINCT FROM '{"crossborder":{"content":"v1","data":{},"saved_at":"2026-01-01"},"debts_loans":{"content":"d1"}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [V039 superseded]: %', v_st; END IF;

  -- (2) active: ebenso, samt data
  SELECT interview_state INTO v_st FROM agent.advisor_plans
   WHERE domain = 'finance' AND status = 'active' AND version = 2;
  IF v_st IS DISTINCT FROM '{"crossborder":{"content":"v2","data":{"x":1},"saved_at":"2026-02-02"},"goals_triggers":{"content":"g2"}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [V039 active]: %', v_st; END IF;

  -- (3) draft mit beiden Schluesseln: der neue gewinnt, der alte ist weg
  SELECT interview_state INTO v_st FROM agent.advisor_plans
   WHERE domain = 'finance' AND status = 'draft' AND version = 3;
  IF v_st IS DISTINCT FROM '{"crossborder":{"content":"neu"},"risk_profile":{"content":"r3"}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [V039 draft]: %', v_st; END IF;

  -- (4) andere Domain unberuehrt
  SELECT interview_state INTO v_st FROM agent.advisor_plans WHERE domain = 'career';
  IF v_st IS DISTINCT FROM '{"altland_crossborder":{"content":"bleibt"}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [V039 andere Domain]: %', v_st; END IF;

  -- (5) zweiter Lauf aendert nichts
  IF EXISTS (SELECT 1 FROM agent.advisor_plans p JOIN t_v039_first f USING (id) WHERE p.interview_state::text <> f.st) THEN
    RAISE EXCEPTION 'FAIL [V039 zweiter Lauf]'; END IF;

  -- (6) fn_plan_gaps sieht den uebernommenen Abschnitt als bestaetigt
  IF finance.fn_plan_gaps('{}'::jsonb)->'open_sections' @> '["crossborder"]'::jsonb
     OR finance.fn_plan_gaps('{}'::jsonb)->'draft_only_sections' @> '["crossborder"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [V039 Plan-Luecke]: %', finance.fn_plan_gaps('{}'::jsonb); END IF;

  RAISE NOTICE 'PASS finance:V039 [draft/active/superseded uebernommen, Inhalt + Status bleiben, neuer Schluessel gewinnt, 2 Laeufe]';
END $$;

ROLLBACK;
