-- tests/db/core/test_fn_note_context_allowed.sql
-- Phase A: core.fn_note_context_allowed(name) — Prosa-Lern-Notizen nur in 'family' ODER im Plan-Dokument einer
-- Advisor-Domaene mit core.advisors.learn_notes=true und AKTIVEM Paket; immer nur managed_by='agent'. Ersetzt die
-- Literal-Liste family/financial_planning.
BEGIN;

DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package)
  VALUES ('__t_plan_on__',  'x', 'lazy', '# Plan', 'agent', 'tpkg'),
         ('__t_plan_off__', 'x', 'lazy', '# Plan', 'agent', 'tpkg'),
         ('__t_plan_seed__','x', 'lazy', '# Plan', 'seed',  'tpkg');
  INSERT INTO core.package_registry (package, status) VALUES ('tpkg', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.advisors (domain, plan_context, review_fn, package, learn_notes) VALUES
    ('__t_on__',   '__t_plan_on__',   'tpkg.fn_review', 'tpkg', true),
    ('__t_off__',  '__t_plan_off__',  'tpkg.fn_review', 'tpkg', false),
    ('__t_seed__', '__t_plan_seed__', 'tpkg.fn_review', 'tpkg', true);

  IF NOT core.fn_note_context_allowed('__t_plan_on__') THEN
    RAISE EXCEPTION 'FAIL [learn_notes=true]: erwartet erlaubt'; END IF;
  IF core.fn_note_context_allowed('__t_plan_off__') THEN
    RAISE EXCEPTION 'FAIL [learn_notes=false]: erwartet abgelehnt (Default fail-closed)'; END IF;
  IF core.fn_note_context_allowed('__t_plan_seed__') THEN
    RAISE EXCEPTION 'FAIL [managed_by=seed]: Instruktions-/Seed-Kontext darf nie Notizen bekommen'; END IF;
  IF core.fn_note_context_allowed('__nope__') THEN
    RAISE EXCEPTION 'FAIL [unbekannt]: erwartet abgelehnt'; END IF;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'tpkg';
  IF core.fn_note_context_allowed('__t_plan_on__') THEN
    RAISE EXCEPTION 'FAIL [Paket inaktiv]: erwartet abgelehnt'; END IF;
  RAISE NOTICE 'PASS fn_note_context_allowed [learn_notes-Opt-in, Default aus, seed nie, Paket aktiv]';
END $$;

ROLLBACK;
